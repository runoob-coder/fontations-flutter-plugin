//! Patches a font that already exists.
//!
//! [crate::font_compile::build_ttf] always starts from an empty font. This
//! module goes the other way: it keeps the outlines, the `cmap` and every table
//! it does not know about, and only rewrites what the caller asked for —
//! metadata (`name` / `OS/2`), kerning (`GPOS`) and substitutions (`GSUB`).
//!
//! Anything this module does not touch is copied over with
//! `FontBuilder::copy_missing_tables`, so `fvar`, `gvar`, `STAT`, `HVAR`,
//! `COLR` and friends survive.

use std::collections::BTreeMap;

use anyhow::{anyhow, Result};
use read_fonts::types::{GlyphId16, NameId, Tag};
use read_fonts::{FontRef, TableProvider};
use skrifa::MetadataProvider;
use write_fonts::from_obj::ToOwnedTable;
use write_fonts::tables::name::{Name, NameRecord};
use write_fonts::tables::os2::{Os2, SelectionFlags};
use write_fonts::FontBuilder;

use crate::api::build::FontModificationRequest;
use crate::font_compile::{
    build_gsub, build_kern_gpos, is_bold_italic, vendor_tag, weight_from_subfamily,
};

/// Platform 3 (Windows), encoding 1 (BMP), language 0x0409 (en-US).
const WINDOWS_ROMAN: (u16, u16, u16) = (3, 1, 0x0409);

/// First name id used for feature labels, so it never collides with the
/// reserved ids below 256.
const FIRST_FEATURE_NAME_ID: u16 = 256;

/// Applies [FontModificationRequest] to `bytes` and returns the new font.
pub fn modify_ttf(bytes: &[u8], request: &FontModificationRequest) -> Result<Vec<u8>> {
    let font = FontRef::new(bytes).map_err(|e| anyhow!("not a usable font file: {e}"))?;
    let charmap = font.charmap();
    let glyph_for = |code_point: u32| -> Result<GlyphId16> {
        charmap
            .map(code_point)
            .map(|glyph_id| GlyphId16::new(to_u16(glyph_id.to_u32())))
            .ok_or_else(|| anyhow!("the font has no glyph for U+{code_point:04X}"))
    };

    let mut builder = FontBuilder::new();

    // --- kerning ------------------------------------------------------------
    if !request.kern_pairs.is_empty() {
        builder.add_table(&build_kern_gpos(&request.kern_pairs, &glyph_for)?)?;
    }

    // --- substitutions ------------------------------------------------------
    let mut substitutions: Vec<(Tag, u32, u32)> = Vec::new();
    let mut ligatures: Vec<(Tag, Vec<u32>, u32)> = Vec::new();
    let mut feature_names: BTreeMap<Tag, NameId> = BTreeMap::new();
    let mut labels: Vec<(NameId, String)> = Vec::new();
    let mut next_name_id = FIRST_FEATURE_NAME_ID;

    for alternate in &request.alternates {
        let tag = parse_tag(&alternate.feature_tag)?;
        let from = glyph_for(alternate.code_point)?.to_u32();
        let to = glyph_for(alternate.replacement_code_point)?.to_u32();
        substitutions.push((tag, from, to));
        if let (Some(name), false) = (&alternate.name, feature_names.contains_key(&tag)) {
            let id = NameId::new(next_name_id);
            next_name_id += 1;
            feature_names.insert(tag, id);
            labels.push((id, name.clone()));
        }
    }

    for ligature in &request.ligatures {
        let tag = parse_tag(&ligature.feature_tag)?;
        let sequence = ligature
            .sequence
            .iter()
            .map(|code_point| glyph_for(*code_point).map(|gid| gid.to_u32()))
            .collect::<Result<Vec<_>>>()?;
        if sequence.len() < 2 {
            return Err(anyhow!("a ligature needs at least two code points"));
        }
        let replacement = glyph_for(ligature.replacement_code_point)?.to_u32();
        ligatures.push((tag, sequence, replacement));
    }

    if !substitutions.is_empty() || !ligatures.is_empty() {
        builder.add_table(&build_gsub(&substitutions, &ligatures, &feature_names)?)?;
    }

    // --- name ---------------------------------------------------------------
    let wanted = [
        (NameId::FAMILY_NAME, request.family_name.as_deref()),
        (NameId::SUBFAMILY_NAME, request.subfamily_name.as_deref()),
        (NameId::MANUFACTURER, request.manufacturer.as_deref()),
        (NameId::DESIGNER, request.designer.as_deref()),
        (NameId::LICENSE_DESCRIPTION, request.license.as_deref()),
        (NameId::VERSION_STRING, request.version.as_deref()),
    ];
    let mut name_records: Vec<(NameId, String)> = wanted
        .iter()
        .filter_map(|(id, value)| value.map(|value| (*id, value.to_string())))
        .collect();
    name_records.extend(labels);

    if !name_records.is_empty() {
        let mut name: Name = font
            .name()
            .map_err(|e| anyhow!("the font has no name table: {e}"))?
            .to_owned_table();
        for (id, value) in &name_records {
            let record = NameRecord {
                platform_id: WINDOWS_ROMAN.0,
                encoding_id: WINDOWS_ROMAN.1,
                language_id: WINDOWS_ROMAN.2,
                name_id: *id,
                string: value.clone().into(),
            };
            match name
                .name_record
                .iter_mut()
                .find(|existing| same_record(existing, *id))
            {
                Some(existing) => *existing = record,
                None => name.name_record.push(record),
            }
        }
        builder.add_table(&name)?;
    }

    // --- OS/2 ---------------------------------------------------------------
    let has_os2_change = request.weight_class.is_some()
        || request.width_class.is_some()
        || request.vendor_id.is_some()
        || request.subfamily_name.is_some();
    if has_os2_change {
        let mut os2: Os2 = font
            .os2()
            .map_err(|e| anyhow!("the font has no OS/2 table: {e}"))?
            .to_owned_table();
        if let Some(weight) = request.weight_class {
            os2.us_weight_class = weight.clamp(1, 1000);
        }
        if let Some(width) = request.width_class {
            os2.us_width_class = width.clamp(1, 9);
        }
        if let Some(vendor) = &request.vendor_id {
            os2.ach_vend_id = vendor_tag(Some(vendor));
        }
        if let Some(subfamily) = &request.subfamily_name {
            let (bold, italic) = is_bold_italic(subfamily);
            let mut flags = SelectionFlags::empty();
            if italic {
                flags |= SelectionFlags::ITALIC;
            }
            if bold {
                flags |= SelectionFlags::BOLD;
            }
            if !bold && !italic {
                flags |= SelectionFlags::REGULAR;
            }
            os2.fs_selection = flags;
            if request.weight_class.is_none() {
                if let Some(weight) = weight_from_subfamily(subfamily) {
                    os2.us_weight_class = weight;
                }
            }
        }
        builder.add_table(&os2)?;
    }

    // Everything else — `head`, `hhea`, `maxp`, `cmap`, `glyf`, `loca`, `fvar`,
    // `gvar`, ... — is carried over unchanged.
    builder.copy_missing_tables(font);

    Ok(builder.build())
}

fn same_record(record: &NameRecord, name_id: NameId) -> bool {
    record.platform_id == WINDOWS_ROMAN.0
        && record.encoding_id == WINDOWS_ROMAN.1
        && record.language_id == WINDOWS_ROMAN.2
        && record.name_id == name_id
}

fn to_u16(value: u32) -> u16 {
    value.min(u16::MAX as u32) as u16
}

fn parse_tag(tag: &str) -> Result<Tag> {
    if tag.is_empty() || tag.len() > 4 {
        return Err(anyhow!("'{tag}' is not a four character feature tag"));
    }
    let mut padded = *b"    ";
    for (slot, byte) in padded.iter_mut().zip(tag.as_bytes()) {
        *slot = *byte;
    }
    Ok(Tag::new(&padded))
}
