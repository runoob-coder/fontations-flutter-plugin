//! Reads the OpenType `MATH` table.
//!
//! `MATH` drives mathematical typesetting: it names the constants a formula
//! layout needs (axis height, fraction gaps, radical rules), says how much a
//! slanted glyph overhangs its advance, and describes how a delimiter is
//! stretched to cover a fraction or a radical.
//!
//! Values come back in design units with the pixel adjustment their device
//! table makes at the requested size kept apart, because the two are in
//! different units and only the caller knows which space it is laying out in.

use read_fonts::tables::math::{
    MathConstants, MathGlyphInfo, MathKernCorner, MathVariants, StretchAxis,
};
use read_fonts::types::GlyphId;

use crate::api::fontations::{
    MathAssemblyPartInfo, MathAssemblyPartListInfo, MathConstantInfo, MathGlyphInfoInfo,
    MathKernEntryInfo, MathKernInfo, MathVariantRecordInfo, MathVariantsInfo,
};

/// The four corners a `MATH` kern can apply to, in the order they are read.
const CORNERS: &[(MathKernCorner, &str)] = &[
    (MathKernCorner::TopRight, "topRight"),
    (MathKernCorner::TopLeft, "topLeft"),
    (MathKernCorner::BottomRight, "bottomRight"),
    (MathKernCorner::BottomLeft, "bottomLeft"),
];

/// Every constant, in the order the OpenType spec lists them.
pub fn constants(constants: &MathConstants<'_>, ppem: u16) -> Vec<MathConstantInfo> {
    use read_fonts::tables::math::MathConstant;
    MathConstant::ALL
        .iter()
        .map(|constant| {
            let value = constants.constant_for_ppem(*constant, ppem);
            MathConstantInfo {
                // `Debug` gives the spec name with a capital first letter.
                name: lower_first(&format!("{constant:?}")),
                index: *constant as u32,
                value: value.value as f64,
                delta_px: value.delta_px as f64,
            }
        })
        .collect()
}

/// What the `MATH` table says about one glyph.
pub fn glyph_info(info: &MathGlyphInfo<'_>, glyph: GlyphId, ppem: u16) -> MathGlyphInfoInfo {
    let italics = info
        .math_italics_correction_info()
        .and_then(|subtable| subtable.ok())
        .and_then(|subtable| subtable.correction_for_ppem(glyph, ppem));
    let accent = info
        .math_top_accent_attachment()
        .and_then(|subtable| subtable.ok())
        .and_then(|subtable| subtable.attachment_for_ppem(glyph, ppem));

    let mut kerns = Vec::new();
    if let Some(kern_info) = info.math_kern_info().and_then(|subtable| subtable.ok()) {
        for (corner, name) in CORNERS {
            let Some(kern) = kern_info.kern(glyph, *corner) else {
                continue;
            };
            let entries = kern
                .entries_for_ppem(ppem)
                .map(|entry| MathKernEntryInfo {
                    max_height: entry.max_height.map(|value| value.value as f64),
                    max_height_delta_px: entry.max_height.map_or(0.0, |v| v.delta_px as f64),
                    kern: entry.kern.value as f64,
                    kern_delta_px: entry.kern.delta_px as f64,
                })
                .collect();
            kerns.push(MathKernInfo {
                corner: (*name).to_string(),
                entries,
            });
        }
    }

    MathGlyphInfoInfo {
        italics_correction: italics.map(|value| value.value as f64),
        italics_correction_delta_px: italics.map_or(0.0, |value| value.delta_px as f64),
        top_accent_attachment: accent.map(|value| value.value as f64),
        top_accent_attachment_delta_px: accent.map_or(0.0, |value| value.delta_px as f64),
        is_extended_shape: info.is_extended_shape(glyph),
        kerns,
    }
}

/// How a glyph stretches along one axis, or `None` when it does not.
///
/// `axis` is `horizontal` (an overbrace) or `vertical` (a parenthesis);
/// anything else is read as vertical.
pub fn variants(
    variants: &MathVariants<'_>,
    glyph: GlyphId,
    axis: &str,
) -> Option<MathVariantsInfo> {
    let axis = match axis.to_ascii_lowercase().as_str() {
        "horizontal" | "horiz" | "h" => StretchAxis::Horizontal,
        _ => StretchAxis::Vertical,
    };
    let construction = variants.glyph_construction(glyph, axis)?;
    let records = construction
        .math_glyph_variant_records()
        .iter()
        .map(|record| MathVariantRecordInfo {
            glyph_id: record.variant_glyph().to_u32(),
            advance: record.advance_measurement().to_u16() as f64,
        })
        .collect();

    let assembly = construction
        .glyph_assembly()
        .and_then(|assembly| assembly.ok())
        .map(|assembly| {
            let correction = assembly.italics_correction_for_ppem(0);
            MathAssemblyPartListInfo {
                italics_correction: correction.value as f64,
                italics_correction_delta_px: correction.delta_px as f64,
                parts: assembly
                    .part_records()
                    .iter()
                    .map(|part| MathAssemblyPartInfo {
                        glyph_id: part.glyph_id().to_u32(),
                        start_connector_length: part.start_connector_length().to_u16() as f64,
                        end_connector_length: part.end_connector_length().to_u16() as f64,
                        full_advance: part.full_advance().to_u16() as f64,
                        is_extender: part
                            .part_flags()
                            .contains(read_fonts::tables::math::PartFlags::EXTENDER_FLAG),
                    })
                    .collect(),
            }
        });

    Some(MathVariantsInfo {
        min_connector_overlap: variants.min_connector_overlap().to_u16() as f64,
        variants: records,
        assembly,
    })
}

fn lower_first(name: &str) -> String {
    let mut out = String::with_capacity(name.len());
    for (index, ch) in name.chars().enumerate() {
        if index == 0 {
            out.extend(ch.to_lowercase());
        } else {
            out.push(ch);
        }
    }
    out
}
