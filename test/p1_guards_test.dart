// Pure Dart tests for the defensive bounds; no native library needed.
@TestOn('vm')
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fontations/fontations.dart';

PathElement element(PathVerb verb, List<double> points) =>
    PathElement(verb: verb, points: Float64List.fromList(points));

ColorPaint solidPaint(double alpha) => ColorPaint(
  kind: PaintKind.solid,
  color: 0xFF112233,
  alpha: alpha,
  x0: 0,
  y0: 0,
  x1: 0,
  y1: 0,
  r0: 0,
  r1: 0,
  startAngle: 0,
  endAngle: 0,
  extend: 'pad',
  stops: const [],
);

List<PathElement> get triangle => [
  element(PathVerb.moveTo, [0, 0]),
  element(PathVerb.lineTo, [10, 10]),
  element(PathVerb.close, []),
];

void main() {
  test(
    'buildPath skips incomplete elements instead of throwing a RangeError',
    () {
      final path = buildPath([
        element(PathVerb.moveTo, [1]),
        element(PathVerb.cubicTo, [1, 2, 3]),
        ...triangle,
      ]);
      expect(() => path.getBounds(), returnsNormally);
      expect(path.getBounds(), isNot(ui.Rect.zero));
    },
  );

  test('buildPath keeps complete elements', () {
    final path = buildPath(triangle);
    expect(path.getBounds(), isNot(ui.Rect.zero));
  });

  test('unknown composite modes fall back to srcOver', () {
    expect(blendModeFor('NotAMode'), ui.BlendMode.srcOver);
    expect(blendModeFor('Multiply'), ui.BlendMode.multiply);
  });

  test('color glyph paint tolerates a zero upem, NaN size and wild alpha', () {
    final canvas = ui.Canvas(ui.PictureRecorder());
    final glyph = ColorGlyphInfo(
      format: 'colrV0',
      layers: [
        ColorLayer(
          elements: triangle,
          paint: solidPaint(2.0),
          composite: 'SrcOver',
        ),
      ],
    );

    expect(() => glyph.paint(canvas, size: 24, unitsPerEm: 0), returnsNormally);
    expect(
      () => glyph.paint(canvas, size: double.nan, unitsPerEm: 1000),
      returnsNormally,
    );
  });
}
