//! Target bodies shared by the libFuzzer binaries and the deterministic tests.

#![allow(dead_code)]

#[path = "helpers.rs"]
mod helpers;

use fontations::api::build::{modify_font, FontModificationRequest};
use fontations::api::fontations::{count_fonts, read_font_info, Font};

// --- Parsing and metadata ---------------------------------------------------

pub fn run_font_entry(data: &[u8]) {
    let bytes = data.to_vec();
    let _ = count_fonts(bytes.clone());
    let _ = read_font_info(bytes.clone(), None);
    let Ok(font) = Font::from_bytes(bytes, None) else {
        return;
    };

    let _ = font.info();
    let _ = font.names();
    let _ = font.axes();
    let _ = font.named_instances();
    let _ = font.tables();
    let _ = font.attributes();
    let _ = font.charmap_info();
    let _ = font.char_mappings();
    let _ = font.glyph_name(helpers::glyph_id(data));
    let _ = font.glyph_to_char(helpers::glyph_id(data));
    let _ = font.char_to_glyph(0x41);
    let _ = font.glyph_name_source();
    let _ = font.name_records(None);
    let _ = font.outline_format();
    let _ = font.layout(None);
    let _ = font.variant_mappings();
    let _ = font.avar_info();
    let _ = font.has_math();
    let _ = font.has_varc();
    let _ = font.vertical_metrics();
    let _ = font.vertical_advance(helpers::glyph_id(data));
    let _ = font.vertical_origin(helpers::glyph_id(data));
    let _ = font.math_constants(None);
    let _ = font.math_variants(helpers::glyph_id(data), "vertical".to_string(), None);
    let _ = font.normalized_coords(helpers::variations(data));

    let tag = helpers::tag_at(data, 0);
    let _ = font.has_table(tag.clone());
    let _ = font.table_length(tag.clone());
    let _ = font.table_data(tag);
}

// --- Shaping ----------------------------------------------------------------

pub fn run_shape(data: &[u8]) {
    let Ok(font) = Font::from_bytes(data.to_vec(), None) else {
        return;
    };
    let text = helpers::text(data);
    let size = helpers::size(data, 3);
    let variations = helpers::variations(data);
    let script = Some(helpers::tag_at(data, 4));
    let language = Some(helpers::tag_at(data, 8));

    let _ = font.shape(text.clone(), size, variations.clone(), None, None, None);
    let _ = font.shape(
        text.clone(),
        size,
        variations.clone(),
        None,
        None,
        Some(Vec::new()),
    );
    let _ = font.shape(
        text.clone(),
        size,
        variations.clone(),
        script.clone(),
        language.clone(),
        Some(vec!["kern".to_string(), "liga".to_string()]),
    );
    let _ = font.shape(
        text,
        size,
        variations,
        script,
        language,
        Some(vec![helpers::tag_at(data, 12)]),
    );
}

// --- Outlines ---------------------------------------------------------------

pub fn run_outline(data: &[u8]) {
    let Ok(font) = Font::from_bytes(data.to_vec(), None) else {
        return;
    };
    let glyph = helpers::glyph_id(data);
    let variations = helpers::variations(data);

    let _ = font.outline(
        glyph,
        helpers::size(data, 2),
        variations.clone(),
        None,
        None,
    );
    let _ = font.outline(glyph, Some(24.0), variations.clone(), Some(true), None);
    let _ = font.outline(glyph, None, variations, Some(false), None);
}

// --- VARC / COLR / bitmaps --------------------------------------------------

pub fn run_varc_color(data: &[u8]) {
    let Ok(font) = Font::from_bytes(data.to_vec(), None) else {
        return;
    };
    let glyph = helpers::glyph_id(data);
    let variations = helpers::variations(data);
    let palette = Some((data.first().copied().unwrap_or(0) as u16) % 4);

    let _ = font.varc_components(glyph, variations.clone());
    let _ = font.color_glyph(glyph, palette, variations);
    let _ = font.has_color_glyph(glyph);
    let _ = font.color_palettes();
    let _ = font.bitmap_glyph(glyph, helpers::size(data, 1));
    let _ = font.bitmap_strikes();
}

// --- Patching ---------------------------------------------------------------

pub fn run_modify(data: &[u8]) {
    let _ = modify_font(data.to_vec(), FontModificationRequest::default());
}
