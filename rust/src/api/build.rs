//! Types for *writing* a TrueType font from scratch with `write-fonts`.
//!
//! The Dart side draws outlines, converts them into contours expressed in font
//! units, and hands them to [build_font], which compiles them into a `.ttf`.

use anyhow::Result;

/// A point of a glyph contour, in font units (y up, baseline at `y = 0`).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ContourPoint {
    pub x: f64,
    pub y: f64,
    /// `false` marks a quadratic (TrueType) control point.
    pub on_curve: bool,
}

/// One closed contour of a glyph.
#[derive(Debug, Clone, PartialEq)]
pub struct GlyphContour {
    pub points: Vec<ContourPoint>,
}

/// A glyph to write into the font.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct GlyphSpec {
    /// The Unicode code point this glyph should be mapped to.
    pub code_point: u32,
    /// The outline at the default location of every axis.
    pub contours: Vec<GlyphContour>,
    /// Advance width in font units. Defaults to `units_per_em`.
    pub advance_width: Option<f64>,
    /// Additional outlines (masters) used to build `gvar`.
    ///
    /// Every master must describe the same character with the **same number of
    /// contours and the same number of points** as [GlyphSpec::contours], in the
    /// same order. Hand drawn outlines normally satisfy this when each master is
    /// drawn with the same number of strokes that are resampled to a fixed point
    /// count.
    pub masters: Vec<VariationMaster>,
    /// Discrete alternates exposed as OpenType features (`ss01`, `cv01`, ...).
    ///
    /// Each one becomes an extra glyph that the `cmap` does not point at; it is
    /// only reachable through a `GSUB` single substitution.
    pub alternates: Vec<StylisticAlternate>,
    /// Parts this glyph is assembled from, producing a **composite glyph**.
    ///
    /// Every component refers to another glyph of the same request by its code
    /// point. Composite glyphs cannot carry `masters` (`gvar` on composites is
    /// not supported), and they take precedence over [GlyphSpec::contours].
    pub components: Vec<GlyphComponent>,
    /// `COLR` layers: solid shapes stacked front to back and colored from the
    /// palette in [FontBuildRequest::palette].
    pub color_layers: Vec<GlyphColorLayer>,
    /// Raw TrueType hinting instructions for this glyph.
    pub instructions: Option<Vec<u8>>,
    /// Advance height for vertical text; defaults to `units_per_em` when the
    /// request declares [FontBuildRequest::vertical_metrics].
    pub vertical_advance: Option<f64>,
    /// Vertical origin of this glyph, used for the top side bearing in
    /// `vmtx`; defaults to the vertical ascender.
    ///
    /// A `VORG` table is *not* written (`write-fonts` has no support for it),
    /// so readers fall back to `vhea` minus the top side bearing.
    pub vertical_origin: Option<f64>,
}

/// One `fvar` axis.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct VariationAxisSpec {
    /// Four character tag, e.g. `wght`.
    pub tag: String,
    /// Display name stored in the `name` table.
    pub name: String,
    pub min_value: f64,
    pub default_value: f64,
    pub max_value: f64,
    /// `avar` segment maps, in **normalized** coordinates (-1..1).
    ///
    /// The default normalization is linear between `min`/`default`/`max`; these
    /// entries remap it, which is how a designer makes one end of an axis move
    /// faster than the other.
    pub mappings: Vec<AxisValueMapSpec>,
}

/// A named instance (preset) exposed through `fvar`.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct NamedInstanceSpec {
    pub name: String,
    /// One **user space** coordinate per axis, in the order of
    /// [FontBuildRequest::axes].
    pub coordinates: Vec<f64>,
}

/// An alternative outline for a glyph, placed somewhere in variation space.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct VariationMaster {
    /// One **user space** coordinate per axis, in the order of
    /// [FontBuildRequest::axes].
    pub coordinates: Vec<f64>,
    pub contours: Vec<GlyphContour>,
    /// Advance width at this location, in font units.
    ///
    /// Given for every master, these are compiled into `HVAR`, so the advance
    /// width interpolates along the axes instead of staying constant.
    pub advance_width: Option<f64>,
    /// Global metrics at this location, compiled into `MVAR`.
    ///
    /// `tag` is one of `hasc`, `hdsc`, `hlgp`, `hcla`, `hcof` and the value is
    /// the metric in font units; the delta against the request's default is
    /// what ends up in the table.
    pub global_metrics: Vec<MetricValue>,
}

/// An alternative outline reachable through an OpenType feature, e.g. `ss01`.
///
/// Unlike [VariationMaster] this is a *discrete* substitution: the glyph is
/// swapped through `GSUB` when the feature is requested, and no interpolation
/// happens. This is what `ss01`..`ss20` (and `cv01`..) are for.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct StylisticAlternate {
    /// Four character feature tag, e.g. `ss01`.
    pub feature_tag: String,
    pub contours: Vec<GlyphContour>,
    /// Advance width in font units. Defaults to `units_per_em`.
    pub advance_width: Option<f64>,
    /// UI label stored in the `name` table and referenced from the feature
    /// through `FeatureParams`, so applications can show a name for `ss01`.
    /// Only used for `ssNN` tags.
    pub name: Option<String>,
}

/// One part of a composite glyph.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct GlyphComponent {
    /// Code point of the glyph to reuse; it must be part of the same request.
    pub code_point: u32,
    /// Offset of the component, in font units.
    pub dx: f64,
    pub dy: f64,
    /// Uniform scale, `1.0` by default.
    pub scale: Option<f64>,
    /// Take the advance width of this component for the whole composite.
    pub use_my_metrics: bool,
}

/// One `COLR` layer of a glyph: a shape filled with a palette color.
#[derive(Debug, Clone, PartialEq)]
pub struct GlyphColorLayer {
    pub contours: Vec<GlyphContour>,
    /// Index into [FontBuildRequest::palette].
    pub palette_index: u16,
}

/// A ligature: a run of code points replaced by a single glyph.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct LigatureSpec {
    /// Feature tag; `liga` is the conventional one.
    pub feature_tag: String,
    /// Code points that trigger the ligature, in order.
    pub sequence: Vec<u32>,
    pub contours: Vec<GlyphContour>,
    /// Advance width in font units. Defaults to `units_per_em`.
    pub advance_width: Option<f64>,
}

/// Vertical layout metrics; writing them produces `vhea` + `vmtx`.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct VerticalMetricsSpec {
    pub ascender: f64,
    pub descender: f64,
    pub line_gap: Option<f64>,
}

/// One `avar` entry: remaps a normalized axis coordinate.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AxisValueMapSpec {
    /// Normalized coordinate from the default (`fvar`) normalization.
    pub from: f64,
    /// Coordinate it is mapped to.
    pub to: f64,
}

/// Value of one global metric, used by `MVAR`.
#[derive(Debug, Clone, PartialEq)]
pub struct MetricValue {
    /// Metric tag: `hasc`, `hdsc`, `hlgp`, `hcla` or `hcof`.
    pub tag: String,
    pub value: f64,
}

/// A table copied into the font verbatim, e.g. `fpgm`, `prep` or `cvt `.
#[derive(Debug, Clone, PartialEq)]
pub struct RawTableSpec {
    /// Four character table tag.
    pub tag: String,
    /// Bytes of the table (without any table directory).
    pub data: Vec<u8>,
}

/// A `cmap` format 14 variation selector, e.g. `U+FE0E`.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct VariationSelectorSpec {
    /// Code point of the selector itself.
    pub selector: u32,
    /// Base code point plus the code point whose glyph should be used instead.
    pub variants: Vec<CodePointVariant>,
}

/// One entry of a [VariationSelectorSpec].
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CodePointVariant {
    pub code_point: u32,
    pub variant_code_point: u32,
}

/// A kerning pair, compiled into a `GPOS` pair positioning lookup.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct KernPair {
    /// Code point of the first glyph.
    pub left: u32,
    /// Code point of the second glyph.
    pub right: u32,
    /// Amount to add to the advance of the first glyph, in font units.
    pub value: f64,
}

/// Everything needed to compile a TrueType font.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct FontBuildRequest {
    pub family_name: String,
    /// Defaults to `Regular`. Also drives `OS/2.fsSelection` and, when
    /// [FontBuildRequest::weight_class] is not given, `OS/2.usWeightClass`
    /// (`Regular` -> 400, `Bold` -> 700, `Light` -> 300, ...).
    pub subfamily_name: Option<String>,
    /// `OS/2.usWeightClass`, 100..1000. Derived from the subfamily name when
    /// absent.
    pub weight_class: Option<u16>,
    /// `OS/2.usWidthClass`, 1..9 (5 is normal).
    pub width_class: Option<u16>,
    /// Four character vendor id written to `OS/2.achVendID`.
    pub vendor_id: Option<String>,
    /// Defaults to 1000.
    pub units_per_em: Option<u32>,
    /// Defaults to `0.8 * units_per_em`.
    pub ascender: Option<f64>,
    /// Defaults to `-0.2 * units_per_em`.
    pub descender: Option<f64>,
    pub glyphs: Vec<GlyphSpec>,
    /// Variation axes. Empty (the default) produces a static font.
    pub axes: Vec<VariationAxisSpec>,
    /// Named instances (presets) for the axes above.
    pub instances: Vec<NamedInstanceSpec>,
    /// Kerning pairs, compiled into a `GPOS` `kern` feature.
    pub kern_pairs: Vec<KernPair>,
    /// `name` table designer (name id 9).
    pub designer: Option<String>,
    /// `name` table license description (name id 13).
    pub license: Option<String>,
    /// `name` table manufacturer (name id 8).
    pub manufacturer: Option<String>,
    /// `name` table version string (name id 5). Defaults to `Version 1.000`.
    pub version: Option<String>,
    /// Vertical layout metrics; when present `vhea` + `vmtx` are written.
    pub vertical_metrics: Option<VerticalMetricsSpec>,
    /// Ligatures, compiled into a `GSUB` ligature substitution.
    pub ligatures: Vec<LigatureSpec>,
    /// `CPAL` palette: colors as `0xAARRGGBB`. Written when any glyph has
    /// [GlyphSpec::color_layers].
    pub palette: Vec<u32>,
    /// `cmap` format 14 variation selectors.
    pub variation_selectors: Vec<VariationSelectorSpec>,
    /// Tables copied verbatim into the font, e.g. `fpgm`, `prep` and `cvt `.
    pub raw_tables: Vec<RawTableSpec>,
}

/// A substitution applied to a glyph that already exists in a font.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct ExistingAlternateSpec {
    /// Feature tag, e.g. `ss01`.
    pub feature_tag: String,
    /// Code point whose glyph is replaced.
    pub code_point: u32,
    /// Code point whose glyph replaces it; it must exist in the font.
    pub replacement_code_point: u32,
    /// UI label, written as a feature parameter of `ssNN`.
    pub name: Option<String>,
}

/// A ligature between glyphs that already exist in a font.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct ExistingLigatureSpec {
    /// Feature tag, e.g. `liga`.
    pub feature_tag: String,
    /// Code points that trigger the ligature, in order.
    pub sequence: Vec<u32>,
    /// Code point whose glyph replaces the sequence.
    pub replacement_code_point: u32,
}

/// Changes applied to a font that already exists.
///
/// Outlines, the `cmap` and every table that is not mentioned here are copied
/// over unchanged, including `fvar`, `gvar`, `STAT` and `HVAR`.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct FontModificationRequest {
    pub family_name: Option<String>,
    pub subfamily_name: Option<String>,
    pub designer: Option<String>,
    pub license: Option<String>,
    pub manufacturer: Option<String>,
    pub version: Option<String>,
    pub weight_class: Option<u16>,
    pub width_class: Option<u16>,
    pub vendor_id: Option<String>,
    /// Kerning, applied through a `GPOS` `kern` feature.
    pub kern_pairs: Vec<KernPair>,
    /// Ligatures built from glyphs the font already has.
    pub ligatures: Vec<ExistingLigatureSpec>,
    /// Substitutions built from glyphs the font already has.
    pub alternates: Vec<ExistingAlternateSpec>,
}

/// Compiles [FontBuildRequest] into the bytes of a `.ttf` file.
///
/// The font always contains glyph 0 (`.notdef`), a `cmap` mapping the requested
/// code points, and the minimal set of tables a TrueType font needs. When
/// [FontBuildRequest::axes] is non-empty the result is a variable font with
/// `fvar` and `gvar`.
pub fn build_font(request: FontBuildRequest) -> Result<Vec<u8>> {
    crate::font_compile::build_ttf(&request)
}

/// Patches an existing font: metadata, kerning and substitutions.
///
/// Outlines and the `cmap` stay exactly as they are, and every table the
/// request does not mention is copied over, so variable fonts keep their
/// `fvar`/`gvar`/`STAT`/`HVAR`.
pub fn modify_font(bytes: Vec<u8>, request: FontModificationRequest) -> Result<Vec<u8>> {
    crate::font_modify::modify_ttf(&bytes, &request)
}
