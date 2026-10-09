import 'dart:ui' as ui;

import 'rust/api/fontations.dart';

/// Builds a [ui.Path] from recorded path elements.
///
/// Font coordinates are y-up while Flutter's canvas is y-down, so [flipY]
/// defaults to `true`.
ui.Path buildPath(
  Iterable<PathElement> elements, {
  double scale = 1.0,
  bool flipY = true,
  double offsetX = 0.0,
  double offsetY = 0.0,
}) {
  double tx(double v) => v * scale + offsetX;
  double ty(double v) => (flipY ? -v : v) * scale + offsetY;

  final path = ui.Path();
  for (final element in elements) {
    final p = element.points;
    switch (element.verb) {
      case PathVerb.moveTo:
        path.moveTo(tx(p[0]), ty(p[1]));
      case PathVerb.lineTo:
        path.lineTo(tx(p[0]), ty(p[1]));
      case PathVerb.quadTo:
        path.quadraticBezierTo(tx(p[0]), ty(p[1]), tx(p[2]), ty(p[3]));
      case PathVerb.cubicTo:
        path.cubicTo(
          tx(p[0]),
          ty(p[1]),
          tx(p[2]),
          ty(p[3]),
          tx(p[4]),
          ty(p[5]),
        );
      case PathVerb.close:
        path.close();
    }
  }
  return path;
}

/// Converts outlines produced by `Font.outline` into Flutter primitives.
extension GlyphOutlinePath on GlyphOutline {
  /// Builds a [ui.Path] from the recorded path elements.
  ///
  /// Font coordinates are y-up, while Flutter's canvas is y-down, so [flipY]
  /// defaults to `true`. When drawing, remember that the baseline sits at
  /// `y = 0`, so glyphs extend towards negative y (see [ui.Path.getBounds]).
  ui.Path toPath({
    double scale = 1.0,
    bool flipY = true,
    double offsetX = 0.0,
    double offsetY = 0.0,
  }) => buildPath(
    elements,
    scale: scale,
    flipY: flipY,
    offsetX: offsetX,
    offsetY: offsetY,
  );

  /// The glyph bounds as a [ui.Rect].
  ui.Rect? get boundsRect => bounds?.toRect(flipY: true);
}

/// Converts a fontations [RectF] into a [ui.Rect].
extension RectFToRect on RectF {
  /// Applies the same `scale`/`offset` transform used by [GlyphOutlinePath.toPath].
  ui.Rect toRect({
    double scale = 1.0,
    bool flipY = true,
    double offsetX = 0.0,
    double offsetY = 0.0,
  }) {
    double tx(double v) => v * scale + offsetX;
    double ty(double v) => (flipY ? -v : v) * scale + offsetY;
    return ui.Rect.fromLTRB(tx(xMin), ty(yMax), tx(xMax), ty(yMin));
  }
}
