//! Capabilities that the upstream fontations crates already ship and that this
//! plugin exposes on top of its core read/write API.
//!
//! * subsetting, via the upstream `skera` crate;
//! * structured access to the less common tables (`SVG `, `gasp`, `meta`,
//!   `BASE`, AAT), which `Font.tableData` only hands out as raw bytes.

use anyhow::{anyhow, Result};
use read_fonts::collections::IntSet;
use read_fonts::tables::meta::Metadata;
use read_fonts::types::{GlyphId, NameId, Tag};
use read_fonts::{FileRef, FontRef, TableProvider};
use skera::{Plan, SubsetFlags, DEFAULT_DROP_TABLES, DEFAULT_LAYOUT_FEATURES};

use crate::limits::check_font_bytes;

// ---------------------------------------------------------------------------
// Subsetting
// ---------------------------------------------------------------------------

/// Which glyphs to keep, and how the subsetter should rewrite the font.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct FontSubsetRequest {
    /// Unicode code points to keep. Layout closure pulls in the glyphs they
    /// need (ligatures, alternates, marks, ...).
    pub code_points: Vec<u32>,
    /// Glyph ids to keep in addition to the code points.
    pub glyph_ids: Vec<u32>,
    /// Keep the original glyph ids, emitting empty glyphs for dropped ones.
    pub retain_glyph_ids: bool,
    /// Drop TrueType hinting instructions.
    pub no_hinting: bool,
    /// Copy tables the subsetter does not understand instead of dropping them.
    pub passthrough_unrecognized: bool,
    /// Keep PostScript glyph names.
    pub glyph_names: bool,
    /// Keep every glyph, name record and table: a full rewrite of the font.
    pub keep_everything: bool,
    /// Layout features to keep. Empty uses the upstream default set.
    pub layout_features: Vec<String>,
    /// Extra table tags to drop on top of the upstream default drop list.
    pub drop_tables: Vec<String>,
}

/// Removes every glyph the request does not ask for, using the upstream
/// `skera` subsetter. Layout tables, `cmap`, hinting and variation tables are
/// rewritten by the subsetter so the result is a valid standalone font.
pub fn subset_font(
    bytes: Vec<u8>,
    index: Option<u32>,
    request: FontSubsetRequest,
) -> Result<Vec<u8>> {
    check_font_bytes(&bytes)?;
    let face = index.unwrap_or(0) as usize;
    let file = FileRef::new(&bytes).map_err(|e| anyhow!("not a valid font file: {e}"))?;
    let font = file
        .fonts()
        .nth(face)
        .ok_or_else(|| anyhow!("font index {face} is out of range"))?
        .map_err(|e| anyhow!("failed to read font {face}: {e}"))?;

    let mut gids = IntSet::<GlyphId>::empty();
    for id in &request.glyph_ids {
        gids.insert(GlyphId::new(*id));
    }
    let mut unicodes = IntSet::<u32>::empty();
    for code_point in &request.code_points {
        unicodes.insert(*code_point);
    }

    let mut flags = SubsetFlags::SUBSET_FLAGS_DEFAULT;
    if request.retain_glyph_ids {
        flags |= SubsetFlags::SUBSET_FLAGS_RETAIN_GIDS;
    }
    if request.no_hinting {
        flags |= SubsetFlags::SUBSET_FLAGS_NO_HINTING;
    }
    if request.passthrough_unrecognized {
        flags |= SubsetFlags::SUBSET_FLAGS_PASSTHROUGH_UNRECOGNIZED;
    }
    if request.glyph_names {
        flags |= SubsetFlags::SUBSET_FLAGS_GLYPH_NAMES;
    }

    // Defaults mirror `skera`'s own CLI / hb-subset: drop legacy layout and
    // bitmap tables, keep name ids 0..=6 in English, allow every script and
    // the standard layout features.
    let mut drop_tables: IntSet<Tag> = if request.keep_everything {
        IntSet::empty()
    } else {
        DEFAULT_DROP_TABLES.iter().copied().collect()
    };
    for tag in &request.drop_tables {
        drop_tables.insert(parse_tag(tag)?);
    }
    let mut name_ids = IntSet::<NameId>::empty();
    name_ids.insert_range(NameId::from(0)..=NameId::from(6));
    let mut name_languages = IntSet::<u16>::empty();
    name_languages.insert(0x0409);
    let mut layout_scripts = IntSet::<Tag>::empty();
    layout_scripts.invert();
    let mut layout_features: IntSet<Tag> = if request.layout_features.is_empty() {
        DEFAULT_LAYOUT_FEATURES.iter().copied().collect()
    } else {
        let mut set = IntSet::empty();
        for tag in &request.layout_features {
            set.insert(parse_tag(tag)?);
        }
        set
    };

    if request.keep_everything {
        flags |= SubsetFlags::KEEP_EVERYTHING;
        gids = IntSet::all();
        unicodes = IntSet::all();
        drop_tables = IntSet::empty();
        name_ids = IntSet::all();
        name_languages = IntSet::all();
        layout_features = IntSet::all();
    }

    let plan = Plan::new(
        &gids,
        &unicodes,
        &font,
        flags,
        &drop_tables,
        &layout_scripts,
        &layout_features,
        &name_ids,
        &name_languages,
    );
    skera::subset_font(&font, &plan).map_err(|e| anyhow!("subsetting failed: {e}"))
}

// ---------------------------------------------------------------------------
// Upstream write request types
// ---------------------------------------------------------------------------

/// One embedded bitmap of an `sbix` strike.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct BitmapGlyphSpec {
    /// Code point of the glyph this bitmap replaces.
    pub code_point: u32,
    /// Four character graphic type: `png `, `jpg `, `tiff` or `dupe`.
    pub format: String,
    /// The encoded image bytes, copied verbatim into the table.
    pub data: Vec<u8>,
    pub origin_offset_x: i32,
    pub origin_offset_y: i32,
}

/// One `sbix` strike: a ppem/ppi pair with a bitmap per glyph.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct BitmapStrikeSpec {
    pub ppem: u32,
    pub ppi: u32,
    pub glyphs: Vec<BitmapGlyphSpec>,
}

/// A `GSUB` multiple substitution: one glyph becomes a sequence of glyphs.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct MultipleSubstitutionSpec {
    pub feature_tag: String,
    pub code_point: u32,
    pub replacement_code_points: Vec<u32>,
}

/// A `GSUB` alternate substitution: one glyph may be swapped for any of these.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct AlternateSubstitutionSpec {
    pub feature_tag: String,
    pub code_point: u32,
    pub replacement_code_points: Vec<u32>,
}

/// A contextual substitution: when `input` appears (optionally surrounded by
/// `backtrack` / `lookahead`), replace its first glyph through a nested single
/// substitution lookup.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct ContextualSubstitutionSpec {
    pub feature_tag: String,
    /// Code points immediately before the input sequence, closest first.
    pub backtrack: Vec<u32>,
    /// Code points of the input sequence; at least one is required.
    pub input: Vec<u32>,
    /// Code points immediately after the input sequence.
    pub lookahead: Vec<u32>,
    /// Code point whose glyph replaces the first input glyph.
    pub replacement_code_point: u32,
}

/// A reverse chaining single substitution: replace `code_point` only when the
/// optional backtrack / lookahead sequences surround it.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct ReverseChainSubstitutionSpec {
    pub feature_tag: String,
    pub code_point: u32,
    pub replacement_code_point: u32,
    pub backtrack: Vec<u32>,
    pub lookahead: Vec<u32>,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct SubstitutionPatchRequest {
    pub multiple: Vec<MultipleSubstitutionSpec>,
    pub alternate: Vec<AlternateSubstitutionSpec>,
    pub contextual: Vec<ContextualSubstitutionSpec>,
    pub reverse_chain: Vec<ReverseChainSubstitutionSpec>,
    /// Write the 2026 v2 subtables (24-bit glyph ids, 32-bit offsets) and the
    /// matching 32-bit GSUB header instead of the original layouts.
    pub use_v2: bool,
}

/// One stop of a `COLR` v1 gradient color line.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct ColorStopSpec {
    pub offset: f64,
    pub palette_index: u32,
    pub alpha: f64,
}

/// One node of a flattened `COLR` v1 paint graph. `children` are indices into
/// [ColorGlyphPaintSpec::nodes], which keeps the graph acyclic for the bridge.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct PaintNodeSpec {
    /// `solid`, `linearGradient`, `radialGradient`, `sweepGradient`, `glyph`,
    /// `translate`, `scale`, `rotate`, `composite` or `layers`.
    pub kind: String,
    pub palette_index: u32,
    pub alpha: f64,
    pub x0: f64,
    pub y0: f64,
    pub x1: f64,
    pub y1: f64,
    pub r0: f64,
    pub r1: f64,
    pub start_angle: f64,
    pub end_angle: f64,
    pub glyph_id: u32,
    pub extend: String,
    pub composite_mode: String,
    pub stops: Vec<ColorStopSpec>,
    pub children: Vec<u32>,
}

/// The paint graph of one base glyph.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct ColorGlyphPaintSpec {
    pub code_point: u32,
    /// Index of the root node in `nodes`.
    pub root: u32,
    pub nodes: Vec<PaintNodeSpec>,
}

// ---------------------------------------------------------------------------
// Feature variations, MATH, SVG / VORG and raw table patches
// ---------------------------------------------------------------------------

/// One condition of a `GSUB` / `GPOS` feature variation record. Nested
/// conditions address earlier entries of the flat list, which keeps the tree
/// acyclic: `children` must only contain indices below the node's own index.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct FeatureConditionSpec {
    /// `axisRange`, `variableValue`, `and`, `or` or `not`.
    pub kind: String,
    /// `fvar` axis index for `axisRange`.
    pub axis_index: u32,
    pub min_value: f64,
    pub max_value: f64,
    /// Fallback value for `variableValue`; true when greater than zero.
    pub default_value: i32,
    /// Delta set index into `GDEF`'s item variation store.
    pub var_index: u32,
    pub children: Vec<u32>,
}

/// An alternate feature table: the lookups this feature runs at the selected
/// location. The feature is addressed by its tag in the target layout table.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct FeatureSubstitutionSpec {
    pub feature_tag: String,
    pub lookup_indices: Vec<u32>,
}

/// One selected record: its condition set (empty means unconditional) and the
/// feature tables it replaces.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct FeatureVariationRecordSpec {
    pub condition_indices: Vec<u32>,
    pub substitutions: Vec<FeatureSubstitutionSpec>,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct FeatureVariationPatchRequest {
    /// `GSUB`, `GPOS` or `both`.
    pub table: String,
    pub conditions: Vec<FeatureConditionSpec>,
    pub records: Vec<FeatureVariationRecordSpec>,
}

/// A `MATH` constant by its OpenType name (`axisHeight`, `fractionRuleThickness`, …).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct MathConstantSpec {
    pub name: String,
    pub value: f64,
}

/// A per glyph `MATH` value (italics correction or top accent attachment).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct MathGlyphValueSpec {
    pub code_point: u32,
    pub value: f64,
}

/// Corner kerns: `heights` are correction heights and `kerns` the kern values;
/// both are in design units and `kerns` has one more entry than `heights`.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct MathKernSpec {
    pub code_point: u32,
    /// `topRight`, `topLeft`, `bottomRight` or `bottomLeft`.
    pub corner: String,
    pub heights: Vec<f64>,
    pub kerns: Vec<f64>,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct MathVariantSpec {
    pub variant_code_point: u32,
    pub advance: f64,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct MathPartSpec {
    pub part_code_point: u32,
    pub start_connector_length: f64,
    pub end_connector_length: f64,
    pub full_advance: f64,
    pub is_extender: bool,
}

/// A stretchy delimiter: ready made sizes plus the pieces used to assemble it.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct MathConstructionSpec {
    pub code_point: u32,
    /// `vertical` or `horizontal`.
    pub axis: String,
    pub variants: Vec<MathVariantSpec>,
    pub parts: Vec<MathPartSpec>,
    pub italics_correction: f64,
    /// Optional device table for the assembly's italics correction: one pixel
    /// delta per ppem starting at `italics_device_start_ppem`.
    pub italics_device_start_ppem: Option<u32>,
    pub italics_device_deltas: Vec<i32>,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct MathTableRequest {
    pub constants: Vec<MathConstantSpec>,
    pub min_connector_overlap: f64,
    pub italics_corrections: Vec<MathGlyphValueSpec>,
    pub top_accent_attachments: Vec<MathGlyphValueSpec>,
    pub extended_shapes: Vec<u32>,
    pub kerns: Vec<MathKernSpec>,
    pub constructions: Vec<MathConstructionSpec>,
}

/// An `SVG ` document for a range of glyphs. `data` is stored verbatim (plain
/// SVG or gzip-compressed SVG).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct SvgDocumentSpec {
    pub start_code_point: u32,
    pub end_code_point: u32,
    pub data: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct VerticalOriginSpec {
    pub code_point: u32,
    pub origin_y: f64,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct VerticalOriginRequest {
    pub default_origin_y: f64,
    pub origins: Vec<VerticalOriginSpec>,
}

/// A table the plugin has no typed writer for, installed as raw bytes.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct PatchRawTableSpec {
    pub tag: String,
    pub data: Vec<u8>,
}

/// One sparse variation region axis of a `VARC` delta set.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct VarcRegionAxisSpec {
    pub axis_index: u32,
    pub start: f64,
    pub peak: f64,
    pub end: f64,
}

/// One region of a `VARC` delta set: its sparse region and the tuple of deltas
/// it contributes (one value per condition / transform field / axis coordinate).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct VarcDeltaSpec {
    pub axes: Vec<VarcRegionAxisSpec>,
    pub deltas: Vec<i32>,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct VarcDeltaSetSpec {
    pub entries: Vec<VarcDeltaSpec>,
}

/// One component of a `VARC` composite glyph. Transform fields left `null` are
/// omitted from the table (and from the tuple of its transform deltas).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct VarcComponentSpec {
    /// Code point of the glyph drawn by this component.
    pub component_code_point: u32,
    /// Index into `VarcPatchRequest.conditions`, or `null` for unconditional.
    pub condition_index: Option<u32>,
    pub axis_indices: Vec<u32>,
    pub axis_values: Vec<f64>,
    /// Indexes into `VarcPatchRequest.delta_sets`.
    pub axis_values_delta_set: Option<u32>,
    pub transform_delta_set: Option<u32>,
    pub translate_x: Option<f64>,
    pub translate_y: Option<f64>,
    pub rotation: Option<f64>,
    pub scale_x: Option<f64>,
    pub scale_y: Option<f64>,
    pub skew_x: Option<f64>,
    pub skew_y: Option<f64>,
    pub center_x: Option<f64>,
    pub center_y: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct VarcGlyphSpec {
    /// Code point of the composite glyph being defined.
    pub code_point: u32,
    pub components: Vec<VarcComponentSpec>,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct VarcPatchRequest {
    pub conditions: Vec<FeatureConditionSpec>,
    pub delta_sets: Vec<VarcDeltaSetSpec>,
    pub glyphs: Vec<VarcGlyphSpec>,
}

/// Adds `sbix` bitmap strikes to an existing font. `write-fonts` 0.56 has the
/// table layout but does not serialize glyph image data, so the strike is
/// assembled here and installed as a raw table.
pub fn add_bitmap_strikes(bytes: Vec<u8>, strikes: Vec<BitmapStrikeSpec>) -> Result<Vec<u8>> {
    crate::upstream_write::add_bitmap_strikes(&bytes, &strikes)
}

/// Adds `GSUB` multiple and alternate substitution lookups to an existing
/// font, keeping every other table (including an existing `GSUB`'s other
/// lookups' siblings) untouched.
pub fn add_substitutions(bytes: Vec<u8>, request: SubstitutionPatchRequest) -> Result<Vec<u8>> {
    crate::upstream_write::add_substitutions(&bytes, &request)
}

/// Writes `COLR` version 1 paint graphs and a matching `CPAL` palette into an
/// existing font.
pub fn add_color_paints(
    bytes: Vec<u8>,
    palette: Vec<u32>,
    glyphs: Vec<ColorGlyphPaintSpec>,
) -> Result<Vec<u8>> {
    crate::upstream_write::add_color_paints(&bytes, &palette, &glyphs)
}

/// Writes `GSUB` / `GPOS` feature variations into an existing font. Existing
/// scripts, features and lookups are kept; only the version 1.1
/// `FeatureVariations` subtable changes.
pub fn add_feature_variations(
    bytes: Vec<u8>,
    request: FeatureVariationPatchRequest,
) -> Result<Vec<u8>> {
    crate::upstream_write::add_feature_variations(&bytes, &request)
}

/// Writes a structured `MATH` table (constants, per glyph corrections and
/// stretchy constructions) into an existing font.
pub fn add_math_table(bytes: Vec<u8>, request: MathTableRequest) -> Result<Vec<u8>> {
    crate::upstream_write::add_math_table(&bytes, &request)
}

/// Writes an `SVG ` table with one document per glyph range.
pub fn add_svg_documents(bytes: Vec<u8>, documents: Vec<SvgDocumentSpec>) -> Result<Vec<u8>> {
    crate::upstream_write::add_svg_documents(&bytes, &documents)
}

/// Writes `VORG` vertical origins into an existing font.
pub fn add_vertical_origins(bytes: Vec<u8>, request: VerticalOriginRequest) -> Result<Vec<u8>> {
    crate::upstream_write::add_vertical_origins(&bytes, &request)
}

/// Writes a structured `VARC` table (variable composite glyphs, conditions and
/// a multi item variation store) into an existing font.
pub fn add_varc_glyphs(bytes: Vec<u8>, request: VarcPatchRequest) -> Result<Vec<u8>> {
    crate::upstream_write::add_varc_glyphs(&bytes, &request)
}

/// Installs arbitrary table bytes into an existing font (for tables with no
/// typed writer, e.g. `VVAR`, `CVAR`, `CBDT` or hand-built `MATH`).
pub fn add_raw_tables(bytes: Vec<u8>, tables: Vec<PatchRawTableSpec>) -> Result<Vec<u8>> {
    crate::upstream_write::add_raw_tables(&bytes, &tables)
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

// ---------------------------------------------------------------------------
// Extended table readers
// ---------------------------------------------------------------------------

/// One `SVG ` document record: the glyph range it paints and a short preview
/// of the (possibly compressed) SVG payload.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct SvgDocumentInfo {
    pub start_glyph_id: u32,
    pub end_glyph_id: u32,
    pub length: u32,
    pub preview: String,
}

/// One `gasp` range: the upper ppem bound and the rasterization behaviour.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct GaspRangeInfo {
    pub max_ppem: u32,
    pub behavior: String,
}

/// One `meta` data map: its tag and the value as UTF-8 when it is text.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct MetaEntryInfo {
    pub tag: String,
    pub length: u32,
    pub value: String,
}

/// Tables that have no typed API on `Font`, summarized in one call.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct ExtendedTableInfo {
    /// Every table tag in the font.
    pub tables: Vec<String>,
    pub svg_documents: Vec<SvgDocumentInfo>,
    pub gasp_ranges: Vec<GaspRangeInfo>,
    pub meta_entries: Vec<MetaEntryInfo>,
    /// Apple Advanced Typography tables present in the font.
    pub aat_tables: Vec<String>,
    pub has_base: bool,
    pub has_cvar: bool,
    pub has_vvar: bool,
    pub has_mvar: bool,
    pub has_dsig: bool,
    pub has_hdmx: bool,
}

const AAT_TAGS: &[&[u8; 4]] = &[
    b"morx", b"mort", b"kerx", b"ankr", b"trak", b"ltag", b"feat", b"bsln", b"just", b"opbd",
    b"prop", b"Zapf",
];

/// Reads the structured parts of the optional tables; missing or malformed
/// tables yield empty lists rather than failing the whole call.
pub(crate) fn read_extended_tables(font: &FontRef<'_>) -> ExtendedTableInfo {
    let tags: Vec<String> = font
        .table_directory()
        .table_records()
        .iter()
        .map(|record| record.tag().to_string())
        .collect();
    let has = |tag: &str| tags.iter().any(|present| present == tag);

    let mut svg_documents = Vec::new();
    if let Ok(svg) = font.svg() {
        if let Ok(list) = svg.svg_document_list() {
            for record in list.document_records() {
                let start = record.start_glyph_id().to_u16() as u32;
                let end = record.end_glyph_id().to_u16() as u32;
                let preview = svg
                    .glyph_data(GlyphId::new(start))
                    .map(|data| String::from_utf8_lossy(&data[..data.len().min(256)]).to_string())
                    .unwrap_or_default();
                svg_documents.push(SvgDocumentInfo {
                    start_glyph_id: start,
                    end_glyph_id: end,
                    length: record.svg_doc_length(),
                    preview,
                });
            }
        }
    }

    let mut gasp_ranges = Vec::new();
    if let Ok(gasp) = font.gasp() {
        for range in gasp.gasp_ranges() {
            gasp_ranges.push(GaspRangeInfo {
                max_ppem: range.range_max_ppem() as u32,
                behavior: format!("{:?}", range.range_gasp_behavior()),
            });
        }
    }

    let mut meta_entries = Vec::new();
    if let Ok(meta) = font.meta() {
        for record in meta.data_maps() {
            let value = match record.data(meta.offset_data()) {
                Ok(Metadata::ScriptLangTags(tags)) => tags
                    .iter()
                    .filter_map(|tag| tag.ok())
                    .map(|tag| tag.as_str())
                    .collect::<Vec<_>>()
                    .join(","),
                Ok(Metadata::Other(bytes)) => String::from_utf8_lossy(bytes).to_string(),
                Err(_) => String::new(),
            };
            meta_entries.push(MetaEntryInfo {
                tag: record.tag().to_string(),
                length: record.data_length(),
                value,
            });
        }
    }

    let aat_tables = AAT_TAGS
        .iter()
        .map(|tag| Tag::new(tag).to_string())
        .filter(|tag| has(tag))
        .collect();

    ExtendedTableInfo {
        tables: tags.clone(),
        svg_documents,
        gasp_ranges,
        meta_entries,
        aat_tables,
        has_base: has("BASE"),
        has_cvar: has("cvar"),
        has_vvar: has("VVAR"),
        has_mvar: has("MVAR"),
        has_dsig: has("DSIG"),
        has_hdmx: has("hdmx"),
    }
}
