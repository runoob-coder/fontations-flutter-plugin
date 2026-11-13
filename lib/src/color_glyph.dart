import 'dart:math' show pi;
import 'dart:ui' as ui;

import 'glyph_path.dart';
import 'rust/api/fontations.dart';

// Keep in sync with `MAX_COLOR_LAYERS` in `rust/src/limits.rs`.
const int _maxColorLayers = 2048;

/// Paints the layers of a `COLR` color glyph onto a Flutter canvas.
extension ColorGlyphPainter on ColorGlyphInfo {
  /// Draws layers in paint order, scaled by `size / unitsPerEm` and flipped
  /// into canvas coordinates by default.
  void paint(
    ui.Canvas canvas, {
    double size = 0,
    int unitsPerEm = 1000,
    ui.Offset offset = ui.Offset.zero,
    bool flipY = true,
  }) {
    final upem = unitsPerEm > 0 ? unitsPerEm : 1000;
    final scale = (size.isFinite && size > 0) ? size / upem : 1.0;
    var drawn = 0;
    for (final layer in layers) {
      if (drawn >= _maxColorLayers) {
        break;
      }
      drawn++;
      final path = buildPath(
        layer.elements,
        scale: scale,
        flipY: flipY,
        offsetX: offset.dx,
        offsetY: offset.dy,
      );
      final paint = _paintFor(
        layer.paint,
        scale: scale,
        flipY: flipY,
        offset: offset,
      );
      final blend = blendModeFor(layer.composite);
      if (blend == ui.BlendMode.srcOver) {
        canvas.drawPath(path, paint);
      } else {
        canvas.saveLayer(null, ui.Paint()..blendMode = blend);
        canvas.drawPath(path, paint);
        canvas.restore();
      }
    }
  }
}

/// Maps a `COLRv1` composite mode name onto a Flutter [ui.BlendMode].
///
/// Unknown names fall back to [ui.BlendMode.srcOver].
ui.BlendMode blendModeFor(String composite) {
  switch (composite) {
    case 'Clear':
      return ui.BlendMode.clear;
    case 'Src':
      return ui.BlendMode.src;
    case 'Dest':
      return ui.BlendMode.dst;
    case 'SrcOver':
      return ui.BlendMode.srcOver;
    case 'DestOver':
      return ui.BlendMode.dstOver;
    case 'SrcIn':
      return ui.BlendMode.srcIn;
    case 'DestIn':
      return ui.BlendMode.dstIn;
    case 'SrcOut':
      return ui.BlendMode.srcOut;
    case 'DestOut':
      return ui.BlendMode.dstOut;
    case 'SrcATop' || 'SrcAtop':
      return ui.BlendMode.srcATop;
    case 'DestATop' || 'DestAtop':
      return ui.BlendMode.dstATop;
    case 'Xor':
      return ui.BlendMode.xor;
    case 'Plus':
      return ui.BlendMode.plus;
    case 'Screen':
      return ui.BlendMode.screen;
    case 'Overlay':
      return ui.BlendMode.overlay;
    case 'Darken':
      return ui.BlendMode.darken;
    case 'Lighten':
      return ui.BlendMode.lighten;
    case 'ColorDodge':
      return ui.BlendMode.colorDodge;
    case 'ColorBurn':
      return ui.BlendMode.colorBurn;
    case 'HardLight':
      return ui.BlendMode.hardLight;
    case 'SoftLight':
      return ui.BlendMode.softLight;
    case 'Difference':
      return ui.BlendMode.difference;
    case 'Exclusion':
      return ui.BlendMode.exclusion;
    case 'Multiply':
      return ui.BlendMode.multiply;
    case 'HslHue':
      return ui.BlendMode.hue;
    case 'HslSaturation':
      return ui.BlendMode.saturation;
    case 'HslColor':
      return ui.BlendMode.color;
    case 'HslLuminosity':
      return ui.BlendMode.luminosity;
    default:
      return ui.BlendMode.srcOver;
  }
}

ui.Paint _paintFor(
  ColorPaint paint, {
  required double scale,
  required bool flipY,
  required ui.Offset offset,
}) {
  final result = ui.Paint()..color = ui.Color(paint.color);
  if (paint.kind == PaintKind.solid) {
    // Alpha comes from font data; clamp it before `withValues`.
    final alpha = paint.alpha.isFinite
        ? paint.alpha.clamp(0.0, 1.0).toDouble()
        : 1.0;
    result.color = ui.Color(paint.color).withValues(alpha: alpha);
    return result;
  }

  final colors = paint.stops.map((stop) => ui.Color(stop.color)).toList();
  final stops = paint.stops.map((stop) => stop.offset).toList();
  if (colors.isEmpty) {
    return result;
  }

  double tx(double v) => v * scale + offset.dx;
  double ty(double v) => (flipY ? -v : v) * scale + offset.dy;

  final tileMode = switch (paint.extend) {
    'repeat' => ui.TileMode.repeated,
    'reflect' => ui.TileMode.mirror,
    _ => ui.TileMode.clamp,
  };

  // `Gradient.sweep` needs an increasing range; flipY reverses COLR angles.
  var sweepStart = _radians(paint.startAngle, flipY);
  var sweepEnd = _radians(paint.endAngle, flipY);
  if (!sweepStart.isFinite) sweepStart = 0;
  if (!sweepEnd.isFinite) sweepEnd = sweepStart + 2 * pi;
  if (sweepEnd < sweepStart) {
    final lower = sweepEnd;
    sweepEnd = sweepStart;
    sweepStart = lower;
  }
  if (sweepEnd == sweepStart) {
    // Equal angles mean a full circle in COLR.
    sweepEnd += 2 * pi;
  }

  result.shader = switch (paint.kind) {
    PaintKind.linear => ui.Gradient.linear(
      ui.Offset(tx(paint.x0), ty(paint.y0)),
      ui.Offset(tx(paint.x1), ty(paint.y1)),
      colors,
      stops.isNotEmpty ? stops : null,
      tileMode,
    ),
    // Approximates `COLR`'s two-circle gradients.
    PaintKind.radial => ui.Gradient.radial(
      ui.Offset(tx(paint.x0), ty(paint.y0)),
      paint.r1 * scale,
      colors,
      stops.isNotEmpty ? stops : null,
      tileMode,
      null,
      ui.Offset(tx(paint.x1), ty(paint.y1)),
      paint.r0 * scale,
    ),
    PaintKind.sweep => ui.Gradient.sweep(
      ui.Offset(tx(paint.x0), ty(paint.y0)),
      colors,
      stops.isNotEmpty ? stops : null,
      tileMode,
      sweepStart,
      sweepEnd,
    ),
    PaintKind.solid => null,
  };
  return result;
}

double _radians(double degrees, bool flipY) =>
    degrees * pi / 180.0 * (flipY ? -1 : 1);
