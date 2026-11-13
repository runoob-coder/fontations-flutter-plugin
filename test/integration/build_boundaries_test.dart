// Native-backed write API tests; needs the host Rust library.
@TestOn('vm')
library;

import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fontations/fontations.dart';

import '../helpers/fixtures.dart';
import '../helpers/matchers.dart';

void main() {
  setUpAll(initFontations);

  final oneGlyph = <GlyphSpec>[glyphSpec(0x41, advanceWidth: 600)];

  // --- buildFont validation --------------------------------------------------

  group('buildFont request validation', () {
    test('a font needs at least one glyph', () async {
      await expectLater(
        buildFont(request: buildRequest()),
        throwsFontError('at least one glyph is required'),
      );
    });

    test('a font needs a family name', () async {
      await expectLater(
        buildFont(
          request: buildRequest(familyName: '', glyphs: oneGlyph),
        ),
        throwsFontError('family name must not be empty'),
      );
    });

    test('two glyphs cannot claim the same code point', () async {
      await expectLater(
        buildFont(
          request: buildRequest(
            glyphs: <GlyphSpec>[glyphSpec(0x41), glyphSpec(0x41)],
          ),
        ),
        throwsFontError('duplicate code point'),
      );
    });
  });

  // --- unitsPerEm boundaries -------------------------------------------------

  group('unitsPerEm is clamped to the TrueType range', () {
    // -1 arrives as u32::MAX and is clamped to the upper bound.
    const cases = <int?, int>{
      0: 16,
      1: 16,
      16: 16,
      1000: 1000,
      16384: 16384,
      65536: 16384,
      -1: 16384,
      null: 1000,
    };

    for (final entry in cases.entries) {
      final requested = entry.key;
      test('unitsPerEm $requested -> ${entry.value}', () async {
        final bytes = await buildFont(
          request: buildRequest(unitsPerEm: requested, glyphs: oneGlyph),
        );
        expect(readFontInfo(bytes: bytes).metrics.unitsPerEm, entry.value);
      });
    }
  });

  // --- Normal build and patch round trips ------------------------------------

  group('build and patch round trips', () {
    test(
      'a minimal font reads back names, metrics, cmap and advance',
      () async {
        final bytes = await buildFont(
          request: buildRequest(familyName: 'RoundTrip', glyphs: oneGlyph),
        );
        final info = readFontInfo(bytes: bytes);
        expect(info.names.family, 'RoundTrip');
        expect(info.metrics.unitsPerEm, 1000);
        expect(info.metrics.glyphCount, 2); // .notdef + A
        expect(countFonts(bytes: bytes), 1);

        final font = Font.fromBytes(bytes: bytes, index: 0);
        expect(font.charToGlyph(codePoint: 0x41), 1);
        expect(
          font.advanceWidth(glyphId: 1, variations: const <VariationSetting>[]),
          600,
        );
        expect(font.tables(), contains('head'));
        expect(font.info().names.family, info.names.family);
      },
    );

    test(
      'modifyFont renames a font and leaves an empty patch readable',
      () async {
        final bytes = interBytes();
        final renamed = await modifyFont(
          bytes: bytes,
          request: modificationRequest(familyName: 'Renamed'),
        );
        expect(readFontInfo(bytes: renamed).names.family, 'Renamed');

        final untouched = await modifyFont(
          bytes: bytes,
          request: modificationRequest(),
        );
        expect(countFonts(bytes: untouched), 1);
        expect(Font.fromBytes(bytes: untouched).tables(), contains('head'));
      },
    );

    test('advanceWidth at size == unitsPerEm matches font units', () {
      final font = Font.fromBytes(bytes: interBytes());
      final glyphId = font.charToGlyph(codePoint: 0x41)!;
      const variations = <VariationSetting>[];
      final upem = readFontInfo(bytes: interBytes()).metrics.unitsPerEm;
      final unscaled = font.advanceWidth(
        glyphId: glyphId,
        variations: variations,
      )!;
      final scaled = font.advanceWidth(
        glyphId: glyphId,
        size: upem.toDouble(),
        variations: variations,
      )!;
      expect(scaled, closeTo(unscaled, 0.01));
    });

    test('an unknown variation tag is accepted without a usable axis', () {
      final font = Font.fromBytes(bytes: interBytes());
      final pinned = font.withVariations(
        variations: const <VariationSetting>[
          VariationSetting(tag: 'xxxx', value: 1),
        ],
      );
      expect(pinned.pinnedVariations().single.tag, 'xxxx');
      expect(font.pinnedVariations(), isEmpty);
      expect(
        pinned.normalizedCoords(variations: const <VariationSetting>[]),
        isNotEmpty,
      );
    });
  });

  // --- Outline data reaching the Dart extensions -----------------------------

  group('outline data flows into the Dart path helpers', () {
    test('toPath and boundsRect describe the same drawn glyph', () async {
      final font = Font.fromBytes(bytes: interBytes());
      final glyphId = font.charToGlyph(codePoint: 0x41)!;
      final outline = await font.outline(
        glyphId: glyphId,
        size: 48,
        variations: const <VariationSetting>[],
      );

      expect(outline.elements, isNotEmpty);
      expect(outline.bounds, isNotNull);
      final bounds = outline.boundsRect!;
      final pathBounds = outline.toPath().getBounds();
      expect(bounds, isNot(ui.Rect.zero));
      expect(pathBounds, isNot(ui.Rect.zero));
      expect(pathBounds.overlaps(bounds), isTrue);
      expect(
        outline.toPath(flipY: false).getBounds().top,
        greaterThanOrEqualTo(0),
      );
    });
  });
}
