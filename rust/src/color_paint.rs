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
use read_fonts::model::glyph::outline::{DrawMemory, PathElement as RawElement};
use read_fonts::types::GlyphId;
use skrifa::color::{Brush, ColorPainter, CompositeMode, Extend, Transform};
use skrifa::ScalerFont;

use crate::api::fontations::{
    ColorLayer, ColorPaint, ColorStop, PaintKind, PathElement, PathVerb, RectF,
};
use crate::limits::{MAX_COLOR_LAYERS, MAX_TRANSFORM_DEPTH};

/// Records the paint callbacks of one color glyph.
pub struct RecordingPainter {
    /// Font-unit scaler used to outline the glyphs a `COLR` graph clips to.
    scaler: ScalerFont,
    /// Resolved palette, as `0xAARRGGBB`.
    palette: Vec<u32>,
    /// Currently pushed transforms, innermost last.
    transforms: Vec<Affine>,
    /// `push_transform` calls dropped once the graph exceeds
    /// `MAX_TRANSFORM_DEPTH`. Counted so `pop_transform` keeps the stack
    /// balanced while the graph unwinds.
    dropped_transforms: usize,
    /// Nested clips, innermost last. A `COLRv1` paint graph can push a glyph
    /// clip inside a box clip, and `pop_clip` has to restore the outer one.
    clips: Vec<(Option<GlyphId>, Option<RectF>)>,
    /// Composite modes of the open layers, innermost last.
    composites: Vec<String>,
    /// Collected layers, in paint order.
    pub layers: Vec<ColorLayer>,
}

impl RecordingPainter {
    pub fn new(scaler: ScalerFont, palette: Vec<u32>) -> Self {
        Self {
            scaler,
            palette,
            transforms: Vec::new(),
            dropped_transforms: 0,
            clips: Vec::new(),
            composites: vec!["SrcOver".to_string()],
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
        let Some(outline) = self.scaler.outline(glyph_id) else {
            return Vec::new();
        };
        let mut raw: Vec<RawElement> = Vec::new();
        if outline.draw(DrawMemory::Scratch, &mut raw).is_err() {
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

impl ColorPainter for RecordingPainter {
    fn push_transform(&mut self, transform: Transform) {
        if self.transforms.len() >= MAX_TRANSFORM_DEPTH {
            self.dropped_transforms += 1;
            return;
        }
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
        // Unwind the pushes we dropped before touching the real stack.
        if self.dropped_transforms > 0 {
            self.dropped_transforms -= 1;
            return;
        }
        self.transforms.pop();
    }

    fn push_clip_glyph(&mut self, glyph_id: GlyphId) {
        self.clips.push((Some(glyph_id), None));
    }

    fn push_clip_box(&mut self, clip_box: read_fonts::types::BoundingBox<f32>) {
        self.clips.push((
            None,
            Some(RectF {
                x_min: clip_box.x_min as f64,
                y_min: clip_box.y_min as f64,
                x_max: clip_box.x_max as f64,
                y_max: clip_box.y_max as f64,
            }),
        ));
    }

    fn pop_clip(&mut self) {
        self.clips.pop();
    }

    fn fill(&mut self, brush: Brush<'_>) {
        if self.layers.len() >= MAX_COLOR_LAYERS {
            return;
        }
        let Some(&(clip_glyph, clip_box)) = self.clips.last() else {
            return;
        };
        let elements = match (clip_glyph, clip_box.as_ref()) {
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
            composite: self
                .composites
                .last()
                .cloned()
                .unwrap_or_else(|| "SrcOver".to_string()),
        });
    }

    fn fill_glyph(
        &mut self,
        glyph_id: GlyphId,
        brush_transform: Option<Transform>,
        brush: Brush<'_>,
    ) {
        // Avoid the default implementation's redundant outline lookup.
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
        self.composites.push(format!("{composite_mode:?}"));
    }

    fn pop_layer(&mut self) {
        // The trait default would leak the innermost layer's composite mode.
        if self.composites.len() > 1 {
            self.composites.pop();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::limits::{MAX_COLOR_LAYERS, MAX_TRANSFORM_DEPTH};
    use read_fonts::model::Font as ModelFont;
    use read_fonts::types::BoundingBox;

    /// A real font is only needed to build the scaler; the painter never
    /// reads its outlines in these tests because the clip is a rectangle.
    fn font_bytes() -> &'static [u8] {
        include_bytes!("../../example/assets/fonts/Inter.ttf")
    }

    fn recording_painter(palette: Vec<u32>) -> RecordingPainter {
        let model = ModelFont::new(font_bytes(), 0).expect("font model");
        RecordingPainter::new(ScalerFont::unhinted(model, None), palette)
    }

    #[test]
    fn color_layers_are_capped() {
        let mut painter = recording_painter(vec![0xFF00_0000]);
        let clip = BoundingBox::<f32> {
            x_min: 0.0,
            y_min: 0.0,
            x_max: 10.0,
            y_max: 10.0,
        };
        for _ in 0..MAX_COLOR_LAYERS + 32 {
            painter.push_clip_box(clip);
            painter.fill(Brush::Solid {
                palette_index: 0,
                alpha: 1.0,
            });
            painter.pop_clip();
        }
        assert_eq!(painter.layers.len(), MAX_COLOR_LAYERS);
    }

    #[test]
    fn nested_clips_and_layers_restore_their_outer_state() {
        let mut painter = recording_painter(vec![0xFF00_0000]);
        let outer = BoundingBox::<f32> {
            x_min: 0.0,
            y_min: 0.0,
            x_max: 10.0,
            y_max: 10.0,
        };
        let inner = BoundingBox::<f32> {
            x_min: 2.0,
            y_min: 2.0,
            x_max: 4.0,
            y_max: 4.0,
        };
        let solid = Brush::Solid {
            palette_index: 0,
            alpha: 1.0,
        };
        painter.push_clip_box(outer);
        painter.fill(solid.clone());
        painter.push_layer(CompositeMode::SrcIn);
        painter.push_clip_box(inner);
        painter.fill(solid.clone());
        painter.pop_clip();
        painter.pop_layer();
        painter.fill(solid);

        assert_eq!(painter.layers.len(), 3);
        assert_eq!(painter.layers[0].elements[0].points, vec![0.0, 0.0]);
        assert_eq!(painter.layers[1].elements[0].points, vec![2.0, 2.0]);
        assert_eq!(painter.layers[2].elements[0].points, vec![0.0, 0.0]);
        assert_eq!(painter.layers[0].composite, "SrcOver");
        assert_eq!(painter.layers[1].composite, "SrcIn");
        assert_eq!(painter.layers[2].composite, "SrcOver");
    }

    #[test]
    fn deep_transform_stacks_stay_balanced() {
        let mut painter = recording_painter(Vec::new());
        for _ in 0..MAX_TRANSFORM_DEPTH + 32 {
            painter.push_transform(Transform::default());
        }
        assert_eq!(painter.transforms.len(), MAX_TRANSFORM_DEPTH);
        for _ in 0..MAX_TRANSFORM_DEPTH + 32 {
            painter.pop_transform();
        }
        assert!(painter.transforms.is_empty());
        assert_eq!(painter.dropped_transforms, 0);
    }
}
