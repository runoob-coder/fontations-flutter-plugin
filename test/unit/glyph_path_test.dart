// Pure Dart tests; no Rust library.
@TestOn('vm')
library;

import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fontations/fontations.dart';

import '../helpers/fixtures.dart';

void main() {
  // --- buildPath: normal flow ------------------------------------------------

  group('buildPath', () {
    test('an empty element list produces an empty path', () {
      expect(buildPath(const <PathElement>[]).getBounds(), ui.Rect.zero);
    });

    test(
      'flips y by default so font coordinates become canvas coordinates',
      () {
        expect(
          buildPath(triangle()).getBounds(),
          const ui.Rect.fromLTRB(0, -10, 10, 0),
        );
      },
    );

    test('flipY: false keeps y-up coordinates', () {
      expect(
        buildPath(triangle(), flipY: false).getBounds(),
        const ui.Rect.fromLTRB(0, 0, 10, 10),
      );
    });

    test('scale multiplies both axes', () {
      expect(
        buildPath(triangle(), scale: 2).getBounds(),
        const ui.Rect.fromLTRB(0, -20, 20, 0),
      );
    });

    test('offset is applied after scale and y flip', () {
      expect(
        buildPath(
          triangle(),
          scale: 2,
          flipY: false,
          offsetX: 5,
          offsetY: 7,
        ).getBounds(),
        const ui.Rect.fromLTRB(5, 7, 25, 27),
      );
      expect(
        buildPath(triangle(), offsetX: 5, offsetY: 7).getBounds(),
        const ui.Rect.fromLTRB(5, -3, 15, 7),
      );
    });

    test('a zero scale collapses the path without throwing', () {
      final bounds = buildPath(triangle(), scale: 0).getBounds();
      expect(bounds.width, 0);
      expect(bounds.height, 0);
    });

    test('draws quadratic curves, flipped into canvas coordinates', () {
      final path = buildPath(<PathElement>[
        pathElement(PathVerb.moveTo, <double>[0, 0]),
        pathElement(PathVerb.quadTo, <double>[10, 10, 20, 0]),
        pathElement(PathVerb.close, <double>[]),
      ]);
      final bounds = path.getBounds();
      expect(bounds.left, 0);
      expect(bounds.right, 20);
      expect(bounds.bottom, 0);
      expect(bounds.top, inInclusiveRange(-10, 0));
    });

    test('draws cubic curves, flipped into canvas coordinates', () {
      final path = buildPath(<PathElement>[
        pathElement(PathVerb.moveTo, <double>[0, 0]),
        pathElement(PathVerb.cubicTo, <double>[0, 10, 10, 10, 10, 0]),
        pathElement(PathVerb.close, <double>[]),
      ]);
      final bounds = path.getBounds();
      expect(bounds.left, 0);
      expect(bounds.right, 10);
      expect(bounds.bottom, 0);
      expect(bounds.top, inInclusiveRange(-10, 0));
    });

    test('close needs no points and extra points are ignored', () {
      final path = buildPath(<PathElement>[
        pathElement(PathVerb.moveTo, <double>[0, 0, 99, 99]),
        pathElement(PathVerb.lineTo, <double>[10, 10, 99, 99]),
        pathElement(PathVerb.close, <double>[]),
      ]);
      expect(path.getBounds(), const ui.Rect.fromLTRB(0, -10, 10, 0));
    });
  });

  // --- buildPath: incomplete elements ---------------------------------------

  group('buildPath defensive bounds', () {
    final incomplete = <String, PathElement>{
      'moveTo (1 of 2)': pathElement(PathVerb.moveTo, <double>[1000]),
      'lineTo (1 of 2)': pathElement(PathVerb.lineTo, <double>[1000]),
      'quadTo (3 of 4)': pathElement(PathVerb.quadTo, <double>[
        1000,
        1000,
        1000,
      ]),
      'cubicTo (5 of 6)': pathElement(PathVerb.cubicTo, <double>[
        1000,
        1000,
        1000,
        1000,
        1000,
      ]),
    };

    for (final entry in incomplete.entries) {
      test('skips ${entry.key} and keeps the following complete elements', () {
        final path = buildPath(<PathElement>[entry.value, ...triangle()]);
        expect(() => path.getBounds(), returnsNormally);
        expect(path.getBounds(), const ui.Rect.fromLTRB(0, -10, 10, 0));
      });
    }

    test('accepts exactly the required number of points', () {
      expect(
        buildPath(<PathElement>[
          pathElement(PathVerb.moveTo, <double>[0, 0]),
          pathElement(PathVerb.quadTo, <double>[1, 2, 3, 4]),
          pathElement(PathVerb.cubicTo, <double>[5, 6, 7, 8, 9, 10]),
        ]).getBounds(),
        isNot(ui.Rect.zero),
      );
    });

    test('an element stream of only incomplete elements stays empty', () {
      final path = buildPath(incomplete.values);
      expect(path.getBounds(), ui.Rect.zero);
    });
  });

  // --- RectFToRect -----------------------------------------------------------

  group('RectFToRect', () {
    const rect = RectF(xMin: 0, yMin: 0, xMax: 10, yMax: 20);

    test('flips y by default', () {
      expect(rect.toRect(), const ui.Rect.fromLTRB(0, -20, 10, 0));
      expect(rect.toRect(flipY: false), const ui.Rect.fromLTRB(0, 0, 10, 20));
    });

    test('uses the same scale and offset as toPath', () {
      expect(
        rect.toRect(scale: 2, flipY: false, offsetX: 5, offsetY: 7),
        const ui.Rect.fromLTRB(5, 7, 25, 47),
      );
      expect(
        rect.toRect(scale: 2, offsetX: 5, offsetY: 7),
        const ui.Rect.fromLTRB(5, -33, 25, 7),
      );
    });

    test('normalises corners inverted by the input or a negative scale', () {
      const reversed = RectF(xMin: 10, yMin: 0, xMax: 0, yMax: 20);
      expect(reversed.toRect(), const ui.Rect.fromLTRB(0, -20, 10, 0));
      expect(
        reversed.toRect(flipY: false),
        const ui.Rect.fromLTRB(0, 0, 10, 20),
      );
      expect(rect.toRect(scale: -1), const ui.Rect.fromLTRB(-10, 0, 0, 20));
      expect(const RectF(xMin: 1, yMin: 1, xMax: 1, yMax: 1).toRect().width, 0);
    });
  });

  // --- GlyphOutlinePath ------------------------------------------------------

  group('GlyphOutlinePath', () {
    test('toPath forwards every transform argument', () {
      final outline = glyphOutline();
      expect(
        outline.toPath().getBounds(),
        const ui.Rect.fromLTRB(0, -10, 10, 0),
      );
      expect(
        outline
            .toPath(scale: 2, flipY: false, offsetX: 5, offsetY: 7)
            .getBounds(),
        const ui.Rect.fromLTRB(5, 7, 25, 27),
      );
    });

    test('boundsRect matches the flipped bounds', () {
      const bounds = RectF(xMin: 2, yMin: 3, xMax: 12, yMax: 23);
      expect(
        glyphOutline(bounds: bounds).boundsRect,
        bounds.toRect(flipY: true),
      );
    });

    test('boundsRect is null when the scaler reported no bounds', () {
      expect(glyphOutline().boundsRect, isNull);
    });

    test('an empty outline is an empty path', () {
      expect(
        glyphOutline(elements: const <PathElement>[]).toPath().getBounds(),
        ui.Rect.zero,
      );
    });
  });
}
