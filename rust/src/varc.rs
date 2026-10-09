//! Resolves the components a `VARC` glyph is drawn from.
//!
//! A `VARC` (variable composite) glyph owns no outline: it is a list of other
//! glyphs, each with its own transform, its own position in variation space and
//! optionally a condition that decides whether it is drawn at all. Reading it
//! is what a client needs to draw, hit test or analyse such a glyph, since
//! asking for its outline already flattens all of that away.

use anyhow::{anyhow, Result};
use read_fonts::tables::layout::Condition;
use read_fonts::tables::varc::Varc;
use read_fonts::types::{F2Dot14, GlyphId};

use crate::api::fontations::{VarcComponentInfo, VarcGlyphInfo};

/// The components of `glyph`, in the order they are drawn.
///
/// `coords` are normalized variation coordinates, already through `avar` and
/// `avar2`; they decide which conditions hold.
pub fn components(varc: &Varc<'_>, glyph: GlyphId, coords: &[F2Dot14]) -> Result<VarcGlyphInfo> {
    let Some(index) = varc
        .coverage()
        .ok()
        .and_then(|coverage| coverage.get(glyph))
    else {
        // Not a composite glyph: nothing is drawn from parts.
        return Ok(VarcGlyphInfo {
            components: Vec::new(),
        });
    };
    let varc_glyph = varc
        .glyph(index as usize)
        .map_err(|e| anyhow!("failed to read VARC glyph {glyph}: {e}"))?;

    let mut components = Vec::new();
    for component in varc_glyph.components() {
        let component =
            component.map_err(|e| anyhow!("failed to read a VARC component of {glyph}: {e}"))?;
        components.push(describe(varc, &component, coords));
    }
    Ok(VarcGlyphInfo { components })
}

fn describe(
    varc: &Varc<'_>,
    component: &read_fonts::tables::varc::VarcComponent<'_>,
    coords: &[F2Dot14],
) -> VarcComponentInfo {
    let condition_met = match component.condition_index() {
        Some(index) => match condition(varc, index) {
            Some(condition) => evaluate(&condition, coords),
            // A component whose condition cannot be read is drawn: dropping it
            // would silently change the shape of the glyph.
            None => true,
        },
        None => true,
    };

    let matrix = component.transform().matrix();
    let axis_indices = match component.axis_indices_index() {
        Some(index) => varc
            .axis_indices(index as usize)
            .map(|deltas| deltas.iter().map(|value| value.max(0) as u32).collect())
            .unwrap_or_default(),
        None => Vec::new(),
    };
    // The axis values are the coordinates the component is drawn at, in the
    // axes named by `axis_indices`. They are stored as `F2Dot14` bits.
    let axis_values = component
        .axis_values()
        .map(|deltas| {
            deltas
                .iter()
                .map(|value| F2Dot14::from_bits(value as i16).to_f32() as f64)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();

    VarcComponentInfo {
        glyph_id: component.gid().to_u32(),
        condition_met,
        transform: vec![
            matrix.xx as f64,
            matrix.yx as f64,
            matrix.xy as f64,
            matrix.yy as f64,
            matrix.dx as f64,
            matrix.dy as f64,
        ],
        axis_indices,
        axis_values,
    }
}

/// The condition at `index` of the table's condition list.
fn condition<'a>(varc: &'a Varc<'a>, index: u32) -> Option<Condition<'a>> {
    let list = varc.condition_list()?.ok()?;
    list.conditions().get(index as usize).ok()
}

/// Whether `condition` holds at `coords`.
fn evaluate(condition: &Condition<'_>, coords: &[F2Dot14]) -> bool {
    match condition {
        Condition::Format1AxisRange(format) => {
            let coord = coords
                .get(format.axis_index() as usize)
                .copied()
                .unwrap_or(F2Dot14::ZERO);
            coord >= format.filter_range_min_value() && coord <= format.filter_range_max_value()
        }
        // Format 2 needs the value of an item variation store entry, and its
        // `default_value` is the value at the default location.
        Condition::Format2VariableValue(_) => true,
        Condition::Format3And(format) => format
            .conditions()
            .iter()
            .flatten()
            .all(|condition| evaluate(&condition, coords)),
        Condition::Format4Or(format) => format
            .conditions()
            .iter()
            .flatten()
            .any(|condition| evaluate(&condition, coords)),
        Condition::Format5Negate(format) => format
            .condition()
            .map(|condition| !evaluate(&condition, coords))
            .unwrap_or(false),
    }
}
