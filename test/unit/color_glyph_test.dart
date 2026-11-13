// Pure Dart tests; a recording canvas replaces pixel comparisons.
@TestOn('vm')
library;

import 'dart:io' show File;
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fontations/fontations.dart';

import '../helpers/fixtures.dart';

/// MAX_COLOR_LAYERS from rust/src/limits.rs.
int rustColorLayerLimit() {
  final source = File('rust/src/limits.rs').readAsStringSync();
  final match = RegExp(r'pub const MAX_COLOR_LAYERS: usize = ([\d_]+);')
      .firstMatch(source);
  expect(
    match,
    isNotNull,
    reason: 'MAX_COLOR_LAYERS is missing from limits.rs',
  );
  return int.parse(match!.group(1)!.replaceAll('_', ''));
}

void main() {
  // --- blendModeFor ----------------------------------------------------------

  group('blendModeFor', () {
    const expected = <String, ui.BlendMode>{
      'Clear': ui.BlendMode.clear,
      'Src': ui.BlendMode.src,
      'Dest': ui.BlendMode.dst,
      'SrcOver': ui.BlendMode.srcOver,
      'DestOver': ui.BlendMode.dstOver,
      'SrcIn': ui.BlendMode.srcIn,
      'DestIn': ui.BlendMode.dstIn,
      'SrcOut': ui.BlendMode.srcOut,
      'DestOut': ui.BlendMode.dstOut,
      'SrcATop': ui.BlendMode.srcATop,
      'DestATop': ui.BlendMode.dstATop,
      'Xor': ui.BlendMode.xor,
      'Plus': ui.BlendMode.plus,
      'Screen': ui.BlendMode.screen,
      'Overlay': ui.BlendMode.overlay,
      'Darken': ui.BlendMode.darken,
      'Lighten': ui.BlendMode.lighten,
      'ColorDodge': ui.BlendMode.colorDodge,
      'ColorBurn': ui.BlendMode.colorBurn,
      'HardLight': ui.BlendMode.hardLight,
      'SoftLight': ui.BlendMode.softLight,
      'Difference': ui.BlendMode.difference,
      'Exclusion': ui.BlendMode.exclusion,
      'Multiply': ui.BlendMode.multiply,
      'HslHue': ui.BlendMode.hue,
      'HslSaturation': ui.BlendMode.saturation,
      'HslColor': ui.BlendMode.color,
      'HslLuminosity': ui.BlendMode.luminosity,
    };

    test('maps every documented COLR composite mode', () {
      for (final entry in expected.entries) {
        expect(
          blendModeFor(entry.key),
          entry.value,
          reason: 'composite mode ${entry.key}',
        );
      }
    });

    test('accepts the lowercase-t variants of the atop modes', () {
      expect(blendModeFor('SrcAtop'), ui.BlendMode.srcATop);
      expect(blendModeFor('DestAtop'), ui.BlendMode.dstATop);
    });

    test('unknown, empty and wrongly cased names fall back to srcOver', () {
      for (final name in <String>['NotAMode', '', 'srcOver', 'SRC', 'Pad']) {
        expect(blendModeFor(name), ui.BlendMode.srcOver, reason: name);
      }
    });
  });

  // --- ColorGlyphPainter.paint: normal flow ----------------------------------

  group('ColorGlyphPainter.paint', () {
    test('an empty layer list draws nothing', () {
      final canvas = RecordingCanvas();
      colorGlyph(const <ColorLayer>[]).paint(canvas, size: 24);
      expect(canvas.draws, isEmpty);
      expect(canvas.layerBlendModes, isEmpty);
      expect(canvas.restoreCount, 0);
    });

    test('scales a solid layer by size / unitsPerEm and flips y', () {
      final canvas = RecordingCanvas();
      colorGlyph(<ColorLayer>[colorLayer()])
          .paint(canvas, size: 100, unitsPerEm: 1000);
      expect(canvas.draws, hasLength(1));
      expect(
        canvas.draws.single.path.getBounds(),
        const ui.Rect.fromLTRB(0, -1, 1, 0),
      );
      expect(canvas.draws.single.paint.shader, isNull);
      expect(canvas.draws.single.paint.color.a, closeTo(1, 0.001));
    });

    test('honours offset and flipY: false', () {
      final canvas = RecordingCanvas();
      colorGlyph(<ColorLayer>[colorLayer()]).paint(
        canvas,
        size: 100,
        unitsPerEm: 1000,
        offset: const ui.Offset(5, 7),
        flipY: false,
      );
      expect(
        canvas.draws.single.path.getBounds(),
        const ui.Rect.fromLTRB(5, 7, 6, 8),
      );
    });

    test('srcOver layers do not need a saveLayer', () {
      final canvas = RecordingCanvas();
      colorGlyph(<ColorLayer>[colorLayer(), colorLayer(composite: 'SrcOver')])
          .paint(canvas, size: 24);
      expect(canvas.draws, hasLength(2));
      expect(canvas.layerBlendModes, isEmpty);
      expect(canvas.restoreCount, 0);
    });

    test(
      'other composite modes open and restore a correctly blended layer',
      () {
        final canvas = RecordingCanvas();
        colorGlyph(<ColorLayer>[
          colorLayer(),
          colorLayer(composite: 'Multiply'),
          colorLayer(composite: 'Screen'),
        ]).paint(canvas, size: 24);
        expect(canvas.draws, hasLength(3));
        expect(canvas.layerBlendModes, <ui.BlendMode>[
          ui.BlendMode.multiply,
          ui.BlendMode.screen,
        ]);
        expect(canvas.restoreCount, 2);
      },
    );
  });

  // --- ColorGlyphPainter.paint: boundary values ------------------------------

  group('ColorGlyphPainter.paint boundary values', () {
    RecordingCanvas paintWith({
      double size = 0,
      int unitsPerEm = 1000,
      double alpha = 1,
    }) {
      final canvas = RecordingCanvas();
      colorGlyph(<ColorLayer>[colorLayer(paint: solidPaint(alpha: alpha))])
          .paint(canvas, size: size, unitsPerEm: unitsPerEm);
      return canvas;
    }

    test('clamps font-supplied alpha and repairs non-finite values', () {
      final cases = <double, double>{
        -1: 0,
        0: 0,
        0.25: 0.25,
        1: 1,
        2: 1,
        double.nan: 1,
        double.infinity: 1,
        double.negativeInfinity: 1,
      };
      for (final entry in cases.entries) {
        final canvas = paintWith(alpha: entry.key);
        expect(
          canvas.draws.single.paint.color.a,
          closeTo(entry.value, 0.001),
          reason: 'alpha ${entry.key}',
        );
      }
    });

    test('a non-positive or non-finite size falls back to a scale of 1', () {
      for (final size in <double>[
        0,
        -1,
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        final canvas = paintWith(size: size);
        expect(
          canvas.draws.single.path.getBounds().height,
          closeTo(10, 0.001),
          reason: 'size $size',
        );
      }
    });

    test('a non-positive unitsPerEm falls back to 1000', () {
      for (final upem in <int>[0, -1, -1000]) {
        final canvas = paintWith(size: 100, unitsPerEm: upem);
        expect(
          canvas.draws.single.path.getBounds().height,
          closeTo(1, 0.001),
          reason: 'unitsPerEm $upem',
        );
      }
    });

    test('zero, NaN size and wild alpha do not throw together', () {
      final canvas = RecordingCanvas();
      expect(
        () =>
            colorGlyph(<ColorLayer>[colorLayer(paint: solidPaint(alpha: 2))])
                .paint(canvas, size: double.nan, unitsPerEm: 0),
        returnsNormally,
      );
      expect(canvas.draws, hasLength(1));
    });
  });

  // --- Gradients -------------------------------------------------------------

  group('gradient paints', () {
    for (final kind in <PaintKind>[
      PaintKind.linear,
      PaintKind.radial,
      PaintKind.sweep,
    ]) {
      test('${kind.name} builds a shader and survives every extend mode', () {
        for (final extend in <String>['pad', 'repeat', 'reflect', 'mystery']) {
          final canvas = RecordingCanvas();
          expect(
            () => colorGlyph(<ColorLayer>[
              colorLayer(
                paint: gradientPaint(kind: kind, extend: extend),
              ),
            ]).paint(canvas, size: 24, flipY: false),
            returnsNormally,
            reason: '$kind / $extend',
          );
          expect(canvas.draws.single.paint.shader, isA<ui.Gradient>());
        }
      });
    }

    test('a forward sweep keeps a valid range after the y flip', () {
      for (final flipY in <bool>[true, false]) {
        final canvas = RecordingCanvas();
        colorGlyph(<ColorLayer>[
          colorLayer(paint: gradientPaint(kind: PaintKind.sweep)),
        ]).paint(canvas, size: 24, flipY: flipY);
        expect(canvas.draws.single.paint.shader, isA<ui.Gradient>());
      }
    });

    test('sweep angles survive equal, reversed and non-finite values', () {
      final cases = <(double, double)>[
        (0, 0), // COLR: equal angles mean a full circle
        (360, 360),
        (360, 0),
        (270, 90),
        (double.nan, double.infinity),
        (0, double.nan),
        (double.negativeInfinity, 90),
      ];
      for (final angles in cases) {
        for (final flipY in <bool>[true, false]) {
          final canvas = RecordingCanvas();
          expect(
            () => colorGlyph(<ColorLayer>[
              colorLayer(
                paint: gradientPaint(
                  kind: PaintKind.sweep,
                  startAngle: angles.$1,
                  endAngle: angles.$2,
                ),
              ),
            ]).paint(canvas, size: 24, flipY: flipY),
            returnsNormally,
            reason: '${angles.$1}..${angles.$2}, flipY $flipY',
          );
          expect(canvas.draws.single.paint.shader, isA<ui.Gradient>());
        }
      }
    });

    test('a gradient without stops falls back to a plain solid paint', () {
      final canvas = RecordingCanvas();
      colorGlyph(<ColorLayer>[
        colorLayer(
          paint: gradientPaint(
            kind: PaintKind.linear,
            stops: const <ColorStop>[],
          ),
        ),
      ]).paint(canvas, size: 24);
      expect(canvas.draws.single.paint.shader, isNull);
    });

    test('a solid paint keeps its RGB channels', () {
      final canvas = RecordingCanvas();
      colorGlyph(<ColorLayer>[colorLayer(paint: solidPaint(color: 0xFF00FF00))])
          .paint(canvas, size: 24);
      expect(canvas.draws.single.paint.color.g, closeTo(1, 0.001));
    });
  });

  // --- Layer ceiling ---------------------------------------------------------

  group('COLR layer ceiling', () {
    test(
      'stops at the MAX_COLOR_LAYERS value declared in rust/src/limits.rs',
      () {
        final limit = rustColorLayerLimit();
        final canvas = RecordingCanvas();
        colorGlyph(List<ColorLayer>.generate(limit + 3, (_) => colorLayer()))
            .paint(canvas, size: 24);
        expect(canvas.draws, hasLength(limit));
      },
    );
  });
}
