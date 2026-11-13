// Requires the host Rust library:
//   (cd rust && cargo build --release) && flutter test
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fontations/fontations.dart';

/// A 840 x 60 bar: the smallest thing that looks like a drawn glyph.
GlyphContour bar(double y) => GlyphContour(
  points: [
    ContourPoint(x: 80, y: y - 30, onCurve: true),
    ContourPoint(x: 920, y: y - 30, onCurve: true),
    ContourPoint(x: 920, y: y + 30, onCurve: true),
    ContourPoint(x: 80, y: y + 30, onCurve: true),
  ],
);

/// A minimal font with one 'A' glyph, used by the reader tests below.
Future<Uint8List> oneGlyphFont(String family, {double? advanceWidth}) =>
    buildFont(
      request: FontBuildRequest(
        familyName: family,
        unitsPerEm: 1000,
        ascender: 800,
        descender: -200,
        glyphs: [
          GlyphSpec(
            codePoint: 0x41,
            contours: [bar(430)],
            advanceWidth: advanceWidth,
            masters: const [],
            alternates: const [],
            components: const [],
            colorLayers: const [],
          ),
        ],
        axes: const [],
        instances: const [],
        kernPairs: const [],
        ligatures: const [],
        rawTables: const [],
        variationSelectors: const [],
        palette: Uint32List(0),
      ),
    );

void main() {
  setUpAll(initFontations);

  test('reports the versions it was built against', () {
    expect(fontationsVersion(), contains('skrifa'));
  });

  test('builds a font and reads it back', () async {
    final bytes = await oneGlyphFont('UnitTest', advanceWidth: 600);

    final info = readFontInfo(bytes: bytes);
    expect(info.names.family, 'UnitTest');
    expect(info.metrics.unitsPerEm, 1000);
    expect(info.metrics.glyphCount, 2); // .notdef + A

    final font = Font.fromBytes(bytes: bytes);
    expect(font.charToGlyph(codePoint: 0x41), 1);
    expect(font.advanceWidth(glyphId: 1, variations: const []), 600);
  });

  test('shapes a run of text', () async {
    final bytes = await buildFont(
      request: FontBuildRequest(
        familyName: 'Shaped',
        unitsPerEm: 1000,
        glyphs: [
          GlyphSpec(
            codePoint: 0x41,
            contours: [bar(430)],
            masters: const [],
            alternates: const [],
            components: const [],
            colorLayers: const [],
          ),
          GlyphSpec(
            codePoint: 0x56,
            contours: [bar(430)],
            masters: const [],
            alternates: const [],
            components: const [],
            colorLayers: const [],
          ),
        ],
        kernPairs: const [KernPair(left: 0x41, right: 0x56, value: -80)],
        axes: const [],
        instances: const [],
        ligatures: const [],
        rawTables: const [],
        variationSelectors: const [],
        palette: Uint32List(0),
      ),
    );

    final font = Font.fromBytes(bytes: bytes);
    final result = font.shape(text: 'AV', variations: const []);
    expect(result.glyphs.map((glyph) => glyph.glyphId), [1, 2]);
    // Two ems of advance, minus the 80 unit kern.
    expect(result.advance, 1920);
  });

  test('draws outlines through the skrifa 0.50 scaler', () async {
    final font = Font.fromBytes(bytes: await oneGlyphFont('Scaler'));
    final glyphId = font.charToGlyph(codePoint: 0x41)!;

    final plain = await font.outline(
      glyphId: glyphId,
      size: 48,
      variations: const [],
    );
    expect(plain.elements, isNotEmpty);
    expect(plain.format, 'glyf');
    expect(plain.scaler.outlineSource, 'glyf');
    expect(plain.scaler.isHinted, isFalse);
    expect(plain.scaler.hintEngine, isNull);
    expect(plain.scaler.dropoutControl, 'simple');
    expect(plain.advanceWidth, closeTo(48.0, 0.01));

    const hinting = HintingSpec(
      engine: HintEngineKind.auto,
      target: RasterTargetKind.mono,
      preserveLinearMetrics: true,
    );
    final hinted = await font.outline(
      glyphId: glyphId,
      size: 24,
      variations: const [],
      hinting: hinting,
    );
    expect(hinted.scaler.hintEngine, 'auto');
    expect(hinted.scaler.isHinted, isTrue);
    expect(hinted.scaler.hintedPpem, 24);
    expect(hinted.scaler.drawnAdvance, isNotNull);
    expect(hinted.scaler.symmetricSmoothing, isNull);

    // A batch must agree with a single draw.
    final batch = await font.outlines(
      glyphIds: [glyphId, glyphId],
      size: 24,
      variations: const [],
      hinting: hinting,
    );
    expect(batch, hasLength(2));
    for (final outline in batch) {
      expect(outline.scaler, hinted.scaler);
      expect(outline.advanceWidth, hinted.advanceWidth);
      expect(
        outline.elements.map((e) => e.points.toList()).toList(),
        hinted.elements.map((e) => e.points.toList()).toList(),
      );
    }

    // Hinting needs a size: font units stay unhinted even with a spec.
    final unscaled = await font.outline(
      glyphId: glyphId,
      variations: const [],
      hinting: hinting,
    );
    expect(unscaled.scaler.isHinted, isFalse);
    expect(unscaled.scaler.hintEngine, isNull);
  });
}
