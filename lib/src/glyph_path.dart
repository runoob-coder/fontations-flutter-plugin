import 'dart:math' show max, min;
import 'dart:ui' as ui;

import 'rust/api/fontations.dart';

/// Builds a [ui.Path] from recorded path elements. Font coordinates are y-up,
/// while Flutter's canvas is y-down, so [flipY] defaults to `true`.
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
    final requiredPoints = switch (element.verb) {
      PathVerb.moveTo || PathVerb.lineTo => 2,
      PathVerb.quadTo => 4,
      PathVerb.cubicTo => 6,
      PathVerb.close => 0,
    };
    if (p.length < requiredPoints) {
      // Skip incomplete elements instead of throwing mid-paint.
      continue;
    }
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
  /// Builds a [ui.Path]; the baseline is at `y = 0`, so flipped glyphs extend
  /// towards negative y.
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
    // flipY / negative scale can invert either axis.
    final x1 = tx(xMin);
    final x2 = tx(xMax);
    final y1 = ty(yMin);
    final y2 = ty(yMax);
    return ui.Rect.fromLTRB(min(x1, x2), min(y1, y2), max(x1, x2), max(y1, y2));
  }
}
