//! Serializes the upstream table types the core font builder does not emit.
//!
//! All three entry points patch an existing font rather than building one:
//! `FontBuilder::copy_missing_tables` keeps outlines, `cmap`, variations and
//! every other table byte-for-byte, and only the table being written changes.

use std::collections::BTreeMap;

use anyhow::{anyhow, Result};
use read_fonts::types::{F2Dot14, FWord, GlyphId, GlyphId16, GlyphId24, Tag, UfWord};
use read_fonts::{FontRef, TableProvider};
use skrifa::MetadataProvider;
use write_fonts::from_obj::ToOwnedTable;
use write_fonts::tables::colr::{
    BaseGlyphList, BaseGlyphPaint, ColorLine, ColorStop, Colr, CompositeMode, Extend, LayerList,
    Paint,
};
use write_fonts::tables::cpal::{ColorRecord, Cpal};
use write_fonts::tables::gpos::Gpos;
use write_fonts::tables::gsub::{
    AlternateSet, AlternateSet2, AlternateSubst, AlternateSubstFormat1, AlternateSubstFormat2,
    Gsub, MultipleSubst, MultipleSubstFormat1, MultipleSubstFormat2,
    ReverseChainSingleSubstFormat1, ReverseChainSingleSubstFormat2, Sequence, Sequence2,
    SingleSubst, SingleSubstFormat4, SubstitutionChainContext, SubstitutionLookup,
    SubstitutionLookupList, SubstitutionLookupList2, SubstitutionSequenceContext,
};
use write_fonts::tables::layout::{
    ChainedSequenceContext, ChainedSequenceContextFormat3, Condition, ConditionSet,
    CoverageFormat1, CoverageTable, DeviceOrVariationIndex, Feature, FeatureList, FeatureParams,
    FeatureRecord, FeatureTableSubstitution, FeatureTableSubstitutionRecord,
    FeatureVariationRecord, FeatureVariations, LangSys, Lookup, LookupFlag, Script, ScriptList,
    ScriptRecord, SequenceContext, SequenceContextFormat3, SequenceContextFormat6,
    SequenceLookupRecord,
};
use write_fonts::tables::math::{
    GlyphAssembly, GlyphPartRecord, Math, MathConstants, MathGlyphConstruction, MathGlyphInfo,
    MathGlyphVariantRecord, MathItalicsCorrectionInfo, MathKern, MathKernInfo, MathKernInfoRecord,
    MathTopAccentAttachment, MathValueRecord, MathVariants, PartFlags,
};
use write_fonts::tables::varc::{
    DecomposedTransform as WriteTransform, VarComponent, VarCompositeGlyph, Varc as WriteVarc,
    VarcVariationIndex,
};
use write_fonts::tables::variations::mivs_builder::{MultiItemVariationStoreBuilder, SparseRegion};
use write_fonts::FontBuilder;

use crate::api::upstream::{
    BitmapGlyphSpec, BitmapStrikeSpec, ColorGlyphPaintSpec, FeatureConditionSpec,
    FeatureVariationPatchRequest, MathConstantSpec, MathConstructionSpec, MathGlyphValueSpec,
    MathTableRequest, PaintNodeSpec, PatchRawTableSpec, SubstitutionPatchRequest, SvgDocumentSpec,
    VarcPatchRequest, VerticalOriginRequest,
};
use crate::limits::{check_font_bytes, MAX_CONDITION_DEPTH, MAX_CONDITION_NODES};

fn font_ref(bytes: &[u8]) -> Result<FontRef<'_>> {
    FontRef::new(bytes).map_err(|e| anyhow!("not a usable font file: {e}"))
}

fn parse_tag(value: &str) -> Result<Tag> {
    let bytes: [u8; 4] = value
        .as_bytes()
        .get(..4)
        .ok_or_else(|| anyhow!("tag '{value}' must be four characters"))?
        .try_into()
        .map_err(|_| anyhow!("tag '{value}' must be four characters"))?;
    Ok(Tag::new(&bytes))
}

fn glyph_for(font: &FontRef<'_>, code_point: u32) -> Result<u32> {
    font.charmap()
        .map(code_point)
        .map(|glyph_id| glyph_id.to_u32())
        .ok_or_else(|| anyhow!("the font has no glyph for U+{code_point:04X}"))
}

fn push_u16(out: &mut Vec<u8>, value: u16) {
    out.extend_from_slice(&value.to_be_bytes());
}

fn push_i16(out: &mut Vec<u8>, value: i16) {
    out.extend_from_slice(&value.to_be_bytes());
}

fn push_u32(out: &mut Vec<u8>, value: u32) {
    out.extend_from_slice(&value.to_be_bytes());
}

fn f2(value: f64) -> F2Dot14 {
    F2Dot14::from_f32(value.clamp(-2.0, 1.9999) as f32)
}

// ---------------------------------------------------------------------------
// B1: sbix bitmap strikes
// ---------------------------------------------------------------------------

/// Adds `sbix` strikes. `write-fonts` 0.56 writes the strike header but not the
/// glyph image payload, so this assembles the table in the OpenType layout
/// (header, per-strike offsets, then `GlyphData` records) and installs it as a
/// raw table.
pub fn add_bitmap_strikes(bytes: &[u8], strikes: &[BitmapStrikeSpec]) -> Result<Vec<u8>> {
    check_font_bytes(bytes)?;
    let font = font_ref(bytes)?;
    if strikes.is_empty() {
        return Err(anyhow!("at least one bitmap strike is required"));
    }
    let num_glyphs = font
        .maxp()
        .map(|maxp| maxp.num_glyphs() as usize)
        .unwrap_or(0);
    if num_glyphs == 0 {
        return Err(anyhow!("the font has no glyphs"));
    }

    let mut strike_data: Vec<Vec<u8>> = Vec::new();
    for strike in strikes {
        let mut by_gid: BTreeMap<usize, &BitmapGlyphSpec> = BTreeMap::new();
        for glyph in &strike.glyphs {
            let gid = glyph_for(&font, glyph.code_point)? as usize;
            if gid >= num_glyphs {
                return Err(anyhow!(
                    "bitmap for U+{:04X} points at glyph {gid}, but the font has {num_glyphs}",
                    glyph.code_point
                ));
            }
            if by_gid.insert(gid, glyph).is_some() {
                return Err(anyhow!("two bitmaps target glyph {gid} in one strike"));
            }
        }
        let graphic_of = |glyph: &BitmapGlyphSpec| -> Result<[u8; 4]> {
            let raw = glyph.format.as_bytes();
            if raw.len() != 4 {
                return Err(anyhow!(
                    "bitmap format '{}' must be four characters (png , jpg , tiff, dupe)",
                    glyph.format
                ));
            }
            Ok([raw[0], raw[1], raw[2], raw[3]])
        };

        let mut header = Vec::new();
        push_u16(&mut header, strike.ppem.min(u16::MAX as u32) as u16);
        push_u16(&mut header, strike.ppi.min(u16::MAX as u32) as u16);
        let mut offsets = vec![0u32; num_glyphs + 1];
        let mut payload = Vec::new();
        let mut cursor = 4usize + 4 * (num_glyphs + 1);
        for gid in 0..num_glyphs {
            offsets[gid] = cursor as u32;
            if let Some(glyph) = by_gid.get(&gid) {
                push_i16(&mut payload, glyph.origin_offset_x as i16);
                push_i16(&mut payload, glyph.origin_offset_y as i16);
                payload.extend_from_slice(&graphic_of(glyph)?);
                payload.extend_from_slice(&glyph.data);
                cursor += 8 + glyph.data.len();
            }
        }
        offsets[num_glyphs] = cursor as u32;
        for offset in offsets {
            push_u32(&mut header, offset);
        }
        header.extend_from_slice(&payload);
        strike_data.push(header);
    }

    let mut table = Vec::new();
    push_u16(&mut table, 1); // version
    push_u16(&mut table, 1); // flags: bit 0 must be set
    push_u32(&mut table, strike_data.len() as u32);
    let mut cursor = 8usize + 4 * strike_data.len();
    for data in &strike_data {
        push_u32(&mut table, cursor as u32);
        cursor += data.len();
    }
    for data in strike_data {
        table.extend_from_slice(&data);
    }

    let mut builder = FontBuilder::new();
    builder.add_raw(Tag::new(b"sbix"), table);
    builder.copy_missing_tables(font);
    Ok(builder.build())
}

// ---------------------------------------------------------------------------
// B2: GSUB substitution patches
// ---------------------------------------------------------------------------

/// One contextual rule, with glyph ids instead of code points.
#[derive(Debug, Clone)]
struct ContextualRule {
    tag: Tag,
    backtrack: Vec<u32>,
    input: Vec<u32>,
    lookahead: Vec<u32>,
    replacement: u32,
}

/// One reverse chaining rule, with glyph ids instead of code points.
#[derive(Debug, Clone)]
struct ReverseRule {
    tag: Tag,
    from: u32,
    to: u32,
    backtrack: Vec<u32>,
    lookahead: Vec<u32>,
}

/// Adds `GSUB` substitutions to an existing font: multiple, alternate,
/// contextual and reverse-chain lookups, in either the original or the 2026
/// v2 encoding. Replacement glyphs must already exist (addressed by code point).
pub fn add_substitutions(bytes: &[u8], request: &SubstitutionPatchRequest) -> Result<Vec<u8>> {
    check_font_bytes(bytes)?;
    let font = font_ref(bytes)?;
    let map = |code_points: &[u32]| -> Result<Vec<u32>> {
        code_points
            .iter()
            .map(|code_point| glyph_for(&font, *code_point))
            .collect()
    };

    let mut multiples = Vec::new();
    for spec in &request.multiple {
        let replacements = map(&spec.replacement_code_points)?;
        if replacements.is_empty() {
            return Err(anyhow!(
                "a multiple substitution needs at least one replacement glyph"
            ));
        }
        multiples.push((
            parse_tag(&spec.feature_tag)?,
            glyph_for(&font, spec.code_point)?,
            replacements,
        ));
    }
    let mut alternates = Vec::new();
    for spec in &request.alternate {
        let replacements = map(&spec.replacement_code_points)?;
        if replacements.is_empty() {
            return Err(anyhow!(
                "an alternate substitution needs at least one replacement glyph"
            ));
        }
        alternates.push((
            parse_tag(&spec.feature_tag)?,
            glyph_for(&font, spec.code_point)?,
            replacements,
        ));
    }
    let mut contextuals = Vec::new();
    for spec in &request.contextual {
        let input = map(&spec.input)?;
        if input.is_empty() {
            return Err(anyhow!("a contextual substitution needs an input sequence"));
        }
        contextuals.push(ContextualRule {
            tag: parse_tag(&spec.feature_tag)?,
            backtrack: map(&spec.backtrack)?,
            input,
            lookahead: map(&spec.lookahead)?,
            replacement: glyph_for(&font, spec.replacement_code_point)?,
        });
    }
    let mut reverses = Vec::new();
    for spec in &request.reverse_chain {
        reverses.push(ReverseRule {
            tag: parse_tag(&spec.feature_tag)?,
            from: glyph_for(&font, spec.code_point)?,
            to: glyph_for(&font, spec.replacement_code_point)?,
            backtrack: map(&spec.backtrack)?,
            lookahead: map(&spec.lookahead)?,
        });
    }
    if multiples.is_empty()
        && alternates.is_empty()
        && contextuals.is_empty()
        && reverses.is_empty()
    {
        return Err(anyhow!("no substitutions requested"));
    }

    let gsub = build_patch_gsub(
        &multiples,
        &alternates,
        &contextuals,
        &reverses,
        request.use_v2,
    )?;
    let mut builder = FontBuilder::new();
    builder.add_table(&gsub)?;
    builder.copy_missing_tables(font);
    Ok(builder.build())
}

fn coverage_for(glyphs: &[u32], v2: bool) -> CoverageTable {
    let mut ids = glyphs.to_vec();
    ids.sort_unstable();
    ids.dedup();
    if v2 {
        CoverageTable::format_3(ids.iter().map(|id| GlyphId24::new(*id)).collect())
    } else {
        CoverageTable::format_1(ids.iter().map(|id| GlyphId16::new(*id as u16)).collect())
    }
}

fn single_coverages(glyphs: &[u32], v2: bool) -> Vec<CoverageTable> {
    glyphs.iter().map(|id| coverage_for(&[*id], v2)).collect()
}

fn add_lookup(
    lookups: &mut Vec<SubstitutionLookup>,
    indices: &mut BTreeMap<Tag, Vec<u16>>,
    tag: Tag,
    lookup: SubstitutionLookup,
) -> Result<()> {
    let index = u16::try_from(lookups.len()).map_err(|_| anyhow!("too many GSUB lookups"))?;
    lookups.push(lookup);
    indices.entry(tag).or_default().push(index);
    Ok(())
}

/// Builds the patch GSUB from scratch. Contextual rules own a nested single
/// substitution lookup that is deliberately *not* referenced by a feature:
/// only the contextual lookup is, so the replacement happens in context.
fn build_patch_gsub(
    multiples: &[(Tag, u32, Vec<u32>)],
    alternates: &[(Tag, u32, Vec<u32>)],
    contextuals: &[ContextualRule],
    reverses: &[ReverseRule],
    v2: bool,
) -> Result<Gsub> {
    let mut lookups: Vec<SubstitutionLookup> = Vec::new();
    let mut indices: BTreeMap<Tag, Vec<u16>> = BTreeMap::new();

    for (tag, from, replacements) in multiples {
        let coverage = coverage_for(&[*from], v2);
        let lookup = if v2 {
            let sequence =
                Sequence2::new(replacements.iter().map(|id| GlyphId24::new(*id)).collect());
            SubstitutionLookup::Multiple(Lookup::new(
                LookupFlag::empty(),
                vec![MultipleSubst::Format2(MultipleSubstFormat2::new(
                    coverage,
                    vec![sequence],
                ))],
            ))
        } else {
            let sequence = Sequence::new(
                replacements
                    .iter()
                    .map(|id| GlyphId16::new(*id as u16))
                    .collect(),
            );
            SubstitutionLookup::Multiple(Lookup::new(
                LookupFlag::empty(),
                vec![MultipleSubst::Format1(MultipleSubstFormat1::new(
                    coverage,
                    vec![sequence],
                ))],
            ))
        };
        add_lookup(&mut lookups, &mut indices, *tag, lookup)?;
    }

    for (tag, from, replacements) in alternates {
        let coverage = coverage_for(&[*from], v2);
        let lookup = if v2 {
            let set =
                AlternateSet2::new(replacements.iter().map(|id| GlyphId24::new(*id)).collect());
            SubstitutionLookup::Alternate(Lookup::new(
                LookupFlag::empty(),
                vec![AlternateSubst::Format2(AlternateSubstFormat2::new(
                    coverage,
                    vec![set],
                ))],
            ))
        } else {
            let set = AlternateSet::new(
                replacements
                    .iter()
                    .map(|id| GlyphId16::new(*id as u16))
                    .collect(),
            );
            SubstitutionLookup::Alternate(Lookup::new(
                LookupFlag::empty(),
                vec![AlternateSubst::Format1(AlternateSubstFormat1::new(
                    coverage,
                    vec![set],
                ))],
            ))
        };
        add_lookup(&mut lookups, &mut indices, *tag, lookup)?;
    }

    for rule in contextuals {
        let nested = u16::try_from(lookups.len()).map_err(|_| anyhow!("too many GSUB lookups"))?;
        let coverage = coverage_for(&[rule.input[0]], v2);
        let single = if v2 {
            SingleSubst::Format4(SingleSubstFormat4::new(
                coverage,
                vec![GlyphId24::new(rule.replacement)],
            ))
        } else {
            SingleSubst::format_2(coverage, vec![GlyphId16::new(rule.replacement as u16)])
        };
        lookups.push(SubstitutionLookup::Single(Lookup::new(
            LookupFlag::empty(),
            vec![single],
        )));
        let records = vec![SequenceLookupRecord::new(0, nested)];
        let lookup = if rule.backtrack.is_empty() && rule.lookahead.is_empty() {
            let input = single_coverages(&rule.input, v2);
            let context = if v2 {
                SequenceContext::Format6(SequenceContextFormat6::new(input, records))
            } else {
                SequenceContext::Format3(SequenceContextFormat3::new(input, records))
            };
            SubstitutionLookup::Contextual(Lookup::new(
                LookupFlag::empty(),
                vec![SubstitutionSequenceContext::from(context)],
            ))
        } else {
            // Upstream has no v2 coverage-based chained context format, so the
            // chained layout keeps Format3 while its coverages follow `v2`.
            let context = ChainedSequenceContext::Format3(ChainedSequenceContextFormat3::new(
                single_coverages(&rule.backtrack, v2),
                single_coverages(&rule.input, v2),
                single_coverages(&rule.lookahead, v2),
                records,
            ));
            SubstitutionLookup::ChainContextual(Lookup::new(
                LookupFlag::empty(),
                vec![SubstitutionChainContext::from(context)],
            ))
        };
        add_lookup(&mut lookups, &mut indices, rule.tag, lookup)?;
    }

    for rule in reverses {
        let lookup = if v2 {
            SubstitutionLookup::Reverse(Lookup::new(
                LookupFlag::empty(),
                vec![ReverseChainSingleSubstFormat2::new(
                    coverage_for(&[rule.from], v2),
                    single_coverages(&rule.backtrack, v2),
                    single_coverages(&rule.lookahead, v2),
                    vec![GlyphId24::new(rule.to)],
                )
                .into()],
            ))
        } else {
            SubstitutionLookup::Reverse(Lookup::new(
                LookupFlag::empty(),
                vec![ReverseChainSingleSubstFormat1::new(
                    coverage_for(&[rule.from], v2),
                    single_coverages(&rule.backtrack, v2),
                    single_coverages(&rule.lookahead, v2),
                    vec![GlyphId16::new(rule.to as u16)],
                )
                .into()],
            ))
        };
        add_lookup(&mut lookups, &mut indices, rule.tag, lookup)?;
    }

    let feature_records: Vec<FeatureRecord> = indices
        .iter()
        .map(|(tag, lookup_indices)| {
            FeatureRecord::new(
                *tag,
                Feature {
                    feature_params: None::<FeatureParams>.into(),
                    lookup_list_indices: lookup_indices.clone(),
                },
            )
        })
        .collect();
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

    let script_list = ScriptList::new(scripts);
    let feature_list = FeatureList::new(feature_records);
    if v2 {
        // A 1.2 header: the three 32-bit offsets take precedence over the
        // original 16-bit ones, and the lookup list uses 32-bit offsets too.
        Ok(Gsub {
            script_list2: Some(script_list).into(),
            feature_list2: Some(feature_list).into(),
            lookup_list2: Some(SubstitutionLookupList2::new(lookups)).into(),
            ..Default::default()
        })
    } else {
        Ok(Gsub::new(
            script_list,
            feature_list,
            SubstitutionLookupList::new(lookups),
        ))
    }
}

// ---------------------------------------------------------------------------
// B3: COLR version 1 paint graphs
// ---------------------------------------------------------------------------

/// Writes `COLR` v1 and `CPAL` for the supplied paint graphs.
pub fn add_color_paints(
    bytes: &[u8],
    palette: &[u32],
    glyphs: &[ColorGlyphPaintSpec],
) -> Result<Vec<u8>> {
    check_font_bytes(bytes)?;
    let font = font_ref(bytes)?;
    if palette.is_empty() {
        return Err(anyhow!("a color font needs a palette"));
    }
    if glyphs.is_empty() {
        return Err(anyhow!("at least one color glyph is required"));
    }

    let mut layer_paints: Vec<Paint> = Vec::new();
    let mut base_paints: Vec<BaseGlyphPaint> = Vec::new();
    for spec in glyphs {
        let gid = glyph_for(&font, spec.code_point)?;
        let paint = build_paint(spec, spec.root as usize, &mut layer_paints, 0)?;
        base_paints.push(BaseGlyphPaint::new(GlyphId16::new(gid as u16), paint));
    }

    let mut colr = Colr::new(0, None, None, 0);
    colr.base_glyph_list = Some(BaseGlyphList::new(base_paints.len() as u32, base_paints)).into();
    if !layer_paints.is_empty() {
        colr.layer_list = Some(LayerList::new(layer_paints.len() as u32, layer_paints)).into();
    }

    let colors: Vec<ColorRecord> = palette
        .iter()
        .map(|argb| ColorRecord {
            blue: (argb & 0xFF) as u8,
            green: ((argb >> 8) & 0xFF) as u8,
            red: ((argb >> 16) & 0xFF) as u8,
            alpha: ((argb >> 24) & 0xFF) as u8,
        })
        .collect();
    let num_colors = colors.len() as u16;
    let cpal = Cpal::new(num_colors, 1, num_colors, Some(colors), vec![0]);

    let mut builder = FontBuilder::new();
    builder.add_table(&colr)?.add_table(&cpal)?;
    builder.copy_missing_tables(font);
    Ok(builder.build())
}

fn child_paint(
    spec: &ColorGlyphPaintSpec,
    node: &PaintNodeSpec,
    which: usize,
    layers: &mut Vec<Paint>,
    depth: usize,
) -> Result<Paint> {
    let id = *node
        .children
        .get(which)
        .ok_or_else(|| anyhow!("paint node '{}' needs child {which}", node.kind))?;
    build_paint(spec, id as usize, layers, depth + 1)
}

fn color_line(node: &PaintNodeSpec) -> ColorLine {
    let stops = node
        .stops
        .iter()
        .map(|stop| ColorStop::new(f2(stop.offset), stop.palette_index as u16, f2(stop.alpha)))
        .collect::<Vec<_>>();
    let extend = match node.extend.as_str() {
        "repeat" => Extend::Repeat,
        "reflect" => Extend::Reflect,
        _ => Extend::Pad,
    };
    ColorLine::new(extend, stops.len() as u16, stops)
}

fn composite_mode(name: &str) -> Result<CompositeMode> {
    Ok(match name {
        "clear" => CompositeMode::Clear,
        "src" => CompositeMode::Src,
        "dest" => CompositeMode::Dest,
        "srcOver" | "" => CompositeMode::SrcOver,
        "destOver" => CompositeMode::DestOver,
        "srcIn" => CompositeMode::SrcIn,
        "destIn" => CompositeMode::DestIn,
        "srcOut" => CompositeMode::SrcOut,
        "destOut" => CompositeMode::DestOut,
        "srcAtop" => CompositeMode::SrcAtop,
        "destAtop" => CompositeMode::DestAtop,
        "xor" => CompositeMode::Xor,
        "plus" => CompositeMode::Plus,
        other => return Err(anyhow!("unknown composite mode '{other}'")),
    })
}

fn build_paint(
    spec: &ColorGlyphPaintSpec,
    index: usize,
    layers: &mut Vec<Paint>,
    depth: usize,
) -> Result<Paint> {
    if depth > 32 {
        return Err(anyhow!("the paint graph is too deep"));
    }
    let node = spec
        .nodes
        .get(index)
        .ok_or_else(|| anyhow!("paint node {index} is missing"))?;
    let word = |value: f64| FWord::new(value as i16);
    let uword = |value: f64| UfWord::new(value.max(0.0) as u16);

    match node.kind.as_str() {
        "solid" => Ok(Paint::solid(node.palette_index as u16, f2(node.alpha))),
        "linearGradient" => Ok(Paint::linear_gradient(
            color_line(node),
            word(node.x0),
            word(node.y0),
            word(node.x1),
            word(node.y1),
            word(node.r0),
            word(node.r1),
        )),
        "radialGradient" => Ok(Paint::radial_gradient(
            color_line(node),
            word(node.x0),
            word(node.y0),
            uword(node.r0),
            word(node.x1),
            word(node.y1),
            uword(node.r1),
        )),
        "sweepGradient" => Ok(Paint::sweep_gradient(
            color_line(node),
            word(node.x0),
            word(node.y0),
            f2(node.start_angle),
            f2(node.end_angle),
        )),
        "glyph" => Ok(Paint::glyph(
            child_paint(spec, node, 0, layers, depth)?,
            GlyphId16::new(node.glyph_id as u16),
        )),
        "translate" => Ok(Paint::translate(
            child_paint(spec, node, 0, layers, depth)?,
            word(node.x0),
            word(node.y0),
        )),
        "scale" => Ok(Paint::scale(
            child_paint(spec, node, 0, layers, depth)?,
            f2(node.x0),
            f2(node.y0),
        )),
        "rotate" => Ok(Paint::rotate(
            child_paint(spec, node, 0, layers, depth)?,
            f2(node.start_angle),
        )),
        "composite" => {
            let source = child_paint(spec, node, 0, layers, depth)?;
            let backdrop = child_paint(spec, node, 1, layers, depth)?;
            Ok(Paint::composite(
                source,
                composite_mode(&node.composite_mode)?,
                backdrop,
            ))
        }
        "layers" => {
            let first = layers.len() as u32;
            let count = node.children.len();
            let mut paints = Vec::with_capacity(count);
            for which in 0..count {
                paints.push(child_paint(spec, node, which, layers, depth)?);
            }
            layers.extend(paints);
            Ok(Paint::colr_layers(count.min(u8::MAX as usize) as u8, first))
        }
        other => Err(anyhow!("unsupported paint kind '{other}'")),
    }
}

// ---------------------------------------------------------------------------
// B4: GSUB / GPOS feature variations
// ---------------------------------------------------------------------------

/// Builds one condition tree. Children must refer to earlier conditions, so a
/// request cannot create a cycle no matter how deep it nests.
fn build_condition(index: usize, specs: &[FeatureConditionSpec], depth: u32) -> Result<Condition> {
    if depth > MAX_CONDITION_DEPTH {
        return Err(anyhow!(
            "condition tree is deeper than {MAX_CONDITION_DEPTH}"
        ));
    }
    let spec = &specs[index];
    let mut children = Vec::new();
    for child in &spec.children {
        let child = *child as usize;
        if child >= index || child >= specs.len() {
            return Err(anyhow!(
                "condition {index} may only reference earlier conditions"
            ));
        }
        children.push(build_condition(child, specs, depth + 1)?);
    }
    let count = u8::try_from(children.len())
        .map_err(|_| anyhow!("a condition has more than 255 children"))?;
    Ok(match spec.kind.as_str() {
        "axisRange" => Condition::format_1_axis_range(
            spec.axis_index as u16,
            f2(spec.min_value),
            f2(spec.max_value),
        ),
        "variableValue" => {
            Condition::format_2_variable_value(spec.default_value as i16, spec.var_index)
        }
        "and" => Condition::format_3_and(count, children),
        "or" => Condition::format_4_or(count, children),
        "not" => {
            if children.len() != 1 {
                return Err(anyhow!("a 'not' condition needs exactly one child"));
            }
            Condition::format_5_negate(children.remove(0))
        }
        other => return Err(anyhow!("unknown condition kind '{other}'")),
    })
}

fn build_feature_variations(
    request: &FeatureVariationPatchRequest,
    features: Option<read_fonts::tables::layout::FeatureList<'_>>,
) -> Result<FeatureVariations> {
    let features = features.ok_or_else(|| anyhow!("the layout table has no feature list"))?;
    let mut records = Vec::new();
    for record in &request.records {
        let condition_set = if record.condition_indices.is_empty() {
            None
        } else {
            let mut conditions = Vec::new();
            for index in &record.condition_indices {
                let index = *index as usize;
                if index >= request.conditions.len() {
                    return Err(anyhow!("condition index {index} is out of range"));
                }
                conditions.push(build_condition(index, &request.conditions, 0)?);
            }
            Some(ConditionSet::new(conditions))
        };
        let mut substitutions = Vec::new();
        for spec in &record.substitutions {
            let tag = parse_tag(&spec.feature_tag)?;
            let feature_index = features
                .feature_records()
                .iter()
                .position(|record| record.feature_tag() == tag)
                .ok_or_else(|| anyhow!("feature '{tag}' is not in the layout table"))?;
            let lookup_indices = spec
                .lookup_indices
                .iter()
                .map(|index| {
                    u16::try_from(*index).map_err(|_| anyhow!("lookup index {index} is too large"))
                })
                .collect::<Result<Vec<_>>>()?;
            substitutions.push(FeatureTableSubstitutionRecord::new(
                feature_index as u16,
                Feature {
                    feature_params: None::<FeatureParams>.into(),
                    lookup_list_indices: lookup_indices,
                },
            ));
        }
        records.push(FeatureVariationRecord::new(
            condition_set,
            Some(FeatureTableSubstitution::new(substitutions)),
        ));
    }
    Ok(FeatureVariations::new(records))
}

/// Patches `GSUB` and/or `GPOS` with a version 1.1 `FeatureVariations` table.
/// The tables themselves are copied via `to_owned_table`, so all existing
/// scripts, features and lookups (including their indices) survive.
pub fn add_feature_variations(
    bytes: &[u8],
    request: &FeatureVariationPatchRequest,
) -> Result<Vec<u8>> {
    check_font_bytes(bytes)?;
    let font = font_ref(bytes)?;
    if request.records.is_empty() {
        return Err(anyhow!("at least one feature variation record is required"));
    }
    if request.conditions.len() > MAX_CONDITION_NODES as usize {
        return Err(anyhow!("too many conditions in the request"));
    }
    let table = request.table.to_ascii_uppercase();
    let gsub = table == "GSUB" || table == "BOTH";
    let gpos = table == "GPOS" || table == "BOTH";
    if !gsub && !gpos {
        return Err(anyhow!("table must be 'GSUB', 'GPOS' or 'both'"));
    }

    let mut builder = FontBuilder::new();
    if gsub {
        let read = font
            .gsub()
            .map_err(|e| anyhow!("the font has no GSUB table: {e}"))?;
        let variations = build_feature_variations(request, read.feature_list().ok())?;
        let mut owned: Gsub = read.to_owned_table();
        owned.feature_variations = Some(variations).into();
        builder.add_table(&owned)?;
    }
    if gpos {
        let read = font
            .gpos()
            .map_err(|e| anyhow!("the font has no GPOS table: {e}"))?;
        let variations = build_feature_variations(request, read.feature_list().ok())?;
        let mut owned: Gpos = read.to_owned_table();
        owned.feature_variations = Some(variations).into();
        builder.add_table(&owned)?;
    }
    builder.copy_missing_tables(font);
    Ok(builder.build())
}

// ---------------------------------------------------------------------------
// B5: a structured MATH table
// ---------------------------------------------------------------------------

fn math_value(value: f64) -> MathValueRecord {
    MathValueRecord::new(FWord::new(value as i16), None)
}

fn assembly_italics(spec: &MathConstructionSpec) -> Result<MathValueRecord> {
    let value = FWord::new(spec.italics_correction as i16);
    let Some(start) = spec.italics_device_start_ppem else {
        return Ok(MathValueRecord::new(value, None));
    };
    if spec.italics_device_deltas.is_empty() {
        return Err(anyhow!("a device table needs at least one pixel delta"));
    }
    let deltas: Vec<i8> = spec
        .italics_device_deltas
        .iter()
        .map(|delta| (*delta).clamp(i8::MIN as i32, i8::MAX as i32) as i8)
        .collect();
    let end = start
        .checked_add(deltas.len() as u32 - 1)
        .ok_or_else(|| anyhow!("device ppem range overflows"))?;
    if end > u16::MAX as u32 {
        return Err(anyhow!("device ppem range exceeds 65535"));
    }
    Ok(MathValueRecord::new(
        value,
        Some(DeviceOrVariationIndex::device(
            start as u16,
            end as u16,
            &deltas,
        )),
    ))
}

fn math_constants(specs: &[MathConstantSpec]) -> Result<MathConstants> {
    let mut constants = MathConstants::default();
    for spec in specs {
        let value = spec.value;
        match spec.name.as_str() {
            "scriptPercentScaleDown" => constants.script_percent_scale_down = value as i16,
            "scriptScriptPercentScaleDown" => {
                constants.script_script_percent_scale_down = value as i16
            }
            "delimitedSubFormulaMinHeight" => {
                constants.delimited_sub_formula_min_height = UfWord::new(value.max(0.0) as u16)
            }
            "displayOperatorMinHeight" => {
                constants.display_operator_min_height = UfWord::new(value.max(0.0) as u16)
            }
            "mathLeading" => constants.math_leading = math_value(value),
            "axisHeight" => constants.axis_height = math_value(value),
            "accentBaseHeight" => constants.accent_base_height = math_value(value),
            "flattenedAccentBaseHeight" => {
                constants.flattened_accent_base_height = math_value(value)
            }
            "subscriptShiftDown" => constants.subscript_shift_down = math_value(value),
            "subscriptTopMax" => constants.subscript_top_max = math_value(value),
            "subscriptBaselineDropMin" => constants.subscript_baseline_drop_min = math_value(value),
            "superscriptShiftUp" => constants.superscript_shift_up = math_value(value),
            "superscriptShiftUpCramped" => {
                constants.superscript_shift_up_cramped = math_value(value)
            }
            "superscriptBottomMin" => constants.superscript_bottom_min = math_value(value),
            "superscriptBaselineDropMax" => {
                constants.superscript_baseline_drop_max = math_value(value)
            }
            "subSuperscriptGapMin" => constants.sub_superscript_gap_min = math_value(value),
            "superscriptBottomMaxWithSubscript" => {
                constants.superscript_bottom_max_with_subscript = math_value(value)
            }
            "spaceAfterScript" => constants.space_after_script = math_value(value),
            "upperLimitGapMin" => constants.upper_limit_gap_min = math_value(value),
            "upperLimitBaselineRiseMin" => {
                constants.upper_limit_baseline_rise_min = math_value(value)
            }
            "lowerLimitGapMin" => constants.lower_limit_gap_min = math_value(value),
            "lowerLimitBaselineDropMin" => {
                constants.lower_limit_baseline_drop_min = math_value(value)
            }
            "stackTopShiftUp" => constants.stack_top_shift_up = math_value(value),
            "stackTopDisplayStyleShiftUp" => {
                constants.stack_top_display_style_shift_up = math_value(value)
            }
            "stackBottomShiftDown" => constants.stack_bottom_shift_down = math_value(value),
            "stackBottomDisplayStyleShiftDown" => {
                constants.stack_bottom_display_style_shift_down = math_value(value)
            }
            "stackGapMin" => constants.stack_gap_min = math_value(value),
            "stackDisplayStyleGapMin" => constants.stack_display_style_gap_min = math_value(value),
            "stretchStackTopShiftUp" => constants.stretch_stack_top_shift_up = math_value(value),
            "stretchStackBottomShiftDown" => {
                constants.stretch_stack_bottom_shift_down = math_value(value)
            }
            "stretchStackGapAboveMin" => constants.stretch_stack_gap_above_min = math_value(value),
            "stretchStackGapBelowMin" => constants.stretch_stack_gap_below_min = math_value(value),
            "fractionNumeratorShiftUp" => constants.fraction_numerator_shift_up = math_value(value),
            "fractionNumeratorDisplayStyleShiftUp" => {
                constants.fraction_numerator_display_style_shift_up = math_value(value)
            }
            "fractionDenominatorShiftDown" => {
                constants.fraction_denominator_shift_down = math_value(value)
            }
            "fractionDenominatorDisplayStyleShiftDown" => {
                constants.fraction_denominator_display_style_shift_down = math_value(value)
            }
            "fractionNumeratorGapMin" => constants.fraction_numerator_gap_min = math_value(value),
            "fractionNumDisplayStyleGapMin" => {
                constants.fraction_num_display_style_gap_min = math_value(value)
            }
            "fractionRuleThickness" => constants.fraction_rule_thickness = math_value(value),
            "fractionDenominatorGapMin" => {
                constants.fraction_denominator_gap_min = math_value(value)
            }
            "fractionDenomDisplayStyleGapMin" => {
                constants.fraction_denom_display_style_gap_min = math_value(value)
            }
            "skewedFractionHorizontalGap" => {
                constants.skewed_fraction_horizontal_gap = math_value(value)
            }
            "skewedFractionVerticalGap" => {
                constants.skewed_fraction_vertical_gap = math_value(value)
            }
            "overbarVerticalGap" => constants.overbar_vertical_gap = math_value(value),
            "overbarRuleThickness" => constants.overbar_rule_thickness = math_value(value),
            "overbarExtraAscender" => constants.overbar_extra_ascender = math_value(value),
            "underbarVerticalGap" => constants.underbar_vertical_gap = math_value(value),
            "underbarRuleThickness" => constants.underbar_rule_thickness = math_value(value),
            "underbarExtraDescender" => constants.underbar_extra_descender = math_value(value),
            "radicalVerticalGap" => constants.radical_vertical_gap = math_value(value),
            "radicalDisplayStyleVerticalGap" => {
                constants.radical_display_style_vertical_gap = math_value(value)
            }
            "radicalRuleThickness" => constants.radical_rule_thickness = math_value(value),
            "radicalExtraAscender" => constants.radical_extra_ascender = math_value(value),
            "radicalKernBeforeDegree" => constants.radical_kern_before_degree = math_value(value),
            "radicalKernAfterDegree" => constants.radical_kern_after_degree = math_value(value),
            "radicalDegreeBottomRaisePercent" => {
                constants.radical_degree_bottom_raise_percent = value as i16
            }
            other => return Err(anyhow!("unknown MATH constant '{other}'")),
        }
    }
    Ok(constants)
}

/// A coverage plus one value per glyph, sorted by glyph id (the order the
/// coverage table and the value array must agree on).
fn value_rows(
    font: &FontRef<'_>,
    values: &[MathGlyphValueSpec],
) -> Result<Option<(CoverageTable, Vec<MathValueRecord>)>> {
    if values.is_empty() {
        return Ok(None);
    }
    let mut rows: Vec<(u32, f64)> = values
        .iter()
        .map(|spec| Ok((glyph_for(font, spec.code_point)?, spec.value)))
        .collect::<Result<_>>()?;
    rows.sort_by_key(|row| row.0);
    Ok(Some((
        coverage_for(&rows.iter().map(|row| row.0).collect::<Vec<_>>(), false),
        rows.iter().map(|row| math_value(row.1)).collect(),
    )))
}

#[derive(Default)]
struct KernRow {
    top_right: Option<MathKern>,
    top_left: Option<MathKern>,
    bottom_right: Option<MathKern>,
    bottom_left: Option<MathKern>,
}

fn math_glyph_info(font: &FontRef<'_>, request: &MathTableRequest) -> Result<MathGlyphInfo> {
    let italics = value_rows(font, &request.italics_corrections)?
        .map(|(coverage, values)| MathItalicsCorrectionInfo::new(coverage, values));
    let accent = value_rows(font, &request.top_accent_attachments)?
        .map(|(coverage, values)| MathTopAccentAttachment::new(coverage, values));
    let extended = if request.extended_shapes.is_empty() {
        None
    } else {
        let ids = request
            .extended_shapes
            .iter()
            .map(|code_point| glyph_for(font, *code_point))
            .collect::<Result<Vec<_>>>()?;
        Some(coverage_for(&ids, false))
    };

    let mut kerns: BTreeMap<u32, KernRow> = BTreeMap::new();
    for spec in &request.kerns {
        let gid = glyph_for(font, spec.code_point)?;
        let kern = MathKern::new(
            spec.heights.iter().copied().map(math_value).collect(),
            spec.kerns.iter().copied().map(math_value).collect(),
        );
        let row = kerns.entry(gid).or_default();
        let slot = match spec.corner.as_str() {
            "topRight" => &mut row.top_right,
            "topLeft" => &mut row.top_left,
            "bottomRight" => &mut row.bottom_right,
            "bottomLeft" => &mut row.bottom_left,
            other => return Err(anyhow!("unknown MATH kern corner '{other}'")),
        };
        *slot = Some(kern);
    }
    let kern_info = if kerns.is_empty() {
        None
    } else {
        let ids: Vec<u32> = kerns.keys().copied().collect();
        let records = kerns
            .into_values()
            .map(|row| {
                MathKernInfoRecord::new(
                    row.top_right,
                    row.top_left,
                    row.bottom_right,
                    row.bottom_left,
                )
            })
            .collect();
        Some(MathKernInfo::new(coverage_for(&ids, false), records))
    };

    Ok(MathGlyphInfo::new(italics, accent, extended, kern_info))
}

fn math_variants(font: &FontRef<'_>, request: &MathTableRequest) -> Result<MathVariants> {
    let mut vertical: Vec<(u32, &MathConstructionSpec)> = Vec::new();
    let mut horizontal: Vec<(u32, &MathConstructionSpec)> = Vec::new();
    for spec in &request.constructions {
        let gid = glyph_for(font, spec.code_point)?;
        if spec.axis.eq_ignore_ascii_case("horizontal") {
            horizontal.push((gid, spec));
        } else {
            vertical.push((gid, spec));
        }
    }
    let build = |rows: &[(u32, &MathConstructionSpec)]| -> Result<(Option<CoverageTable>, Vec<MathGlyphConstruction>)> {
        if rows.is_empty() {
            return Ok((None, Vec::new()));
        }
        let mut sorted = rows.to_vec();
        sorted.sort_by_key(|row| row.0);
        let mut constructions = Vec::new();
        for (_, spec) in &sorted {
            let variants = spec
                .variants
                .iter()
                .map(|variant| {
                    Ok(MathGlyphVariantRecord::new(
                        GlyphId16::new(glyph_for(font, variant.variant_code_point)? as u16),
                        UfWord::new(variant.advance.max(0.0) as u16),
                    ))
                })
                .collect::<Result<Vec<_>>>()?;
            let assembly = if spec.parts.is_empty() {
                None
            } else {
                let parts = spec
                    .parts
                    .iter()
                    .map(|part| {
                        Ok(GlyphPartRecord::new(
                            GlyphId16::new(glyph_for(font, part.part_code_point)? as u16),
                            UfWord::new(part.start_connector_length.max(0.0) as u16),
                            UfWord::new(part.end_connector_length.max(0.0) as u16),
                            UfWord::new(part.full_advance.max(0.0) as u16),
                            if part.is_extender {
                                PartFlags::EXTENDER_FLAG
                            } else {
                                PartFlags::empty()
                            },
                        ))
                    })
                    .collect::<Result<Vec<_>>>()?;
                Some(GlyphAssembly::new(assembly_italics(spec)?, parts))
            };
            constructions.push(MathGlyphConstruction::new(assembly, variants));
        }
        Ok((
            Some(coverage_for(
                &sorted.iter().map(|row| row.0).collect::<Vec<_>>(),
                false,
            )),
            constructions,
        ))
    };
    let (vert_coverage, vert_constructions) = build(&vertical)?;
    let (horiz_coverage, horiz_constructions) = build(&horizontal)?;
    Ok(MathVariants::new(
        UfWord::new(request.min_connector_overlap.max(0.0) as u16),
        vert_coverage,
        horiz_coverage,
        vert_constructions,
        horiz_constructions,
    ))
}

pub fn add_math_table(bytes: &[u8], request: &MathTableRequest) -> Result<Vec<u8>> {
    check_font_bytes(bytes)?;
    let font = font_ref(bytes)?;
    let math = Math::new(
        math_constants(&request.constants)?,
        math_glyph_info(&font, request)?,
        math_variants(&font, request)?,
    );
    let mut builder = FontBuilder::new();
    builder.add_table(&math)?;
    builder.copy_missing_tables(font);
    Ok(builder.build())
}

// ---------------------------------------------------------------------------
// B6: SVG documents, VORG vertical origins and raw tables
// ---------------------------------------------------------------------------

pub fn add_svg_documents(bytes: &[u8], documents: &[SvgDocumentSpec]) -> Result<Vec<u8>> {
    check_font_bytes(bytes)?;
    let font = font_ref(bytes)?;
    if documents.is_empty() {
        return Err(anyhow!("at least one SVG document is required"));
    }
    let mut records: Vec<(u16, u16, Vec<u8>)> = documents
        .iter()
        .map(|doc| {
            let start = glyph_for(&font, doc.start_code_point)? as u16;
            let end = glyph_for(&font, doc.end_code_point)? as u16;
            if start > end || doc.data.is_empty() {
                return Err(anyhow!("an SVG document needs a glyph range and data"));
            }
            Ok((start, end, doc.data.clone()))
        })
        .collect::<Result<_>>()?;
    records.sort_by_key(|record| record.0);

    let mut list = Vec::new();
    push_u16(&mut list, records.len() as u16);
    let mut cursor = 2usize + 12 * records.len();
    for (start, end, data) in &records {
        push_u16(&mut list, *start);
        push_u16(&mut list, *end);
        push_u32(&mut list, cursor as u32);
        push_u32(&mut list, data.len() as u32);
        cursor += data.len();
    }
    for (_, _, data) in &records {
        list.extend_from_slice(data);
    }
    let mut table = Vec::new();
    push_u16(&mut table, 0); // version
    push_u32(&mut table, 10); // SVGDocumentListOffset
    push_u32(&mut table, 0); // reserved
    table.extend_from_slice(&list);

    let mut builder = FontBuilder::new();
    builder.add_raw(Tag::new(b"SVG "), table);
    builder.copy_missing_tables(font);
    Ok(builder.build())
}

pub fn add_vertical_origins(bytes: &[u8], request: &VerticalOriginRequest) -> Result<Vec<u8>> {
    check_font_bytes(bytes)?;
    let font = font_ref(bytes)?;
    let mut origins: Vec<(u16, i16)> = request
        .origins
        .iter()
        .map(|origin| {
            Ok((
                glyph_for(&font, origin.code_point)? as u16,
                origin.origin_y as i16,
            ))
        })
        .collect::<Result<_>>()?;
    origins.sort_by_key(|origin| origin.0);

    let mut table = Vec::new();
    push_u16(&mut table, 1); // majorVersion
    push_u16(&mut table, 0); // minorVersion
    push_i16(&mut table, request.default_origin_y as i16);
    push_u16(&mut table, origins.len() as u16);
    for (gid, origin_y) in origins {
        push_u16(&mut table, gid);
        push_i16(&mut table, origin_y);
    }
    let mut builder = FontBuilder::new();
    builder.add_raw(Tag::new(b"VORG"), table);
    builder.copy_missing_tables(font);
    Ok(builder.build())
}

// ---------------------------------------------------------------------------
// B7: a structured VARC table
// ---------------------------------------------------------------------------

/// Builds the multi item variation store from the request and remembers each
/// delta set's temporary id so components can point at it.
fn varc_delta_sets(
    request: &VarcPatchRequest,
) -> Result<(MultiItemVariationStoreBuilder, Vec<u32>)> {
    let mut store = MultiItemVariationStoreBuilder::new();
    let mut temp_ids = Vec::new();
    for set in &request.delta_sets {
        if set.entries.is_empty() {
            return Err(anyhow!("a VARC delta set needs at least one region"));
        }
        let tuple_len = set.entries[0].deltas.len();
        if tuple_len == 0
            || set
                .entries
                .iter()
                .any(|entry| entry.deltas.len() != tuple_len)
        {
            return Err(anyhow!(
                "all regions of a VARC delta set need equal tuple lengths"
            ));
        }
        let deltas = set
            .entries
            .iter()
            .map(|entry| {
                let axes = entry
                    .axes
                    .iter()
                    .map(|axis| {
                        (
                            axis.axis_index as u16,
                            f2(axis.start),
                            f2(axis.peak),
                            f2(axis.end),
                        )
                    })
                    .collect();
                (SparseRegion::new(axes), entry.deltas.clone())
            })
            .collect();
        temp_ids.push(
            store
                .add_deltas(deltas)
                .map_err(|e| anyhow!("invalid VARC delta set: {e}"))?,
        );
    }
    Ok((store, temp_ids))
}

pub fn add_varc_glyphs(bytes: &[u8], request: &VarcPatchRequest) -> Result<Vec<u8>> {
    check_font_bytes(bytes)?;
    let font = font_ref(bytes)?;
    if request.glyphs.is_empty() {
        return Err(anyhow!("at least one VARC glyph is required"));
    }
    if request.conditions.len() > MAX_CONDITION_NODES as usize {
        return Err(anyhow!("too many VARC conditions"));
    }
    let (store, temp_ids) = varc_delta_sets(request)?;
    let mut conditions = Vec::new();
    for index in 0..request.conditions.len() {
        conditions.push(build_condition(index, &request.conditions, 0)?);
    }
    let pending = |index: Option<u32>| -> Result<Option<VarcVariationIndex>> {
        match index {
            None => Ok(None),
            Some(index) => {
                let id = temp_ids
                    .get(index as usize)
                    .ok_or_else(|| anyhow!("VARC delta set {index} is out of range"))?;
                Ok(Some(VarcVariationIndex::PendingVariationIndex(*id)))
            }
        }
    };

    let mut glyphs: Vec<(u16, VarCompositeGlyph)> = Vec::new();
    for glyph in &request.glyphs {
        let gid = glyph_for(&font, glyph.code_point)?;
        if gid > u16::MAX as u32 {
            return Err(anyhow!("VARC coverage cannot address glyph {gid}"));
        }
        let mut components = Vec::new();
        for component in &glyph.components {
            if component.axis_indices.len() != component.axis_values.len() {
                return Err(anyhow!(
                    "VARC axis indices and values must have equal lengths"
                ));
            }
            let condition_index = match component.condition_index {
                None => None,
                Some(index) => {
                    if index as usize >= conditions.len() {
                        return Err(anyhow!("VARC condition {index} is out of range"));
                    }
                    Some(VarcVariationIndex::VariationIndex(index))
                }
            };
            let axis_values = if component.axis_indices.is_empty() {
                None
            } else {
                Some(
                    component
                        .axis_indices
                        .iter()
                        .zip(&component.axis_values)
                        .map(|(axis, value)| (*axis as u16, *value as f32))
                        .collect::<BTreeMap<_, _>>(),
                )
            };
            components.push(VarComponent {
                reset_unspecified_axes: false,
                gid: GlyphId::new(glyph_for(&font, component.component_code_point)?),
                condition_index,
                axis_values,
                axis_values_var_index: pending(component.axis_values_delta_set)?,
                transform: WriteTransform {
                    translate_x: component.translate_x,
                    translate_y: component.translate_y,
                    rotation: component.rotation,
                    scale_x: component.scale_x,
                    scale_y: component.scale_y,
                    skew_x: component.skew_x,
                    skew_y: component.skew_y,
                    center_x: component.center_x,
                    center_y: component.center_y,
                },
                transform_var_index: pending(component.transform_delta_set)?,
            });
        }
        glyphs.push((gid as u16, VarCompositeGlyph(components)));
    }
    // `CoverageFormat1` is looked up with a binary search and its index selects
    // the composite glyph, so both lists must be sorted by glyph id.
    glyphs.sort_by_key(|row| row.0);
    if glyphs.windows(2).any(|pair| pair[0].0 == pair[1].0) {
        return Err(anyhow!("two VARC glyphs share the same code point"));
    }
    let coverage = CoverageTable::Format1(CoverageFormat1::new(
        glyphs.iter().map(|row| GlyphId16::new(row.0)).collect(),
    ));
    let composites = glyphs.into_iter().map(|row| row.1).collect();
    let varc = WriteVarc::new_from_composite_glyphs(coverage, store, conditions, composites);

    let mut builder = FontBuilder::new();
    builder.add_table(&varc)?;
    builder.copy_missing_tables(font);
    Ok(builder.build())
}

pub fn add_raw_tables(bytes: &[u8], tables: &[PatchRawTableSpec]) -> Result<Vec<u8>> {
    check_font_bytes(bytes)?;
    let font = font_ref(bytes)?;
    if tables.is_empty() {
        return Err(anyhow!("at least one raw table is required"));
    }
    let mut builder = FontBuilder::new();
    for table in tables {
        let tag = parse_tag(&table.tag)?;
        builder.add_raw(tag, table.data.clone());
    }
    builder.copy_missing_tables(font);
    Ok(builder.build())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::upstream::{
        AlternateSubstitutionSpec, ColorGlyphPaintSpec, ContextualSubstitutionSpec,
        FontSubsetRequest, MultipleSubstitutionSpec, PaintNodeSpec, ReverseChainSubstitutionSpec,
        SubstitutionPatchRequest,
    };

    fn inter() -> &'static [u8] {
        include_bytes!("../../example/assets/fonts/Inter.ttf")
    }

    fn has_table(bytes: &[u8], tag: &[u8; 4]) -> bool {
        let font = FontRef::new(bytes).unwrap();
        font.table_directory()
            .table_records()
            .iter()
            .any(|record| record.tag() == Tag::new(tag))
    }

    #[test]
    fn subset_keeps_only_the_requested_code_points() {
        let request = FontSubsetRequest {
            code_points: vec![0x41, 0x42],
            ..Default::default()
        };
        let out = crate::api::upstream::subset_font(inter().to_vec(), None, request).unwrap();
        let original = FontRef::new(inter()).unwrap();
        let subset = FontRef::new(&out).unwrap();
        assert!(subset.maxp().unwrap().num_glyphs() < original.maxp().unwrap().num_glyphs());
        assert!(subset.charmap().map(0x41u32).is_some());
        assert!(subset.charmap().map(0x42u32).is_some());
        assert!(subset.charmap().map(0x5Au32).is_none());
    }

    #[test]
    fn sbix_strike_contains_the_image_data() {
        let strike = BitmapStrikeSpec {
            ppem: 32,
            ppi: 72,
            glyphs: vec![BitmapGlyphSpec {
                code_point: 0x41,
                format: "png ".to_string(),
                data: vec![0x89, 0x50, 0x4E, 0x47],
                ..Default::default()
            }],
        };
        let out = add_bitmap_strikes(inter(), &[strike]).unwrap();
        assert!(has_table(&out, b"sbix"));
        let font = FontRef::new(&out).unwrap();
        let data = font.table_data(Tag::new(b"sbix")).unwrap();
        let bytes = data.as_bytes();
        assert_eq!(&bytes[0..2], &[0, 1]); // version 1
        assert_eq!(&bytes[4..8], &[0, 0, 0, 1]); // one strike
        assert!(bytes
            .windows(4)
            .any(|window| window == [0x89, 0x50, 0x4E, 0x47]));
    }

    #[test]
    fn gsub_multiple_and_alternate_lookups_are_written() {
        use crate::api::fontations::Font;

        let request = SubstitutionPatchRequest {
            multiple: vec![MultipleSubstitutionSpec {
                feature_tag: "mlt1".to_string(),
                code_point: 0x41,
                replacement_code_points: vec![0x42, 0x43],
            }],
            alternate: vec![AlternateSubstitutionSpec {
                feature_tag: "alt1".to_string(),
                code_point: 0x44,
                replacement_code_points: vec![0x45, 0x46],
            }],
            contextual: vec![],
            reverse_chain: vec![],
            use_v2: false,
        };
        let out = add_substitutions(inter(), &request).unwrap();
        let font = FontRef::new(&out).unwrap();
        let gsub = font.gsub().unwrap();
        let features: Vec<String> = gsub
            .feature_list()
            .unwrap()
            .feature_records()
            .iter()
            .map(|record| record.feature_tag().to_string())
            .collect();
        assert!(features.contains(&"mlt1".to_string()));
        assert!(features.contains(&"alt1".to_string()));
        assert!(gsub.lookup_list2().is_none()); // original 16-bit header

        // The shaper still applies the original-layout lookup end to end.
        let original = Font::from_bytes(inter().to_vec(), None).unwrap();
        let b = original.char_to_glyph(0x42).unwrap().unwrap();
        let c = original.char_to_glyph(0x43).unwrap().unwrap();
        let shaped = Font::from_bytes(out, None)
            .unwrap()
            .shape(
                "A".to_string(),
                None,
                vec![],
                None,
                None,
                Some(vec!["mlt1".to_string()]),
            )
            .unwrap();
        assert_eq!(
            shaped
                .glyphs
                .iter()
                .map(|glyph| glyph.glyph_id)
                .collect::<Vec<_>>(),
            vec![b, c]
        );
    }

    #[test]
    fn v2_contextual_and_reverse_lookups_shape_text() {
        use crate::api::fontations::Font;

        let original = inter();
        let plain = Font::from_bytes(original.to_vec(), None).unwrap();
        let a = plain.char_to_glyph(0x41).unwrap().unwrap();
        let b = plain.char_to_glyph(0x42).unwrap().unwrap();
        let c = plain.char_to_glyph(0x43).unwrap().unwrap();
        let e = plain.char_to_glyph(0x45).unwrap().unwrap();

        let request = SubstitutionPatchRequest {
            multiple: vec![MultipleSubstitutionSpec {
                feature_tag: "mlt2".to_string(),
                code_point: 0x41,
                replacement_code_points: vec![0x42, 0x43],
            }],
            alternate: vec![AlternateSubstitutionSpec {
                feature_tag: "alt2".to_string(),
                code_point: 0x44,
                replacement_code_points: vec![0x45, 0x46],
            }],
            contextual: vec![ContextualSubstitutionSpec {
                feature_tag: "cnt2".to_string(),
                backtrack: vec![],
                input: vec![0x41, 0x42],
                lookahead: vec![],
                replacement_code_point: 0x43,
            }],
            reverse_chain: vec![ReverseChainSubstitutionSpec {
                feature_tag: "rvs2".to_string(),
                code_point: 0x42,
                replacement_code_point: 0x43,
                backtrack: vec![0x41],
                lookahead: vec![],
            }],
            use_v2: true,
        };
        let out = add_substitutions(original, &request).unwrap();
        let gsub = FontRef::new(&out).unwrap().gsub().unwrap();
        assert!(gsub.lookup_list2().is_some()); // 2026 32-bit GSUB header

        let font = Font::from_bytes(out, None).unwrap();
        let shape = |text: &str, feature: &str| -> Vec<u32> {
            font.shape(
                text.to_string(),
                None,
                vec![],
                None,
                None,
                Some(vec![feature.to_string()]),
            )
            .unwrap()
            .glyphs
            .iter()
            .map(|glyph| glyph.glyph_id)
            .collect()
        };
        // MultipleSubst Format2, AlternateSubst Format2, SingleSubst Format4
        // (nested), SequenceContext Format6 and ReverseChain Format2.
        assert_eq!(shape("AB", "mlt2"), vec![b, c, b]);
        assert_eq!(shape("D", "alt2"), vec![e]);
        assert_eq!(shape("AB", "cnt2"), vec![c, b]);
        assert_eq!(shape("AB", "rvs2"), vec![a, c]);
        // Outside the context nothing is replaced.
        assert_eq!(shape("A", "cnt2"), vec![a]);
        assert_eq!(shape("B", "rvs2"), vec![b]);
    }

    #[test]
    fn chained_contextual_rules_respect_backtrack_and_lookahead() {
        use crate::api::fontations::Font;

        let original = Font::from_bytes(inter().to_vec(), None).unwrap();
        let a = original.char_to_glyph(0x41).unwrap().unwrap();
        let b = original.char_to_glyph(0x42).unwrap().unwrap();
        let c = original.char_to_glyph(0x43).unwrap().unwrap();
        let d = original.char_to_glyph(0x44).unwrap().unwrap();

        let request = SubstitutionPatchRequest {
            contextual: vec![ContextualSubstitutionSpec {
                feature_tag: "chn1".to_string(),
                backtrack: vec![0x41],
                input: vec![0x42],
                lookahead: vec![0x44],
                replacement_code_point: 0x43,
            }],
            use_v2: false,
            ..Default::default()
        };
        let out = add_substitutions(inter(), &request).unwrap();
        let font = Font::from_bytes(out, None).unwrap();
        let shape = |text: &str| -> Vec<u32> {
            font.shape(
                text.to_string(),
                None,
                vec![],
                None,
                None,
                Some(vec!["chn1".to_string()]),
            )
            .unwrap()
            .glyphs
            .iter()
            .map(|glyph| glyph.glyph_id)
            .collect()
        };
        assert_eq!(shape("ABD"), vec![a, c, d]);
        assert_eq!(shape("AB"), vec![a, b]); // missing lookahead
        assert_eq!(shape("BD"), vec![b, d]); // missing backtrack
    }

    #[test]
    fn colr_v1_paint_graph_is_written() {
        let glyph = ColorGlyphPaintSpec {
            code_point: 0x41,
            root: 0,
            nodes: vec![PaintNodeSpec {
                kind: "solid".to_string(),
                palette_index: 0,
                alpha: 1.0,
                ..Default::default()
            }],
        };
        let out = add_color_paints(inter(), &[0xFFFF0000], &[glyph]).unwrap();
        assert!(has_table(&out, b"COLR"));
        assert!(has_table(&out, b"CPAL"));
        let font = FontRef::new(&out).unwrap();
        let colr = font.colr().unwrap();
        assert_eq!(colr.version(), 1);
        assert!(colr
            .base_glyph_list()
            .expect("v1 COLR has a base glyph list")
            .is_ok());
    }

    // -----------------------------------------------------------------------
    // B4–B6: feature variations, MATH, SVG / VORG / raw tables
    // -----------------------------------------------------------------------

    use crate::api::build::{ContourPoint, FontBuildRequest, GlyphContour, GlyphSpec};
    use crate::api::fontations::Font;
    use crate::api::upstream::{
        FeatureConditionSpec, FeatureSubstitutionSpec, FeatureVariationPatchRequest,
        FeatureVariationRecordSpec, MathConstantSpec, MathConstructionSpec, MathGlyphValueSpec,
        MathKernSpec, MathPartSpec, MathTableRequest, MathVariantSpec, PatchRawTableSpec,
        SvgDocumentSpec, VarcComponentSpec, VarcDeltaSetSpec, VarcDeltaSpec, VarcGlyphSpec,
        VarcPatchRequest, VarcRegionAxisSpec, VerticalOriginRequest, VerticalOriginSpec,
    };

    fn box_glyph(code_point: u32) -> GlyphSpec {
        GlyphSpec {
            code_point,
            contours: vec![GlyphContour {
                points: vec![
                    ContourPoint {
                        x: 80.0,
                        y: 400.0,
                        on_curve: true,
                    },
                    ContourPoint {
                        x: 400.0,
                        y: 400.0,
                        on_curve: true,
                    },
                    ContourPoint {
                        x: 400.0,
                        y: 460.0,
                        on_curve: true,
                    },
                    ContourPoint {
                        x: 80.0,
                        y: 460.0,
                        on_curve: true,
                    },
                ],
            }],
            ..Default::default()
        }
    }

    fn fixture() -> Vec<u8> {
        crate::font_compile::build_ttf(&FontBuildRequest {
            family_name: "PatchFixture".to_string(),
            units_per_em: Some(1000),
            glyphs: vec![box_glyph(0x41), box_glyph(0x42), box_glyph(0x43)],
            ..Default::default()
        })
        .unwrap()
    }

    fn font_with_multiple_substitution() -> Vec<u8> {
        add_substitutions(
            &fixture(),
            &SubstitutionPatchRequest {
                multiple: vec![MultipleSubstitutionSpec {
                    feature_tag: "mlt1".to_string(),
                    code_point: 0x41,
                    replacement_code_points: vec![0x42, 0x43],
                }],
                ..Default::default()
            },
        )
        .unwrap()
    }

    fn variation_request() -> FeatureVariationPatchRequest {
        FeatureVariationPatchRequest {
            table: "GSUB".to_string(),
            conditions: vec![FeatureConditionSpec {
                kind: "variableValue".to_string(),
                default_value: 1,
                var_index: u32::MAX, // NO_VARIATION_INDEX: always true
                ..Default::default()
            }],
            records: vec![FeatureVariationRecordSpec {
                condition_indices: vec![0],
                substitutions: vec![FeatureSubstitutionSpec {
                    feature_tag: "mlt1".to_string(),
                    lookup_indices: vec![], // an alternate feature with no lookups
                }],
            }],
        }
    }

    #[test]
    fn feature_variations_keep_existing_features_and_change_the_plan() {
        let bytes =
            add_feature_variations(&font_with_multiple_substitution(), &variation_request())
                .unwrap();
        let read = FontRef::new(&bytes).unwrap();
        let gsub = read.gsub().unwrap();
        assert!(
            gsub.feature_variations().is_some(),
            "GSUB needs version 1.1"
        );
        assert_eq!(gsub.feature_list().unwrap().feature_records().len(), 1);

        let font = Font::from_bytes(bytes, None).unwrap();
        let shape = |features: Option<Vec<String>>| {
            font.shape("A".to_string(), None, vec![], None, None, features)
                .unwrap()
                .glyphs
                .len()
        };
        // The selected record substitutes `mlt1` with an empty feature table,
        // so the original multiple substitution no longer runs.
        assert_eq!(shape(Some(vec!["mlt1".to_string()])), 1);
        assert_eq!(shape(Some(vec![])), 1);
    }

    #[test]
    fn feature_variations_preserve_v2_gsub_lists() {
        let v2 = add_substitutions(
            &fixture(),
            &SubstitutionPatchRequest {
                multiple: vec![MultipleSubstitutionSpec {
                    feature_tag: "mlt1".to_string(),
                    code_point: 0x41,
                    replacement_code_points: vec![0x42, 0x43],
                }],
                use_v2: true,
                ..Default::default()
            },
        )
        .unwrap();
        let bytes = add_feature_variations(&v2, &variation_request()).unwrap();
        let font = Font::from_bytes(bytes, None).unwrap();
        // A 1.2 header keeps its script/feature/lookup lists in the 32-bit
        // fields; losing them on the way through `to_owned_table` would make
        // the feature disappear.
        assert!(font
            .layout(Some("GSUB".to_string()))
            .unwrap()
            .iter()
            .any(|table| table.features.iter().any(|f| f.tag == "mlt1")));
        assert_eq!(
            font.shape(
                "A".to_string(),
                None,
                vec![],
                None,
                None,
                Some(vec!["mlt1".to_string()])
            )
            .unwrap()
            .glyphs
            .len(),
            1
        );
    }

    #[test]
    fn feature_variation_requests_are_validated() {
        let base = font_with_multiple_substitution();
        let mut wrong_table = variation_request();
        wrong_table.table = "MATH".to_string();
        assert!(add_feature_variations(&base, &wrong_table).is_err());

        let mut unknown_kind = variation_request();
        unknown_kind.conditions[0].kind = "mystery".to_string();
        assert!(add_feature_variations(&base, &unknown_kind).is_err());

        let mut cycle = variation_request();
        cycle.conditions[0].children = vec![0];
        assert!(add_feature_variations(&base, &cycle).is_err());

        let mut missing_feature = variation_request();
        missing_feature.records[0].substitutions[0].feature_tag = "zzzz".to_string();
        assert!(add_feature_variations(&base, &missing_feature).is_err());
    }

    #[test]
    fn math_table_round_trips_with_device_corrections() {
        let request = MathTableRequest {
            constants: vec![
                MathConstantSpec {
                    name: "axisHeight".to_string(),
                    value: 250.0,
                },
                MathConstantSpec {
                    name: "fractionRuleThickness".to_string(),
                    value: 40.0,
                },
            ],
            min_connector_overlap: 10.0,
            italics_corrections: vec![MathGlyphValueSpec {
                code_point: 0x41,
                value: 42.0,
            }],
            top_accent_attachments: vec![MathGlyphValueSpec {
                code_point: 0x41,
                value: 300.0,
            }],
            extended_shapes: vec![0x41],
            kerns: vec![MathKernSpec {
                code_point: 0x41,
                corner: "topRight".to_string(),
                heights: vec![10.0],
                kerns: vec![5.0, 8.0],
            }],
            constructions: vec![MathConstructionSpec {
                code_point: 0x41,
                axis: "vertical".to_string(),
                variants: vec![MathVariantSpec {
                    variant_code_point: 0x42,
                    advance: 600.0,
                }],
                parts: vec![MathPartSpec {
                    part_code_point: 0x43,
                    start_connector_length: 10.0,
                    end_connector_length: 20.0,
                    full_advance: 300.0,
                    is_extender: true,
                }],
                italics_correction: 12.0,
                italics_device_start_ppem: Some(20),
                italics_device_deltas: vec![3, 7],
            }],
        };
        let bytes = add_math_table(&fixture(), &request).unwrap();
        assert!(has_table(&bytes, b"MATH"));
        let font = Font::from_bytes(bytes, None).unwrap();
        assert!(font.has_math().unwrap());

        let constants = font.math_constants(None).unwrap().unwrap();
        assert!(constants
            .iter()
            .any(|c| c.name == "axisHeight" && c.value == 250.0));
        assert!(constants
            .iter()
            .any(|c| c.name == "fractionRuleThickness" && c.value == 40.0));

        let gid = font.char_to_glyph(0x41).unwrap().unwrap();
        let info = font.math_glyph_info(gid, None).unwrap().unwrap();
        assert_eq!(info.italics_correction, Some(42.0));
        assert_eq!(info.top_accent_attachment, Some(300.0));
        assert!(info.is_extended_shape);
        assert_eq!(info.kerns.len(), 1);
        assert_eq!(info.kerns[0].corner, "topRight");

        let plain = font
            .math_variants(gid, "vertical".to_string(), None)
            .unwrap()
            .unwrap();
        assert_eq!(plain.min_connector_overlap, 10.0);
        assert_eq!(plain.variants.len(), 1);
        assert_eq!(plain.variants[0].advance, 600.0);
        let assembly = plain.assembly.clone().unwrap();
        assert_eq!(assembly.italics_correction, 12.0);
        assert_eq!(assembly.italics_correction_delta_px, 0.0);
        assert!(assembly.parts[0].is_extender);

        // The device table only contributes at the requested ppem.
        let at_21 = font
            .math_variants(gid, "vertical".to_string(), Some(21))
            .unwrap()
            .unwrap();
        assert_eq!(at_21.assembly.unwrap().italics_correction_delta_px, 7.0);
        assert!(font
            .math_variants(gid, "horizontal".to_string(), None)
            .unwrap()
            .is_none());
    }

    #[test]
    fn math_rejects_unknown_constants_and_corners() {
        let mut request = MathTableRequest::default();
        request.constants.push(MathConstantSpec {
            name: "notAConstant".to_string(),
            value: 1.0,
        });
        assert!(add_math_table(&fixture(), &request).is_err());

        let mut request = MathTableRequest::default();
        request.kerns.push(MathKernSpec {
            code_point: 0x41,
            corner: "upwards".to_string(),
            ..Default::default()
        });
        assert!(add_math_table(&fixture(), &request).is_err());
    }

    #[test]
    fn varc_glyphs_round_trip_with_conditions_and_deltas() {
        let region = || VarcRegionAxisSpec {
            axis_index: 0,
            start: 0.0,
            peak: 1.0,
            end: 1.0,
        };
        let request = VarcPatchRequest {
            conditions: vec![FeatureConditionSpec {
                kind: "variableValue".to_string(),
                default_value: 1,
                var_index: u32::MAX,
                ..Default::default()
            }],
            delta_sets: vec![
                VarcDeltaSetSpec {
                    entries: vec![VarcDeltaSpec {
                        axes: vec![region()],
                        deltas: vec![100],
                    }],
                },
                VarcDeltaSetSpec {
                    entries: vec![VarcDeltaSpec {
                        axes: vec![region()],
                        deltas: vec![4096],
                    }],
                },
            ],
            glyphs: vec![VarcGlyphSpec {
                code_point: 0x41,
                components: vec![VarcComponentSpec {
                    component_code_point: 0x42,
                    condition_index: Some(0),
                    axis_indices: vec![0],
                    axis_values: vec![0.5],
                    axis_values_delta_set: Some(1),
                    transform_delta_set: Some(0),
                    translate_x: Some(50.0),
                    ..Default::default()
                }],
            }],
        };
        let bytes = add_varc_glyphs(&fixture(), &request).unwrap();
        assert!(has_table(&bytes, b"VARC"));
        let font = Font::from_bytes(bytes, None).unwrap();
        assert!(font.has_varc().unwrap());
        let gid = font.char_to_glyph(0x41).unwrap().unwrap();
        let info = font.varc_components(gid, vec![]).unwrap().unwrap();
        assert_eq!(info.components.len(), 1);
        let component = &info.components[0];
        assert_eq!(component.glyph_id, 2);
        assert!(component.condition_met);
        assert_eq!(component.axis_indices, vec![0]);
        assert!((component.axis_values[0] - 0.5).abs() < 1e-6);
        assert!((component.transform[4] - 50.0).abs() < 1e-6);
    }

    #[test]
    fn varc_requests_are_validated() {
        let mut bad_condition = VarcPatchRequest::default();
        bad_condition.glyphs.push(VarcGlyphSpec {
            code_point: 0x41,
            components: vec![VarcComponentSpec {
                component_code_point: 0x42,
                condition_index: Some(3),
                ..Default::default()
            }],
        });
        assert!(add_varc_glyphs(&fixture(), &bad_condition).is_err());

        let mut bad_delta = VarcPatchRequest::default();
        bad_delta.glyphs.push(VarcGlyphSpec {
            code_point: 0x41,
            components: vec![VarcComponentSpec {
                component_code_point: 0x42,
                transform_delta_set: Some(0),
                ..Default::default()
            }],
        });
        assert!(add_varc_glyphs(&fixture(), &bad_delta).is_err());

        let mut uneven_tuple = VarcPatchRequest::default();
        uneven_tuple.delta_sets.push(VarcDeltaSetSpec {
            entries: vec![
                VarcDeltaSpec {
                    axes: vec![],
                    deltas: vec![1],
                },
                VarcDeltaSpec {
                    axes: vec![],
                    deltas: vec![1, 2],
                },
            ],
        });
        assert!(add_varc_glyphs(&fixture(), &uneven_tuple).is_err());
    }

    #[test]
    fn svg_vorg_and_raw_tables_round_trip() {
        let base = fixture();
        let with_svg = add_svg_documents(
            &base,
            &[SvgDocumentSpec {
                start_code_point: 0x41,
                end_code_point: 0x42,
                data: b"<svg><rect/></svg>".to_vec(),
            }],
        )
        .unwrap();
        let with_vorg = add_vertical_origins(
            &with_svg,
            &VerticalOriginRequest {
                default_origin_y: 880.0,
                origins: vec![VerticalOriginSpec {
                    code_point: 0x41,
                    origin_y: 867.0,
                }],
            },
        )
        .unwrap();
        let bytes = add_raw_tables(
            &with_vorg,
            &[PatchRawTableSpec {
                tag: "CVAR".to_string(),
                data: vec![1, 2, 3, 4],
            }],
        )
        .unwrap();
        assert!(has_table(&bytes, b"SVG "));
        assert!(has_table(&bytes, b"VORG"));
        assert!(has_table(&bytes, b"CVAR"));

        let font = Font::from_bytes(bytes, None).unwrap();
        assert_eq!(
            font.table_data("CVAR".to_string()).unwrap(),
            Some(vec![1, 2, 3, 4])
        );
        assert_eq!(font.vertical_origin(1).unwrap(), Some(867.0));
        assert_eq!(font.vertical_origin(2).unwrap(), Some(880.0));
        let extended = font.extended_tables().unwrap();
        assert_eq!(extended.svg_documents.len(), 1);
        assert!(extended.svg_documents[0]
            .preview
            .contains("<svg><rect/></svg>"));
    }
}
