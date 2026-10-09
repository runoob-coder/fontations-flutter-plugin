//! Dart-facing bindings for the [fontations](https://github.com/googlefonts/fontations)
//! font stack, exposed through `flutter_rust_bridge`.
//!
//! The implementation is intentionally thin: it wraps `read-fonts` / `skrifa`
//! with types that map cleanly onto Dart (`String`, `double`, `int`, `List`).

use std::collections::HashMap;
use std::sync::{Arc, OnceLock};

use anyhow::{anyhow, Result};
use flutter_rust_bridge::frb;
use read_fonts::tables::cmap::MapVariant;
use read_fonts::tables::layout::{FeatureList, ScriptList};
use read_fonts::{FileRef, TableProvider};
use skrifa::attribute::Style;
use skrifa::bitmap::{BitmapData, BitmapFormat};
use skrifa::color::ColorGlyphFormat;
use skrifa::instance::Location;
use skrifa::outline::{DrawSettings, HintingInstance, HintingOptions, OutlineGlyphFormat};
use skrifa::prelude::*;
use skrifa::string::{LocalizedString, StringId};
use skrifa::{AxisCollection, GlyphId};

use crate::color_paint::RecordingPainter;

/// Axis-aligned bounding box.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RectF {
    pub x_min: f64,
    pub y_min: f64,
    pub x_max: f64,
    pub y_max: f64,
}

/// Global font metrics, as reported by `skrifa`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FontMetrics {
    pub units_per_em: u32,
    pub glyph_count: u32,
    pub is_monospace: bool,
    pub is_variable: bool,
    pub italic_angle: f64,
    pub ascent: f64,
    pub descent: f64,
    pub leading: f64,
    pub cap_height: Option<f64>,
    pub x_height: Option<f64>,
    pub average_width: Option<f64>,
    pub max_width: Option<f64>,
    pub bounds: Option<RectF>,
}

/// The strings from the OpenType `name` table that are most useful in a UI.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct FontNames {
    pub family: Option<String>,
    pub subfamily: Option<String>,
    pub full_name: Option<String>,
    pub postscript_name: Option<String>,
    pub typographic_family: Option<String>,
    pub typographic_subfamily: Option<String>,
    pub version: Option<String>,
    pub manufacturer: Option<String>,
    pub designer: Option<String>,
    pub license: Option<String>,
}

/// One `fvar` axis.
#[derive(Debug, Clone, PartialEq)]
pub struct VariationAxis {
    /// The four character axis tag, e.g. `wght`.
    pub tag: String,
    /// The localized axis name, when the font provides one.
    pub name: Option<String>,
    pub min_value: f64,
    pub default_value: f64,
    pub max_value: f64,
    /// Whether the axis should be hidden from user interfaces.
    pub hidden: bool,
}

/// A named instance from the `fvar` table.
#[derive(Debug, Clone, PartialEq)]
pub struct NamedInstanceInfo {
    pub subfamily_name: Option<String>,
    pub postscript_name: Option<String>,
    /// User space coordinates, ordered like [`Font::axes`].
    pub user_coords: Vec<f64>,
    /// Axis tags, ordered like [`NamedInstanceInfo::user_coords`].
    pub axis_tags: Vec<String>,
}

/// A snapshot of everything that can be read without picking a glyph.
#[derive(Debug, Clone, PartialEq)]
pub struct FontInfo {
    pub names: FontNames,
    pub metrics: FontMetrics,
    pub axes: Vec<VariationAxis>,
    pub instances: Vec<NamedInstanceInfo>,
    /// Four character tags of every table present in the font.
    pub tables: Vec<String>,
}

/// One variation setting in *user* space, e.g. `wght` = `700`.
#[derive(Debug, Clone, PartialEq)]
pub struct VariationSetting {
    pub tag: String,
    pub value: f64,
}

/// The verb of a single path element of a glyph outline.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum PathVerb {
    MoveTo,
    LineTo,
    QuadTo,
    CubicTo,
    Close,
}

/// A single path element; the meaning of `points` depends on `verb`:
/// `MoveTo`/`LineTo` -> `[x, y]`, `QuadTo` -> `[cx, cy, x, y]`,
/// `CubicTo` -> `[cx0, cy0, cx1, cy1, x, y]`, `Close` -> `[]`.
#[derive(Debug, Clone, PartialEq)]
pub struct PathElement {
    pub verb: PathVerb,
    pub points: Vec<f64>,
}

/// A drawn glyph outline.
#[derive(Debug, Clone, PartialEq)]
pub struct GlyphOutline {
    pub elements: Vec<PathElement>,
    pub bounds: Option<RectF>,
    pub advance_width: Option<f64>,
    /// Where the outline came from: `glyf`, `cff`, `cff2` or `varc`.
    pub format: Option<String>,
    /// True when the outline embeds hinting instructions.
    pub has_hinting: bool,
    /// True when the glyph is flagged as having overlapping contours.
    pub has_overlaps: bool,
}

/// One record of the `name` table, resolved to a string.
#[derive(Debug, Clone, PartialEq)]
pub struct NameRecordInfo {
    pub name_id: u16,
    pub platform_id: u16,
    pub encoding_id: u16,
    pub language_id: u16,
    /// BCP 47 language tag, when the platform encodes one.
    pub language: Option<String>,
    pub value: String,
}

/// Style attributes, taken from `OS/2` (or `head` when `OS/2` is missing).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FontAttributes {
    /// `usWeightClass` like value in the 100..1000 range.
    pub weight: f64,
    /// `usWidthClass` mapped onto a CSS stretch percentage (100% is normal).
    pub stretch_percentage: f64,
    /// `normal`, `italic` or `oblique`.
    pub style: StyleKind,
    /// Slant in degrees, only set for oblique styles.
    pub oblique_angle: Option<f64>,
}

/// Whether a font is upright, italic or oblique.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum StyleKind {
    Normal,
    Italic,
    Oblique,
}

/// Summary of the `cmap` table.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CharmapInfo {
    pub has_map: bool,
    pub is_symbol: bool,
    /// True when a `cmap` format 14 (variation selectors) subtable is present.
    pub has_variant_map: bool,
    /// Number of character to glyph mappings.
    pub mapping_count: u32,
}

/// One `cmap` entry.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CharMapping {
    pub code_point: u32,
    pub glyph_id: u32,
}

/// Glyph level metrics.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct GlyphMetrics {
    pub advance_width: Option<f64>,
    pub left_side_bearing: Option<f64>,
    pub bounds: Option<RectF>,
}

/// Vertical metrics from the `vhea` table.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct VerticalMetrics {
    pub ascender: f64,
    pub descender: f64,
    pub line_gap: f64,
    pub advance_height_max: f64,
}

/// One embedded bitmap size.
#[derive(Debug, Clone, PartialEq)]
pub struct BitmapStrikeInfo {
    pub index: u32,
    pub ppem_x: f64,
    pub ppem_y: f64,
    /// `sbix`, `cbdt` or `ebdt`.
    pub format: String,
}

/// A bitmap glyph, decoded into RGBA (or raw PNG when the strike stores PNG).
#[derive(Debug, Clone, PartialEq)]
pub struct BitmapGlyphInfo {
    /// `rgba`, `png` or `mask` (mask pixels are RGBA with the alpha channel set).
    pub pixel_format: String,
    pub width: u32,
    pub height: u32,
    pub pixels: Vec<u8>,
    /// Outer bearings, in font units.
    pub bearing_x: f64,
    pub bearing_y: f64,
    /// Inner bearings, in pixels.
    pub inner_bearing_x: f64,
    pub inner_bearing_y: f64,
    pub ppem_x: f64,
    pub ppem_y: f64,
    pub advance: Option<f64>,
    /// `topLeft` or `bottomLeft`.
    pub placement_origin: String,
}

/// One stop of a `COLRv1` gradient.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ColorStop {
    /// Normalized position in the 0..1 range.
    pub offset: f64,
    /// `0xAARRGGBB`, taken from the palette.
    pub color: u32,
    /// Extra alpha to multiply the color with.
    pub alpha: f64,
}

/// Which kind of fill a color glyph layer uses.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum PaintKind {
    Solid,
    Linear,
    Radial,
    Sweep,
}

/// The fill of one color glyph layer.
///
/// Coordinates are font units, y up — the space `COLR` paint graphs use. Only
/// the fields that belong to [ColorPaint::kind] are meaningful: `color` and
/// `alpha` for a solid fill, the two points (and radii) plus `stops` for
/// gradients.
#[derive(Debug, Clone, PartialEq)]
pub struct ColorPaint {
    pub kind: PaintKind,
    /// `0xAARRGGBB`, straight from the palette.
    pub color: u32,
    /// Extra alpha to multiply the color with.
    pub alpha: f64,
    /// Start point of a linear gradient, or first circle of a radial one.
    pub x0: f64,
    pub y0: f64,
    /// End point of a linear gradient, or second circle of a radial one.
    pub x1: f64,
    pub y1: f64,
    /// Radii of a radial gradient; the center of a sweep gradient.
    pub r0: f64,
    pub r1: f64,
    /// Start and end angle of a sweep gradient, in degrees.
    pub start_angle: f64,
    pub end_angle: f64,
    /// `pad`, `repeat` or `reflect`.
    pub extend: String,
    /// Empty for solid fills.
    pub stops: Vec<ColorStop>,
}

/// One filled shape of a color glyph.
#[derive(Debug, Clone, PartialEq)]
pub struct ColorLayer {
    pub elements: Vec<PathElement>,
    pub paint: ColorPaint,
    /// `COLRv1` composite mode, e.g. `SrcOver`.
    pub composite: String,
}

/// A `COLR` glyph flattened into layers, in font units (y up).
#[derive(Debug, Clone, PartialEq)]
pub struct ColorGlyphInfo {
    /// `colrV0` or `colrV1`.
    pub format: String,
    pub bounds: Option<RectF>,
    pub layers: Vec<ColorLayer>,
}

/// One `CPAL` palette.
#[derive(Debug, Clone, PartialEq)]
pub struct ColorPaletteInfo {
    pub index: u16,
    /// Colors as `0xAARRGGBB`.
    pub colors: Vec<u32>,
}

/// Features, scripts and languages of one OpenType layout table.
#[derive(Debug, Clone, PartialEq)]
pub struct LayoutTableInfo {
    /// `GSUB` or `GPOS`.
    pub table: String,
    pub scripts: Vec<String>,
    /// `dflt` plus the language system tags, e.g. `latn ` / `TRK `.
    pub languages: Vec<String>,
    pub features: Vec<LayoutFeatureInfo>,
    pub lookup_count: u16,
}

/// One feature of a `GSUB` / `GPOS` table.
#[derive(Debug, Clone, PartialEq)]
pub struct LayoutFeatureInfo {
    /// Four character tag, e.g. `ss01`.
    pub tag: String,
    /// Scripts whose language systems reference this feature.
    pub scripts: Vec<String>,
    /// Language systems that reference this feature.
    pub languages: Vec<String>,
    pub lookup_indices: Vec<u16>,
}

/// One glyph of a shaped run.
#[derive(Debug, Clone, PartialEq)]
pub struct ShapedGlyph {
    pub glyph_id: u32,
    /// Index of the character in the input this glyph came from. Several
    /// glyphs can share one (a decomposition) and one glyph can cover several
    /// (a ligature).
    pub cluster: u32,
    /// How far to move after drawing this glyph, in the requested size or in
    /// font units when no size was given.
    pub x_advance: f64,
    pub y_advance: f64,
    /// Where to draw the glyph relative to the pen, y up.
    pub x_offset: f64,
    pub y_offset: f64,
}

/// The result of applying `GSUB` and `GPOS` to a run of text.
#[derive(Debug, Clone, PartialEq)]
pub struct ShapeResult {
    pub glyphs: Vec<ShapedGlyph>,
    /// Sum of every x advance: the width of the run.
    pub advance: f64,
}

/// One `MATH` constant, named as the OpenType spec spells it.
#[derive(Debug, Clone, PartialEq)]
pub struct MathConstantInfo {
    /// e.g. `fractionNumeratorGapMin`.
    pub name: String,
    /// The HarfBuzz numbering, which is also the spec order.
    pub index: u32,
    /// The value as the font stores it, in design units.
    pub value: f64,
    /// What the value's device table adds at the requested size, in pixels.
    pub delta_px: f64,
}

/// One band of a `MATH` kern table.
#[derive(Debug, Clone, PartialEq)]
pub struct MathKernEntryInfo {
    /// Height the band reaches up to; `None` for the last, unbounded band.
    pub max_height: Option<f64>,
    pub max_height_delta_px: f64,
    pub kern: f64,
    pub kern_delta_px: f64,
}

/// The kern of one corner of a `MATH` glyph.
#[derive(Debug, Clone, PartialEq)]
pub struct MathKernInfo {
    /// `topRight`, `topLeft`, `bottomRight` or `bottomLeft`.
    pub corner: String,
    pub entries: Vec<MathKernEntryInfo>,
}

/// What the `MATH` table says about one glyph.
#[derive(Debug, Clone, PartialEq)]
pub struct MathGlyphInfoInfo {
    pub italics_correction: Option<f64>,
    pub italics_correction_delta_px: f64,
    /// Where an accent sits above this glyph, horizontally.
    pub top_accent_attachment: Option<f64>,
    pub top_accent_attachment_delta_px: f64,
    /// True when the glyph is tall enough that a following script is
    /// positioned against its own height rather than the font's.
    pub is_extended_shape: bool,
    pub kerns: Vec<MathKernInfo>,
}

/// One size of a stretchable `MATH` glyph.
#[derive(Debug, Clone, PartialEq)]
pub struct MathVariantRecordInfo {
    pub glyph_id: u32,
    /// How big the glyph is along the stretch axis.
    pub advance: f64,
}

/// One piece a `MATH` glyph is assembled from when no single size fits.
#[derive(Debug, Clone, PartialEq)]
pub struct MathAssemblyPartInfo {
    pub glyph_id: u32,
    pub start_connector_length: f64,
    pub end_connector_length: f64,
    pub full_advance: f64,
    /// An extender is the piece that may be repeated.
    pub is_extender: bool,
}

/// How a `MATH` glyph stretches along one axis.
#[derive(Debug, Clone, PartialEq)]
pub struct MathVariantsInfo {
    /// Overlap between two assembled pieces, in design units.
    pub min_connector_overlap: f64,
    pub variants: Vec<MathVariantRecordInfo>,
    pub assembly: Option<MathAssemblyPartListInfo>,
}

/// The pieces a `MATH` glyph is assembled from.
#[derive(Debug, Clone, PartialEq)]
pub struct MathAssemblyPartListInfo {
    pub italics_correction: f64,
    pub italics_correction_delta_px: f64,
    pub parts: Vec<MathAssemblyPartInfo>,
}

/// One component a `VARC` glyph is built from.
#[derive(Debug, Clone, PartialEq)]
pub struct VarcComponentInfo {
    pub glyph_id: u32,
    /// `false` when the component carries a condition the current variation
    /// location does not satisfy, in which case it is not drawn.
    pub condition_met: bool,
    /// The component's transform as `xx, yx, xy, yy, dx, dy`.
    pub transform: Vec<f64>,
    /// Indices of the axes the component sets; empty when it sets none.
    pub axis_indices: Vec<u32>,
    /// Values for those axes, in normalized space.
    pub axis_values: Vec<f64>,
}

/// A `VARC` glyph broken into the components it is drawn from.
#[derive(Debug, Clone, PartialEq)]
pub struct VarcGlyphInfo {
    pub components: Vec<VarcComponentInfo>,
}

/// One `cmap` format 14 entry: a character plus a variation selector.
#[derive(Debug, Clone, PartialEq)]
pub struct VariantMappingInfo {
    pub code_point: u32,
    pub selector: u32,
    /// `useDefault` when the selector should be ignored, `variant` when it
    /// names another glyph.
    pub kind: String,
    /// The glyph the pair maps to; `None` for `useDefault`.
    pub glyph_id: Option<u32>,
}

/// One segment of an `avar` axis mapping.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AxisValueMapInfo {
    /// Normalized coordinate as it comes out of `fvar`.
    pub from: f64,
    /// What it is remapped to, and what `gvar` deltas are expressed in.
    pub to: f64,
}

/// One axis of the `avar` table.
#[derive(Debug, Clone, PartialEq)]
pub struct AxisSegmentMapsInfo {
    pub tag: String,
    pub maps: Vec<AxisValueMapInfo>,
}

/// What the `avar` table does.
#[derive(Debug, Clone, PartialEq)]
pub struct AvarInfo {
    /// `1.0` for a plain `avar`; `2.0` when it also carries `avar2` deltas.
    pub version: String,
    /// True when axis values are further adjusted by an item variation store.
    pub has_avar2: bool,
    pub axes: Vec<AxisSegmentMapsInfo>,
}

/// Parsed font, kept alive on the Rust side.
///
/// The raw bytes are owned by Rust, so Dart only ever holds an opaque handle.
#[frb(opaque)]
#[derive(Debug, Clone)]
pub struct Font {
    data: Vec<u8>,
    index: u32,
    /// Glyph id -> first code point that maps to it, built the first time
    /// `glyph_to_char` needs it. `Arc` so clones of this opaque handle share
    /// one map; `OnceLock` so repeated lookups cost nothing after the first.
    reverse_cmap: Arc<OnceLock<HashMap<u32, u32>>>,
}

impl Font {
    /// Parses a font (or a single font out of a `.ttc` collection).
    #[frb(sync)]
    pub fn from_bytes(bytes: Vec<u8>, index: Option<u32>) -> Result<Font> {
        let index = index.unwrap_or(0);
        let file = FileRef::new(&bytes).map_err(|e| anyhow!("not a valid font file: {e}"))?;
        file.fonts()
            .nth(index as usize)
            .ok_or_else(|| anyhow!("font index {index} is out of range"))?
            .map_err(|e| anyhow!("failed to read font {index}: {e}"))?;
        Ok(Font {
            data: bytes,
            index,
            reverse_cmap: Arc::new(OnceLock::new()),
        })
    }

    fn font_ref(&self) -> Result<FontRef<'_>> {
        let file = FileRef::new(&self.data).map_err(|e| anyhow!("not a valid font file: {e}"))?;
        file.fonts()
            .nth(self.index as usize)
            .ok_or_else(|| anyhow!("font index {} is out of range", self.index))?
            .map_err(|e| anyhow!("failed to read font {}: {e}", self.index))
    }

    /// Number of fonts contained in `bytes` (1 for a plain font, >1 for a `.ttc`).
    #[frb(sync)]
    pub fn count_fonts(bytes: Vec<u8>) -> Result<u32> {
        let file = FileRef::new(&bytes).map_err(|e| anyhow!("not a valid font file: {e}"))?;
        match file {
            FileRef::Font(_) => Ok(1),
            FileRef::Collection(collection) => Ok(collection.len()),
        }
    }

    /// Everything that can be read without picking a glyph.
    #[frb(sync)]
    pub fn info(&self) -> Result<FontInfo> {
        let font = self.font_ref()?;
        let metrics = font.metrics(Size::unscaled(), LocationRef::default());
        // Parsed once and shared: `font.axes()` re-reads `fvar` every call, and
        // `info` needs it for `is_variable`, the axis list and the instances.
        let axes = font.axes();
        Ok(FontInfo {
            names: read_names(&font),
            metrics: FontMetrics {
                units_per_em: metrics.units_per_em as u32,
                glyph_count: metrics.glyph_count as u32,
                is_monospace: metrics.is_monospace,
                is_variable: !axes.is_empty(),
                italic_angle: metrics.italic_angle as f64,
                ascent: metrics.ascent as f64,
                descent: metrics.descent as f64,
                leading: metrics.leading as f64,
                cap_height: metrics.cap_height.map(|v| v as f64),
                x_height: metrics.x_height.map(|v| v as f64),
                average_width: metrics.average_width.map(|v| v as f64),
                max_width: metrics.max_width.map(|v| v as f64),
                bounds: metrics.bounds.map(|b| RectF {
                    x_min: b.x_min as f64,
                    y_min: b.y_min as f64,
                    x_max: b.x_max as f64,
                    y_max: b.y_max as f64,
                }),
            },
            axes: read_axes(&font, &axes),
            instances: read_instances(&font, &axes),
            tables: font
                .table_directory()
                .table_records()
                .iter()
                .map(|record| record.tag().to_string())
                .collect(),
        })
    }

    /// Localized strings from the `name` table.
    #[frb(sync)]
    pub fn names(&self) -> Result<FontNames> {
        Ok(read_names(&self.font_ref()?))
    }

    /// Metrics at the given size (pass `None` for font units) and variation location.
    #[frb(sync)]
    pub fn metrics(
        &self,
        size: Option<f64>,
        variations: Vec<VariationSetting>,
    ) -> Result<FontMetrics> {
        let font = self.font_ref()?;
        let location = build_location(&font, &variations);
        let metrics = font.metrics(to_size(size), &location);
        Ok(FontMetrics {
            units_per_em: metrics.units_per_em as u32,
            glyph_count: metrics.glyph_count as u32,
            is_monospace: metrics.is_monospace,
            is_variable: !font.axes().is_empty(),
            italic_angle: metrics.italic_angle as f64,
            ascent: metrics.ascent as f64,
            descent: metrics.descent as f64,
            leading: metrics.leading as f64,
            cap_height: metrics.cap_height.map(|v| v as f64),
            x_height: metrics.x_height.map(|v| v as f64),
            average_width: metrics.average_width.map(|v| v as f64),
            max_width: metrics.max_width.map(|v| v as f64),
            bounds: metrics.bounds.map(|b| RectF {
                x_min: b.x_min as f64,
                y_min: b.y_min as f64,
                x_max: b.x_max as f64,
                y_max: b.y_max as f64,
            }),
        })
    }

    /// The `fvar` axes; empty for static fonts.
    #[frb(sync)]
    pub fn axes(&self) -> Result<Vec<VariationAxis>> {
        let font = self.font_ref()?;
        let axes = font.axes();
        Ok(read_axes(&font, &axes))
    }

    /// The named instances from the `fvar` table.
    #[frb(sync)]
    pub fn named_instances(&self) -> Result<Vec<NamedInstanceInfo>> {
        let font = self.font_ref()?;
        let axes = font.axes();
        Ok(read_instances(&font, &axes))
    }

    /// Four character tags of every table in the font.
    #[frb(sync)]
    pub fn tables(&self) -> Result<Vec<String>> {
        Ok(self
            .font_ref()?
            .table_directory()
            .table_records()
            .iter()
            .map(|record| record.tag().to_string())
            .collect())
    }

    /// Raw bytes of one table, e.g. `GSUB`; `None` when the font lacks it.
    ///
    /// Offsets inside the returned data are relative to the start of the table,
    /// so the bytes can be handed to any OpenType parser.
    #[frb(sync)]
    pub fn table_data(&self, tag: String) -> Result<Option<Vec<u8>>> {
        let font = self.font_ref()?;
        let tag = table_tag(&tag)?;
        Ok(font.data_for_tag(tag).map(|data| data.as_bytes().to_vec()))
    }

    /// Size of one table in bytes; `None` when the font lacks it.
    #[frb(sync)]
    pub fn table_length(&self, tag: String) -> Result<Option<u32>> {
        let font = self.font_ref()?;
        let tag = table_tag(&tag)?;
        Ok(font.data_for_tag(tag).map(|data| data.len() as u32))
    }

    /// Whether the font contains `tag`.
    #[frb(sync)]
    pub fn has_table(&self, tag: String) -> Result<bool> {
        let font = self.font_ref()?;
        let tag = table_tag(&tag)?;
        Ok(font.data_for_tag(tag).is_some())
    }

    /// Scripts, languages and features of `GSUB` and/or `GPOS`.
    ///
    /// Pass `table` (`"GSUB"` or `"GPOS"`) to read a single table, or `None`
    /// for both.
    #[frb(sync)]
    pub fn layout(&self, table: Option<String>) -> Result<Vec<LayoutTableInfo>> {
        let font = self.font_ref()?;
        let wanted = table.map(|tag| tag.to_ascii_uppercase());
        let reads_gsub = matches!(wanted.as_deref(), None | Some("GSUB"));
        let reads_gpos = matches!(wanted.as_deref(), None | Some("GPOS"));

        let mut out = Vec::new();
        if reads_gsub {
            if let Ok(gsub) = font.gsub() {
                out.push(read_layout(
                    "GSUB",
                    gsub.script_list().ok(),
                    gsub.feature_list().ok(),
                    gsub.lookup_list().ok().map(|list| list.lookup_count()),
                ));
            }
        }
        if reads_gpos {
            if let Ok(gpos) = font.gpos() {
                out.push(read_layout(
                    "GPOS",
                    gpos.script_list().ok(),
                    gpos.feature_list().ok(),
                    gpos.lookup_list().ok().map(|list| list.lookup_count()),
                ));
            }
        }
        Ok(out)
    }

    /// Style attributes, taken from `OS/2` (or `head` when `OS/2` is missing).
    #[frb(sync)]
    pub fn attributes(&self) -> Result<FontAttributes> {
        let font = self.font_ref()?;
        let attributes = font.attributes();
        let (style, oblique_angle) = match attributes.style {
            Style::Normal => (StyleKind::Normal, None),
            Style::Italic => (StyleKind::Italic, None),
            Style::Oblique(angle) => (StyleKind::Oblique, angle.map(|a| a as f64)),
        };
        Ok(FontAttributes {
            weight: attributes.weight.value() as f64,
            stretch_percentage: attributes.stretch.percentage() as f64,
            style,
            oblique_angle,
        })
    }

    /// Glyph name from `post` or `CFF`, when the font provides names.
    #[frb(sync)]
    pub fn glyph_name(&self, glyph_id: u32) -> Result<Option<String>> {
        let font = self.font_ref()?;
        let names = font.glyph_names();
        Ok(names
            .get(GlyphId::new(glyph_id))
            .map(|name| name.to_string()))
    }

    /// Where the glyph names come from.
    #[frb(sync)]
    pub fn glyph_name_source(&self) -> Result<String> {
        let font = self.font_ref()?;
        Ok(format!("{:?}", font.glyph_names().source()))
    }

    /// Every record of the `name` table, optionally filtered by name id.
    #[frb(sync)]
    pub fn name_records(&self, name_id: Option<u32>) -> Result<Vec<NameRecordInfo>> {
        let font = self.font_ref()?;
        let name = font.name().map_err(|e| anyhow!("no name table: {e}"))?;
        let mut out = Vec::new();
        for record in name.name_record() {
            let id = record.name_id().to_u16();
            if let Some(wanted) = name_id {
                if id as u32 != wanted {
                    continue;
                }
            }
            let localized = LocalizedString::new(&name, record);
            let mut value = String::new();
            for ch in localized.chars() {
                value.push(ch);
            }
            out.push(NameRecordInfo {
                name_id: id,
                platform_id: record.platform_id(),
                encoding_id: record.encoding_id(),
                language_id: record.language_id(),
                language: localized.language().map(|s| s.to_string()),
                value,
            });
        }
        Ok(out)
    }

    /// Summary of the `cmap` table.
    #[frb(sync)]
    pub fn charmap_info(&self) -> Result<CharmapInfo> {
        let font = self.font_ref()?;
        let charmap = font.charmap();
        Ok(CharmapInfo {
            has_map: charmap.has_map(),
            is_symbol: charmap.is_symbol(),
            has_variant_map: charmap.has_variant_map(),
            mapping_count: charmap.mappings().count() as u32,
        })
    }

    /// Every character to glyph mapping of the `cmap` table.
    #[frb(sync)]
    pub fn char_mappings(&self) -> Result<Vec<CharMapping>> {
        let font = self.font_ref()?;
        Ok(font
            .charmap()
            .mappings()
            .map(|(code_point, glyph_id)| CharMapping {
                code_point,
                glyph_id: glyph_id.to_u32(),
            })
            .collect())
    }

    /// First code point that maps to `glyph_id`, if any.
    ///
    /// The reverse `cmap` is built on the first call and then reused, so asking
    /// for one glyph after another stays cheap. Use `charMappings` when you
    /// want the whole table in one go.
    #[frb(sync)]
    pub fn glyph_to_char(&self, glyph_id: u32) -> Result<Option<u32>> {
        // Surface a parse failure the same way every other method does, rather
        // than caching an empty map and quietly reporting "no such glyph".
        self.font_ref()?;

        let map = self.reverse_cmap.get_or_init(|| {
            let Ok(font) = self.font_ref() else {
                return HashMap::new();
            };
            // `or_insert` keeps the first code point of each glyph, which is
            // what a fresh linear scan would have found.
            font.charmap()
                .mappings()
                .fold(HashMap::new(), |mut map, (code_point, gid)| {
                    map.entry(gid.to_u32()).or_insert(code_point);
                    map
                })
        });

        Ok(map.get(&glyph_id).copied())
    }

    /// Advance width, left side bearing and bounds of one glyph.
    #[frb(sync)]
    pub fn glyph_metrics(
        &self,
        glyph_id: u32,
        size: Option<f64>,
        variations: Vec<VariationSetting>,
    ) -> Result<GlyphMetrics> {
        let font = self.font_ref()?;
        let location = build_location(&font, &variations);
        let metrics = font.glyph_metrics(to_size(size), &location);
        let glyph_id = GlyphId::new(glyph_id);
        Ok(GlyphMetrics {
            advance_width: metrics.advance_width(glyph_id).map(|v| v as f64),
            left_side_bearing: metrics.left_side_bearing(glyph_id).map(|v| v as f64),
            bounds: metrics.bounds(glyph_id).map(|b| RectF {
                x_min: b.x_min as f64,
                y_min: b.y_min as f64,
                x_max: b.x_max as f64,
                y_max: b.y_max as f64,
            }),
        })
    }

    /// Metrics of the vertical layout, from `vhea`.
    #[frb(sync)]
    pub fn vertical_metrics(&self) -> Result<Option<VerticalMetrics>> {
        let font = self.font_ref()?;
        let Ok(vhea) = font.vhea() else {
            return Ok(None);
        };
        Ok(Some(VerticalMetrics {
            ascender: i16::from(vhea.ascender()) as f64,
            descender: i16::from(vhea.descender()) as f64,
            line_gap: i16::from(vhea.line_gap()) as f64,
            advance_height_max: u16::from(vhea.advance_height_max()) as f64,
        }))
    }

    /// Advance height of a glyph, from `vmtx`.
    #[frb(sync)]
    pub fn vertical_advance(&self, glyph_id: u32) -> Result<Option<f64>> {
        let font = self.font_ref()?;
        let Ok(vhea) = font.vhea() else {
            return Ok(None);
        };
        let Ok(vmtx) = font.vmtx() else {
            return Ok(None);
        };
        let index = glyph_id as usize;
        let num_long = vhea.number_of_long_ver_metrics() as usize;
        if index < num_long {
            Ok(vmtx.v_metrics().get(index).map(|m| m.advance() as f64))
        } else {
            // Beyond `number_of_long_ver_metrics` every glyph shares the last
            // advance height in `vhea.caret...`; `vmtx` stores only bearings.
            Ok(vmtx.v_metrics().last().map(|m| m.advance() as f64))
        }
    }

    /// Vertical origin of a glyph: `VORG` when present, otherwise `vhea`
    /// ascender minus the top side bearing.
    #[frb(sync)]
    pub fn vertical_origin(&self, glyph_id: u32) -> Result<Option<f64>> {
        let font = self.font_ref()?;
        if let Ok(vorg) = font.vorg() {
            for record in vorg.vert_origin_y_metrics() {
                if record.glyph_index().to_u32() == glyph_id {
                    return Ok(Some(record.vert_origin_y() as f64));
                }
            }
            return Ok(Some(vorg.default_vert_origin_y() as f64));
        }
        let vhea = font.vhea().ok();
        let vmtx = font.vmtx().ok();
        match (vhea, vmtx) {
            (Some(vhea), Some(vmtx)) => {
                let index = glyph_id as usize;
                let num_long = vhea.number_of_long_ver_metrics() as usize;
                let tsb = if index < num_long {
                    vmtx.v_metrics().get(index).map(|m| m.side_bearing())
                } else {
                    vmtx.top_side_bearings()
                        .get(index - num_long)
                        .map(|v| v.get())
                };
                Ok(tsb.map(|tsb| i16::from(vhea.ascender()) as f64 - tsb as f64))
            }
            _ => Ok(None),
        }
    }

    /// The `CPAL` palettes of the font; empty when it has no color palette.
    #[frb(sync)]
    pub fn color_palettes(&self) -> Result<Vec<ColorPaletteInfo>> {
        let font = self.font_ref()?;
        let palettes = font.color_palettes();
        Ok((0..palettes.len())
            .filter_map(|index| {
                palettes.get(index).map(|palette| ColorPaletteInfo {
                    index,
                    colors: palette.colors().iter().map(argb).collect(),
                })
            })
            .collect())
    }

    /// Whether `glyph_id` has a `COLR` color outline.
    #[frb(sync)]
    pub fn has_color_glyph(&self, glyph_id: u32) -> Result<bool> {
        let font = self.font_ref()?;
        Ok(font.color_glyphs().get(GlyphId::new(glyph_id)).is_some())
    }

    /// Flattens a `COLR` glyph into filled layers, in font units (y up).
    ///
    /// Returns `None` when the glyph has no color outline. Layers are painted
    /// back to front; Dart scales them by `size / unitsPerEm` and flips y.
    #[frb(sync)]
    pub fn color_glyph(
        &self,
        glyph_id: u32,
        palette_index: Option<u16>,
        variations: Vec<VariationSetting>,
    ) -> Result<Option<ColorGlyphInfo>> {
        let font = self.font_ref()?;
        let glyph_id = GlyphId::new(glyph_id);
        let collection = font.color_glyphs();
        let Some(glyph) = collection.get(glyph_id) else {
            return Ok(None);
        };

        let palettes = font.color_palettes();
        let index = palette_index.unwrap_or(0);
        let palette = palettes
            .get(index)
            .or_else(|| palettes.get(0))
            .map(|palette| palette.colors().iter().map(argb).collect())
            .unwrap_or_default();

        let location = build_location(&font, &variations);
        let mut painter = RecordingPainter::new(&font, palette);
        glyph
            .paint(&location, &mut painter)
            .map_err(|e| anyhow!("failed to paint color glyph {glyph_id}: {e}"))?;

        let bounds = glyph
            .bounding_box(&location, Size::unscaled())
            .map(|b| RectF {
                x_min: b.x_min as f64,
                y_min: b.y_min as f64,
                x_max: b.x_max as f64,
                y_max: b.y_max as f64,
            });

        Ok(Some(ColorGlyphInfo {
            format: match glyph.format() {
                ColorGlyphFormat::ColrV0 => "colrV0",
                ColorGlyphFormat::ColrV1 => "colrV1",
            }
            .to_string(),
            bounds,
            layers: painter.layers,
        }))
    }

    /// The embedded bitmap sizes of the font.
    #[frb(sync)]
    pub fn bitmap_strikes(&self) -> Result<Vec<BitmapStrikeInfo>> {
        let font = self.font_ref()?;
        let strikes = font.bitmap_strikes();
        Ok(strikes
            .iter()
            .enumerate()
            .map(|(index, strike)| BitmapStrikeInfo {
                index: index as u32,
                // A strike only carries one ppem in `skrifa`'s model.
                ppem_x: strike.ppem() as f64,
                ppem_y: strike.ppem() as f64,
                format: bitmap_format_name(strikes.format()).to_string(),
            })
            .collect())
    }

    /// The embedded bitmap of a glyph, decoded into RGBA.
    ///
    /// Picks the strike closest to `ppem`; without `ppem` the largest one is
    /// used. `pixels` holds RGBA bytes for `rgba`/`mask` and the raw PNG for
    /// `png`.
    #[frb(sync)]
    pub fn bitmap_glyph(
        &self,
        glyph_id: u32,
        ppem: Option<f64>,
    ) -> Result<Option<BitmapGlyphInfo>> {
        let font = self.font_ref()?;
        let strikes = font.bitmap_strikes();
        let glyph = match ppem {
            Some(ppem) => strikes.glyph_for_size(Size::new(ppem as f32), GlyphId::new(glyph_id)),
            None => strikes
                .iter()
                .filter_map(|strike| strike.get(GlyphId::new(glyph_id)))
                .max_by_key(|glyph| (glyph.ppem_y * 1000.0) as u32),
        };
        let Some(glyph) = glyph else {
            return Ok(None);
        };

        let (pixel_format, pixels) = match glyph.data {
            BitmapData::Bgra(bytes) => ("rgba", bgra_to_rgba(bytes)),
            BitmapData::Mask(mask) => match mask.decode(glyph.width, glyph.height) {
                Ok(alpha) => ("mask", alpha_to_rgba(&alpha)),
                Err(e) => return Err(anyhow!("failed to decode bitmap mask: {e:?}")),
            },
            BitmapData::Png(bytes) => ("png", bytes.to_vec()),
        };

        Ok(Some(BitmapGlyphInfo {
            pixel_format: pixel_format.to_string(),
            width: glyph.width,
            height: glyph.height,
            pixels,
            bearing_x: glyph.bearing_x as f64,
            bearing_y: glyph.bearing_y as f64,
            inner_bearing_x: glyph.inner_bearing_x as f64,
            inner_bearing_y: glyph.inner_bearing_y as f64,
            ppem_x: glyph.ppem_x as f64,
            ppem_y: glyph.ppem_y as f64,
            advance: glyph.advance.map(|v| v as f64),
            placement_origin: match glyph.placement_origin {
                skrifa::bitmap::Origin::TopLeft => "topLeft",
                skrifa::bitmap::Origin::BottomLeft => "bottomLeft",
            }
            .to_string(),
        }))
    }

    /// Which table the outlines of this font come from.
    #[frb(sync)]
    pub fn outline_format(&self) -> Result<Option<String>> {
        let font = self.font_ref()?;
        Ok(font
            .outline_glyphs()
            .format()
            .map(|format| outline_format_name(format).to_string()))
    }

    /// Maps a Unicode code point to a glyph id, if the font covers it.
    #[frb(sync)]
    pub fn char_to_glyph(&self, code_point: u32) -> Result<Option<u32>> {
        let font = self.font_ref()?;
        Ok(font
            .charmap()
            .map(char::from_u32(code_point).unwrap_or('\u{0}'))
            .map(|id| id.to_u32()))
    }

    /// Advance width of a glyph, in the requested size (or font units).
    #[frb(sync)]
    pub fn advance_width(
        &self,
        glyph_id: u32,
        size: Option<f64>,
        variations: Vec<VariationSetting>,
    ) -> Result<Option<f64>> {
        let font = self.font_ref()?;
        let location = build_location(&font, &variations);
        Ok(font
            .glyph_metrics(to_size(size), &location)
            .advance_width(GlyphId::new(glyph_id))
            .map(|v| v as f64))
    }

    /// Draws a glyph outline into a list of path elements.
    ///
    /// Set `hinted` to apply the hinting instructions embedded in the font
    /// (`glyf` bytecode or CFF stem hints). Hinting needs a real size, so it
    /// is ignored when `size` is `null` (font units).
    pub fn outline(
        &self,
        glyph_id: u32,
        size: Option<f64>,
        variations: Vec<VariationSetting>,
        hinted: Option<bool>,
    ) -> Result<GlyphOutline> {
        let font = self.font_ref()?;
        let location = build_location(&font, &variations);
        let glyph_id = GlyphId::new(glyph_id);
        let size = to_size(size);

        let outlines = font.outline_glyphs();
        let glyph = outlines
            .get(glyph_id)
            .ok_or_else(|| anyhow!("glyph {glyph_id} has no outline"))?;

        let mut elements = Vec::<read_fonts::model::glyph::outline::PathElement>::new();
        let wants_hinting = hinted.unwrap_or(false) && size.ppem().is_some();
        if wants_hinting {
            let instance =
                HintingInstance::new(&outlines, size, &location, HintingOptions::default())
                    .map_err(|e| anyhow!("failed to set up hinting: {e}"))?;
            glyph
                .draw(DrawSettings::hinted(&instance, false), &mut elements)
                .map_err(|e| anyhow!("failed to draw glyph {glyph_id}: {e}"))?;
        } else {
            glyph
                .draw(DrawSettings::unhinted(size, &location), &mut elements)
                .map_err(|e| anyhow!("failed to draw glyph {glyph_id}: {e}"))?;
        }

        // One metrics instance for both lookups: it re-reads `hmtx` (and
        // `HVAR`/`VORG` when present) every time it is constructed.
        let metrics = font.glyph_metrics(size, &location);
        let bounds = metrics.bounds(glyph_id).map(|b| RectF {
            x_min: b.x_min as f64,
            y_min: b.y_min as f64,
            x_max: b.x_max as f64,
            y_max: b.y_max as f64,
        });
        let advance_width = metrics.advance_width(glyph_id).map(|v| v as f64);

        Ok(GlyphOutline {
            elements: elements.iter().map(convert_element).collect(),
            bounds,
            advance_width,
            format: Some(outline_format_name(glyph.format()).to_string()),
            has_hinting: glyph.has_hinting().unwrap_or(false),
            has_overlaps: glyph.has_overlaps().unwrap_or(false),
        })
    }

    /// Applies `GSUB` and `GPOS` to a run of text.
    ///
    /// This is what a text engine does before it draws: characters become
    /// glyph ids, ligatures and substitutions are applied, and every glyph
    /// comes back with an advance and an offset. Offsets are y up, in the
    /// requested size (or in font units when `size` is `null`).
    ///
    /// `script` and `language` are four character OpenType tags; without them
    /// the font's `DFLT` (or `latn`) script and its default language system
    /// are used. `features` names the features to turn on — `liga`, `kern`,
    /// `ss01`, … — and when it is `null` the ones that are on by default are
    /// used (`kern`, `liga`, `ccmp`, `mark`, …). An **empty** list turns every
    /// feature off, which is what a "before shaping" comparison needs.
    #[frb(sync)]
    pub fn shape(
        &self,
        text: String,
        size: Option<f64>,
        variations: Vec<VariationSetting>,
        script: Option<String>,
        language: Option<String>,
        features: Option<Vec<String>>,
    ) -> Result<ShapeResult> {
        let font = self.font_ref()?;
        let location = build_location(&font, &variations);
        let options = crate::shaping::ShapeOptions {
            script: optional_tag(script.as_deref())?,
            language: optional_tag(language.as_deref())?,
            features: features
                .map(|tags| tags.iter().filter_map(|tag| table_tag(tag).ok()).collect()),
            size: size.map(|size| size as f32),
            coords: location.coords(),
        };
        Ok(crate::shaping::shape(&font, &text, &options))
    }

    /// Whether the font has a `MATH` table.
    #[frb(sync)]
    pub fn has_math(&self) -> Result<bool> {
        Ok(self.font_ref()?.math().is_ok())
    }

    /// Every constant of the `MATH` table, in the order the spec lists them.
    ///
    /// `ppem` is the size the device tables are resolved at; without it only
    /// the stored design unit values are reported. `None` when the font has no
    /// `MATH` table.
    #[frb(sync)]
    pub fn math_constants(&self, ppem: Option<u32>) -> Result<Option<Vec<MathConstantInfo>>> {
        let font = self.font_ref()?;
        let Ok(math) = font.math() else {
            return Ok(None);
        };
        let Ok(constants) = math.math_constants() else {
            return Ok(Some(Vec::new()));
        };
        Ok(Some(crate::math::constants(
            &constants,
            ppem.unwrap_or(0) as u16,
        )))
    }

    /// What the `MATH` table says about one glyph: italics correction, accent
    /// attachment and the four corner kerns. `None` when there is no `MATH`.
    #[frb(sync)]
    pub fn math_glyph_info(
        &self,
        glyph_id: u32,
        ppem: Option<u32>,
    ) -> Result<Option<MathGlyphInfoInfo>> {
        let font = self.font_ref()?;
        let Ok(math) = font.math() else {
            return Ok(None);
        };
        let Ok(info) = math.math_glyph_info() else {
            return Ok(Some(crate::math::glyph_info(
                &read_fonts::tables::math::MathGlyphInfo::default(),
                GlyphId::new(glyph_id),
                ppem.unwrap_or(0) as u16,
            )));
        };
        Ok(Some(crate::math::glyph_info(
            &info,
            GlyphId::new(glyph_id),
            ppem.unwrap_or(0) as u16,
        )))
    }

    /// How a `MATH` glyph stretches: the ready made sizes and, when no size
    /// fits, the pieces it is assembled from.
    ///
    /// `axis` is `horizontal` or `vertical`. `None` when the font has no
    /// `MATH` table or the glyph does not stretch along that axis.
    #[frb(sync)]
    pub fn math_variants(&self, glyph_id: u32, axis: String) -> Result<Option<MathVariantsInfo>> {
        let font = self.font_ref()?;
        let Ok(math) = font.math() else {
            return Ok(None);
        };
        let Ok(variants) = math.math_variants() else {
            return Ok(None);
        };
        Ok(crate::math::variants(
            &variants,
            GlyphId::new(glyph_id),
            &axis,
        ))
    }

    /// Whether the font has a `VARC` table.
    #[frb(sync)]
    pub fn has_varc(&self) -> Result<bool> {
        Ok(self.font_ref()?.varc().is_ok())
    }

    /// The components a `VARC` glyph is drawn from, in order.
    ///
    /// Empty when the font has no `VARC` table or the glyph is not a
    /// composite. `variations` decides which components' conditions hold.
    #[frb(sync)]
    pub fn varc_components(
        &self,
        glyph_id: u32,
        variations: Vec<VariationSetting>,
    ) -> Result<Option<VarcGlyphInfo>> {
        let font = self.font_ref()?;
        let Ok(varc) = font.varc() else {
            return Ok(None);
        };
        let location = build_location(&font, &variations);
        crate::varc::components(&varc, GlyphId::new(glyph_id), location.coords()).map(Some)
    }

    /// Maps a character plus a variation selector through `cmap` format 14.
    ///
    /// `kind` is `useDefault` — the selector should be ignored and the
    /// character's own glyph used — or `variant`, in which case `glyphId` is
    /// set. `None` when the font has no format 14 subtable or the pair is not
    /// in it.
    #[frb(sync)]
    pub fn map_variant(
        &self,
        code_point: u32,
        selector: u32,
    ) -> Result<Option<VariantMappingInfo>> {
        let font = self.font_ref()?;
        Ok(font
            .charmap()
            .map_variant(code_point, selector)
            .map(|variant| match variant {
                MapVariant::UseDefault => VariantMappingInfo {
                    code_point,
                    selector,
                    kind: "useDefault".to_string(),
                    glyph_id: None,
                },
                MapVariant::Variant(glyph) => VariantMappingInfo {
                    code_point,
                    selector,
                    kind: "variant".to_string(),
                    glyph_id: Some(glyph.to_u32()),
                },
            }))
    }

    /// Every entry of the `cmap` format 14 subtable.
    #[frb(sync)]
    pub fn variant_mappings(&self) -> Result<Vec<VariantMappingInfo>> {
        let font = self.font_ref()?;
        Ok(font
            .charmap()
            .variant_mappings()
            .map(|(code_point, selector, variant)| match variant {
                MapVariant::UseDefault => VariantMappingInfo {
                    code_point,
                    selector,
                    kind: "useDefault".to_string(),
                    glyph_id: None,
                },
                MapVariant::Variant(glyph) => VariantMappingInfo {
                    code_point,
                    selector,
                    kind: "variant".to_string(),
                    glyph_id: Some(glyph.to_u32()),
                },
            })
            .collect())
    }

    /// What the `avar` table does to each axis.
    ///
    /// `None` when the font is static or has no `avar`. Version `2.0` means
    /// `avar2` deltas from an item variation store are applied on top of the
    /// segment maps.
    #[frb(sync)]
    pub fn avar_info(&self) -> Result<Option<AvarInfo>> {
        let font = self.font_ref()?;
        let Ok(avar) = font.avar() else {
            return Ok(None);
        };
        let version = avar.version();
        let axes = font
            .axes()
            .iter()
            .enumerate()
            .map(|(index, axis)| AxisSegmentMapsInfo {
                tag: axis.tag().to_string(),
                maps: avar
                    .axis_segment_maps()
                    .get(index)
                    .and_then(|maps| maps.ok())
                    .map(|maps| {
                        maps.axis_value_maps()
                            .iter()
                            .map(|map| AxisValueMapInfo {
                                from: map.from_coordinate().to_f32() as f64,
                                to: map.to_coordinate().to_f32() as f64,
                            })
                            .collect()
                    })
                    .unwrap_or_default(),
            })
            .collect();
        Ok(Some(AvarInfo {
            version: format!("{}.{}", version.major, version.minor),
            has_avar2: avar.var_store().is_some(),
            axes,
        }))
    }

    /// The normalized coordinates `variations` ends up as, in axis order.
    ///
    /// This is the number `gvar` deltas are scaled by: user space is clamped
    /// to the axis range and normalized by `fvar`, then remapped by `avar` and
    /// shifted by any `avar2` deltas.
    #[frb(sync)]
    pub fn normalized_coords(&self, variations: Vec<VariationSetting>) -> Result<Vec<f64>> {
        let font = self.font_ref()?;
        let location = build_location(&font, &variations);
        Ok(location
            .coords()
            .iter()
            .map(|coord| coord.to_f32() as f64)
            .collect())
    }
}

fn optional_tag(tag: Option<&str>) -> Result<Option<Tag>> {
    match tag {
        Some(tag) => Ok(Some(table_tag(tag)?)),
        None => Ok(None),
    }
}

fn to_size(size: Option<f64>) -> Size {
    match size {
        Some(ppem) => Size::new(ppem as f32),
        None => Size::unscaled(),
    }
}

fn build_location(font: &FontRef<'_>, variations: &[VariationSetting]) -> Location {
    let axes = font.axes();
    let settings = variations
        .iter()
        .filter_map(|setting| {
            let bytes = setting.tag.as_bytes();
            let tag: &[u8; 4] = bytes.get(..4)?.try_into().ok()?;
            Some((Tag::new(tag), setting.value as f32))
        })
        .collect::<Vec<_>>();
    axes.location(settings)
}

fn read_names(font: &FontRef<'_>) -> FontNames {
    let name = |id: StringId| -> Option<String> {
        font.localized_strings(id)
            .english_or_first()
            .map(|s| s.to_string())
    };
    FontNames {
        family: name(StringId::FAMILY_NAME),
        subfamily: name(StringId::SUBFAMILY_NAME),
        full_name: name(StringId::FULL_NAME),
        postscript_name: name(StringId::POSTSCRIPT_NAME),
        typographic_family: name(StringId::TYPOGRAPHIC_FAMILY_NAME),
        typographic_subfamily: name(StringId::TYPOGRAPHIC_SUBFAMILY_NAME),
        version: name(StringId::VERSION_STRING),
        manufacturer: name(StringId::MANUFACTURER),
        designer: name(StringId::DESIGNER),
        license: name(StringId::LICENSE_DESCRIPTION),
    }
}

fn read_axes(font: &FontRef<'_>, axes: &AxisCollection<'_>) -> Vec<VariationAxis> {
    axes.iter()
        .map(|axis| VariationAxis {
            tag: axis.tag().to_string(),
            name: font
                .localized_strings(axis.name_id())
                .english_or_first()
                .map(|s| s.to_string()),
            min_value: axis.min_value() as f64,
            default_value: axis.default_value() as f64,
            max_value: axis.max_value() as f64,
            hidden: axis.is_hidden(),
        })
        .collect()
}

fn read_instances(font: &FontRef<'_>, axes: &AxisCollection<'_>) -> Vec<NamedInstanceInfo> {
    let axis_tags = axes
        .iter()
        .map(|axis| axis.tag().to_string())
        .collect::<Vec<_>>();
    font.named_instances()
        .iter()
        .map(|instance| NamedInstanceInfo {
            subfamily_name: font
                .localized_strings(instance.subfamily_name_id())
                .english_or_first()
                .map(|s| s.to_string()),
            postscript_name: instance
                .postscript_name_id()
                .and_then(|id| font.localized_strings(id).english_or_first())
                .map(|s| s.to_string()),
            user_coords: instance.user_coords().map(|v| v as f64).collect(),
            axis_tags: axis_tags.clone(),
        })
        .collect()
}

/// Parses a four character table tag.
fn table_tag(tag: &str) -> Result<Tag> {
    let bytes = tag.as_bytes();
    if bytes.len() > 4 || bytes.is_empty() {
        return Err(anyhow!("'{tag}' is not a four character table tag"));
    }
    let mut padded = *b"    ";
    for (slot, byte) in padded.iter_mut().zip(bytes) {
        *slot = *byte;
    }
    Ok(Tag::new(&padded))
}

/// Reads the shared `GSUB`/`GPOS` script, language and feature lists.
fn read_layout<'a>(
    table: &str,
    scripts: Option<ScriptList<'a>>,
    features: Option<FeatureList<'a>>,
    lookup_count: Option<u16>,
) -> LayoutTableInfo {
    let mut script_tags: Vec<String> = Vec::new();
    let mut languages: Vec<String> = Vec::new();
    // (feature index, script, language) triples taken from every language
    // system, so a feature can report where it is reachable from.
    let mut references: Vec<(u16, String, String)> = Vec::new();

    if let Some(scripts) = scripts {
        let data = scripts.offset_data();
        for record in scripts.script_records() {
            let script_tag = record.script_tag().to_string();
            script_tags.push(script_tag.clone());
            let Ok(script) = record.script(data) else {
                continue;
            };
            if let Some(Ok(lang_sys)) = script.default_lang_sys() {
                languages.push("dflt".to_string());
                for index in lang_sys.feature_indices() {
                    references.push((index.get(), script_tag.clone(), "dflt".to_string()));
                }
            }
            for lang_record in script.lang_sys_records() {
                let language = lang_record.lang_sys_tag().to_string();
                languages.push(language.clone());
                if let Ok(lang_sys) = lang_record.lang_sys(data) {
                    for index in lang_sys.feature_indices() {
                        references.push((index.get(), script_tag.clone(), language.clone()));
                    }
                }
            }
        }
    }

    // Bucket the references by feature index once. Scanning the whole list
    // once per feature costs O(features x references), which is painful on a
    // font that declares dozens of features across many language systems.
    let feature_count = features
        .as_ref()
        .map(|list| list.feature_records().len())
        .unwrap_or(0);
    let mut by_feature: Vec<(Vec<String>, Vec<String>)> =
        vec![(Vec::new(), Vec::new()); feature_count];
    for (feature_index, script, language) in references {
        let Some((scripts, languages)) = by_feature.get_mut(feature_index as usize) else {
            continue;
        };
        if !scripts.contains(&script) {
            scripts.push(script);
        }
        if !languages.contains(&language) {
            languages.push(language);
        }
    }

    let mut feature_infos = Vec::new();
    if let Some(features) = features {
        let data = features.offset_data();
        for (index, record) in features.feature_records().iter().enumerate() {
            let (feature_scripts, feature_languages) = by_feature
                .get_mut(index)
                .map(std::mem::take)
                .unwrap_or_default();
            let lookup_indices = record
                .feature(data)
                .map(|feature| {
                    feature
                        .lookup_list_indices()
                        .iter()
                        .map(|index| index.get())
                        .collect()
                })
                .unwrap_or_default();
            feature_infos.push(LayoutFeatureInfo {
                tag: record.feature_tag().to_string(),
                scripts: feature_scripts,
                languages: feature_languages,
                lookup_indices,
            });
        }
    }

    script_tags.sort();
    script_tags.dedup();
    languages.sort();
    languages.dedup();

    LayoutTableInfo {
        table: table.to_string(),
        scripts: script_tags,
        languages,
        features: feature_infos,
        lookup_count: lookup_count.unwrap_or(0),
    }
}

fn argb(color: &skrifa::color::Color) -> u32 {
    let (r, g, b, a) = (color.red, color.green, color.blue, color.alpha);
    ((a as u32) << 24) | ((r as u32) << 16) | ((g as u32) << 8) | b as u32
}

fn bgra_to_rgba(bytes: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(bytes.len());
    for chunk in bytes.chunks_exact(4) {
        out.extend_from_slice(&[chunk[2], chunk[1], chunk[0], chunk[3]]);
    }
    out
}

fn alpha_to_rgba(alpha: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(alpha.len() * 4);
    for value in alpha {
        out.extend_from_slice(&[0xFF, 0xFF, 0xFF, *value]);
    }
    out
}

fn bitmap_format_name(format: Option<BitmapFormat>) -> &'static str {
    match format {
        Some(BitmapFormat::Sbix) => "sbix",
        Some(BitmapFormat::Cbdt) => "cbdt",
        Some(BitmapFormat::Ebdt) => "ebdt",
        None => "none",
    }
}

fn outline_format_name(format: OutlineGlyphFormat) -> &'static str {
    match format {
        OutlineGlyphFormat::Glyf => "glyf",
        OutlineGlyphFormat::Cff => "cff",
        OutlineGlyphFormat::Cff2 => "cff2",
        OutlineGlyphFormat::Varc => "varc",
    }
}

fn convert_element(element: &read_fonts::model::glyph::outline::PathElement) -> PathElement {
    use read_fonts::model::glyph::outline::PathElement as E;
    match *element {
        E::MoveTo { x, y } => PathElement {
            verb: PathVerb::MoveTo,
            points: vec![x as f64, y as f64],
        },
        E::LineTo { x, y } => PathElement {
            verb: PathVerb::LineTo,
            points: vec![x as f64, y as f64],
        },
        E::QuadTo { cx0, cy0, x, y } => PathElement {
            verb: PathVerb::QuadTo,
            points: vec![cx0 as f64, cy0 as f64, x as f64, y as f64],
        },
        E::CurveTo {
            cx0,
            cy0,
            cx1,
            cy1,
            x,
            y,
        } => PathElement {
            verb: PathVerb::CubicTo,
            points: vec![
                cx0 as f64, cy0 as f64, cx1 as f64, cy1 as f64, x as f64, y as f64,
            ],
        },
        E::Close => PathElement {
            verb: PathVerb::Close,
            points: vec![],
        },
    }
}

/// Number of fonts inside `bytes`, without keeping anything alive.
#[frb(sync)]
pub fn count_fonts(bytes: Vec<u8>) -> Result<u32> {
    Font::count_fonts(bytes)
}

/// One-shot convenience helper: parse `bytes` and read its metadata.
#[frb(sync)]
pub fn read_font_info(bytes: Vec<u8>, index: Option<u32>) -> Result<FontInfo> {
    Font::from_bytes(bytes, index)?.info()
}

/// Versions of the fontations crates this plugin was built against.
#[frb(sync)]
pub fn fontations_version() -> String {
    format!(
        "skrifa {} / read-fonts {} / font-types {}",
        env!("FONTATIONS_SKRIFA_VERSION"),
        env!("FONTATIONS_READ_FONTS_VERSION"),
        env!("FONTATIONS_FONT_TYPES_VERSION"),
    )
}

/// Called once by `flutter_rust_bridge` before any other function runs.
#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::build::{
        ContourPoint as BuildPoint, FontBuildRequest, GlyphContour, GlyphSpec, KernPair,
        StylisticAlternate,
    };
    use crate::font_compile::build_ttf;

    /// A 840 x 60 rectangle, used as a stand in for a drawn glyph.
    fn rectangle(y0: f64, y1: f64) -> GlyphContour {
        GlyphContour {
            points: vec![
                BuildPoint {
                    x: 80.0,
                    y: y0,
                    on_curve: true,
                },
                BuildPoint {
                    x: 920.0,
                    y: y0,
                    on_curve: true,
                },
                BuildPoint {
                    x: 920.0,
                    y: y1,
                    on_curve: true,
                },
                BuildPoint {
                    x: 80.0,
                    y: y1,
                    on_curve: true,
                },
            ],
        }
    }

    /// A font with one glyph, one stylistic alternate and one kern pair.
    fn sample_font() -> Font {
        let bytes = build_ttf(&FontBuildRequest {
            family_name: "Sample".to_string(),
            subfamily_name: Some("Regular".to_string()),
            units_per_em: Some(1000),
            designer: Some("A Designer".to_string()),
            glyphs: vec![
                GlyphSpec {
                    code_point: 'A' as u32,
                    contours: vec![rectangle(400.0, 460.0)],
                    alternates: vec![StylisticAlternate {
                        feature_tag: "ss01".to_string(),
                        contours: vec![rectangle(200.0, 260.0)],
                        name: Some("Low bar".to_string()),
                        ..Default::default()
                    }],
                    ..Default::default()
                },
                GlyphSpec {
                    code_point: 'V' as u32,
                    contours: vec![rectangle(400.0, 460.0)],
                    ..Default::default()
                },
            ],
            kern_pairs: vec![KernPair {
                left: 'A' as u32,
                right: 'V' as u32,
                value: -80.0,
            }],
            ..Default::default()
        })
        .expect("build");
        Font::from_bytes(bytes, None).expect("parse")
    }

    #[test]
    fn exposes_raw_table_data() {
        let font = sample_font();
        assert!(font.has_table("head".to_string()).unwrap());
        assert!(font.has_table("GSUB".to_string()).unwrap());
        assert!(font.has_table("GPOS".to_string()).unwrap());
        assert!(!font.has_table("COLR".to_string()).unwrap());

        let head = font.table_data("head".to_string()).unwrap().unwrap();
        // `head` is 54 bytes and starts with its version.
        assert_eq!(head.len(), 54);
        assert_eq!(font.table_length("head".to_string()).unwrap(), Some(54));

        assert!(font.table_data("COLR".to_string()).unwrap().is_none());
        assert!(font.table_data("toolong".to_string()).is_err());
    }

    #[test]
    fn reads_layout_features() {
        let font = sample_font();
        let tables = font.layout(None).unwrap();
        assert_eq!(tables.len(), 2, "{tables:?}");

        let gsub = tables.iter().find(|t| t.table == "GSUB").unwrap();
        assert!(gsub.features.iter().any(|f| f.tag == "ss01"));
        assert!(gsub.scripts.contains(&"latn".to_string()));
        assert!(gsub.languages.contains(&"dflt".to_string()));
        assert_eq!(gsub.lookup_count, 1);

        let gpos = tables.iter().find(|t| t.table == "GPOS").unwrap();
        assert_eq!(gpos.features.len(), 1);
        assert_eq!(gpos.features[0].tag, "kern");
        assert_eq!(gpos.features[0].lookup_indices, vec![0]);

        let gsub_only = font.layout(Some("GSUB".to_string())).unwrap();
        assert_eq!(gsub_only.len(), 1);
        assert_eq!(gsub_only[0].table, "GSUB");
    }

    #[test]
    fn reads_attributes_and_names() {
        let font = sample_font();
        let attributes = font.attributes().unwrap();
        assert_eq!(attributes.weight, 400.0);
        assert_eq!(attributes.style, StyleKind::Normal);
        assert_eq!(attributes.stretch_percentage, 100.0);

        let records = font.name_records(Some(1)).unwrap();
        assert!(records.iter().any(|r| r.value == "Sample"));
        let designer = font.name_records(Some(9)).unwrap();
        assert_eq!(designer[0].value, "A Designer");
        // Every record of a filtered read shares the requested name id.
        assert!(font.name_records(None).unwrap().len() >= records.len());
    }

    #[test]
    fn reads_charmap() {
        let font = sample_font();
        let info = font.charmap_info().unwrap();
        assert!(info.has_map);
        assert_eq!(info.mapping_count, 2);

        let mappings = font.char_mappings().unwrap();
        assert_eq!(mappings.len(), 2);
        assert_eq!(mappings[0].code_point, 'A' as u32);
        assert_eq!(mappings[0].glyph_id, 1);

        assert_eq!(font.char_to_glyph('A' as u32).unwrap(), Some(1));
        assert_eq!(font.glyph_to_char(2).unwrap(), Some('V' as u32));
    }

    #[test]
    fn reads_glyph_metrics_and_outlines() {
        let font = sample_font();
        let metrics = font.glyph_metrics(1, None, Vec::new()).unwrap();
        assert_eq!(metrics.advance_width, Some(1000.0));
        assert_eq!(metrics.left_side_bearing, Some(80.0));
        assert!(metrics.bounds.is_some());

        let scaled = font.glyph_metrics(1, Some(50.0), Vec::new()).unwrap();
        // 50 / 1000 of the font unit advance.
        assert!((scaled.advance_width.unwrap() - 50.0).abs() < 0.01);

        assert_eq!(font.outline_format().unwrap(), Some("glyf".to_string()));
        let outline = font.outline(1, Some(48.0), Vec::new(), None).unwrap();
        assert_eq!(outline.format.as_deref(), Some("glyf"));
        assert!(!outline.elements.is_empty());
        // Hinting is a no-op on a font without instructions, but it must not
        // fail or change the element count.
        let hinted = font.outline(1, Some(48.0), Vec::new(), Some(true)).unwrap();
        assert_eq!(hinted.elements.len(), outline.elements.len());
    }

    #[test]
    fn reports_absent_color_bitmaps_and_vertical_metrics() {
        let font = sample_font();
        assert!(!font.has_color_glyph(1).unwrap());
        assert!(font.color_glyph(1, None, Vec::new()).unwrap().is_none());
        assert!(font.color_palettes().unwrap().is_empty());
        assert!(font.bitmap_strikes().unwrap().is_empty());
        assert!(font.bitmap_glyph(1, None).unwrap().is_none());
        assert!(font.vertical_metrics().unwrap().is_none());
        assert!(font.vertical_advance(1).unwrap().is_none());
        assert!(font.vertical_origin(1).unwrap().is_none());
    }

    #[test]
    fn shapes_text_and_applies_kerning() {
        let font = sample_font();
        let plain = font
            .shape("AV".to_string(), None, Vec::new(), None, None, None)
            .unwrap();

        assert_eq!(plain.glyphs.len(), 2);
        assert_eq!(plain.glyphs[0].cluster, 0);
        assert_eq!(plain.glyphs[1].cluster, 1);
        // Both glyphs advance 1000 and the kern pair takes 80 off the first.
        assert!(
            (plain.advance - 1920.0).abs() < 0.5,
            "advance was {}",
            plain.advance
        );

        // Kerning lives in GPOS, so asking for GSUB features only leaves the
        // advances alone.
        let no_kern = font
            .shape(
                "AV".to_string(),
                None,
                Vec::new(),
                None,
                None,
                Some(vec!["liga".to_string()]),
            )
            .unwrap();
        assert!(
            (no_kern.advance - 2000.0).abs() < 0.5,
            "{}",
            no_kern.advance
        );

        // An empty list turns every feature off, so the kern pair does not run.
        let none = font
            .shape(
                "AV".to_string(),
                None,
                Vec::new(),
                None,
                None,
                Some(Vec::new()),
            )
            .unwrap();
        assert!((none.advance - 2000.0).abs() < 0.5, "{}", none.advance);

        // A size scales the result.
        let scaled = font
            .shape("AV".to_string(), Some(50.0), Vec::new(), None, None, None)
            .unwrap();
        assert!((scaled.advance - 96.0).abs() < 0.5, "{}", scaled.advance);

        // Default features do not turn a stylistic set on.
        assert_eq!(plain.glyphs[0].glyph_id, 1);
    }

    #[test]
    fn shapes_text_with_a_requested_feature() {
        let font = sample_font();
        let alternate = font
            .shape(
                "A".to_string(),
                None,
                Vec::new(),
                None,
                None,
                Some(vec!["ss01".to_string()]),
            )
            .unwrap();

        assert_eq!(alternate.glyphs.len(), 1);
        // `ss01` swaps the glyph for the alternate the request declared.
        assert_ne!(alternate.glyphs[0].glyph_id, 1);
    }

    #[test]
    fn reads_cmap_variation_selectors() {
        let bytes = build_ttf(&FontBuildRequest {
            family_name: "Uvs".to_string(),
            glyphs: vec![
                GlyphSpec {
                    code_point: 0x845B,
                    contours: vec![rectangle(400.0, 460.0)],
                    ..Default::default()
                },
                GlyphSpec {
                    code_point: 0xE0100,
                    contours: vec![rectangle(200.0, 260.0)],
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
        .expect("build");
        let font = Font::from_bytes(bytes, None).expect("parse");

        let mapped = font.map_variant(0x845B, 0xE0100).unwrap().expect("mapped");
        assert_eq!(mapped.kind, "variant");
        assert_eq!(mapped.glyph_id, Some(2));

        // A pair the font does not name is not in the subtable at all.
        assert!(font.map_variant(0x845B, 0xE0101).unwrap().is_none());

        let all = font.variant_mappings().unwrap();
        assert!(all.iter().any(|entry| entry.code_point == 0x845B
            && entry.selector == 0xE0100
            && entry.glyph_id == Some(2)));
    }

    #[test]
    fn reads_avar_and_normalized_coords() {
        let bytes = build_ttf(&FontBuildRequest {
            family_name: "Avar".to_string(),
            glyphs: vec![GlyphSpec {
                code_point: 0x4E00,
                contours: vec![rectangle(400.0, 460.0)],
                masters: vec![crate::api::build::VariationMaster {
                    coordinates: vec![900.0],
                    contours: vec![rectangle(200.0, 300.0)],
                    ..Default::default()
                }],
                ..Default::default()
            }],
            axes: vec![crate::api::build::VariationAxisSpec {
                tag: "wght".to_string(),
                name: "Weight".to_string(),
                min_value: 100.0,
                default_value: 400.0,
                max_value: 900.0,
                // Pin the axis to the default: every coordinate normalizes to 0.
                mappings: vec![
                    crate::api::build::AxisValueMapSpec {
                        from: -1.0,
                        to: 0.0,
                    },
                    crate::api::build::AxisValueMapSpec { from: 0.0, to: 0.0 },
                    crate::api::build::AxisValueMapSpec { from: 1.0, to: 0.0 },
                ],
            }],
            ..Default::default()
        })
        .expect("build");
        let font = Font::from_bytes(bytes, None).expect("parse");

        let avar = font.avar_info().unwrap().expect("avar");
        assert_eq!(avar.version, "1.0");
        assert!(!avar.has_avar2);
        assert_eq!(avar.axes.len(), 1);
        assert_eq!(avar.axes[0].tag, "wght");
        assert_eq!(avar.axes[0].maps.len(), 3);
        assert_eq!(avar.axes[0].maps[2].from, 1.0);
        assert_eq!(avar.axes[0].maps[2].to, 0.0);

        let coords = font
            .normalized_coords(vec![VariationSetting {
                tag: "wght".to_string(),
                value: 900.0,
            }])
            .unwrap();
        assert_eq!(coords.len(), 1);
        // 900 is the maximum, i.e. 1.0 before `avar`, and the mapping pins it.
        assert!(coords[0].abs() < 0.01, "{coords:?}");
    }

    #[test]
    fn reports_absent_math_varc_and_variants() {
        let font = sample_font();
        assert!(!font.has_math().unwrap());
        assert!(font.math_constants(None).unwrap().is_none());
        assert!(font.math_glyph_info(1, None).unwrap().is_none());
        assert!(font
            .math_variants(1, "vertical".to_string())
            .unwrap()
            .is_none());

        assert!(!font.has_varc().unwrap());
        assert!(font.varc_components(1, Vec::new()).unwrap().is_none());

        assert!(font.variant_mappings().unwrap().is_empty());
        assert!(font.map_variant(0x41, 0xE0100).unwrap().is_none());
        // A static font has no `avar`.
        assert!(font.avar_info().unwrap().is_none());
        assert!(font.normalized_coords(Vec::new()).unwrap().is_empty());
    }

    #[test]
    fn reads_glyph_names_when_the_font_has_none() {
        let font = sample_font();
        // `post` 3.0 carries no names, so skrifa synthesizes `glyph00001`.
        let source = font.glyph_name_source().unwrap();
        assert!(
            source.contains("None") || source.contains("Synthesized"),
            "{source}"
        );
        assert!(font.glyph_name(1).unwrap().is_some());
    }
}
