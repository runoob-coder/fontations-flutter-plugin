//! Flattens a `COLR` glyph into a list of filled path layers.
//!
//! `skrifa` walks a `COLRv1` paint graph through the [`ColorPainter`] trait,
//! which is designed for immediate mode 2D APIs. Flutter's `Canvas` is
//! immediate too, but the drawing happens on the Dart side, so the callbacks
//! are recorded here and handed over as plain data.
//!
//! Everything is kept in **font units with y pointing up**, which is the space
//! the paint graph operates in. Dart scales by `size / unitsPerEm` and flips y,
//! exactly like it does for `Font.outline`.

use kurbo::Affine;
use read_fonts::model::glyph::outline::PathElement as RawElement;
use read_fonts::types::GlyphId;
use skrifa::color::{Brush, ColorPainter, CompositeMode, Extend, Transform};
use skrifa::instance::{LocationRef, Size};
use skrifa::outline::DrawSettings;
use skrifa::{FontRef, MetadataProvider};

use crate::api::fontations::{
    ColorLayer, ColorPaint, ColorStop, PaintKind, PathElement, PathVerb, RectF,
};

/// Records the paint callbacks of one color glyph.
pub struct RecordingPainter<'f, 'a> {
    font: &'f FontRef<'a>,
    /// Resolved palette, as `0xAARRGGBB`.
    palette: Vec<u32>,
    /// Currently pushed transforms, innermost last.
    transforms: Vec<Affine>,
    /// Glyph whose outline clips the next `fill`.
    clip_glyph: Option<GlyphId>,
    /// Rectangle that clips the next `fill`.
    clip_box: Option<RectF>,
    /// Composite mode of the layer that is currently open.
    composite: String,
    /// Collected layers, in paint order.
    pub layers: Vec<ColorLayer>,
}

impl<'f, 'a> RecordingPainter<'f, 'a> {
    pub fn new(font: &'f FontRef<'a>, palette: Vec<u32>) -> Self {
        Self {
            font,
            palette,
            transforms: Vec::new(),
            clip_glyph: None,
            clip_box: None,
            composite: "SrcOver".to_string(),
            layers: Vec::new(),
        }
    }

    fn current_transform(&self) -> Affine {
        self.transforms
            .iter()
            .fold(Affine::IDENTITY, |acc, next| acc * *next)
    }

    /// Uniform scale of the current transform, used to scale radii and angles.
    fn scale(&self) -> f64 {
        let affine = self.current_transform();
        let det = affine.as_coeffs();
        (det[0] * det[3] - det[1] * det[2])
            .abs()
            .sqrt()
            .max(f64::EPSILON)
    }

    fn color(&self, palette_index: u16) -> u32 {
        self.palette
            .get(palette_index as usize)
            .copied()
            .unwrap_or(0xFF_00_00_00)
    }

    fn stops(&self, stops: &[skrifa::color::ColorStop]) -> Vec<ColorStop> {
        stops
            .iter()
            .map(|stop| ColorStop {
                offset: stop.offset as f64,
                color: self.color(stop.palette_index),
                alpha: stop.alpha as f64,
            })
            .collect()
    }

    fn extend_name(extend: Extend) -> String {
        match extend {
            Extend::Pad => "pad",
            Extend::Repeat => "repeat",
            Extend::Reflect => "reflect",
            _ => "pad",
        }
        .to_string()
    }

    fn paint(&self, brush: Brush<'_>) -> ColorPaint {
        let empty = || ColorPaint {
            kind: PaintKind::Solid,
            color: 0,
            alpha: 1.0,
            x0: 0.0,
            y0: 0.0,
            x1: 0.0,
            y1: 0.0,
            r0: 0.0,
            r1: 0.0,
            start_angle: 0.0,
            end_angle: 0.0,
            extend: "pad".to_string(),
            stops: Vec::new(),
        };

        match brush {
            Brush::Solid {
                palette_index,
                alpha,
            } => ColorPaint {
                color: self.color(palette_index),
                alpha: alpha as f64,
                ..empty()
            },
            Brush::LinearGradient {
                p0,
                p1,
                color_stops,
                extend,
            } => {
                let affine = self.current_transform();
                let p0 = affine * kurbo::Point::new(p0.x as f64, p0.y as f64);
                let p1 = affine * kurbo::Point::new(p1.x as f64, p1.y as f64);
                ColorPaint {
                    kind: PaintKind::Linear,
                    x0: p0.x,
                    y0: p0.y,
                    x1: p1.x,
                    y1: p1.y,
                    extend: Self::extend_name(extend),
                    stops: self.stops(color_stops),
                    ..empty()
                }
            }
            Brush::RadialGradient {
                c0,
                r0,
                c1,
                r1,
                color_stops,
                extend,
            } => {
                let affine = self.current_transform();
                let scale = self.scale();
                let c0 = affine * kurbo::Point::new(c0.x as f64, c0.y as f64);
                let c1 = affine * kurbo::Point::new(c1.x as f64, c1.y as f64);
                ColorPaint {
                    kind: PaintKind::Radial,
                    x0: c0.x,
                    y0: c0.y,
                    r0: r0 as f64 * scale,
                    x1: c1.x,
                    y1: c1.y,
                    r1: r1 as f64 * scale,
                    extend: Self::extend_name(extend),
                    stops: self.stops(color_stops),
                    ..empty()
                }
            }
            Brush::SweepGradient {
                c0,
                start_angle,
                end_angle,
                color_stops,
                extend,
            } => {
                let affine = self.current_transform();
                let c0 = affine * kurbo::Point::new(c0.x as f64, c0.y as f64);
                ColorPaint {
                    kind: PaintKind::Sweep,
                    x0: c0.x,
                    y0: c0.y,
                    start_angle: start_angle as f64,
                    end_angle: end_angle as f64,
                    extend: Self::extend_name(extend),
                    stops: self.stops(color_stops),
                    ..empty()
                }
            }
        }
    }

    /// Outline of `glyph_id` in font units, with the current transform applied.
    fn glyph_elements(&self, glyph_id: GlyphId) -> Vec<PathElement> {
        let Some(glyph) = self.font.outline_glyphs().get(glyph_id) else {
            return Vec::new();
        };
        let mut raw: Vec<RawElement> = Vec::new();
        if glyph
            .draw(
                DrawSettings::unhinted(Size::unscaled(), LocationRef::default()),
                &mut raw,
            )
            .is_err()
        {
            return Vec::new();
        }
        let affine = self.current_transform();
        raw.iter().map(|e| Self::convert(e, affine)).collect()
    }

    fn convert(element: &RawElement, affine: Affine) -> PathElement {
        let point = |x: f32, y: f32| {
            let p = affine * kurbo::Point::new(x as f64, y as f64);
            [p.x, p.y]
        };
        match *element {
            RawElement::MoveTo { x, y } => {
                let p = point(x, y);
                PathElement {
                    verb: PathVerb::MoveTo,
                    points: p.to_vec(),
                }
            }
            RawElement::LineTo { x, y } => {
                let p = point(x, y);
                PathElement {
                    verb: PathVerb::LineTo,
                    points: p.to_vec(),
                }
            }
            RawElement::QuadTo { cx0, cy0, x, y } => {
                let c = point(cx0, cy0);
                let p = point(x, y);
                PathElement {
                    verb: PathVerb::QuadTo,
                    points: vec![c[0], c[1], p[0], p[1]],
                }
            }
            RawElement::CurveTo {
                cx0,
                cy0,
                cx1,
                cy1,
                x,
                y,
            } => {
                let c0 = point(cx0, cy0);
                let c1 = point(cx1, cy1);
                let p = point(x, y);
                PathElement {
                    verb: PathVerb::CubicTo,
                    points: vec![c0[0], c0[1], c1[0], c1[1], p[0], p[1]],
                }
            }
            RawElement::Close => PathElement {
                verb: PathVerb::Close,
                points: vec![],
            },
        }
    }

    fn rect_elements(rect: &RectF) -> Vec<PathElement> {
        vec![
            PathElement {
                verb: PathVerb::MoveTo,
                points: vec![rect.x_min, rect.y_min],
            },
            PathElement {
                verb: PathVerb::LineTo,
                points: vec![rect.x_max, rect.y_min],
            },
            PathElement {
                verb: PathVerb::LineTo,
                points: vec![rect.x_max, rect.y_max],
            },
            PathElement {
                verb: PathVerb::LineTo,
                points: vec![rect.x_min, rect.y_max],
            },
            PathElement {
                verb: PathVerb::Close,
                points: vec![],
            },
        ]
    }
}

impl ColorPainter for RecordingPainter<'_, '_> {
    fn push_transform(&mut self, transform: Transform) {
        self.transforms.push(Affine::new([
            transform.xx as f64,
            transform.yx as f64,
            transform.xy as f64,
            transform.yy as f64,
            transform.dx as f64,
            transform.dy as f64,
        ]));
    }

    fn pop_transform(&mut self) {
        self.transforms.pop();
    }

    fn push_clip_glyph(&mut self, glyph_id: GlyphId) {
        self.clip_glyph = Some(glyph_id);
    }

    fn push_clip_box(&mut self, clip_box: read_fonts::types::BoundingBox<f32>) {
        self.clip_box = Some(RectF {
            x_min: clip_box.x_min as f64,
            y_min: clip_box.y_min as f64,
            x_max: clip_box.x_max as f64,
            y_max: clip_box.y_max as f64,
        });
    }

    fn pop_clip(&mut self) {
        self.clip_glyph = None;
        self.clip_box = None;
    }

    fn fill(&mut self, brush: Brush<'_>) {
        let elements = match (self.clip_glyph, self.clip_box.as_ref()) {
            (Some(glyph_id), _) => self.glyph_elements(glyph_id),
            (None, Some(rect)) => Self::rect_elements(rect),
            (None, None) => return,
        };
        if elements.is_empty() {
            return;
        }
        self.layers.push(ColorLayer {
            elements,
            paint: self.paint(brush),
            composite: self.composite.clone(),
        });
    }

    fn fill_glyph(
        &mut self,
        glyph_id: GlyphId,
        brush_transform: Option<Transform>,
        brush: Brush<'_>,
    ) {
        // The default implementation pushes the clip glyph and fills; doing it
        // directly avoids a redundant outline lookup.
        if let Some(transform) = brush_transform {
            self.push_transform(transform);
            self.push_clip_glyph(glyph_id);
            self.fill(brush);
            self.pop_clip();
            self.pop_transform();
        } else {
            self.push_clip_glyph(glyph_id);
            self.fill(brush);
            self.pop_clip();
        }
    }

    fn push_layer(&mut self, composite_mode: CompositeMode) {
        self.composite = format!("{composite_mode:?}");
    }
}
