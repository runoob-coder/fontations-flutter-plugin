//! Compiles a set of drawn contours into a binary TrueType font.
//!
//! This is the write-side counterpart of `api::fontations`: where that module
//! reads fonts with `read-fonts`/`skrifa`, this one writes them with
//! `write-fonts`.
//!
//! Static and variable fonts are both supported: adding [VariationAxisSpec]s to
//! the request produces `fvar` + `gvar`.

use std::collections::{BTreeMap, HashMap};

use anyhow::{anyhow, Result};
use kurbo::{BezPath, Point};
use read_fonts::types::{
    F2Dot14, Fixed, GlyphId, GlyphId16, MajorMinor, NameId, Tag, Uint24, Version16Dot16,
};
use write_fonts::tables::avar::{Avar, AxisValueMap, SegmentMaps};
use write_fonts::tables::cmap::{
    Cmap, CmapSubtable, EncodingRecord, NonDefaultUvs, PlatformId, UvsMapping, VariationSelector,
};
use write_fonts::tables::colr::{BaseGlyph, Colr, Layer as ColrLayer};
use write_fonts::tables::cpal::{ColorRecord as CpalColor, Cpal};
use write_fonts::tables::fvar::{AxisInstanceArrays, Fvar, InstanceRecord, VariationAxisRecord};
use write_fonts::tables::glyf::{
    Anchor, Bbox, Component, ComponentFlags, CompositeGlyph, GlyfLocaBuilder, Glyph, SimpleGlyph,
    Transform,
};
use write_fonts::tables::gpos::{
    Gpos, PairPos, PairSet, PairValueRecord, PositionLookup, PositionLookupList, ValueRecord,
};
use write_fonts::tables::gsub::{
    Gsub, Ligature, LigatureSet, LigatureSubstFormat1, SingleSubst, SubstitutionLookup,
    SubstitutionLookupList,
};
use write_fonts::tables::gvar::{GlyphDelta, GlyphDeltas, GlyphVariations, Gvar};
use write_fonts::tables::head::Head;
use write_fonts::tables::hhea::Hhea;
use write_fonts::tables::hmtx::{Hmtx, LongMetric};
use write_fonts::tables::hvar::Hvar;
use write_fonts::tables::layout::{
    CoverageFormat1, CoverageTable, Feature, FeatureList, FeatureParams, FeatureRecord, LangSys,
    Lookup, LookupFlag, Script, ScriptList, ScriptRecord, StylisticSetParams,
};
use write_fonts::tables::loca::LocaFormat;
use write_fonts::tables::maxp::Maxp;
use write_fonts::tables::mvar::Mvar;
use write_fonts::tables::name::{Name, NameRecord};
use write_fonts::tables::os2::{Os2, SelectionFlags};
use write_fonts::tables::post::Post;
use write_fonts::tables::stat::{
    AxisRecord as DesignAxisRecord, AxisValue, AxisValueRecord, AxisValueTableFlags, Stat,
};
use write_fonts::tables::variations::{
    ItemVariationData, ItemVariationStore, RegionAxisCoordinates, Tent, VariationRegion,
    VariationRegionList,
};
use write_fonts::tables::vhea::Vhea;
use write_fonts::tables::vmtx::Vmtx;
use write_fonts::{FontBuilder, OffsetMarker};

use crate::api::build::{
    ContourPoint, FontBuildRequest, GlyphContour, GlyphSpec, KernPair, VariationMaster,
};

/// A validated axis, plus the `avar` mapping that remaps its normalization.
struct Axis {
    tag: Tag,
    name: String,
    min_value: f64,
    default_value: f64,
    max_value: f64,
    /// `avar` entries, sorted by `from`.
    mappings: Vec<(f64, f64)>,
}

/// Platform 3 (Windows), encoding 1 (BMP), language 0x0409 (en-US).
const WINDOWS_ROMAN: (u16, u16, u16) = (3, 1, 0x0409);

/// First name id used for axis / instance names, so that it never collides with
/// the reserved ids below 256.
const FIRST_VARIATION_NAME_ID: u16 = 256;

/// Maximum number of axes `fvar`/`gvar` can reasonably carry here.
const MAX_AXES: usize = 16;

/// `gvar` always stores four extra "phantom" points per glyph.
const PHANTOM_POINT_COUNT: usize = 4;

pub fn build_ttf(request: &FontBuildRequest) -> Result<Vec<u8>> {
    if request.family_name.trim().is_empty() {
        return Err(anyhow!("family name must not be empty"));
    }
    if request.glyphs.is_empty() {
        return Err(anyhow!("at least one glyph is required"));
    }

    let axes = validate_axes(request)?;
    let variable = !axes.is_empty();

    let upem = request.units_per_em.unwrap_or(1000).clamp(16, 16384);
    let upem_f = upem as f64;
    let ascender = request.ascender.unwrap_or(upem_f * 0.8);
    let descender = request.descender.unwrap_or(-upem_f * 0.2);

    // --- glyf / loca -------------------------------------------------------
    // Glyph 0 is always `.notdef`, then one glyph per requested character, and
    // finally the glyphs no `cmap` entry points at: stylistic alternates,
    // ligature glyphs and `COLR` layers.
    // Two glyphs claiming the same code point used to be resolved in two
    // different places: `gid_of` below keeps the *last* one (HashMap::collect),
    // while the cmap keeps the *first* one (`Cmap::from_mappings` sorts and
    // dedups before it checks for conflicts, so its conflict detection never
    // fires). The result compiles but references glyphs the cmap never points
    // at, so reject it here instead.
    let mut seen: HashMap<u32, usize> = HashMap::new();
    for (index, spec) in request.glyphs.iter().enumerate() {
        if let Some(&previous) = seen.get(&spec.code_point) {
            return Err(anyhow!(
                "duplicate code point U+{:04X}: glyph {} and glyph {} both claim it",
                spec.code_point,
                previous + 1,
                index + 1
            ));
        }
        if char::from_u32(spec.code_point).is_none() {
            // `Cmap::from_mappings` needs a `char`, so fail here where the
            // offending glyph can still be named.
            return Err(anyhow!(
                "U+{:04X} (glyph {}) is not a valid code point",
                spec.code_point,
                index + 1
            ));
        }
        seen.insert(spec.code_point, index);
    }

    let gid_of: HashMap<u32, u32> = request
        .glyphs
        .iter()
        .enumerate()
        .map(|(index, spec)| (spec.code_point, (index + 1) as u32))
        .collect();

    let mut glyphs = vec![Glyph::Empty];
    let mut point_sets: Vec<Vec<Vec<ContourPoint>>> = vec![Vec::new()];
    let mut advances: Vec<f64> = vec![0.0];
    let mut substitutions: Vec<(Tag, u32, u32)> = Vec::new();
    let mut ligature_specs: Vec<(Tag, Vec<u32>, u32)> = Vec::new();
    let mut color_glyphs: Vec<(u32, Vec<(u32, u16)>)> = Vec::new();
    // Composite glyphs need the bounding boxes of the glyphs they reuse, so
    // they are filled in once every other glyph exists.
    let mut composites: Vec<(usize, Vec<CompositePart>)> = Vec::new();

    for spec in &request.glyphs {
        if !spec.components.is_empty() {
            if !spec.masters.is_empty() {
                return Err(anyhow!(
                    "glyph U+{:04X} is a composite: composites cannot have masters",
                    spec.code_point
                ));
            }
            let parts = spec
                .components
                .iter()
                .map(|part| {
                    let gid = *gid_of.get(&part.code_point).ok_or_else(|| {
                        anyhow!(
                            "composite of U+{:04X} reuses U+{:04X}, which has no glyph",
                            spec.code_point,
                            part.code_point
                        )
                    })?;
                    Ok(CompositePart {
                        gid,
                        dx: part.dx,
                        dy: part.dy,
                        scale: part.scale.unwrap_or(1.0),
                        use_my_metrics: part.use_my_metrics,
                    })
                })
                .collect::<Result<Vec<_>>>()?;
            composites.push((glyphs.len(), parts));
            glyphs.push(Glyph::Empty);
            point_sets.push(Vec::new());
        } else {
            let (glyph, points) = build_glyph(
                &spec.contours,
                spec.code_point,
                spec.instructions.as_deref(),
            )?;
            glyphs.push(glyph);
            point_sets.push(points);
        }
        advances.push(spec.advance_width.unwrap_or(upem_f));
    }

    for (index, spec) in request.glyphs.iter().enumerate() {
        let from_gid = (index + 1) as u32;
        for alternate in &spec.alternates {
            let tag = parse_tag(&alternate.feature_tag)?;
            let (glyph, points) = build_glyph(&alternate.contours, spec.code_point, None)?;
            glyphs.push(glyph);
            point_sets.push(points);
            advances.push(alternate.advance_width.unwrap_or(upem_f));
            let to_gid = (glyphs.len() - 1) as u32;
            substitutions.push((tag, from_gid, to_gid));
        }
    }

    for ligature in &request.ligatures {
        let tag = parse_tag(&ligature.feature_tag)?;
        if ligature.sequence.len() < 2 {
            return Err(anyhow!("a ligature needs at least two code points"));
        }
        let sequence = ligature
            .sequence
            .iter()
            .map(|code_point| {
                gid_of.get(code_point).copied().ok_or_else(|| {
                    anyhow!("ligature references U+{code_point:04X}, which has no glyph")
                })
            })
            .collect::<Result<Vec<_>>>()?;
        let (glyph, _) = build_glyph(&ligature.contours, ligature.sequence[0], None)?;
        glyphs.push(glyph);
        point_sets.push(Vec::new());
        advances.push(ligature.advance_width.unwrap_or(upem_f));
        let ligature_gid = (glyphs.len() - 1) as u32;
        ligature_specs.push((tag, sequence, ligature_gid));
    }

    for (index, spec) in request.glyphs.iter().enumerate() {
        let base_gid = (index + 1) as u32;
        let mut layers = Vec::new();
        for layer in &spec.color_layers {
            let (glyph, _) = build_glyph(&layer.contours, spec.code_point, None)?;
            glyphs.push(glyph);
            point_sets.push(Vec::new());
            // Layer glyphs are drawn on top of the base glyph; they take no
            // advance of their own.
            advances.push(0.0);
            let layer_gid = (glyphs.len() - 1) as u32;
            layers.push((layer_gid, layer.palette_index));
        }
        if !layers.is_empty() {
            color_glyphs.push((base_gid, layers));
        }
    }

    // Two passes, so a composite may reuse another composite.
    for _ in 0..2 {
        for (index, parts) in &composites {
            let built = build_composite(parts, &glyphs)?;
            glyphs[*index] = built;
        }
    }

    if !variable {
        for spec in &request.glyphs {
            if !spec.masters.is_empty() {
                return Err(anyhow!(
                    "glyph U+{:04X} has masters but no axes were declared",
                    spec.code_point
                ));
            }
        }
    }

    let mut glyf_loca = GlyfLocaBuilder::new();
    for (index, glyph) in glyphs.iter().enumerate() {
        glyf_loca.add_glyph(glyph).map_err(|e| {
            let label = glyph_label(index, request);
            anyhow!("failed to write glyph {label}: {e}")
        })?;
    }
    let (glyf, loca, loca_format) = glyf_loca.build();

    // --- metrics -----------------------------------------------------------
    let num_glyphs = glyphs.len() as u16;
    let mut max_points = 0u32;
    let mut max_contours = 0u32;
    let mut advance_width_max = 0u32;
    let mut min_lsb = 0i32;
    let mut min_rsb = 0i32;
    let mut x_max_extent = 0i32;
    let mut x_min = 0i32;
    let mut y_min = 0i32;
    let mut x_max = 0i32;
    let mut y_max = 0i32;
    let mut h_metrics = Vec::with_capacity(glyphs.len());

    for (index, glyph) in glyphs.iter().enumerate() {
        let advance = if index == 0 {
            0
        } else {
            advances[index].round().clamp(0.0, u16::MAX as f64) as u32
        };
        let bbox = glyph.bbox().unwrap_or_default();

        if let Some(simple) = as_simple(glyph) {
            max_points = max_points.max(simple.contours.iter().map(|c| c.len() as u32).sum());
            max_contours = max_contours.max(simple.contours.len() as u32);
        }
        advance_width_max = advance_width_max.max(advance);

        if bbox.x_max != 0 || bbox.y_max != 0 || bbox.x_min != 0 || bbox.y_min != 0 {
            min_lsb = min_lsb.min(bbox.x_min as i32);
            min_rsb = min_rsb.min(advance as i32 - bbox.x_max as i32);
            x_max_extent = x_max_extent.max(bbox.x_max as i32);
            x_min = x_min.min(bbox.x_min as i32);
            y_min = y_min.min(bbox.y_min as i32);
            x_max = x_max.max(bbox.x_max as i32);
            y_max = y_max.max(bbox.y_max as i32);
        }

        h_metrics.push(LongMetric {
            advance: advance as u16,
            side_bearing: bbox.x_min,
        });
    }

    // --- tables ------------------------------------------------------------
    let head = Head {
        units_per_em: upem as u16,
        index_to_loc_format: match loca_format {
            LocaFormat::Short => 0,
            LocaFormat::Long => 1,
        },
        x_min: to_i16(x_min),
        y_min: to_i16(y_min),
        x_max: to_i16(x_max),
        y_max: to_i16(y_max),
        lowest_rec_ppem: 8,
        ..Default::default()
    };

    let hhea = Hhea {
        ascender: to_i16(ascender.round() as i32).into(),
        descender: to_i16(descender.round() as i32).into(),
        line_gap: 0.into(),
        advance_width_max: to_u16(advance_width_max).into(),
        min_left_side_bearing: to_i16(min_lsb).into(),
        min_right_side_bearing: to_i16(min_rsb).into(),
        x_max_extent: to_i16(x_max_extent).into(),
        caret_slope_rise: 1,
        caret_slope_run: 0,
        caret_offset: 0,
        number_of_h_metrics: num_glyphs,
    };

    let maxp = Maxp {
        num_glyphs,
        max_points: Some(to_u16(max_points)),
        max_contours: Some(to_u16(max_contours)),
        max_composite_points: Some(0),
        max_composite_contours: Some(0),
        max_zones: Some(2),
        max_twilight_points: Some(0),
        max_storage: Some(0),
        max_function_defs: Some(0),
        max_instruction_defs: Some(0),
        max_stack_elements: Some(0),
        max_size_of_instructions: Some(0),
        max_component_elements: Some(0),
        max_component_depth: Some(0),
    };

    let hmtx = Hmtx {
        h_metrics,
        left_side_bearings: Vec::new(),
    };

    let post = Post {
        version: Version16Dot16::VERSION_3_0,
        num_glyphs: Some(num_glyphs),
        ..Default::default()
    };

    let subfamily = request
        .subfamily_name
        .clone()
        .unwrap_or_else(|| "Regular".to_string());
    let full_name = format!("{} {}", request.family_name, subfamily);
    let postscript_name = format!(
        "{}{}",
        request.family_name.replace(' ', ""),
        subfamily.replace(' ', "")
    );

    let version = request
        .version
        .clone()
        .unwrap_or_else(|| "Version 1.000".to_string());
    let mut name_records = vec![
        name_record(NameId::FAMILY_NAME, &request.family_name),
        name_record(NameId::SUBFAMILY_NAME, &subfamily),
        name_record(
            NameId::UNIQUE_ID,
            &format!("{full_name}; built with fontations"),
        ),
        name_record(NameId::FULL_NAME, &full_name),
        name_record(NameId::VERSION_STRING, &version),
        name_record(NameId::POSTSCRIPT_NAME, &postscript_name),
    ];
    if let Some(manufacturer) = &request.manufacturer {
        name_records.push(name_record(NameId::MANUFACTURER, manufacturer));
    }
    if let Some(designer) = &request.designer {
        name_records.push(name_record(NameId::DESIGNER, designer));
    }
    if let Some(license) = &request.license {
        name_records.push(name_record(NameId::LICENSE_DESCRIPTION, license));
    }

    let code_points: Vec<u32> = request.glyphs.iter().map(|spec| spec.code_point).collect();
    let avg_width = if advances.len() > 1 {
        advances[1..].iter().copied().sum::<f64>() / (advances.len() - 1) as f64
    } else {
        0.0
    };
    let (bold, italic) = is_bold_italic(&subfamily);
    let mut fs_selection = SelectionFlags::empty();
    if italic {
        fs_selection |= SelectionFlags::ITALIC;
    }
    if bold {
        fs_selection |= SelectionFlags::BOLD;
    }
    if !bold && !italic {
        fs_selection |= SelectionFlags::REGULAR;
    }
    let weight_class = request
        .weight_class
        .or_else(|| weight_from_subfamily(&subfamily))
        .unwrap_or(400)
        .clamp(1, 1000);
    let ranges = unicode_ranges(&code_points);

    let os2 = Os2 {
        x_avg_char_width: to_i16(avg_width.round() as i32),
        us_weight_class: weight_class,
        us_width_class: request.width_class.unwrap_or(5).clamp(1, 9),
        fs_type: 0, // installable embedding
        s_family_class: 0,
        panose_10: [0u8; 10],
        ul_unicode_range_1: ranges[0],
        ul_unicode_range_2: ranges[1],
        ul_unicode_range_3: ranges[2],
        ul_unicode_range_4: ranges[3],
        ach_vend_id: vendor_tag(request.vendor_id.as_deref()),
        fs_selection,
        us_first_char_index: to_u16(code_points.iter().copied().min().unwrap_or(0)),
        us_last_char_index: to_u16(code_points.iter().copied().max().unwrap_or(0)),
        s_typo_ascender: to_i16(ascender.round() as i32),
        s_typo_descender: to_i16(descender.round() as i32),
        s_typo_line_gap: 0,
        us_win_ascent: to_u16(ascender.round().max(0.0) as u32),
        us_win_descent: to_u16((-descender).round().max(0.0) as u32),
        // The `OS/2` version is derived from which optional fields are set, so
        // these all have to be present together (they are the version 4 fields).
        ul_code_page_range_1: Some(1), // Latin-1
        ul_code_page_range_2: Some(0),
        sx_height: Some(to_i16((ascender * 0.5).round() as i32)),
        s_cap_height: Some(to_i16((ascender * 0.7).round() as i32)),
        us_default_char: Some(0),
        us_break_char: Some(32),
        us_max_context: Some(1),
        ..Default::default()
    };

    let mappings = request
        .glyphs
        .iter()
        .enumerate()
        .map(|(index, spec)| {
            let ch = char::from_u32(spec.code_point)
                .ok_or_else(|| anyhow!("U+{:04X} is not a valid code point", spec.code_point))?;
            Ok((ch, GlyphId::new((index + 1) as u32)))
        })
        .collect::<Result<Vec<_>>>()?;
    let mut cmap = Cmap::from_mappings(mappings).map_err(|e| anyhow!("cmap conflict: {e}"))?;

    // --- cmap format 14 (variation selectors) ------------------------------
    if !request.variation_selectors.is_empty() {
        let mut selectors = Vec::with_capacity(request.variation_selectors.len());
        for spec in &request.variation_selectors {
            let mappings = spec
                .variants
                .iter()
                .map(|variant| {
                    let glyph_id = *gid_of.get(&variant.variant_code_point).ok_or_else(|| {
                        anyhow!(
                            "variation selector U+{:04X} references U+{:04X}, which has no glyph",
                            spec.selector,
                            variant.variant_code_point
                        )
                    })?;
                    Ok(UvsMapping::new(
                        Uint24::new(variant.code_point),
                        to_u16(glyph_id),
                    ))
                })
                .collect::<Result<Vec<_>>>()?;
            let num_uvs_mappings = mappings.len() as u32;
            let non_default = NonDefaultUvs::new(num_uvs_mappings, mappings).into();
            selectors.push(VariationSelector::new(
                Uint24::new(spec.selector),
                None,
                non_default,
            ));
        }
        // Platform 0 (Unicode), encoding 5 is the convention for UVS.
        cmap.encoding_records.push(EncodingRecord::new(
            PlatformId::Unicode,
            5,
            CmapSubtable::format_14(selectors),
        ));
    }

    let mut builder = FontBuilder::new();
    builder
        .add_table(&head)?
        .add_table(&hhea)?
        .add_table(&maxp)?
        .add_table(&os2)?
        .add_table(&hmtx)?
        .add_table(&loca)?
        .add_table(&glyf)?
        .add_table(&cmap)?
        .add_table(&post)?;

    // --- variations --------------------------------------------------------
    let mut next_name_id = FIRST_VARIATION_NAME_ID;
    if variable {
        for (index, axis) in axes.iter().enumerate() {
            name_records.push(name_record(
                NameId::new(FIRST_VARIATION_NAME_ID + index as u16),
                &axis.name,
            ));
        }
        let instance_base = FIRST_VARIATION_NAME_ID + axes.len() as u16;
        for (index, instance) in request.instances.iter().enumerate() {
            name_records.push(name_record(
                NameId::new(instance_base + index as u16),
                &instance.name,
            ));
        }
        next_name_id = instance_base + request.instances.len() as u16;

        let fvar = build_fvar(request, &axes, instance_base)?;
        let gvar = build_gvar(request, &axes, &point_sets, num_glyphs as u32)?;
        builder.add_table(&fvar)?.add_table(&gvar)?;

        // `STAT` exposes the axes and named instances to font menus.
        builder.add_table(&build_stat(&axes, request, instance_base))?;

        // `avar` remaps the normalization of the axes.
        if axes.iter().any(|axis| !axis.mappings.is_empty()) {
            builder.add_table(&build_avar(&axes))?;
        }

        // `HVAR` makes the advance width follow the axes, `MVAR` does the same
        // for the global metrics.
        let (hvar, mvar) = build_metric_variations(
            request,
            &axes,
            &advances,
            ascender,
            descender,
            num_glyphs as u32,
        )?;
        if let Some(hvar) = hvar {
            builder.add_table(&hvar)?;
        }
        if let Some(mvar) = mvar {
            builder.add_table(&mvar)?;
        }
    }

    // --- substitutions and ligatures ---------------------------------------
    let feature_names = build_feature_names(request, &mut name_records, &mut next_name_id);
    if !substitutions.is_empty() || !ligature_specs.is_empty() {
        let gsub = build_gsub(&substitutions, &ligature_specs, &feature_names)?;
        builder.add_table(&gsub)?;
    }

    // --- color glyphs -------------------------------------------------------
    if !color_glyphs.is_empty() {
        if request.palette.is_empty() {
            return Err(anyhow!(
                "a glyph has color layers, so the request needs a palette"
            ));
        }
        let (colr, cpal) = build_color_tables(&color_glyphs, &request.palette)?;
        builder.add_table(&colr)?.add_table(&cpal)?;
    }

    // --- vertical metrics ---------------------------------------------------
    if let Some(vertical) = &request.vertical_metrics {
        let (vhea, vmtx) = build_vertical_metrics(request, vertical, &glyphs)?;
        builder.add_table(&vhea)?.add_table(&vmtx)?;
    }

    // --- tables copied verbatim, e.g. `fpgm`, `prep` and `cvt ` -------------
    for raw in &request.raw_tables {
        let tag = parse_tag(&raw.tag)?;
        builder.add_raw(tag, raw.data.clone());
    }

    // --- kerning ------------------------------------------------------------
    if !request.kern_pairs.is_empty() {
        let glyph_for = |code_point: u32| -> Result<GlyphId16> {
            gid_of
                .get(&code_point)
                .map(|gid| GlyphId16::new(to_u16(*gid)))
                .ok_or_else(|| {
                    anyhow!("kerning pair references U+{code_point:04X}, which has no glyph")
                })
        };
        let gpos = build_kern_gpos(&request.kern_pairs, glyph_for)?;
        builder.add_table(&gpos)?;
    }

    builder.add_table(&Name {
        name_record: name_records,
        lang_tag_record: None,
    })?;

    Ok(builder.build())
}

fn validate_axes(request: &FontBuildRequest) -> Result<Vec<Axis>> {
    if request.axes.is_empty() {
        return Ok(Vec::new());
    }
    if request.axes.len() > MAX_AXES {
        return Err(anyhow!("at most {MAX_AXES} axes are supported"));
    }

    let mut seen = Vec::with_capacity(request.axes.len());
    let mut axes = Vec::with_capacity(request.axes.len());
    for spec in &request.axes {
        let tag = parse_tag(&spec.tag)?;
        if seen.contains(&tag) {
            return Err(anyhow!("duplicate axis tag '{}'", spec.tag));
        }
        seen.push(tag);
        if !(spec.min_value <= spec.default_value && spec.default_value <= spec.max_value) {
            return Err(anyhow!(
                "axis '{}' must satisfy min <= default <= max",
                spec.tag
            ));
        }
        let mut mappings: Vec<(f64, f64)> =
            spec.mappings.iter().map(|map| (map.from, map.to)).collect();
        mappings.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
        for (from, to) in &mappings {
            if !(-1.0..=1.0).contains(from) || !(-1.0..=1.0).contains(to) {
                return Err(anyhow!(
                    "avar mapping of axis '{}' must stay in the -1..1 range",
                    spec.tag
                ));
            }
        }
        axes.push(Axis {
            tag,
            name: spec.name.clone(),
            min_value: spec.min_value,
            default_value: spec.default_value,
            max_value: spec.max_value,
            mappings,
        });
    }

    for instance in &request.instances {
        if instance.coordinates.len() != axes.len() {
            return Err(anyhow!(
                "named instance '{}' needs {} coordinates, got {}",
                instance.name,
                axes.len(),
                instance.coordinates.len()
            ));
        }
    }

    Ok(axes)
}

fn build_fvar(request: &FontBuildRequest, axes: &[Axis], instance_base: u16) -> Result<Fvar> {
    let axis_records = axes
        .iter()
        .enumerate()
        .map(|(index, axis)| VariationAxisRecord {
            axis_tag: axis.tag,
            min_value: Fixed::from_f64(axis.min_value),
            default_value: Fixed::from_f64(axis.default_value),
            max_value: Fixed::from_f64(axis.max_value),
            flags: 0,
            axis_name_id: NameId::new(FIRST_VARIATION_NAME_ID + index as u16),
        })
        .collect();

    let instances = request
        .instances
        .iter()
        .enumerate()
        .map(|(index, instance)| InstanceRecord {
            subfamily_name_id: NameId::new(instance_base + index as u16),
            flags: 0,
            coordinates: instance
                .coordinates
                .iter()
                .map(|value| Fixed::from_f64(*value))
                .collect(),
            post_script_name_id: None,
        })
        .collect();

    Ok(Fvar {
        axis_instance_arrays: OffsetMarker::new(AxisInstanceArrays::new(axis_records, instances)),
    })
}

/// Builds a `GSUB` table with one `SingleSubst` lookup per feature tag.
///
/// Each feature is referenced from every language system, exactly like real
/// fonts do (Inter registers `ss01`..`ss08` the same way). That reference does
/// **not** turn the feature on: it only makes it reachable, so a text engine
/// can still apply it when asked for `ss01`. Leaving the features out entirely
/// makes Flutter's macOS shaper ignore `FontFeature('ss01')` altogether.
/// Builds a `GSUB` table from single substitutions and ligatures.
///
/// `substitutions` are `(feature tag, glyph to replace, replacement glyph)` and
/// `ligatures` are `(feature tag, glyph ids of the sequence, ligature glyph)`.
/// Both may share a feature tag, in which case the feature owns one lookup of
/// each kind.
pub(crate) fn build_gsub(
    substitutions: &[(Tag, u32, u32)],
    ligatures: &[(Tag, Vec<u32>, u32)],
    feature_names: &BTreeMap<Tag, NameId>,
) -> Result<Gsub> {
    // `BTreeMap` keeps the tags sorted, which the `FeatureList` requires.
    let mut singles: BTreeMap<Tag, Vec<(GlyphId16, GlyphId16)>> = BTreeMap::new();
    for (tag, from, to) in substitutions {
        let from = GlyphId16::new(to_u16(*from) as u16);
        let to = GlyphId16::new(to_u16(*to) as u16);
        singles.entry(*tag).or_default().push((from, to));
    }
    let mut ligas: BTreeMap<Tag, Vec<(Vec<GlyphId16>, GlyphId16)>> = BTreeMap::new();
    for (tag, sequence, replacement) in ligatures {
        ligas.entry(*tag).or_default().push((
            sequence
                .iter()
                .map(|gid| GlyphId16::new(to_u16(*gid)))
                .collect(),
            GlyphId16::new(to_u16(*replacement)),
        ));
    }

    let mut tags: Vec<Tag> = singles.keys().chain(ligas.keys()).copied().collect();
    tags.sort_by_key(|tag| tag.to_string());
    tags.dedup();

    let mut lookups: Vec<SubstitutionLookup> = Vec::new();
    let mut feature_records = Vec::with_capacity(tags.len());

    for tag in tags {
        let mut indices: Vec<u16> = Vec::new();

        if let Some(pairs) = singles.get(&tag) {
            let mut coverage: Vec<GlyphId16> = Vec::with_capacity(pairs.len());
            let mut replacements: Vec<GlyphId16> = Vec::with_capacity(pairs.len());
            for (from, to) in pairs {
                // A glyph can only be substituted once per lookup.
                if coverage.contains(from) {
                    continue;
                }
                coverage.push(*from);
                replacements.push(*to);
            }
            let subtables = vec![SingleSubst::format_2(
                CoverageTable::Format1(CoverageFormat1::new(coverage)),
                replacements,
            )];
            indices.push(lookups.len() as u16);
            lookups.push(SubstitutionLookup::Single(Lookup::new(
                LookupFlag::empty(),
                subtables,
            )));
        }

        if let Some(entries) = ligas.get(&tag) {
            // One ligature set per first glyph of a sequence.
            let mut by_first: BTreeMap<GlyphId16, Vec<Ligature>> = BTreeMap::new();
            for (sequence, replacement) in entries {
                let Some((first, rest)) = sequence.split_first() else {
                    continue;
                };
                by_first
                    .entry(*first)
                    .or_default()
                    .push(Ligature::new(*replacement, rest.to_vec()));
            }
            let coverage: Vec<GlyphId16> = by_first.keys().copied().collect();
            let sets: Vec<LigatureSet> = by_first
                .into_values()
                .map(|ligatures| LigatureSet::new(ligatures))
                .collect();

            indices.push(lookups.len() as u16);
            lookups.push(SubstitutionLookup::Ligature(Lookup::new(
                LookupFlag::empty(),
                vec![LigatureSubstFormat1::new(
                    CoverageTable::Format1(CoverageFormat1::new(coverage)),
                    sets,
                )],
            )));
        }

        // `ssNN` and `cvNN` features can carry a UI label; the name id is
        // written into the `name` table by `build_feature_names`.
        let feature_params = feature_names
            .get(&tag)
            .map(|name_id| FeatureParams::StylisticSet(StylisticSetParams::new(*name_id)));
        feature_records.push(FeatureRecord::new(
            tag,
            Feature {
                feature_params: feature_params.into(),
                lookup_list_indices: indices,
            },
        ));
    }

    // Register the default script, plus the scripts a shaper is most likely to
    // ask for. `required_feature_index` stays `0xFFFF` (none), so nothing is
    // forced on; the features are only made reachable.
    let feature_indices: Vec<u16> = (0..feature_records.len() as u16).collect();
    let scripts = [b"DFLT", b"hani", b"latn"]
        .iter()
        .map(|tag| {
            ScriptRecord::new(
                Tag::new(tag),
                Script::new(
                    Some(LangSys {
                        required_feature_index: 0xFFFF,
                        feature_indices: feature_indices.clone(),
                    }),
                    Vec::new(),
                ),
            )
        })
        .collect();

    Ok(Gsub {
        script_list: OffsetMarker::new(ScriptList::new(scripts)),
        feature_list: OffsetMarker::new(FeatureList::new(feature_records)),
        lookup_list: OffsetMarker::new(SubstitutionLookupList::new(lookups)),
        feature_variations: None.into(),
    })
}

/// A readable name for a glyph index, used in error messages.
fn glyph_label(index: usize, request: &FontBuildRequest) -> String {
    if index == 0 {
        return ".notdef".to_string();
    }
    if let Some(spec) = request.glyphs.get(index - 1) {
        return format!("U+{:04X}", spec.code_point);
    }
    format!("alternate glyph {index}")
}

/// Builds a `STAT` table from the `fvar` axes and named instances.
///
/// Font menus read `STAT` to show axis and preset names; `fvar` alone only
/// describes the design space.
fn build_stat(axes: &[Axis], request: &FontBuildRequest, instance_base: u16) -> Stat {
    let design_axes = axes
        .iter()
        .enumerate()
        .map(|(index, axis)| {
            DesignAxisRecord::new(
                axis.tag,
                NameId::new(FIRST_VARIATION_NAME_ID + index as u16),
                index as u16,
            )
        })
        .collect();

    let axis_values = request
        .instances
        .iter()
        .enumerate()
        .map(|(index, instance)| {
            AxisValue::format_4(
                AxisValueTableFlags::empty(),
                NameId::new(instance_base + index as u16),
                instance
                    .coordinates
                    .iter()
                    .enumerate()
                    .map(|(axis_index, value)| {
                        AxisValueRecord::new(axis_index as u16, Fixed::from_f64(*value))
                    })
                    .collect(),
            )
        })
        .collect();

    // The elided fallback is the name of the default instance, which is the
    // subfamily name these requests always carry.
    Stat::new(design_axes, axis_values, NameId::SUBFAMILY_NAME)
}

/// Builds an `HVAR` table so advance widths follow the variation axes.
///
/// One region per distinct master location that carries an advance width, and
/// one delta row per glyph id (`.notdef` included), which is the implicit
/// mapping `HVAR` uses when it has no `DeltaSetIndexMap`.
///
/// Returns `None` when no master declares an advance width.
/// Builds an `avar` table from the axes that carry a segment map.
///
/// Axes without mappings get an empty `SegmentMaps`, which is the identity.
fn build_avar(axes: &[Axis]) -> Avar {
    let segment_maps = axes
        .iter()
        .map(|axis| {
            SegmentMaps::new(
                axis.mappings
                    .iter()
                    .map(|(from, to)| {
                        AxisValueMap::new(
                            F2Dot14::from_f32(*from as f32),
                            F2Dot14::from_f32(*to as f32),
                        )
                    })
                    .collect(),
            )
        })
        .collect();
    Avar::new(segment_maps)
}

/// Builds `HVAR` (advance widths) and `MVAR` (global metrics).
///
/// Both share one region list: every distinct master location that declares
/// either an advance width or a global metric becomes a region.
fn build_metric_variations(
    request: &FontBuildRequest,
    axes: &[Axis],
    advances: &[f64],
    ascender: f64,
    descender: f64,
    num_glyphs: u32,
) -> Result<(Option<Hvar>, Option<Mvar>)> {
    let region_coords = master_regions(request, axes);
    if region_coords.is_empty() {
        return Ok((None, None));
    }

    let hvar_rows = advance_rows(request, axes, advances, &region_coords, num_glyphs);
    let mvar_rows = metric_rows(request, axes, &region_coords, ascender, descender)?;

    let mut hvar = None;
    if !hvar_rows.is_empty() {
        let store = build_item_variation_store(axes, &region_coords, &hvar_rows)?;
        hvar = Some(Hvar::new(store, None, None, None));
    }

    let mut mvar = None;
    if !mvar_rows.rows.is_empty() {
        let store = build_item_variation_store(axes, &region_coords, &mvar_rows.rows)?;
        mvar = Some(Mvar::new(
            MajorMinor::VERSION_1_0,
            Some(store),
            mvar_rows
                .tags
                .iter()
                .enumerate()
                .map(|(index, tag)| {
                    write_fonts::tables::mvar::ValueRecord::new(*tag, 0, index as u16)
                })
                .collect(),
        ));
    }

    Ok((hvar, mvar))
}

/// Every distinct master location that carries advance or metric deltas.
fn master_regions(request: &FontBuildRequest, axes: &[Axis]) -> Vec<Vec<f64>> {
    let mut region_coords: Vec<Vec<f64>> = Vec::new();
    for spec in &request.glyphs {
        for master in &spec.masters {
            let declares = master.advance_width.is_some() || !master.global_metrics.is_empty();
            if !declares || master.coordinates.len() != axes.len() {
                continue;
            }
            let normalized = normalized_coords(axes, &master.coordinates);
            if !region_coords.contains(&normalized) {
                region_coords.push(normalized);
            }
        }
    }
    region_coords
}

/// One delta row per glyph id: how much the advance width moves at a master.
///
/// Returns an empty vector when no master declares an advance width.
fn advance_rows(
    request: &FontBuildRequest,
    axes: &[Axis],
    advances: &[f64],
    region_coords: &[Vec<f64>],
    num_glyphs: u32,
) -> Vec<Vec<i32>> {
    let declares = request.glyphs.iter().any(|spec| {
        spec.masters
            .iter()
            .any(|master| master.advance_width.is_some())
    });
    if !declares {
        return Vec::new();
    }

    // Without a `DeltaSetIndexMap` the row index *is* the glyph id, so rows have
    // to be laid out in glyph id order:
    //   [.notdef, base glyphs..., alternates..., ligatures..., color layers...]
    // Padding a base glyph with zeros right after its own row (rather than at
    // the end) shifted every later row onto the wrong glyph, which silently
    // interpolated the wrong advance widths as soon as the font had a single
    // stylistic alternate.
    let mut rows: Vec<Vec<i32>> = vec![vec![0; region_coords.len()]];
    for (index, spec) in request.glyphs.iter().enumerate() {
        let default_advance = advances.get(index + 1).copied().unwrap_or(0.0);
        let mut row = vec![0i32; region_coords.len()];
        for master in &spec.masters {
            let Some(master_advance) = master.advance_width else {
                continue;
            };
            if let Some(position) = region_index(axes, master, region_coords) {
                row[position] = (master_advance - default_advance).round() as i32;
            }
        }
        rows.push(row);
    }

    // Glyph 0 (.notdef) never varies, and neither do stylistic alternates,
    // ligatures or `COLR` layers - they all live after the base glyphs, so the
    // padding for them goes here, in one block.
    let padding = num_glyphs as usize - rows.len().min(num_glyphs as usize);
    rows.extend(std::iter::repeat_n(
        vec![0i32; region_coords.len()],
        padding,
    ));
    rows
}

struct MetricRows {
    tags: Vec<Tag>,
    rows: Vec<Vec<i32>>,
}

/// One delta row per global metric tag.
fn metric_rows(
    request: &FontBuildRequest,
    axes: &[Axis],
    region_coords: &[Vec<f64>],
    ascender: f64,
    descender: f64,
) -> Result<MetricRows> {
    let mut tags: Vec<Tag> = Vec::new();
    for spec in &request.glyphs {
        for master in &spec.masters {
            for metric in &master.global_metrics {
                let tag = parse_tag(&metric.tag)?;
                if !SUPPORTED_MVAR_TAGS.contains(&tag) {
                    return Err(anyhow!(
                        "'{}' is not a supported MVAR tag ({})",
                        metric.tag,
                        SUPPORTED_MVAR_TAGS
                            .iter()
                            .map(|tag| tag.to_string())
                            .collect::<Vec<_>>()
                            .join(", ")
                    ));
                }
                if !tags.contains(&tag) {
                    tags.push(tag);
                }
            }
        }
    }
    if tags.is_empty() {
        return Ok(MetricRows {
            tags,
            rows: Vec::new(),
        });
    }
    tags.sort_by_key(|tag| tag.to_string());

    let mut rows: Vec<Vec<i32>> = Vec::with_capacity(tags.len());
    for tag in &tags {
        let default_value = default_metric(*tag, ascender, descender);
        let mut row = vec![0i32; region_coords.len()];
        for spec in &request.glyphs {
            for master in &spec.masters {
                let Some(position) = region_index(axes, master, region_coords) else {
                    continue;
                };
                if let Some(metric) = master
                    .global_metrics
                    .iter()
                    .find(|metric| parse_tag(&metric.tag).ok() == Some(*tag))
                {
                    row[position] = (metric.value - default_value).round() as i32;
                }
            }
        }
        rows.push(row);
    }

    Ok(MetricRows { tags, rows })
}

/// The metrics `MVAR` may describe, and the value they default to.
const SUPPORTED_MVAR_TAGS: [Tag; 4] = [
    Tag::new(b"hasc"), // ascender
    Tag::new(b"hdsc"), // descender
    Tag::new(b"hlgp"), // line gap
    Tag::new(b"hcla"), // cap height
];

fn default_metric(tag: Tag, ascender: f64, descender: f64) -> f64 {
    if tag == Tag::new(b"hasc") {
        ascender
    } else if tag == Tag::new(b"hdsc") {
        descender
    } else if tag == Tag::new(b"hcla") {
        ascender * 0.7
    } else {
        // `hlgp` — there is no line gap in a request.
        0.0
    }
}

/// Index of the region a master sits in, if any.
fn region_index(
    axes: &[Axis],
    master: &VariationMaster,
    region_coords: &[Vec<f64>],
) -> Option<usize> {
    if master.coordinates.len() != axes.len() {
        return None;
    }
    let normalized = normalized_coords(axes, &master.coordinates);
    region_coords
        .iter()
        .position(|coords| *coords == normalized)
}

/// Packs delta rows into an item variation store.
///
/// `word_delta_count` with its high bit set means every delta is a four byte
/// big endian `i32` — the layout `read-fonts` expects.
fn build_item_variation_store(
    axes: &[Axis],
    region_coords: &[Vec<f64>],
    rows: &[Vec<i32>],
) -> Result<ItemVariationStore> {
    let regions: Vec<VariationRegion> = region_coords
        .iter()
        .map(|coords| {
            VariationRegion::new(
                coords
                    .iter()
                    .map(|&peak| {
                        let peak = F2Dot14::from_f32(peak as f32);
                        let (start, end) = if peak.to_f32() >= 0.0 {
                            (F2Dot14::from_f32(0.0), peak)
                        } else {
                            (peak, F2Dot14::from_f32(0.0))
                        };
                        RegionAxisCoordinates::new(start, peak, end)
                    })
                    .collect(),
            )
        })
        .collect();

    let mut delta_sets = Vec::with_capacity(rows.len() * region_coords.len() * 4);
    for row in rows {
        for delta in row {
            delta_sets.extend_from_slice(&delta.to_be_bytes());
        }
    }

    let region_count = region_coords.len() as u16;
    let data = ItemVariationData::new(
        rows.len() as u16,
        region_count | 0x8000, // high bit: deltas are four bytes wide
        (0..region_count).collect(),
        delta_sets,
    );
    Ok(ItemVariationStore::new(
        VariationRegionList::new(axes.len() as u16, regions),
        vec![Some(data)],
    ))
}

/// Writes `COLR` (version 0) and `CPAL` for the glyphs that declare layers.
fn build_color_tables(
    color_glyphs: &[(u32, Vec<(u32, u16)>)],
    palette: &[u32],
) -> Result<(Colr, Cpal)> {
    let mut base_glyph_records: Vec<BaseGlyph> = Vec::new();
    let mut layer_records: Vec<ColrLayer> = Vec::new();

    for (base_gid, layers) in color_glyphs {
        let first_layer_index = layer_records.len() as u16;
        for (layer_gid, palette_index) in layers {
            if *palette_index as usize >= palette.len() {
                return Err(anyhow!(
                    "color layer {} points at palette index {}, but the palette has {} colors",
                    layer_gid,
                    palette_index,
                    palette.len()
                ));
            }
            layer_records.push(ColrLayer::new(
                GlyphId16::new(to_u16(*layer_gid)),
                *palette_index,
            ));
        }
        base_glyph_records.push(BaseGlyph::new(
            GlyphId16::new(to_u16(*base_gid)),
            first_layer_index,
            layers.len() as u16,
        ));
    }

    let colr = Colr::new(
        base_glyph_records.len() as u16,
        Some(base_glyph_records),
        Some(layer_records.clone()),
        layer_records.len() as u16,
    );

    let colors: Vec<CpalColor> = palette
        .iter()
        .map(|argb| CpalColor {
            blue: (argb & 0xFF) as u8,
            green: ((argb >> 8) & 0xFF) as u8,
            red: ((argb >> 16) & 0xFF) as u8,
            alpha: ((argb >> 24) & 0xFF) as u8,
        })
        .collect();
    let num_colors = colors.len() as u16;
    let cpal = Cpal::new(num_colors, 1, num_colors, Some(colors), vec![0]);

    Ok((colr, cpal))
}

/// Writes `vhea` and `vmtx` so the font can be laid out vertically.
fn build_vertical_metrics(
    request: &FontBuildRequest,
    vertical: &crate::api::build::VerticalMetricsSpec,
    glyphs: &[Glyph],
) -> Result<(Vhea, Vmtx)> {
    let line_gap = vertical.line_gap.unwrap_or(0.0);
    let default_advance = vertical.ascender - vertical.descender;
    // Without an explicit `vertical_origin` a glyph hangs from the vertical
    // ascender, which is the usual convention for CJK layout.
    let origin = vertical.ascender;

    let mut v_metrics: Vec<LongMetric> = Vec::with_capacity(glyphs.len());
    let mut advance_height_max = 0u32;
    let mut min_tsb = 0i32;
    let mut min_bsb = 0i32;
    let mut y_max_extent = 0i32;

    for (index, glyph) in glyphs.iter().enumerate() {
        let advance = if index == 0 {
            0.0
        } else {
            request
                .glyphs
                .get(index - 1)
                .and_then(|spec| spec.vertical_advance)
                .unwrap_or(default_advance)
        };
        let bbox = glyph.bbox().unwrap_or_default();
        let glyph_origin = request
            .glyphs
            .get(index.saturating_sub(1))
            .and_then(|spec| spec.vertical_origin)
            .unwrap_or(origin);
        let top_side_bearing = glyph_origin - bbox.y_max as f64;
        let bottom_side_bearing = (glyph_origin - advance) - bbox.y_min as f64;

        let advance = advance.round().clamp(0.0, u16::MAX as f64) as u32;
        advance_height_max = advance_height_max.max(advance);
        if index != 0 {
            min_tsb = min_tsb.min(top_side_bearing.round() as i32);
            min_bsb = min_bsb.min(bottom_side_bearing.round() as i32);
            y_max_extent = y_max_extent.max((bbox.y_max as i32).max(advance as i32));
        }
        v_metrics.push(LongMetric::new(
            to_u16(advance),
            to_i16(top_side_bearing.round() as i32),
        ));
    }

    let vhea = Vhea::new(
        to_i16(vertical.ascender.round() as i32).into(),
        to_i16(vertical.descender.round() as i32).into(),
        to_i16(line_gap.round() as i32).into(),
        to_u16(advance_height_max).into(),
        to_i16(min_tsb).into(),
        to_i16(min_bsb).into(),
        to_i16(y_max_extent).into(),
        1,
        0,
        0,
        v_metrics.len() as u16,
    );
    // Every glyph has its own entry, so there are no trailing bearings.
    Ok((vhea, Vmtx::new(v_metrics, Vec::new())))
}

fn normalized_coords(axes: &[Axis], coordinates: &[f64]) -> Vec<f64> {
    axes.iter()
        .zip(coordinates.iter())
        .map(|(axis, value)| normalize(axis, *value))
        .collect()
}

/// Allocates a name id for every stylistic set that carries a UI label.
fn build_feature_names(
    request: &FontBuildRequest,
    name_records: &mut Vec<NameRecord>,
    next_name_id: &mut u16,
) -> BTreeMap<Tag, NameId> {
    let mut names = BTreeMap::new();
    for spec in &request.glyphs {
        for alternate in &spec.alternates {
            let (Some(name), Ok(tag)) =
                (alternate.name.as_ref(), parse_tag(&alternate.feature_tag))
            else {
                continue;
            };
            if names.contains_key(&tag) {
                continue;
            }
            let id = NameId::new(*next_name_id);
            *next_name_id += 1;
            name_records.push(name_record(id, name));
            names.insert(tag, id);
        }
    }
    names
}

/// Builds a `GPOS` table with a single `kern` feature.
/// Builds a `GPOS` table with a single `kern` feature.
///
/// `glyph_for` maps a code point onto a glyph id, which is all that differs
/// between a font built from scratch and one that is being patched.
pub(crate) fn build_kern_gpos(
    pairs: &[KernPair],
    glyph_for: impl Fn(u32) -> Result<GlyphId16>,
) -> Result<Gpos> {
    // `PairPos` format 1 is one coverage entry (the left glyph) per pair set.
    //
    // Both the coverage array and the records inside a pair set are looked up
    // with a binary search (`read_fonts`: `CoverageTable::get` and
    // `PairSet::find_pair_value_record`), so they must be sorted by glyph id.
    // Collecting into `BTreeMap`s keeps them in order and drops the linear
    // scan per pair that an unsorted `Vec` needed.
    let mut by_left: BTreeMap<GlyphId16, BTreeMap<GlyphId16, i16>> = BTreeMap::new();
    for pair in pairs {
        let left = glyph_for(pair.left)?;
        let right = glyph_for(pair.right)?;
        by_left
            .entry(left)
            .or_default()
            .insert(right, to_i16(pair.value.round() as i32));
    }

    let lefts: Vec<GlyphId16> = by_left.keys().copied().collect();
    let pair_sets = by_left
        .values()
        .map(|rights| {
            PairSet::new(
                rights
                    .iter()
                    .map(|(right, value)| {
                        PairValueRecord::new(
                            *right,
                            // Kerning changes the advance of the *first* glyph.
                            ValueRecord::new().with_x_advance(*value),
                            ValueRecord::new(),
                        )
                    })
                    .collect(),
            )
        })
        .collect();
    let lookups = vec![PositionLookup::Pair(Lookup::new(
        LookupFlag::empty(),
        vec![PairPos::format_1(
            CoverageTable::Format1(CoverageFormat1::new(lefts)),
            pair_sets,
        )],
    ))];
    let feature_records = vec![FeatureRecord::new(
        Tag::new(b"kern"),
        Feature {
            feature_params: None.into(),
            lookup_list_indices: vec![0],
        },
    )];
    let scripts = [b"DFLT", b"hani", b"latn"]
        .iter()
        .map(|tag| {
            ScriptRecord::new(
                Tag::new(tag),
                Script::new(
                    Some(LangSys {
                        required_feature_index: 0xFFFF,
                        feature_indices: vec![0],
                    }),
                    Vec::new(),
                ),
            )
        })
        .collect();

    Ok(Gpos::new(
        ScriptList::new(scripts),
        FeatureList::new(feature_records),
        PositionLookupList::new(lookups),
    ))
}

/// Whether the subfamily name describes a bold and/or italic style.
pub(crate) fn is_bold_italic(subfamily: &str) -> (bool, bool) {
    let lowered = subfamily.to_lowercase();
    let spaced = lowered.replace(['-', '_'], " ");
    let words: Vec<&str> = spaced.split_whitespace().collect();
    let bold = words.iter().any(|word| {
        matches!(
            *word,
            "bold" | "semibold" | "demibold" | "extrabold" | "ultrabold" | "black" | "heavy"
        )
    });
    let italic = words
        .iter()
        .any(|word| matches!(*word, "italic" | "oblique" | "slanted"));
    (bold, italic)
}

/// Maps a subfamily name onto an `OS/2` weight class.
pub(crate) fn weight_from_subfamily(subfamily: &str) -> Option<u16> {
    let lowered = subfamily.to_lowercase();
    let spaced = lowered.replace(['-', '_'], " ");
    let words: Vec<&str> = spaced.split_whitespace().collect();
    // Checked in order: the more specific names have to win over "bold" and
    // "light", which are substrings of them.
    for word in &words {
        match *word {
            "thin" | "hairline" => return Some(100),
            "extralight" | "ultralight" => return Some(200),
            "light" => return Some(300),
            "regular" | "book" | "normal" | "roman" => return Some(400),
            "medium" => return Some(500),
            "semibold" | "demibold" => return Some(600),
            "extrabold" | "ultrabold" => return Some(800),
            "black" | "heavy" | "ultra" => return Some(900),
            _ => {}
        }
    }
    if words.iter().any(|word| *word == "bold") {
        return Some(700);
    }
    None
}

/// Best effort `OS/2` unicode range bits for a set of code points.
///
/// Only the blocks this compiler is likely to see are listed; the ranges are
/// advisory metadata, and getting one wrong never breaks rendering.
fn unicode_ranges(code_points: &[u32]) -> [u32; 4] {
    const BLOCKS: [(u8, u32, u32); 24] = [
        (0, 0x0000, 0x007F),  // Basic Latin
        (1, 0x0080, 0x00FF),  // Latin-1 Supplement
        (2, 0x0100, 0x017F),  // Latin Extended-A
        (3, 0x0180, 0x024F),  // Latin Extended-B
        (7, 0x0370, 0x03FF),  // Greek and Coptic
        (8, 0x0400, 0x04FF),  // Cyrillic
        (10, 0x0530, 0x058F), // Armenian
        (11, 0x0590, 0x05FF), // Hebrew
        (12, 0x0600, 0x06FF), // Arabic
        (15, 0x0780, 0x07BF), // Thaana
        (17, 0x0900, 0x097F), // Devanagari
        (18, 0x0980, 0x09FF), // Bengali
        (21, 0x0B00, 0x0B7F), // Oriya
        (22, 0x0B80, 0x0BFF), // Tamil
        (23, 0x0C00, 0x0C7F), // Telugu
        (24, 0x0C80, 0x0CFF), // Kannada
        (27, 0x0E00, 0x0E7F), // Thai
        (28, 0x0E80, 0x0EFF), // Lao
        (29, 0x0F00, 0x0FFF), // Tibetan
        (32, 0x1100, 0x11FF), // Hangul Jamo
        (48, 0x2700, 0x27BF), // Dingbats
        (57, 0x4E00, 0x9FFF), // CJK Unified Ideographs
        (58, 0x3000, 0x303F), // CJK Symbols and Punctuation
        (59, 0x3040, 0x309F), // Hiragana
    ];

    let mut ranges = [0u32; 4];
    for code_point in code_points {
        for (bit, start, end) in BLOCKS {
            if *code_point < start || *code_point > end {
                continue;
            }
            let word = (bit / 32) as usize;
            ranges[word] |= 1 << (bit % 32);
        }
    }
    ranges
}

/// Pads a vendor id into a four character tag; defaults to `NONE`.
pub(crate) fn vendor_tag(vendor: Option<&str>) -> Tag {
    let bytes = vendor.unwrap_or("NONE").as_bytes();
    let mut padded = *b"NONE";
    for (slot, byte) in padded.iter_mut().zip(bytes.iter().take(4)) {
        *slot = *byte;
    }
    Tag::new(&padded)
}

fn build_gvar(
    request: &FontBuildRequest,
    axes: &[Axis],
    point_sets: &[Vec<Vec<ContourPoint>>],
    num_glyphs: u32,
) -> Result<Gvar> {
    // Glyph 0 (.notdef) never varies.
    let mut variations = vec![GlyphVariations::new(GlyphId::new(0), Vec::new())];

    for (index, spec) in request.glyphs.iter().enumerate() {
        let gid = GlyphId::new((index + 1) as u32);
        let default_points = &point_sets[index + 1];
        let default_flat = flatten(default_points);

        let mut deltas = Vec::with_capacity(spec.masters.len());
        for master in &spec.masters {
            deltas.push(build_deltas(
                spec,
                master,
                axes,
                default_points,
                &default_flat,
            )?);
        }
        variations.push(GlyphVariations::new(gid, deltas));
    }

    // `gvar` stores one offset per glyph id, so it needs an entry for every
    // glyph in the font - not just the ones the `cmap` points at. Stylistic
    // alternates, ligatures and `COLR` layers come after the base glyphs and
    // never vary, but they still need a (empty) record, otherwise the table is
    // shorter than `maxp.numGlyphs` and readers index past its end.
    while variations.len() < num_glyphs as usize {
        let gid = GlyphId::new(variations.len() as u32);
        variations.push(GlyphVariations::new(gid, Vec::new()));
    }

    Gvar::new(variations, axes.len() as u16).map_err(|e| anyhow!("failed to build gvar: {e}"))
}

fn build_deltas(
    spec: &GlyphSpec,
    master: &VariationMaster,
    axes: &[Axis],
    default_points: &[Vec<ContourPoint>],
    default_flat: &[ContourPoint],
) -> Result<GlyphDeltas> {
    if master.coordinates.len() != axes.len() {
        return Err(anyhow!(
            "master of U+{:04X} needs {} coordinates, got {}",
            spec.code_point,
            axes.len(),
            master.coordinates.len()
        ));
    }

    let tents = axes
        .iter()
        .zip(master.coordinates.iter())
        .map(|(axis, value)| {
            let normalized = normalize(axis, *value);
            Tent::new(F2Dot14::from_f32(normalized as f32), None)
        })
        .collect::<Vec<_>>();

    let master_points = ordered_contours(&master.contours);
    if master_points.len() != default_points.len() {
        return Err(anyhow!(
            "master of U+{:04X} has {} contours but the default outline has {}; \
             draw every master with the same number of strokes",
            spec.code_point,
            master_points.len(),
            default_points.len()
        ));
    }

    let master_flat = flatten(&master_points);
    if master_flat.len() != default_flat.len() {
        return Err(anyhow!(
            "master of U+{:04X} has {} points but the default outline has {}; \
             masters must be point compatible",
            spec.code_point,
            master_flat.len(),
            default_flat.len()
        ));
    }

    // `gvar` deltas cover the glyph points plus four phantom points (left side
    // bearing, advance width and the vertical pair). They stay zero here, but
    // they have to be present: readers size their delta buffer as
    // `num_points + 4` and ignore a shorter array.
    let deltas = default_flat
        .iter()
        .zip(master_flat.iter())
        .map(|(from, to)| GlyphDelta::required(delta_i16(to.x - from.x), delta_i16(to.y - from.y)))
        .chain(std::iter::repeat_n(
            GlyphDelta::required(0, 0),
            PHANTOM_POINT_COUNT,
        ))
        .collect();

    Ok(GlyphDeltas::new(tents, deltas))
}

/// Maps a user space coordinate onto the normalized `[-1, 1]` range, then
/// applies the `avar` mapping of the axis (when it has one).
///
/// This is the coordinate `gvar`, `HVAR` and `MVAR` deltas are expressed in, so
/// it has to match what a reader computes: `fvar` normalization first, `avar`
/// second.
fn normalize(axis: &Axis, value: f64) -> f64 {
    apply_avar(axis, normalize_default(axis, value))
}

/// Linear `fvar` normalization, before `avar`.
fn normalize_default(axis: &Axis, value: f64) -> f64 {
    if value == axis.default_value {
        return 0.0;
    }
    let normalized = if value > axis.default_value {
        let span = axis.max_value - axis.default_value;
        if span <= 0.0 {
            0.0
        } else {
            (value - axis.default_value) / span
        }
    } else {
        let span = axis.default_value - axis.min_value;
        if span <= 0.0 {
            0.0
        } else {
            (value - axis.default_value) / span
        }
    };
    normalized.clamp(-1.0, 1.0)
}

/// Applies the `avar` segment map of an axis to a normalized coordinate.
///
/// Without mappings this is the identity, which is what `fvar` alone gives.
fn apply_avar(axis: &Axis, normalized: f64) -> f64 {
    if axis.mappings.is_empty() {
        return normalized;
    }
    let first = axis.mappings[0];
    if normalized <= first.0 {
        return first.1;
    }
    for window in axis.mappings.windows(2) {
        let (from, to) = window[0];
        let (next_from, next_to) = window[1];
        if normalized >= from && normalized <= next_from {
            let span = next_from - from;
            if span == 0.0 {
                return to;
            }
            let t = (normalized - from) / span;
            return to + (next_to - to) * t;
        }
    }
    axis.mappings[axis.mappings.len() - 1].1
}

/// One reused glyph inside a composite, in the order it is drawn.
struct CompositePart {
    gid: u32,
    dx: f64,
    dy: f64,
    scale: f64,
    use_my_metrics: bool,
}

/// Assembles a composite glyph from parts of glyphs that already exist.
///
/// The bounding box of every part is the referenced glyph's box, scaled and
/// moved into place; the composite box is their union.
fn build_composite(parts: &[CompositePart], glyphs: &[Glyph]) -> Result<Glyph> {
    let mut components: Vec<(Component, Bbox)> = Vec::with_capacity(parts.len());
    for part in parts {
        let part_bbox = glyphs
            .get(part.gid as usize)
            .and_then(|glyph| glyph.bbox())
            .unwrap_or_default();
        let placed = Bbox {
            x_min: (part_bbox.x_min as f64 * part.scale).round() as i16 + part.dx.round() as i16,
            y_min: (part_bbox.y_min as f64 * part.scale).round() as i16 + part.dy.round() as i16,
            x_max: (part_bbox.x_max as f64 * part.scale).round() as i16 + part.dx.round() as i16,
            y_max: (part_bbox.y_max as f64 * part.scale).round() as i16 + part.dy.round() as i16,
        };
        let transform = Transform {
            xx: F2Dot14::from_f32(part.scale as f32),
            yx: F2Dot14::from_f32(0.0),
            xy: F2Dot14::from_f32(0.0),
            yy: F2Dot14::from_f32(part.scale as f32),
        };
        let component = Component::new(
            GlyphId16::new(to_u16(part.gid)),
            Anchor::Offset {
                x: part.dx.round() as i16,
                y: part.dy.round() as i16,
            },
            transform,
            ComponentFlags {
                use_my_metrics: part.use_my_metrics,
                ..Default::default()
            },
        );
        components.push((component, placed));
    }

    CompositeGlyph::try_from_iter(components)
        .map(Glyph::Composite)
        .map_err(|_| anyhow!("a composite glyph needs at least one component"))
}

fn build_glyph(
    contours: &[GlyphContour],
    code_point: u32,
    instructions: Option<&[u8]>,
) -> Result<(Glyph, Vec<Vec<ContourPoint>>)> {
    let ordered = ordered_contours(contours);
    let path = bezpath_from(&ordered);
    if path.is_empty() {
        return Ok((Glyph::Empty, Vec::new()));
    }
    let mut simple = SimpleGlyph::from_bezpath(&path)
        .map_err(|e| anyhow!("glyph U+{code_point:04X} has a malformed outline ({e:?})"))?;
    if let Some(instructions) = instructions {
        simple.instructions = instructions.to_vec();
    }
    let glyph = Glyph::from(simple);

    // `gvar` deltas are indexed by glyph point number, so the compiler must not
    // add or drop points.
    if let Some(simple) = as_simple(&glyph) {
        if simple.contours.len() != ordered.len() {
            return Err(anyhow!(
                "glyph U+{code_point:04X}: contour count changed while compiling"
            ));
        }
        for (index, contour) in simple.contours.iter().enumerate() {
            if contour.len() != ordered[index].len() {
                return Err(anyhow!(
                    "glyph U+{code_point:04X}: contour {index} changed point count \
                     ({} -> {}) while compiling",
                    ordered[index].len(),
                    contour.len()
                ));
            }
        }
    }

    Ok((glyph, ordered))
}

fn as_simple(glyph: &Glyph) -> Option<&SimpleGlyph> {
    match glyph {
        Glyph::Simple(simple) => Some(simple),
        _ => None,
    }
}

fn flatten(contours: &[Vec<ContourPoint>]) -> Vec<ContourPoint> {
    contours.iter().flatten().copied().collect()
}

/// Rewrites contours into the exact point order that will end up in `glyf`.
///
/// Runs of off-curve points get the implied on-curve midpoints that the `glyf`
/// table expects, so callers may pass either all on-curve points (typical for
/// hand drawn strokes) or genuine quadratic control points.
fn ordered_contours(contours: &[GlyphContour]) -> Vec<Vec<ContourPoint>> {
    let mut result = Vec::with_capacity(contours.len());

    for contour in contours {
        let points = &contour.points;
        if points.len() < 2 {
            continue;
        }

        let mut ordered = Vec::with_capacity(points.len() + 4);

        // Start on an on-curve point. If every point is off-curve, start at the
        // implied midpoint between the last and the first point.
        match points.iter().position(|p| p.on_curve) {
            Some(index) => {
                ordered.push(points[index]);
                let rotated = rotate(points, index);
                extend_ordered(&mut ordered, &rotated[1..]);
            }
            None => {
                let last = points[points.len() - 1];
                let first = points[0];
                ordered.push(ContourPoint {
                    x: (last.x + first.x) / 2.0,
                    y: (last.y + first.y) / 2.0,
                    on_curve: true,
                });
                extend_ordered(&mut ordered, points);
            }
        }

        result.push(ordered);
    }

    result
}

/// Appends `rest` to `ordered`, inserting implied on-curve midpoints.
///
/// A trailing off-curve point is kept as-is: `glyf` implicitly closes the
/// contour, which produces the `quadTo(last, start)` segment.
fn extend_ordered(ordered: &mut Vec<ContourPoint>, rest: &[ContourPoint]) {
    let mut index = 0;
    while index < rest.len() {
        let point = rest[index];
        if point.on_curve {
            ordered.push(point);
            index += 1;
            continue;
        }
        match rest.get(index + 1) {
            Some(next) if next.on_curve => {
                ordered.push(point);
                ordered.push(*next);
                index += 2;
            }
            Some(next) => {
                ordered.push(point);
                ordered.push(ContourPoint {
                    x: (point.x + next.x) / 2.0,
                    y: (point.y + next.y) / 2.0,
                    on_curve: true,
                });
                index += 1;
            }
            None => {
                ordered.push(point);
                index += 1;
            }
        }
    }
}

/// Builds the `kurbo` path matching [ordered_contours].
fn bezpath_from(contours: &[Vec<ContourPoint>]) -> BezPath {
    let mut path = BezPath::new();

    for points in contours {
        if points.len() < 2 {
            continue;
        }
        let start = Point::new(points[0].x, points[0].y);
        path.move_to(start);

        let mut index = 1;
        while index < points.len() {
            let point = points[index];
            if point.on_curve {
                path.line_to(Point::new(point.x, point.y));
                index += 1;
            } else {
                match points.get(index + 1) {
                    Some(next) => {
                        path.quad_to(Point::new(point.x, point.y), Point::new(next.x, next.y));
                        index += 2;
                    }
                    // Implicit closing segment back to the start point.
                    None => {
                        path.quad_to(Point::new(point.x, point.y), start);
                        index += 1;
                    }
                }
            }
        }

        path.close_path();
    }

    path
}

fn rotate(points: &[ContourPoint], index: usize) -> Vec<ContourPoint> {
    points[index..]
        .iter()
        .chain(points[..index].iter())
        .copied()
        .collect()
}

fn parse_tag(tag: &str) -> Result<Tag> {
    let mut bytes = *b"    ";
    for (slot, byte) in bytes.iter_mut().zip(tag.as_bytes().iter().take(4)) {
        *slot = *byte;
    }
    Ok(Tag::new(&bytes))
}

fn name_record(name_id: NameId, value: &str) -> NameRecord {
    NameRecord {
        platform_id: WINDOWS_ROMAN.0,
        encoding_id: WINDOWS_ROMAN.1,
        language_id: WINDOWS_ROMAN.2,
        name_id,
        string: OffsetMarker::new(value.to_string()),
    }
}

fn to_i16(value: i32) -> i16 {
    value.clamp(i16::MIN as i32, i16::MAX as i32) as i16
}

fn to_u16(value: u32) -> u16 {
    value.min(u16::MAX as u32) as u16
}

fn delta_i16(value: f64) -> i16 {
    to_i16(value.round() as i32)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::build::{
        FontBuildRequest, GlyphSpec, NamedInstanceSpec, StylisticAlternate, VariationAxisSpec,
    };
    use skrifa::{instance::Size, MetadataProvider};

    fn bar(y_min: f64, y_max: f64, half_height: f64) -> GlyphContour {
        let y0 = y_min - half_height;
        let y1 = y_max + half_height;
        GlyphContour {
            points: vec![
                ContourPoint {
                    x: 80.0,
                    y: y0,
                    on_curve: true,
                },
                ContourPoint {
                    x: 920.0,
                    y: y0,
                    on_curve: true,
                },
                ContourPoint {
                    x: 920.0,
                    y: y1,
                    on_curve: true,
                },
                ContourPoint {
                    x: 80.0,
                    y: y1,
                    on_curve: true,
                },
            ],
        }
    }

    #[test]
    fn builds_a_parsable_font() {
        let bytes = build_ttf(&FontBuildRequest {
            family_name: "Draw".to_string(),
            subfamily_name: None,
            units_per_em: None,
            ascender: None,
            descender: None,
            glyphs: vec![GlyphSpec {
                code_point: 0x4E00, // 一
                contours: vec![bar(430.0, 430.0, 20.0)],
                advance_width: None,
                masters: Vec::new(),
                alternates: Vec::new(),
                ..Default::default()
            }],
            axes: Vec::new(),
            instances: Vec::new(),
            ..Default::default()
        })
        .expect("build");

        let font = skrifa::FontRef::new(&bytes).expect("parse");
        let metrics = font.metrics(Size::unscaled(), skrifa::instance::LocationRef::default());
        assert_eq!(metrics.units_per_em, 1000);
        assert_eq!(metrics.glyph_count, 2);

        let glyph = font.charmap().map('一').expect("'一' should be mapped");
        assert_eq!(glyph.to_u32(), 1);

        let mut elements = Vec::new();
        font.outline_glyphs()
            .get(glyph)
            .expect("outline")
            .draw(
                Size::unscaled(),
                &mut elements as &mut Vec<read_fonts::model::glyph::outline::PathElement>,
            )
            .expect("draw");
        assert!(!elements.is_empty());
    }

    #[test]
    fn builds_a_variable_font() {
        let bytes = build_ttf(&FontBuildRequest {
            family_name: "VariableDraw".to_string(),
            subfamily_name: None,
            units_per_em: None,
            ascender: None,
            descender: None,
            glyphs: vec![GlyphSpec {
                code_point: 0x4E00,
                contours: vec![bar(430.0, 430.0, 20.0)],
                advance_width: None,
                alternates: Vec::new(),
                masters: vec![
                    VariationMaster {
                        coordinates: vec![100.0],
                        contours: vec![bar(430.0, 430.0, 6.0)],
                        ..Default::default()
                    },
                    VariationMaster {
                        coordinates: vec![900.0],
                        contours: vec![bar(430.0, 430.0, 60.0)],
                        ..Default::default()
                    },
                ],
                ..Default::default()
            }],
            axes: vec![VariationAxisSpec {
                tag: "wght".to_string(),
                name: "Weight".to_string(),
                min_value: 100.0,
                default_value: 400.0,
                max_value: 900.0,
                ..Default::default()
            }],
            instances: vec![
                NamedInstanceSpec {
                    name: "Thin".to_string(),
                    coordinates: vec![100.0],
                },
                NamedInstanceSpec {
                    name: "Black".to_string(),
                    coordinates: vec![900.0],
                },
            ],
            ..Default::default()
        })
        .expect("build");

        let font = skrifa::FontRef::new(&bytes).expect("parse");
        let axes = font.axes();
        assert_eq!(axes.len(), 1);
        assert_eq!(axes.iter().next().unwrap().tag().to_string(), "wght");
        assert_eq!(font.named_instances().len(), 2);

        // The stroke has to get thicker as the axis moves towards the "black"
        // master, which proves `gvar` deltas are applied.
        let glyph = font.charmap().map('一').expect("mapped");
        let height_at = |value: f32| -> f64 {
            let location = axes.location([("wght", value)]);
            let bounds = font
                .glyph_metrics(Size::unscaled(), &location)
                .bounds(glyph)
                .expect("bounds");
            (bounds.y_max - bounds.y_min) as f64
        };

        let thin = height_at(100.0);
        let default = height_at(400.0);
        let black = height_at(900.0);
        assert!(
            thin < default && default < black,
            "thin={thin} default={default} black={black}"
        );
    }

    #[test]
    fn builds_stylistic_alternates() {
        use read_fonts::TableProvider;

        let bytes = build_ttf(&FontBuildRequest {
            family_name: "Alternates".to_string(),
            subfamily_name: None,
            units_per_em: None,
            ascender: None,
            descender: None,
            glyphs: vec![GlyphSpec {
                code_point: 0x4E00,
                contours: vec![bar(430.0, 430.0, 20.0)],
                advance_width: None,
                alternates: vec![
                    StylisticAlternate {
                        feature_tag: "ss01".to_string(),
                        contours: vec![bar(300.0, 300.0, 15.0)],
                        advance_width: None,
                        ..Default::default()
                    },
                    StylisticAlternate {
                        feature_tag: "ss02".to_string(),
                        contours: vec![bar(560.0, 560.0, 25.0)],
                        advance_width: None,
                        ..Default::default()
                    },
                ],
                masters: Vec::new(),
                ..Default::default()
            }],
            axes: Vec::new(),
            instances: Vec::new(),
            ..Default::default()
        })
        .expect("build");

        let font = skrifa::FontRef::new(&bytes).expect("parse");

        // .notdef + 一 + two alternates.
        assert_eq!(
            font.metrics(Size::unscaled(), skrifa::instance::LocationRef::default())
                .glyph_count,
            4
        );

        // The alternates must not be reachable through the cmap.
        assert_eq!(font.charmap().map('一').unwrap().to_u32(), 1);

        let gsub = font.gsub().expect("gsub table");

        let features = gsub.feature_list().expect("feature list");
        let feature_data = features.offset_data();
        let tags = features
            .feature_records()
            .iter()
            .map(|record| record.feature_tag().to_string())
            .collect::<Vec<_>>();
        assert_eq!(tags, ["ss01", "ss02"]);

        // Every language system references both features (at index 0 and 1), so
        // a shaper can reach them, but none is forced on.
        let scripts = gsub.script_list().expect("script list");
        let script_data = scripts.offset_data();
        let mut lang_sys_count = 0;
        for record in scripts.script_records() {
            let script = record.script(script_data).expect("script");
            let lang_sys = script.default_lang_sys().expect("default lang sys");
            let lang_sys = lang_sys.expect("lang sys");
            assert_eq!(lang_sys.required_feature_index(), 0xFFFF);
            let indices = lang_sys
                .feature_indices()
                .iter()
                .map(|index| index.get())
                .collect::<Vec<_>>();
            assert_eq!(indices, [0, 1]);
            lang_sys_count += 1;
        }
        assert_eq!(lang_sys_count, 3);

        // Each feature owns one lookup swapping glyph 1 for its alternate.
        let lookups = gsub.lookup_list().expect("lookup list");
        assert_eq!(lookups.lookup_count(), 2);
        for (index, record) in features.feature_records().iter().enumerate() {
            let feature = record.feature(feature_data).expect("feature");
            assert_eq!(feature.lookup_list_indices()[0].get(), index as u16);

            let lookup = lookups.lookups().get(index).expect("lookup");
            let read_fonts::tables::gsub::SubstitutionSubtables::Single(subtables) =
                lookup.subtables().expect("subtables")
            else {
                panic!("expected single substitution subtables");
            };
            let read_fonts::tables::gsub::SingleSubst::Format2(sub) =
                subtables.get(0).expect("subtable")
            else {
                panic!("expected a format 2 subtable");
            };
            assert_eq!(sub.coverage().expect("coverage").get(1u32), Some(0));
            assert_eq!(
                sub.substitute_glyph_ids()[0].get().to_u32(),
                (index + 2) as u32
            );
        }
    }

    #[test]
    fn rejects_point_incompatible_masters() {
        let error = build_ttf(&FontBuildRequest {
            family_name: "Bad".to_string(),
            subfamily_name: None,
            units_per_em: None,
            ascender: None,
            descender: None,
            glyphs: vec![GlyphSpec {
                code_point: 0x4E00,
                contours: vec![bar(430.0, 430.0, 20.0)],
                advance_width: None,
                alternates: Vec::new(),
                masters: vec![VariationMaster {
                    coordinates: vec![900.0],
                    // A different number of points for the same shape.
                    contours: vec![GlyphContour {
                        points: vec![
                            ContourPoint {
                                x: 80.0,
                                y: 400.0,
                                on_curve: true,
                            },
                            ContourPoint {
                                x: 920.0,
                                y: 400.0,
                                on_curve: true,
                            },
                            ContourPoint {
                                x: 920.0,
                                y: 460.0,
                                on_curve: true,
                            },
                        ],
                    }],
                    ..Default::default()
                }],
                ..Default::default()
            }],
            axes: vec![VariationAxisSpec {
                tag: "wght".to_string(),
                name: "Weight".to_string(),
                min_value: 100.0,
                default_value: 400.0,
                max_value: 900.0,
                ..Default::default()
            }],
            instances: Vec::new(),
            ..Default::default()
        })
        .expect_err("should fail");
        assert!(error.to_string().contains("point compatible"), "{error}");
    }

    fn sample_request() -> FontBuildRequest {
        FontBuildRequest {
            family_name: "Sample".to_string(),
            subfamily_name: Some("Regular".to_string()),
            units_per_em: Some(1000),
            glyphs: vec![GlyphSpec {
                code_point: 0x4E00, // 一
                contours: vec![bar(430.0, 430.0, 20.0)],
                ..Default::default()
            }],
            ..Default::default()
        }
    }

    #[test]
    fn writes_os2_style_metadata() {
        use read_fonts::tables::os2::SelectionFlags;
        use read_fonts::TableProvider;

        let bytes = build_ttf(&FontBuildRequest {
            family_name: "Meta".to_string(),
            subfamily_name: Some("Bold Italic".to_string()),
            vendor_id: Some("NOOB".to_string()),
            designer: Some("A Designer".to_string()),
            license: Some("OFL 1.1".to_string()),
            manufacturer: Some("A Foundry".to_string()),
            version: Some("Version 2.000".to_string()),
            ..sample_request()
        })
        .expect("build");
        let font = skrifa::FontRef::new(&bytes).expect("parse");

        let os2 = font.os2().expect("OS/2");
        // "Bold Italic" maps onto weight 700 and the BOLD + ITALIC bits.
        assert_eq!(os2.us_weight_class(), 700);
        assert!(os2.fs_selection().contains(SelectionFlags::BOLD));
        assert!(os2.fs_selection().contains(SelectionFlags::ITALIC));
        assert!(!os2.fs_selection().contains(SelectionFlags::REGULAR));
        assert_eq!(os2.ach_vend_id().to_string(), "NOOB");
        // U+4E00 sets bit 57 (CJK Unified Ideographs), i.e. bit 25 of range 2.
        assert_ne!(os2.ul_unicode_range_2() & (1 << 25), 0);

        let designer = font
            .localized_strings(skrifa::string::StringId::DESIGNER)
            .english_or_first()
            .expect("designer");
        assert_eq!(designer.chars().collect::<String>(), "A Designer");
        let version = font
            .localized_strings(skrifa::string::StringId::VERSION_STRING)
            .english_or_first()
            .expect("version");
        assert_eq!(version.chars().collect::<String>(), "Version 2.000");
        let license = font
            .localized_strings(skrifa::string::StringId::LICENSE_DESCRIPTION)
            .english_or_first()
            .expect("license");
        assert_eq!(license.chars().collect::<String>(), "OFL 1.1");
    }

    #[test]
    fn regular_subfamily_sets_the_regular_flag() {
        use read_fonts::tables::os2::SelectionFlags;
        use read_fonts::TableProvider;

        let bytes = build_ttf(&sample_request()).expect("build");
        let os2 = skrifa::FontRef::new(&bytes)
            .expect("parse")
            .os2()
            .expect("OS/2");
        assert_eq!(os2.us_weight_class(), 400);
        assert!(os2.fs_selection().contains(SelectionFlags::REGULAR));
        assert!(!os2.fs_selection().contains(SelectionFlags::BOLD));
    }

    #[test]
    fn writes_stat_axes_and_instances() {
        use read_fonts::TableProvider;

        let bytes = build_ttf(&variable_request()).expect("build");
        let font = skrifa::FontRef::new(&bytes).expect("parse");
        let stat = font.stat().expect("STAT");

        let axes = stat.design_axes().expect("design axes");
        assert_eq!(axes.len(), 1);
        assert_eq!(axes[0].axis_tag().to_string(), "wght");
        // One axis value per named instance.
        assert_eq!(stat.axis_value_count(), 2);
    }

    #[test]
    fn writes_hvar_so_advance_widths_interpolate() {
        let bytes = build_ttf(&FontBuildRequest {
            glyphs: vec![GlyphSpec {
                code_point: 0x4E00,
                contours: vec![bar(430.0, 430.0, 20.0)],
                // 1000 is the default (units_per_em).
                masters: vec![
                    VariationMaster {
                        coordinates: vec![100.0],
                        contours: vec![bar(430.0, 430.0, 6.0)],
                        advance_width: Some(600.0),
                        ..Default::default()
                    },
                    VariationMaster {
                        coordinates: vec![900.0],
                        contours: vec![bar(430.0, 430.0, 60.0)],
                        advance_width: Some(1200.0),
                        ..Default::default()
                    },
                ],
                ..Default::default()
            }],
            ..variable_request()
        })
        .expect("build");

        let font = skrifa::FontRef::new(&bytes).expect("parse");
        let axes = font.axes();
        let glyph = font.charmap().map('一').expect("mapped");
        let advance_at = |value: f32| -> f64 {
            let location = axes.location([("wght", value)]);
            font.glyph_metrics(Size::unscaled(), &location)
                .advance_width(glyph)
                .expect("advance") as f64
        };

        let thin = advance_at(100.0);
        let default = advance_at(400.0);
        let black = advance_at(900.0);
        assert!(
            (thin - 600.0).abs() < 1.0
                && (default - 1000.0).abs() < 1.0
                && (black - 1200.0).abs() < 1.0,
            "thin={thin} default={default} black={black}"
        );
        // Halfway between the default and the black master.
        let middle = advance_at(650.0);
        assert!((middle - 1100.0).abs() < 1.0, "middle={middle}");
    }

    #[test]
    fn writes_kern_pairs() {
        use read_fonts::TableProvider;

        let bytes = build_ttf(&FontBuildRequest {
            glyphs: vec![
                GlyphSpec {
                    code_point: 'A' as u32,
                    contours: vec![bar(300.0, 300.0, 20.0)],
                    ..Default::default()
                },
                GlyphSpec {
                    code_point: 'V' as u32,
                    contours: vec![bar(300.0, 300.0, 20.0)],
                    ..Default::default()
                },
            ],
            kern_pairs: vec![KernPair {
                left: 'A' as u32,
                right: 'V' as u32,
                value: -80.0,
            }],
            ..sample_request()
        })
        .expect("build");

        let font = skrifa::FontRef::new(&bytes).expect("parse");
        let gpos = font.gpos().expect("GPOS");
        let features = gpos.feature_list().expect("feature list");
        let tags: Vec<String> = features
            .feature_records()
            .iter()
            .map(|record| record.feature_tag().to_string())
            .collect();
        assert_eq!(tags, ["kern"]);

        let lookups = gpos.lookup_list().expect("lookup list");
        assert_eq!(lookups.lookup_count(), 1);
        let lookup = lookups.lookups().get(0).expect("lookup");
        let read_fonts::tables::gpos::PositionSubtables::Pair(subtables) =
            lookup.subtables().expect("subtables")
        else {
            panic!("expected a pair positioning subtable");
        };
        let read_fonts::tables::gpos::PairPos::Format1(pair_pos) =
            subtables.get(0).expect("subtable")
        else {
            panic!("expected pair pos format 1");
        };
        // 'A' is glyph 1, 'V' is glyph 2.
        let coverage = pair_pos.coverage().expect("coverage");
        assert_eq!(coverage.get(1u32), Some(0));
        let pair_set = pair_pos.pair_sets().get(0).expect("pair set");
        let record = pair_set
            .pair_value_records()
            .iter()
            .next()
            .expect("record")
            .expect("readable record");
        assert_eq!(record.second_glyph().to_u32(), 2);
        assert_eq!(record.value_record1.x_advance(), Some(-80));
    }

    #[test]
    fn writes_stylistic_set_names() {
        use read_fonts::TableProvider;

        let bytes = build_ttf(&FontBuildRequest {
            glyphs: vec![GlyphSpec {
                code_point: 0x4E00,
                contours: vec![bar(430.0, 430.0, 20.0)],
                alternates: vec![StylisticAlternate {
                    feature_tag: "ss01".to_string(),
                    contours: vec![bar(300.0, 300.0, 15.0)],
                    name: Some("Rounded".to_string()),
                    ..Default::default()
                }],
                ..Default::default()
            }],
            ..sample_request()
        })
        .expect("build");

        let font = skrifa::FontRef::new(&bytes).expect("parse");
        let gsub = font.gsub().expect("GSUB");
        let features = gsub.feature_list().expect("feature list");
        let data = features.offset_data();
        let record = features
            .feature_records()
            .iter()
            .find(|record| record.feature_tag().to_string() == "ss01")
            .expect("ss01");
        let feature = record.feature(data).expect("feature");
        let params = feature
            .feature_params()
            .expect("feature params")
            .expect("resolved");
        let read_fonts::tables::layout::FeatureParams::StylisticSet(params) = params else {
            panic!("expected stylistic set params");
        };
        let label = font
            .localized_strings(skrifa::string::StringId::new(params.ui_name_id().to_u16()))
            .english_or_first()
            .expect("label");
        assert_eq!(label.chars().collect::<String>(), "Rounded");
    }

    // --- regressions: these all used to produce a broken font without an
    // --- error, because the mistake only shows up in a binary search.

    #[test]
    fn rejects_duplicate_code_points() {
        let error = build_ttf(&FontBuildRequest {
            glyphs: vec![
                GlyphSpec {
                    code_point: 0x4E00,
                    contours: vec![bar(430.0, 430.0, 20.0)],
                    ..Default::default()
                },
                GlyphSpec {
                    code_point: 0x4E00, // claimed a second time
                    contours: vec![bar(200.0, 200.0, 20.0)],
                    ..Default::default()
                },
            ],
            ..sample_request()
        })
        .expect_err("two glyphs may not claim one code point");
        assert!(
            error.to_string().contains("duplicate code point"),
            "{error}"
        );
    }

    #[test]
    fn kern_pairs_are_sorted_whatever_order_they_are_declared_in() {
        use read_fonts::TableProvider;

        // 'V' is glyph 2 and 'A' is glyph 1, and the pairs are declared V->A
        // first. A coverage table built in declaration order is not ascending,
        // and `read_fonts` looks it up with a binary search, so nothing would
        // ever match and every kern would silently do nothing.
        let bytes = build_ttf(&FontBuildRequest {
            glyphs: vec![
                GlyphSpec {
                    code_point: 'A' as u32,
                    contours: vec![bar(300.0, 300.0, 20.0)],
                    ..Default::default()
                },
                GlyphSpec {
                    code_point: 'V' as u32,
                    contours: vec![bar(300.0, 300.0, 20.0)],
                    ..Default::default()
                },
            ],
            kern_pairs: vec![
                KernPair {
                    left: 'V' as u32,
                    right: 'A' as u32,
                    value: -60.0,
                },
                KernPair {
                    left: 'A' as u32,
                    right: 'V' as u32,
                    value: -80.0,
                },
            ],
            ..sample_request()
        })
        .expect("build");

        let font = skrifa::FontRef::new(&bytes).expect("parse");
        let gpos = font.gpos().expect("GPOS");
        let lookups = gpos.lookup_list().expect("lookup list");
        let lookup = lookups.lookups().get(0).expect("lookup");
        let read_fonts::tables::gpos::PositionSubtables::Pair(subtables) =
            lookup.subtables().expect("subtables")
        else {
            panic!("expected a pair positioning subtable");
        };
        let read_fonts::tables::gpos::PairPos::Format1(pair_pos) =
            subtables.get(0).expect("subtable")
        else {
            panic!("expected pair pos format 1");
        };

        // Coverage has to be ascending by glyph id.
        let coverage = pair_pos.coverage().expect("coverage");
        assert_eq!(coverage.get(1u32), Some(0), "'A' (glyph 1) must be found");
        assert_eq!(coverage.get(2u32), Some(1), "'V' (glyph 2) must be found");

        // And the records inside each pair set are binary searched too.
        assert!(
            pair_pos
                .pair_sets()
                .get(0)
                .expect("pair set for 'A'")
                .find_pair_value_record(GlyphId16::new(2))
                .is_some(),
            "A -> V must be found"
        );
        assert!(
            pair_pos
                .pair_sets()
                .get(1)
                .expect("pair set for 'V'")
                .find_pair_value_record(GlyphId16::new(1))
                .is_some(),
            "V -> A must be found"
        );
    }

    #[test]
    fn gvar_covers_every_glyph_of_a_variable_font_with_alternates() {
        use read_fonts::TableProvider;

        let bytes = build_ttf(&FontBuildRequest {
            glyphs: vec![GlyphSpec {
                code_point: 0x4E00,
                contours: vec![bar(430.0, 430.0, 20.0)],
                masters: vec![VariationMaster {
                    coordinates: vec![900.0],
                    contours: vec![bar(430.0, 430.0, 60.0)],
                    ..Default::default()
                }],
                alternates: vec![StylisticAlternate {
                    feature_tag: "ss01".to_string(),
                    contours: vec![bar(200.0, 200.0, 20.0)],
                    ..Default::default()
                }],
                ..Default::default()
            }],
            ..variable_request()
        })
        .expect("build");

        let font = skrifa::FontRef::new(&bytes).expect("parse");
        let num_glyphs = font
            .metrics(Size::unscaled(), skrifa::instance::LocationRef::default())
            .glyph_count;
        // .notdef + 一 + the ss01 alternate.
        assert_eq!(num_glyphs, 3);

        // gvar stores one offset per glyph id, so a table that stops at the
        // cmap glyphs is shorter than maxp.numGlyphs and breaks every reader.
        assert_eq!(
            font.gvar().expect("gvar").glyph_count(),
            num_glyphs,
            "gvar must cover every glyph id"
        );
    }

    #[test]
    fn hvar_rows_stay_aligned_with_glyph_ids_when_alternates_exist() {
        // 一 (glyph 1) owns an alternate, so the alternate ends up as glyph 3
        // while 二 stays glyph 2. Without a DeltaSetIndexMap the row index *is*
        // the glyph id, so the padding for the alternate belongs at the end;
        // putting it next to its own base glyph moves every later row onto the
        // wrong glyph and interpolates the wrong advance widths.
        let bytes = build_ttf(&FontBuildRequest {
            glyphs: vec![
                GlyphSpec {
                    code_point: 0x4E00, // 一
                    contours: vec![bar(430.0, 430.0, 20.0)],
                    alternates: vec![StylisticAlternate {
                        feature_tag: "ss01".to_string(),
                        contours: vec![bar(200.0, 200.0, 20.0)],
                        ..Default::default()
                    }],
                    ..Default::default()
                },
                GlyphSpec {
                    code_point: 0x4E8C, // 二, glyph 2, declares the advance
                    contours: vec![bar(430.0, 430.0, 20.0)],
                    masters: vec![VariationMaster {
                        coordinates: vec![900.0],
                        contours: vec![bar(430.0, 430.0, 60.0)],
                        advance_width: Some(1200.0),
                        ..Default::default()
                    }],
                    ..Default::default()
                },
            ],
            ..variable_request()
        })
        .expect("build");

        let font = skrifa::FontRef::new(&bytes).expect("parse");
        let axes = font.axes();
        let advance_of = |code_point: char, value: f32| -> f64 {
            let location = axes.location([("wght", value)]);
            font.glyph_metrics(Size::unscaled(), &location)
                .advance_width(font.charmap().map(code_point).expect("mapped"))
                .expect("advance") as f64
        };

        // 二 declares the master advance and must follow the axis.
        let regular = advance_of('二', 400.0);
        let black = advance_of('二', 900.0);
        assert!((regular - 1000.0).abs() < 1.0, "regular={regular}");
        assert!((black - 1200.0).abs() < 1.0, "black={black}");

        // 一 declares nothing, so it must stay put - before the fix it picked
        // up whatever row the misalignment left on glyphs 1 and 3.
        assert!(
            (advance_of('一', 400.0) - 1000.0).abs() < 1.0
                && (advance_of('一', 900.0) - 1000.0).abs() < 1.0,
            "一 must not vary"
        );
    }

    fn variable_request() -> FontBuildRequest {
        FontBuildRequest {
            family_name: "Variable".to_string(),
            glyphs: vec![GlyphSpec {
                code_point: 0x4E00,
                contours: vec![bar(430.0, 430.0, 20.0)],
                ..Default::default()
            }],
            axes: vec![VariationAxisSpec {
                tag: "wght".to_string(),
                name: "Weight".to_string(),
                min_value: 100.0,
                default_value: 400.0,
                max_value: 900.0,
                ..Default::default()
            }],
            instances: vec![
                NamedInstanceSpec {
                    name: "Thin".to_string(),
                    coordinates: vec![100.0],
                },
                NamedInstanceSpec {
                    name: "Black".to_string(),
                    coordinates: vec![900.0],
                },
            ],
            ..Default::default()
        }
    }
    fn bar_at(x0: f64, x1: f64, y0: f64, y1: f64) -> GlyphContour {
        GlyphContour {
            points: vec![
                ContourPoint {
                    x: x0,
                    y: y0,
                    on_curve: true,
                },
                ContourPoint {
                    x: x1,
                    y: y0,
                    on_curve: true,
                },
                ContourPoint {
                    x: x1,
                    y: y1,
                    on_curve: true,
                },
                ContourPoint {
                    x: x0,
                    y: y1,
                    on_curve: true,
                },
            ],
        }
    }

    #[test]
    fn writes_composite_glyphs() {
        let bytes = build_ttf(&FontBuildRequest {
            family_name: "Composite".to_string(),
            glyphs: vec![
                GlyphSpec {
                    code_point: 'A' as u32,
                    contours: vec![bar_at(80.0, 920.0, 400.0, 460.0)],
                    ..Default::default()
                },
                GlyphSpec {
                    code_point: 'B' as u32,
                    components: vec![
                        crate::api::build::GlyphComponent {
                            code_point: 'A' as u32,
                            ..Default::default()
                        },
                        crate::api::build::GlyphComponent {
                            code_point: 'A' as u32,
                            dx: 100.0,
                            dy: 200.0,
                            ..Default::default()
                        },
                    ],
                    ..Default::default()
                },
            ],
            ..Default::default()
        })
        .expect("build");

        let font = skrifa::FontRef::new(&bytes).expect("parse");
        let gid_b = font.charmap().map('B').expect("mapped");
        assert_eq!(gid_b.to_u32(), 2);

        // Drawing the composite has to place both copies of the component, so
        // the outline reaches past the first one.
        let mut elements: Vec<read_fonts::model::glyph::outline::PathElement> = Vec::new();
        font.outline_glyphs()
            .get(gid_b)
            .expect("outline")
            .draw(Size::unscaled(), &mut elements)
            .expect("draw");
        let mut y_max = f32::MIN;
        for element in &elements {
            match *element {
                read_fonts::model::glyph::outline::PathElement::MoveTo { y, .. }
                | read_fonts::model::glyph::outline::PathElement::LineTo { y, .. }
                | read_fonts::model::glyph::outline::PathElement::QuadTo { y, .. }
                | read_fonts::model::glyph::outline::PathElement::CurveTo { y, .. } => {
                    y_max = y_max.max(y)
                }
                read_fonts::model::glyph::outline::PathElement::Close => {}
            }
        }
        assert!(y_max > 600.0, "y_max={y_max} elements={elements:?}");
    }

    #[test]
    fn rejects_masters_on_composite_glyphs() {
        let error = build_ttf(&FontBuildRequest {
            family_name: "Bad".to_string(),
            glyphs: vec![
                GlyphSpec {
                    code_point: 'A' as u32,
                    contours: vec![bar(430.0, 430.0, 20.0)],
                    ..Default::default()
                },
                GlyphSpec {
                    code_point: 'B' as u32,
                    components: vec![crate::api::build::GlyphComponent {
                        code_point: 'A' as u32,
                        ..Default::default()
                    }],
                    masters: vec![VariationMaster {
                        coordinates: vec![900.0],
                        contours: vec![bar(430.0, 430.0, 20.0)],
                        ..Default::default()
                    }],
                    ..Default::default()
                },
            ],
            axes: vec![VariationAxisSpec {
                tag: "wght".to_string(),
                name: "Weight".to_string(),
                min_value: 100.0,
                default_value: 400.0,
                max_value: 900.0,
                ..Default::default()
            }],
            ..Default::default()
        })
        .expect_err("should fail");
        assert!(error.to_string().contains("composite"), "{error}");
    }

    #[test]
    fn writes_ligatures() {
        use read_fonts::TableProvider;

        let bytes = build_ttf(&FontBuildRequest {
            family_name: "Ligatures".to_string(),
            glyphs: vec![
                GlyphSpec {
                    code_point: 'f' as u32,
                    contours: vec![bar_at(80.0, 400.0, 400.0, 460.0)],
                    ..Default::default()
                },
                GlyphSpec {
                    code_point: 'i' as u32,
                    contours: vec![bar_at(80.0, 400.0, 400.0, 460.0)],
                    ..Default::default()
                },
            ],
            ligatures: vec![crate::api::build::LigatureSpec {
                feature_tag: "liga".to_string(),
                sequence: vec!['f' as u32, 'i' as u32],
                contours: vec![bar_at(80.0, 800.0, 400.0, 460.0)],
                ..Default::default()
            }],
            ..Default::default()
        })
        .expect("build");

        let font = skrifa::FontRef::new(&bytes).expect("parse");
        let gsub = font.gsub().expect("GSUB");
        let features = gsub.feature_list().expect("feature list");
        let tags: Vec<String> = features
            .feature_records()
            .iter()
            .map(|record| record.feature_tag().to_string())
            .collect();
        assert_eq!(tags, ["liga"]);

        // The ligature glyph (glyph 3) is not reachable through the cmap.
        assert_eq!(font.charmap().map('f').unwrap().to_u32(), 1);

        let lookups = gsub.lookup_list().expect("lookup list");
        let lookup = lookups.lookups().get(0).expect("lookup");
        let read_fonts::tables::gsub::SubstitutionSubtables::Ligature(subtables) =
            lookup.subtables().expect("subtables")
        else {
            panic!("expected a ligature subtable");
        };
        let lig = subtables.get(0).expect("subtable");
        // 'f' (glyph 1) is the first glyph of the sequence.
        assert_eq!(lig.coverage().expect("coverage").get(1u32), Some(0));
        let ligature_set = lig.ligature_sets().get(0).expect("ligature set");
        let ligature = ligature_set
            .ligatures()
            .iter()
            .next()
            .expect("ligature")
            .expect("readable");
        assert_eq!(ligature.ligature_glyph().to_u32(), 3);
        let components: Vec<u32> = ligature
            .component_glyph_ids()
            .iter()
            .map(|gid| gid.get().to_u32())
            .collect();
        // The first glyph of the sequence is implied by the coverage.
        assert_eq!(components, [2]);
    }

    #[test]
    fn writes_color_layers_and_palette() {
        let font = crate::api::fontations::Font::from_bytes(
            build_ttf(&FontBuildRequest {
                family_name: "Color".to_string(),
                palette: vec![0xFFFF0000, 0xFF0000FF],
                glyphs: vec![GlyphSpec {
                    code_point: 0x2764, // ❤
                    contours: vec![bar(430.0, 430.0, 20.0)],
                    color_layers: vec![
                        crate::api::build::GlyphColorLayer {
                            contours: vec![bar_at(100.0, 500.0, 200.0, 300.0)],
                            palette_index: 0,
                        },
                        crate::api::build::GlyphColorLayer {
                            contours: vec![bar_at(500.0, 900.0, 200.0, 300.0)],
                            palette_index: 1,
                        },
                    ],
                    ..Default::default()
                }],
                ..Default::default()
            })
            .expect("build"),
            None,
        )
        .expect("parse");

        let palettes = font.color_palettes().expect("palettes");
        assert_eq!(palettes.len(), 1);
        assert_eq!(palettes[0].colors, [0xFFFF0000, 0xFF0000FF]);

        let glyph_id = font.char_to_glyph(0x2764).expect("mapped").unwrap();
        assert!(font.has_color_glyph(glyph_id).expect("has color"));
        let glyph = font
            .color_glyph(glyph_id, None, Vec::new())
            .expect("color glyph")
            .expect("present");
        assert_eq!(glyph.format, "colrV0");
        assert_eq!(glyph.layers.len(), 2);
    }

    #[test]
    fn writes_avar_and_remaps_the_axis() {
        let build = |mappings: Vec<crate::api::build::AxisValueMapSpec>| -> Vec<u8> {
            build_ttf(&FontBuildRequest {
                family_name: "Avar".to_string(),
                glyphs: vec![GlyphSpec {
                    code_point: 0x4E00,
                    contours: vec![bar(430.0, 430.0, 20.0)],
                    masters: vec![VariationMaster {
                        coordinates: vec![900.0],
                        contours: vec![bar(430.0, 430.0, 60.0)],
                        ..Default::default()
                    }],
                    ..Default::default()
                }],
                axes: vec![VariationAxisSpec {
                    tag: "wght".to_string(),
                    name: "Weight".to_string(),
                    min_value: 100.0,
                    default_value: 400.0,
                    max_value: 900.0,
                    mappings,
                }],
                ..Default::default()
            })
            .expect("build")
        };

        let height_at = |bytes: &[u8], value: f32| -> f64 {
            let font = skrifa::FontRef::new(bytes).expect("parse");
            let location = font.axes().location([("wght", value)]);
            let glyph = font.charmap().map('一').expect("mapped");
            let bounds = font
                .glyph_metrics(Size::unscaled(), &location)
                .bounds(glyph)
                .expect("bounds");
            (bounds.y_max - bounds.y_min) as f64
        };

        let plain = build(Vec::new());
        // Pinning the whole axis to the default makes the master unreachable,
        // so the outline stops changing: proof the mapping is applied.
        let pinned = build(vec![
            crate::api::build::AxisValueMapSpec {
                from: -1.0,
                to: 0.0,
            },
            crate::api::build::AxisValueMapSpec { from: 0.0, to: 0.0 },
            crate::api::build::AxisValueMapSpec { from: 1.0, to: 0.0 },
        ]);

        assert!(height_at(&plain, 900.0) > height_at(&plain, 400.0));
        assert!(
            (height_at(&pinned, 900.0) - height_at(&pinned, 400.0)).abs() < 1.0,
            "{} vs {}",
            height_at(&pinned, 900.0),
            height_at(&pinned, 400.0)
        );
    }

    #[test]
    fn writes_mvar_so_global_metrics_interpolate() {
        let bytes = build_ttf(&FontBuildRequest {
            family_name: "Mvar".to_string(),
            ascender: Some(800.0),
            descender: Some(-200.0),
            glyphs: vec![GlyphSpec {
                code_point: 0x4E00,
                contours: vec![bar(430.0, 430.0, 20.0)],
                masters: vec![VariationMaster {
                    coordinates: vec![900.0],
                    contours: vec![bar(430.0, 430.0, 60.0)],
                    global_metrics: vec![crate::api::build::MetricValue {
                        tag: "hasc".to_string(),
                        value: 1000.0,
                    }],
                    ..Default::default()
                }],
                ..Default::default()
            }],
            axes: vec![VariationAxisSpec {
                tag: "wght".to_string(),
                name: "Weight".to_string(),
                min_value: 100.0,
                default_value: 400.0,
                max_value: 900.0,
                ..Default::default()
            }],
            ..Default::default()
        })
        .expect("build");

        let font = skrifa::FontRef::new(&bytes).expect("parse");
        let ascent_at = |value: f32| -> f64 {
            let location = font.axes().location([("wght", value)]);
            font.metrics(Size::unscaled(), &location).ascent as f64
        };
        assert!(
            (ascent_at(400.0) - 800.0).abs() < 1.0,
            "{}",
            ascent_at(400.0)
        );
        assert!(
            (ascent_at(900.0) - 1000.0).abs() < 1.0,
            "{}",
            ascent_at(900.0)
        );
    }

    #[test]
    fn writes_vertical_metrics() {
        let font = crate::api::fontations::Font::from_bytes(
            build_ttf(&FontBuildRequest {
                family_name: "Vertical".to_string(),
                vertical_metrics: Some(crate::api::build::VerticalMetricsSpec {
                    ascender: 880.0,
                    descender: -120.0,
                    line_gap: None,
                }),
                glyphs: vec![GlyphSpec {
                    code_point: 0x4E00,
                    contours: vec![bar(430.0, 430.0, 20.0)],
                    ..Default::default()
                }],
                ..Default::default()
            })
            .expect("build"),
            None,
        )
        .expect("parse");

        let metrics = font.vertical_metrics().expect("vertical").expect("present");
        assert_eq!(metrics.ascender, 880.0);
        assert_eq!(metrics.descender, -120.0);
        // 880 - (-120) is the default advance height.
        assert!((font.vertical_advance(1).unwrap().unwrap() - 1000.0).abs() < 1.0);
    }

    #[test]
    fn writes_cmap_variation_selectors() {
        let font = crate::api::fontations::Font::from_bytes(
            build_ttf(&FontBuildRequest {
                family_name: "Uvs".to_string(),
                glyphs: vec![
                    GlyphSpec {
                        code_point: 0x845B,
                        contours: vec![bar(430.0, 430.0, 20.0)],
                        ..Default::default()
                    },
                    GlyphSpec {
                        code_point: 0xE0100,
                        contours: vec![bar_at(100.0, 900.0, 200.0, 300.0)],
                        ..Default::default()
                    },
                ],
                variation_selectors: vec![crate::api::build::VariationSelectorSpec {
                    selector: 0xE0100,
                    variants: vec![crate::api::build::CodePointVariant {
                        code_point: 0x845B,
                        variant_code_point: 0xE0100,
                    }],
                }],
                ..Default::default()
            })
            .expect("build"),
            None,
        )
        .expect("parse");

        assert!(font.charmap_info().expect("charmap").has_variant_map);
        assert!(font.has_table("cmap".to_string()).expect("cmap"));
    }

    #[test]
    fn writes_raw_tables_and_glyph_instructions() {
        let font = crate::api::fontations::Font::from_bytes(
            build_ttf(&FontBuildRequest {
                family_name: "Hinted".to_string(),
                glyphs: vec![GlyphSpec {
                    code_point: 0x4E00,
                    contours: vec![bar(430.0, 430.0, 20.0)],
                    instructions: Some(vec![0xB0, 0x01, 0x2F, 0x3E]),
                    ..Default::default()
                }],
                raw_tables: vec![crate::api::build::RawTableSpec {
                    tag: "fpgm".to_string(),
                    data: vec![0xB0, 0x01],
                }],
                ..Default::default()
            })
            .expect("build"),
            None,
        )
        .expect("parse");

        assert!(font.has_table("fpgm".to_string()).expect("fpgm"));
        assert_eq!(
            font.table_data("fpgm".to_string()).expect("data").unwrap(),
            vec![0xB0, 0x01]
        );

        // The instructions are stored in the glyph, right after its points.
        let glyf = font.table_data("glyf".to_string()).unwrap().unwrap();
        assert!(
            glyf.windows(4)
                .any(|window| window == [0xB0, 0x01, 0x2F, 0x3E]),
            "instructions not found in glyf"
        );
    }

    #[test]
    fn modifies_an_existing_font() {
        use crate::font_modify::modify_ttf;

        let original = build_ttf(&FontBuildRequest {
            family_name: "Original".to_string(),
            glyphs: vec![
                GlyphSpec {
                    code_point: 'A' as u32,
                    contours: vec![bar_at(80.0, 400.0, 400.0, 460.0)],
                    ..Default::default()
                },
                GlyphSpec {
                    code_point: 'V' as u32,
                    contours: vec![bar_at(80.0, 400.0, 400.0, 460.0)],
                    ..Default::default()
                },
                GlyphSpec {
                    code_point: 0x4E00,
                    contours: vec![bar_at(80.0, 800.0, 400.0, 460.0)],
                    ..Default::default()
                },
            ],
            ..Default::default()
        })
        .expect("build");

        let patched = modify_ttf(
            &original,
            &crate::api::build::FontModificationRequest {
                family_name: Some("Patched".to_string()),
                subfamily_name: Some("Bold".to_string()),
                designer: Some("Someone".to_string()),
                kern_pairs: vec![KernPair {
                    left: 'A' as u32,
                    right: 'V' as u32,
                    value: -80.0,
                }],
                alternates: vec![crate::api::build::ExistingAlternateSpec {
                    feature_tag: "ss01".to_string(),
                    code_point: 'A' as u32,
                    replacement_code_point: 0x4E00,
                    name: Some("Wide A".to_string()),
                }],
                ..Default::default()
            },
        )
        .expect("modify");

        let font = crate::api::fontations::Font::from_bytes(patched, None).expect("parse");

        // Metadata changed...
        let records = font.name_records(Some(1)).expect("records");
        assert!(records.iter().any(|record| record.value == "Patched"));
        assert_eq!(font.attributes().expect("attributes").weight, 700.0);

        // ...the outlines did not.
        assert_eq!(font.char_to_glyph('A' as u32).unwrap(), Some(1));
        assert_eq!(font.char_to_glyph(0x4E00).unwrap(), Some(3));

        let layout = font.layout(None).expect("layout");
        let gsub = layout.iter().find(|table| table.table == "GSUB").unwrap();
        assert!(gsub.features.iter().any(|feature| feature.tag == "ss01"));
        let gpos = layout.iter().find(|table| table.table == "GPOS").unwrap();
        assert_eq!(gpos.features[0].tag, "kern");
    }
}
