// Native-backed error and boundary tests; needs the host Rust library.
// Run from the package root via ./scripts/test.sh --integration.
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fontations/fontations.dart';

import '../helpers/fixtures.dart';
import '../helpers/matchers.dart';

FontSubsetRequest subsetRequest() => FontSubsetRequest(
  codePoints: Uint32List.fromList(<int>[0x41]),
  glyphIds: Uint32List(0),
  retainGlyphIds: false,
  noHinting: false,
  passthroughUnrecognized: false,
  glyphNames: false,
  keepEverything: false,
  layoutFeatures: const <String>[],
  dropTables: const <String>[],
);

void main() {
  late Uint8List bytes;
  late Font font;
  late int glyphId;

  setUpAll(() async {
    await initFontations();
    bytes = interBytes();
    font = Font.fromBytes(bytes: bytes);
    glyphId = font.charToGlyph(codePoint: 0x41)!;
  });

  // --- Malformed font bytes --------------------------------------------------

  group('malformed font bytes are rejected', () {
    test('countFonts rejects empty and junk data', () {
      expect(
        () => countFonts(bytes: <int>[]),
        throwsFontError('not a valid font file'),
      );
      expect(
        () => countFonts(bytes: <int>[0, 1, 0, 0]),
        throwsFontError('not a valid font file'),
      );
      expect(countFonts(bytes: bytes), 1);
    });

    test('readFontInfo rejects empty and junk data', () {
      expect(
        () => readFontInfo(bytes: <int>[]),
        throwsFontError('not a valid font file'),
      );
      expect(
        () => readFontInfo(bytes: <int>[1, 2, 3]),
        throwsFontError('not a valid font file'),
      );
    });

    test('Font.fromBytes rejects empty data', () {
      expect(
        () => Font.fromBytes(bytes: <int>[]),
        throwsFontError('not a valid font file'),
      );
    });

    test('an out-of-range collection index is rejected by both readers', () {
      expect(
        () => readFontInfo(bytes: bytes, index: 5),
        throwsFontError('font index 5 is out of range'),
      );
      expect(
        () => Font.fromBytes(bytes: bytes, index: -1),
        throwsFontError('is out of range'),
      );
      expect(() => Font.fromBytes(bytes: bytes, index: 0), returnsNormally);
    });

    test('font patchers reject unusable input', () async {
      await expectLater(
        modifyFont(
          bytes: <int>[],
          request: modificationRequest(familyName: 'X'),
        ),
        throwsFontError('not a usable font file'),
      );
      await expectLater(
        subsetFont(bytes: <int>[], request: subsetRequest()),
        throwsFontError('not a valid font file'),
      );
      await expectLater(
        addRawTables(bytes: <int>[], tables: const <PatchRawTableSpec>[]),
        throwsFontError('not a usable font file'),
      );
    });

    test('a patch request with nothing to do is rejected', () async {
      await expectLater(
        addRawTables(bytes: bytes, tables: const <PatchRawTableSpec>[]),
        throwsFontError('at least one raw table is required'),
      );
    });
  });

  // --- Invalid arguments -----------------------------------------------------

  group('invalid arguments on a valid font', () {
    test('table tags must be exactly four characters', () {
      expect(
        () => font.hasTable(tag: ''),
        throwsFontError('is not a four character table tag'),
      );
      expect(
        () => font.hasTable(tag: 'TOOLONG'),
        throwsFontError('is not a four character table tag'),
      );
      expect(font.hasTable(tag: 'head'), isTrue);
    });

    test('a text run over MAX_SHAPE_CHARS is rejected', () {
      expect(
        () => font.shape(
          text: 'A' * 70000,
          variations: const <VariationSetting>[],
        ),
        throwsFontError('text is too long'),
      );
    });

    test(
      'more than MAX_VARIATION_SETTINGS is rejected, exactly 64 is fine',
      () {
        final settings = List<VariationSetting>.filled(
          65,
          const VariationSetting(tag: 'wght', value: 400),
        );
        expect(
          () => font.shape(text: 'A', variations: settings),
          throwsFontError('too many variation settings'),
        );
        expect(
          font.shape(text: 'A', variations: settings.take(64).toList()).glyphs,
          hasLength(1),
        );
      },
    );

    test('outline and outlines report a missing glyph', () async {
      await expectLater(
        font.outline(glyphId: 999999, variations: const <VariationSetting>[]),
        throwsFontError('has no outline'),
      );
      await expectLater(
        font.outline(glyphId: -1, variations: const <VariationSetting>[]),
        throwsFontError('has no outline'),
      );
      await expectLater(
        font.outlines(
          glyphIds: <int>[glyphId, 999999],
          variations: const <VariationSetting>[],
        ),
        throwsFontError('has no outline'),
      );
    });
  });

  // --- Boundary values that must not crash -----------------------------------

  group('boundary values on a valid font', () {
    test('an empty run shapes to an empty, zero-width result', () {
      final result = font.shape(
        text: '',
        variations: const <VariationSetting>[],
      );
      expect(result.glyphs, isEmpty);
      expect(result.advance, 0);
    });

    test('an empty feature list switches every feature off', () {
      expect(
        font
            .shape(
              text: 'fi',
              variations: const <VariationSetting>[],
              features: const <String>[],
            )
            .glyphs,
        hasLength(2),
      );
    });

    test(
      'invalid and unmapped code points are a miss, not a fallback glyph',
      () {
        for (final codePoint in <int>[
          -1,
          0xD800, // surrogate
          0x110000, // above U+10FFFF
          0x7FFFFFFF,
          0x10FFFF, // valid but unmapped
        ]) {
          expect(
            font.charToGlyph(codePoint: codePoint),
            isNull,
            reason: 'codePoint $codePoint',
          );
        }
        expect(font.charToGlyph(codePoint: 0x41), glyphId);
      },
    );

    test('out-of-range glyph ids return null instead of throwing', () {
      const variations = <VariationSetting>[];
      expect(
        font.advanceWidth(glyphId: 999999, variations: variations),
        isNull,
      );
      expect(font.glyphName(glyphId: 999999), isNull);
      expect(font.glyphToChar(glyphId: 999999), isNull);
      expect(font.colorGlyph(glyphId: 999999, variations: variations), isNull);
      expect(font.bitmapGlyph(glyphId: 999999), isNull);
      expect(
        font.varcComponents(glyphId: 999999, variations: variations),
        isNull,
      );
      expect(font.verticalOrigin(glyphId: 999999), isNull);
      expect(font.tableData(tag: 'ZZZZ'), isNull);
      expect(font.tableLength(tag: 'ZZZZ'), isNull);
      expect(font.mathConstants(), isNull);
      expect(font.mathVariants(glyphId: glyphId, axis: 'diagonal'), isNull);
      expect(font.mapVariant(codePoint: 0x41, selector: 0xFE00), isNull);
      expect(
        () => font.glyphMetrics(glyphId: 999999, variations: variations),
        returnsNormally,
      );
    });

    test('non-finite and non-positive outline sizes still draw', () async {
      for (final size in <double>[0, -1, double.nan, double.infinity]) {
        final outline = await font.outline(
          glyphId: glyphId,
          size: size,
          variations: const <VariationSetting>[],
        );
        expect(outline.elements, isNotEmpty, reason: 'size $size');
      }
      expect(
        await font.outlines(
          glyphIds: const <int>[],
          variations: const <VariationSetting>[],
        ),
        isEmpty,
      );
    });
  });

  // --- Initialization --------------------------------------------------------

  group('initialization', () {
    test('repeated calls are safe and keep the library usable', () async {
      await expectLater(initFontations(), completes);
      await expectLater(initFontations(), completes);
      expect(fontationsVersion(), contains('skrifa'));
      expect(font.charToGlyph(codePoint: 0x41), glyphId);
    });
  });
}
