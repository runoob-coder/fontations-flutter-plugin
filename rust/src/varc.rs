//! Resolves the components a `VARC` glyph is drawn from.
//!
//! A `VARC` (variable composite) glyph owns no outline: it is a list of other
//! glyphs, each with its own transform, its own position in variation space and
//! optionally a condition that decides whether it is drawn at all. Reading it
//! is what a client needs to draw, hit test or analyse such a glyph, since
//! asking for its outline already flattens all of that away.

use anyhow::{anyhow, Result};
use read_fonts::tables::layout::Condition;
use read_fonts::tables::varc::{
    DecomposedTransform, MultiItemVariationStore, SparseVariationRegionList, Varc, VarcComponent,
    VarcFlags,
};
use read_fonts::tables::variations::NO_VARIATION_INDEX;
use read_fonts::types::{F2Dot14, GlyphId};

use crate::api::fontations::{VarcComponentInfo, VarcGlyphInfo};
use crate::limits::{ConditionBudget, MAX_CONDITION_DEPTH, MAX_VARC_AXES, MAX_VARC_COMPONENTS};

/// The components of `glyph`, in the order they are drawn.
///
/// `coords` are normalized variation coordinates, already through `avar` and
/// `avar2`; they decide which conditions hold.
///
/// Component counts, axis arrays and condition trees are all font controlled.
/// Every one of them is bounded here, and the condition budget is shared by the
/// whole glyph rather than reset per component.
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

    // A VARC table may carry a MultiItemVariationStore: conditions of format 2
    // and variable transforms / axis coordinates all resolve through it.
    let store = varc.multi_var_store().transpose().ok().flatten();
    let regions = store.as_ref().and_then(|store| store.region_list().ok());

    let mut budget = ConditionBudget::default();
    let mut components = Vec::new();
    for (position, component) in varc_glyph.components().enumerate() {
        if position >= MAX_VARC_COMPONENTS {
            return Err(anyhow!(
                "VARC glyph {glyph} has more than {MAX_VARC_COMPONENTS} components"
            ));
        }
        let component =
            component.map_err(|e| anyhow!("failed to read a VARC component of {glyph}: {e}"))?;
        components.push(describe(
            varc,
            &component,
            coords,
            store.as_ref(),
            regions.as_ref(),
            &mut budget,
        ));
    }
    Ok(VarcGlyphInfo { components })
}

/// Resolves one variation index to a tuple of interpolated deltas.
///
/// `VARC` uses a *sparse* item variation store: each region lists only the axes
/// it acts on, and every row holds `tuple_len` deltas per region. Missing data
/// is reported as `None` so the caller can keep the unvaried value.
fn store_deltas(
    store: Option<&MultiItemVariationStore<'_>>,
    regions: Option<&SparseVariationRegionList<'_>>,
    coords: &[F2Dot14],
    var_index: u32,
    tuple_len: usize,
) -> Option<Vec<f64>> {
    if tuple_len == 0 || var_index == NO_VARIATION_INDEX {
        return Some(vec![0.0; tuple_len]);
    }
    let store = store?;
    let regions = regions?;
    let data = store
        .variation_data()
        .get((var_index >> 16) as usize)
        .ok()?;
    let raw: Vec<i32> = data
        .delta_set((var_index & 0xFFFF) as usize)
        .ok()?
        .iter()
        .collect();
    let mut out = vec![0.0f64; tuple_len];
    let mut cursor = 0usize;
    for index in data.region_indices() {
        let scalar = regions
            .regions()
            .get(index.get() as usize)
            .ok()?
            .compute_scalar_f32(coords) as f64;
        for slot in out.iter_mut() {
            *slot += raw.get(cursor).copied().unwrap_or(0) as f64 * scalar;
            cursor += 1;
        }
    }
    Some(out)
}

/// Adds the transform deltas in flag order, exactly as the VARC spec stores
/// them. Rotation and scale/skew deltas are fixed point, translations are not.
fn apply_transform_deltas(
    component: &VarcComponent<'_>,
    transform: &mut DecomposedTransform,
    deltas: &[f64],
) {
    let flags = component.flags();
    let mut next = deltas.iter().map(|delta| *delta as f32);
    if flags.contains(VarcFlags::HAVE_TRANSLATE_X) {
        transform.set_translate_x(transform.translate_x() + next.next().unwrap_or(0.0));
    }
    if flags.contains(VarcFlags::HAVE_TRANSLATE_Y) {
        transform.set_translate_y(transform.translate_y() + next.next().unwrap_or(0.0));
    }
    if flags.contains(VarcFlags::HAVE_ROTATION) {
        transform.set_rotation(transform.rotation() + next.next().unwrap_or(0.0) / 4096.0);
    }
    if flags.contains(VarcFlags::HAVE_SCALE_X) {
        transform.set_scale_x(transform.scale_x() + next.next().unwrap_or(0.0) / 1024.0);
    }
    if flags.contains(VarcFlags::HAVE_SCALE_Y) {
        transform.set_scale_y(transform.scale_y() + next.next().unwrap_or(0.0) / 1024.0);
    }
    if flags.contains(VarcFlags::HAVE_SKEW_X) {
        transform.set_skew_x(transform.skew_x() + next.next().unwrap_or(0.0) / 4096.0);
    }
    if flags.contains(VarcFlags::HAVE_SKEW_Y) {
        transform.set_skew_y(transform.skew_y() + next.next().unwrap_or(0.0) / 4096.0);
    }
    if flags.contains(VarcFlags::HAVE_TCENTER_X) {
        transform.set_center_x(transform.center_x() + next.next().unwrap_or(0.0));
    }
    if flags.contains(VarcFlags::HAVE_TCENTER_Y) {
        transform.set_center_y(transform.center_y() + next.next().unwrap_or(0.0));
    }
    if !flags.contains(VarcFlags::HAVE_SCALE_Y) {
        transform.set_scale_y(transform.scale_x());
    }
}

fn describe(
    varc: &Varc<'_>,
    component: &VarcComponent<'_>,
    coords: &[F2Dot14],
    store: Option<&MultiItemVariationStore<'_>>,
    regions: Option<&SparseVariationRegionList<'_>>,
    budget: &mut ConditionBudget,
) -> VarcComponentInfo {
    let mut delta = |index: u32| -> Option<f64> {
        store_deltas(store, regions, coords, index, 1).and_then(|values| values.first().copied())
    };
    let condition_met = match component.condition_index() {
        Some(index) => match condition(varc, index) {
            Some(condition) => evaluate(&condition, coords, 0, budget, &mut delta),
            // Draw a component whose condition cannot be read.
            None => true,
        },
        None => true,
    };

    let mut transform = *component.transform();
    if let Some(index) = component.transform_var_index() {
        // The tuple has one delta per transform field the component stores.
        let count = transform_field_count(component.flags());
        if let Some(deltas) = store_deltas(store, regions, coords, index, count) {
            apply_transform_deltas(component, &mut transform, &deltas);
        }
    }
    let matrix = transform.matrix();

    let axis_indices = match component.axis_indices_index() {
        Some(index) => varc
            .axis_indices(index as usize)
            .map(|deltas| {
                deltas
                    .iter()
                    .take(MAX_VARC_AXES)
                    .map(|value| value.max(0) as u32)
                    .collect()
            })
            .unwrap_or_default(),
        None => Vec::new(),
    };
    // Component coordinates in the `axis_indices` axes are packed F2Dot14
    // bits; their variation deltas are in the same raw unit.
    let mut axis_values: Vec<f64> = component
        .axis_values()
        .map(|deltas| {
            deltas
                .iter()
                .take(MAX_VARC_AXES)
                .map(|value| value as f64)
                .collect()
        })
        .unwrap_or_default();
    if let Some(index) = component.axis_values_var_index() {
        if let Some(deltas) = store_deltas(store, regions, coords, index, axis_values.len()) {
            for (value, delta) in axis_values.iter_mut().zip(deltas) {
                *value += delta;
            }
        }
    }
    let axis_values = axis_values
        .iter()
        .map(|value| {
            let bits = value.round().clamp(i16::MIN as f64, i16::MAX as f64) as i16;
            F2Dot14::from_bits(bits).to_f32() as f64
        })
        .collect();

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

/// How many transform fields the component stores, in the order the deltas
/// are packed.
fn transform_field_count(flags: VarcFlags) -> usize {
    const FIELDS: &[VarcFlags] = &[
        VarcFlags::HAVE_TRANSLATE_X,
        VarcFlags::HAVE_TRANSLATE_Y,
        VarcFlags::HAVE_ROTATION,
        VarcFlags::HAVE_SCALE_X,
        VarcFlags::HAVE_SCALE_Y,
        VarcFlags::HAVE_SKEW_X,
        VarcFlags::HAVE_SKEW_Y,
        VarcFlags::HAVE_TCENTER_X,
        VarcFlags::HAVE_TCENTER_Y,
    ];
    FIELDS.iter().filter(|flag| flags.contains(**flag)).count()
}

/// The condition at `index` of the table's condition list.
fn condition<'a>(varc: &'a Varc<'a>, index: u32) -> Option<Condition<'a>> {
    let list = varc.condition_list()?.ok()?;
    // A null offset means unconditional, not a format 0 table.
    if list
        .condition_offsets()
        .get(index as usize)?
        .get()
        .is_null()
    {
        return None;
    }
    list.conditions().get(index as usize).ok()
}

/// Whether `condition` holds at `coords`.
///
/// `depth` and `budget` bound the whole condition tree. A malformed condition
/// list can nest arbitrarily or point back at itself, and Rust aborts the
/// process on stack overflow, so neither can be left unbounded. When a bound
/// is reached the condition is treated as satisfied: drawing the component is
/// the conservative choice, since dropping it changes the glyph's shape.
fn evaluate(
    condition: &Condition<'_>,
    coords: &[F2Dot14],
    depth: u32,
    budget: &mut ConditionBudget,
    delta: &mut dyn FnMut(u32) -> Option<f64>,
) -> bool {
    if depth > MAX_CONDITION_DEPTH || !budget.spend() {
        return true;
    }
    match condition {
        Condition::Format1AxisRange(format) => {
            let coord = coords
                .get(format.axis_index() as usize)
                .copied()
                .unwrap_or(F2Dot14::ZERO);
            coord >= format.filter_range_min_value() && coord <= format.filter_range_max_value()
        }
        // Format 2 compares a default value plus its variation delta to zero.
        Condition::Format2VariableValue(format) => {
            let index = format.var_index();
            let adjustment = if index == NO_VARIATION_INDEX {
                0.0
            } else {
                delta(index).unwrap_or(0.0)
            };
            f64::from(format.default_value()) + adjustment > 0.0
        }
        Condition::Format3And(format) => format
            .conditions()
            .iter()
            .flatten()
            .all(|condition| evaluate(&condition, coords, depth + 1, budget, delta)),
        Condition::Format4Or(format) => format
            .conditions()
            .iter()
            .flatten()
            .any(|condition| evaluate(&condition, coords, depth + 1, budget, delta)),
        Condition::Format5Negate(format) => format
            .condition()
            .map(|condition| !evaluate(&condition, coords, depth + 1, budget, delta))
            .unwrap_or(false),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    use read_fonts::types::GlyphId16;
    use read_fonts::{FontData, FontRead};
    use write_fonts::dump_table;
    use write_fonts::tables::layout::{
        Condition as WriteCondition, CoverageFormat1, CoverageTable as WriteCoverage,
    };
    use write_fonts::tables::varc::{
        DecomposedTransform as WriteTransform, VarComponent, VarCompositeGlyph, Varc as WriteVarc,
        VarcVariationIndex,
    };
    use write_fonts::tables::variations::mivs_builder::{
        MultiItemVariationStoreBuilder, SparseRegion,
    };

    /// A VARC glyph with one component whose condition, translation and axis
    /// coordinate all vary along axis 0 through a MultiItemVariationStore.
    fn varc_bytes() -> Vec<u8> {
        let region = || {
            SparseRegion::new(vec![(
                0,
                F2Dot14::ZERO,
                F2Dot14::from_f32(1.0),
                F2Dot14::from_f32(1.0),
            )])
        };
        let mut store = MultiItemVariationStoreBuilder::new();
        let condition_delta = store.add_deltas(vec![(region(), vec![-2i32])]).unwrap();
        let transform_delta = store.add_deltas(vec![(region(), vec![100i32])]).unwrap();
        let axes_delta = store.add_deltas(vec![(region(), vec![4096i32])]).unwrap();
        // The builder is Clone, so the same delta sets can be laid out twice:
        // once to learn the final variation index, once inside the VARC table.
        let (_, remapping) = store.clone().build();
        let condition_index = remapping.get(condition_delta).unwrap();

        let coverage = WriteCoverage::Format1(CoverageFormat1::new(vec![GlyphId16::new(7)]));
        let conditions = vec![WriteCondition::format_2_variable_value(1, condition_index)];
        let composite = VarCompositeGlyph(vec![VarComponent {
            reset_unspecified_axes: false,
            gid: GlyphId::new(1),
            condition_index: Some(VarcVariationIndex::VariationIndex(0)),
            axis_values: Some(BTreeMap::from([(0u16, 0.5f32)])),
            axis_values_var_index: Some(VarcVariationIndex::PendingVariationIndex(axes_delta)),
            transform: WriteTransform {
                translate_x: Some(50.0),
                ..Default::default()
            },
            transform_var_index: Some(VarcVariationIndex::PendingVariationIndex(transform_delta)),
        }]);
        let varc =
            WriteVarc::new_from_composite_glyphs(coverage, store, conditions, vec![composite]);
        dump_table(&varc).unwrap()
    }

    #[test]
    fn format_2_conditions_and_variation_deltas_are_applied() {
        let bytes = varc_bytes();
        let varc = read_fonts::tables::varc::Varc::read(FontData::new(&bytes)).unwrap();
        let glyph = GlyphId::new(7);

        let at_default = components(&varc, glyph, &[F2Dot14::ZERO]).unwrap();
        assert_eq!(at_default.components.len(), 1);
        let base = &at_default.components[0];
        assert_eq!(base.glyph_id, 1);
        assert!(base.condition_met, "default_value 1 stays positive");
        assert_eq!(base.axis_indices, vec![0]);
        assert!((base.axis_values[0] - 0.5).abs() < 1e-6);
        assert!((base.transform[4] - 50.0).abs() < 1e-6);

        let at_peak = components(&varc, glyph, &[F2Dot14::from_f32(1.0)]).unwrap();
        let varied = &at_peak.components[0];
        assert!(!varied.condition_met, "1 + (-2) is no longer positive");
        // Translation is a raw value, axis coordinates are F2Dot14 bits.
        assert!((varied.transform[4] - 150.0).abs() < 1e-6);
        assert!((varied.axis_values[0] - 0.75).abs() < 1e-6);

        // A glyph outside the coverage has no components.
        assert!(components(&varc, GlyphId::new(2), &[])
            .unwrap()
            .components
            .is_empty());
    }
}
