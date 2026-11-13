// Generated value objects need no RustLib.init().
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fontations/fontations.dart';

import '../helpers/fixtures.dart';

void main() {
  // --- Value equality --------------------------------------------------------

  group('generated value objects', () {
    test('scalar-only models compare by value and hash consistently', () {
      final pairs = <List<Object>>[
        <Object>[
          const RectF(xMin: 0, yMin: 1, xMax: 2, yMax: 3),
          const RectF(xMin: 0, yMin: 1, xMax: 2, yMax: 3),
        ],
        <Object>[
          const ColorStop(offset: 0.5, color: 0xFFAABBCC, alpha: 0.25),
          const ColorStop(offset: 0.5, color: 0xFFAABBCC, alpha: 0.25),
        ],
        <Object>[
          const ContourPoint(x: 1, y: 2, onCurve: true),
          const ContourPoint(x: 1, y: 2, onCurve: true),
        ],
        <Object>[
          const VariationSetting(tag: 'wght', value: 700),
          const VariationSetting(tag: 'wght', value: 700),
        ],
        <Object>[
          const KernPair(left: 0x41, right: 0x56, value: -80),
          const KernPair(left: 0x41, right: 0x56, value: -80),
        ],
        <Object>[scalerInfo(), scalerInfo()],
      ];
      for (final pair in pairs) {
        expect(pair[0], pair[1], reason: '${pair[0].runtimeType} equality');
        expect(
          pair[0].hashCode,
          pair[1].hashCode,
          reason: '${pair[0].runtimeType} hashCode',
        );
      }
    });

    test('a changed scalar field breaks equality', () {
      expect(
        const VariationSetting(tag: 'wght', value: 700),
        isNot(const VariationSetting(tag: 'wght', value: 701)),
      );
      expect(
        const RectF(xMin: 0, yMin: 0, xMax: 1, yMax: 1),
        isNot(const RectF(xMin: 0, yMin: 0, xMax: 2, yMax: 1)),
      );
    });

    test('nullable fields participate in equality', () {
      expect(scalerInfo(), scalerInfo());
      expect(scalerInfo(isHinted: true), isNot(scalerInfo(isHinted: false)));
      expect(
        ScalerInfo(
          hintEngine: 'auto',
          isHinted: true,
          dropoutControl: 'simple',
        ),
        isNot(scalerInfo(isHinted: true)),
      );
    });

    test('nested value objects compare by value when lists are shared', () {
      final elements = triangle();
      final a = glyphOutline(
        elements: elements,
        bounds: const RectF(xMin: 0, yMin: 0, xMax: 10, yMax: 10),
      );
      final b = glyphOutline(
        elements: elements,
        bounds: const RectF(xMin: 0, yMin: 0, xMax: 10, yMax: 10),
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('list and typed-data fields keep reference semantics', () {
      final points = Float64List.fromList(<double>[1, 2]);
      final a = PathElement(verb: PathVerb.moveTo, points: points);
      final b = PathElement(verb: PathVerb.moveTo, points: points);
      final c = PathElement(
        verb: PathVerb.moveTo,
        points: Float64List.fromList(<double>[1, 2]),
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      // FRB compares typed data by identity.
      expect(a == c, isFalse);
      expect(
        const ShapeResult(glyphs: <ShapedGlyph>[], advance: 0),
        const ShapeResult(glyphs: <ShapedGlyph>[], advance: 0),
      );
    });
  });

  // --- Request construction --------------------------------------------------

  group('request models', () {
    test('buildRequest fixtures preserve every supplied field', () {
      final request = buildRequest(
        familyName: 'Family',
        unitsPerEm: 2048,
        glyphs: <GlyphSpec>[glyphSpec(0x41, advanceWidth: 600)],
        kernPairs: const <KernPair>[
          KernPair(left: 0x41, right: 0x56, value: -80),
        ],
      );
      expect(request.familyName, 'Family');
      expect(request.unitsPerEm, 2048);
      expect(request.glyphs.single.advanceWidth, 600);
      expect(request.kernPairs.single.value, -80);
      expect(request.palette, isEmpty);
      expect(request.axes, isEmpty);
    });

    test('a modification request keeps optional fields nullable', () {
      final request = modificationRequest();
      expect(request.familyName, isNull);
      expect(request.kernPairs, isEmpty);
      expect(modificationRequest(familyName: 'Renamed').familyName, 'Renamed');
    });
  });

  // --- Enums -----------------------------------------------------------------

  group('generated enums', () {
    test('path verbs cover every element the path builder handles', () {
      expect(PathVerb.values.map((verb) => verb.name), <String>[
        'moveTo',
        'lineTo',
        'quadTo',
        'cubicTo',
        'close',
      ]);
    });

    test('paint kinds and raster targets expose the documented variants', () {
      expect(
        PaintKind.values.map((kind) => kind.name),
        containsAll(<String>['solid', 'linear', 'radial', 'sweep']),
      );
      expect(
        RasterTargetKind.values.map((target) => target.name),
        containsAll(<String>['mono', 'normal', 'light', 'lcd', 'verticalLcd']),
      );
    });
  });
}
