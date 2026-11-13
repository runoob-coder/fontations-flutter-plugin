// End-to-end tests for the upstream-backed APIs. Like fontations_test.dart
// these run on the Dart VM and need the host Rust library:
//
//   (cd rust && cargo build --release) && flutter test test/upstream_test.dart
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fontations/fontations.dart';

Uint8List interBytes() =>
    File('example/assets/fonts/Inter.ttf').readAsBytesSync();

PaintNodeSpec node({
  required String kind,
  int paletteIndex = 0,
  double alpha = 1,
  int glyphId = 0,
  List<int> children = const [],
}) => PaintNodeSpec(
  kind: kind,
  paletteIndex: paletteIndex,
  alpha: alpha,
  x0: 0,
  y0: 0,
  x1: 0,
  y1: 0,
  r0: 0,
  r1: 0,
  startAngle: 0,
  endAngle: 0,
  glyphId: glyphId,
  extend: 'pad',
  compositeMode: '',
  stops: const [],
  children: Uint32List.fromList(children),
);

void main() {
  setUpAll(initFontations);

  test('subsetFont keeps only the requested characters', () async {
    final bytes = interBytes();
    final subset = await subsetFont(
      bytes: bytes,
      request: FontSubsetRequest(
        codePoints: Uint32List.fromList([0x41, 0x42]),
        glyphIds: Uint32List(0),
        retainGlyphIds: false,
        noHinting: false,
        passthroughUnrecognized: false,
        glyphNames: false,
        keepEverything: false,
        layoutFeatures: const [],
        dropTables: const [],
      ),
    );
    expect(subset.length, lessThan(bytes.length));
    final font = Font.fromBytes(bytes: subset);
    expect(font.charToGlyph(codePoint: 0x41), isNotNull);
    expect(font.charToGlyph(codePoint: 0x42), isNotNull);
    expect(font.charToGlyph(codePoint: 0x5A), isNull);
  });

  test(
    'withVariations pins a location; extendedTables lists optional tables',
    () {
      final font = Font.fromBytes(bytes: interBytes());
      final pinned = font.withVariations(
        variations: const [VariationSetting(tag: 'wght', value: 700)],
      );
      expect(pinned.pinnedVariations().single.tag, 'wght');
      expect(font.pinnedVariations(), isEmpty);
      final tables = font.extendedTables();
      expect(tables.tables, contains('head'));
      expect(tables.tables, contains('cmap'));
    },
  );

  test('addBitmapStrikes writes a strike skrifa can read', () async {
    final bytes = await addBitmapStrikes(
      bytes: interBytes(),
      strikes: [
        BitmapStrikeSpec(
          ppem: 32,
          ppi: 72,
          glyphs: [
            BitmapGlyphSpec(
              codePoint: 0x41,
              format: 'png ',
              data: Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]),
              originOffsetX: 0,
              originOffsetY: 0,
            ),
          ],
        ),
      ],
    );
    final font = Font.fromBytes(bytes: bytes);
    expect(font.hasTable(tag: 'sbix'), isTrue);
    expect(font.bitmapStrikes(), isNotEmpty);
  });

  test('addSubstitutions exposes multiple and alternate features', () async {
    final bytes = await addSubstitutions(
      bytes: interBytes(),
      request: SubstitutionPatchRequest(
        multiple: [
          MultipleSubstitutionSpec(
            featureTag: 'mlt1',
            codePoint: 0x41,
            replacementCodePoints: Uint32List.fromList([0x42, 0x43]),
          ),
        ],
        alternate: [
          AlternateSubstitutionSpec(
            featureTag: 'alt1',
            codePoint: 0x44,
            replacementCodePoints: Uint32List.fromList([0x45, 0x46]),
          ),
        ],
        contextual: const [],
        reverseChain: const [],
        useV2: false,
      ),
    );
    final features = Font.fromBytes(bytes: bytes)
        .layout(table: 'GSUB')
        .expand((table) => table.features)
        .map((feature) => feature.tag)
        .toList();
    expect(features, contains('mlt1'));
    expect(features, contains('alt1'));
  });

  test('addColorPaints writes a readable COLRv1 paint graph', () async {
    final original = interBytes();
    final glyphId = Font.fromBytes(bytes: original)
        .charToGlyph(codePoint: 0x41)!;
    final bytes = await addColorPaints(
      bytes: original,
      palette: Uint32List.fromList([0xFFFF0000, 0xFF0000FF]),
      glyphs: [
        ColorGlyphPaintSpec(
          codePoint: 0x41,
          root: 0,
          nodes: [
            node(kind: 'layers', children: [1]),
            node(kind: 'glyph', glyphId: glyphId, children: [2]),
            node(kind: 'solid', paletteIndex: 0),
          ],
        ),
      ],
    );
    final font = Font.fromBytes(bytes: bytes);
    expect(font.hasColorGlyph(glyphId: glyphId), isTrue);
    final glyph = font.colorGlyph(glyphId: glyphId, variations: const []);
    expect(glyph, isNotNull);
    expect(glyph!.layers, isNotEmpty);
  });

  test('v2 GSUB contextual and reverse-chain lookups shape text', () async {
    final bytes = interBytes();
    final plain = Font.fromBytes(bytes: bytes);
    final a = plain.charToGlyph(codePoint: 0x41)!;
    final b = plain.charToGlyph(codePoint: 0x42)!;
    final c = plain.charToGlyph(codePoint: 0x43)!;

    final patched = await addSubstitutions(
      bytes: bytes,
      request: SubstitutionPatchRequest(
        multiple: const [],
        alternate: const [],
        contextual: [
          ContextualSubstitutionSpec(
            featureTag: 'cnt2',
            backtrack: Uint32List(0),
            input: Uint32List.fromList([0x41, 0x42]),
            lookahead: Uint32List(0),
            replacementCodePoint: 0x43,
          ),
        ],
        reverseChain: [
          ReverseChainSubstitutionSpec(
            featureTag: 'rvs2',
            codePoint: 0x42,
            replacementCodePoint: 0x43,
            backtrack: Uint32List.fromList([0x41]),
            lookahead: Uint32List(0),
          ),
        ],
        useV2: true,
      ),
    );

    final font = Font.fromBytes(bytes: patched);
    List<int> shape(String text, String feature) => font
        .shape(text: text, variations: const [], features: [feature])
        .glyphs
        .map((glyph) => glyph.glyphId)
        .toList();

    expect(shape('AB', 'cnt2'), [c, b]);
    expect(shape('AB', 'rvs2'), [a, c]);
    expect(shape('A', 'cnt2'), [a]);
    expect(shape('B', 'rvs2'), [b]);
  });

  // ---------------------------------------------------------------------------
  // Feature variations, MATH, VARC, SVG / VORG and raw table patches
  // ---------------------------------------------------------------------------

  FeatureConditionSpec condition({
    required String kind,
    int axisIndex = 0,
    double minValue = 0,
    double maxValue = 1,
    int defaultValue = 0,
    int varIndex = 0xFFFFFFFF,
    List<int> children = const [],
  }) => FeatureConditionSpec(
    kind: kind,
    axisIndex: axisIndex,
    minValue: minValue,
    maxValue: maxValue,
    defaultValue: defaultValue,
    varIndex: varIndex,
    children: Uint32List.fromList(children),
  );

  VarcRegionAxisSpec region() =>
      const VarcRegionAxisSpec(axisIndex: 0, start: 0, peak: 1, end: 1);

  test(
    'addFeatureVariations keeps features and changes the shaping plan',
    () async {
      final withLookups = await addSubstitutions(
        bytes: interBytes(),
        request: SubstitutionPatchRequest(
          multiple: [
            MultipleSubstitutionSpec(
              featureTag: 'mlt1',
              codePoint: 0x41,
              replacementCodePoints: Uint32List.fromList([0x42, 0x43]),
            ),
          ],
          alternate: const [],
          contextual: const [],
          reverseChain: const [],
          useV2: false,
        ),
      );
      final patched = await addFeatureVariations(
        bytes: withLookups,
        request: FeatureVariationPatchRequest(
          table: 'GSUB',
          conditions: [condition(kind: 'variableValue', defaultValue: 1)],
          records: [
            FeatureVariationRecordSpec(
              conditionIndices: Uint32List.fromList([0]),
              substitutions: [
                FeatureSubstitutionSpec(
                  featureTag: 'mlt1',
                  lookupIndices: Uint32List(0),
                ),
              ],
            ),
          ],
        ),
      );

      final font = Font.fromBytes(bytes: patched);
      final features = font
          .layout(table: 'GSUB')
          .expand((table) => table.features)
          .map((feature) => feature.tag);
      expect(features, contains('mlt1'));
      // The selected record replaces `mlt1` with an empty feature table.
      expect(
        font.shape(text: 'A', variations: const [], features: ['mlt1']).glyphs,
        hasLength(1),
      );
    },
  );

  test('feature variation requests are validated', () async {
    final withLookups = await addSubstitutions(
      bytes: interBytes(),
      request: SubstitutionPatchRequest(
        multiple: [
          MultipleSubstitutionSpec(
            featureTag: 'mlt1',
            codePoint: 0x41,
            replacementCodePoints: Uint32List.fromList([0x42]),
          ),
        ],
        alternate: const [],
        contextual: const [],
        reverseChain: const [],
        useV2: false,
      ),
    );
    Future<Uint8List> patch(String table, String kind) => addFeatureVariations(
      bytes: withLookups,
      request: FeatureVariationPatchRequest(
        table: table,
        conditions: [condition(kind: kind)],
        records: [
          FeatureVariationRecordSpec(
            conditionIndices: Uint32List.fromList([0]),
            substitutions: [
              FeatureSubstitutionSpec(
                featureTag: 'mlt1',
                lookupIndices: Uint32List(0),
              ),
            ],
          ),
        ],
      ),
    );
    await expectLater(patch('MATH', 'variableValue'), throwsA(anything));
    await expectLater(patch('GSUB', 'mystery'), throwsA(anything));
  });

  test(
    'addMathTable round trips through the reader, including device deltas',
    () async {
      final bytes = await addMathTable(
        bytes: interBytes(),
        request: MathTableRequest(
          constants: const [
            MathConstantSpec(name: 'axisHeight', value: 250),
            MathConstantSpec(name: 'fractionRuleThickness', value: 40),
          ],
          minConnectorOverlap: 10,
          italicsCorrections: const [
            MathGlyphValueSpec(codePoint: 0x41, value: 42),
          ],
          topAccentAttachments: const [
            MathGlyphValueSpec(codePoint: 0x41, value: 300),
          ],
          extendedShapes: Uint32List.fromList([0x41]),
          kerns: [
            MathKernSpec(
              codePoint: 0x41,
              corner: 'topRight',
              heights: Float64List.fromList([10]),
              kerns: Float64List.fromList([5, 8]),
            ),
          ],
          constructions: [
            MathConstructionSpec(
              codePoint: 0x41,
              axis: 'vertical',
              variants: const [
                MathVariantSpec(variantCodePoint: 0x42, advance: 600),
              ],
              parts: const [
                MathPartSpec(
                  partCodePoint: 0x43,
                  startConnectorLength: 10,
                  endConnectorLength: 20,
                  fullAdvance: 300,
                  isExtender: true,
                ),
              ],
              italicsCorrection: 12,
              italicsDeviceStartPpem: 20,
              italicsDeviceDeltas: Int32List.fromList([3, 7]),
            ),
          ],
        ),
      );

      final font = Font.fromBytes(bytes: bytes);
      expect(font.hasMath(), isTrue);
      final constants = font.mathConstants()!;
      expect(constants.firstWhere((c) => c.name == 'axisHeight').value, 250);
      final gid = font.charToGlyph(codePoint: 0x41)!;
      final info = font.mathGlyphInfo(glyphId: gid)!;
      expect(info.italicsCorrection, 42);
      expect(info.topAccentAttachment, 300);
      expect(info.isExtendedShape, isTrue);
      expect(info.kerns.single.corner, 'topRight');

      final plain = font.mathVariants(glyphId: gid, axis: 'vertical')!;
      expect(plain.minConnectorOverlap, 10);
      expect(plain.variants.single.advance, 600);
      expect(plain.assembly!.italicsCorrection, 12);
      expect(plain.assembly!.italicsCorrectionDeltaPx, 0);
      expect(plain.assembly!.parts.single.isExtender, isTrue);
      expect(
        font
            .mathVariants(glyphId: gid, axis: 'vertical', ppem: 21)!
            .assembly!
            .italicsCorrectionDeltaPx,
        7,
      );
      expect(font.mathVariants(glyphId: gid, axis: 'horizontal'), isNull);
    },
  );

  test('addVarcGlyphs writes readable conditions and transforms', () async {
    final bytes = await addVarcGlyphs(
      bytes: interBytes(),
      request: VarcPatchRequest(
        conditions: [condition(kind: 'variableValue', defaultValue: 1)],
        deltaSets: [
          VarcDeltaSetSpec(
            entries: [
              VarcDeltaSpec(
                axes: [region()],
                deltas: Int32List.fromList([100]),
              ),
            ],
          ),
          VarcDeltaSetSpec(
            entries: [
              VarcDeltaSpec(
                axes: [region()],
                deltas: Int32List.fromList([4096]),
              ),
            ],
          ),
        ],
        glyphs: [
          VarcGlyphSpec(
            codePoint: 0x41,
            components: [
              VarcComponentSpec(
                componentCodePoint: 0x42,
                conditionIndex: 0,
                axisIndices: Uint32List.fromList([0]),
                axisValues: Float64List.fromList([0.5]),
                axisValuesDeltaSet: 1,
                transformDeltaSet: 0,
                translateX: 50,
              ),
            ],
          ),
        ],
      ),
    );

    final font = Font.fromBytes(bytes: bytes);
    expect(font.hasVarc(), isTrue);
    final gid = font.charToGlyph(codePoint: 0x41)!;
    final info = font.varcComponents(glyphId: gid, variations: const [])!;
    expect(info.components, hasLength(1));
    final component = info.components.single;
    expect(component.conditionMet, isTrue);
    expect(component.axisIndices.single, 0);
    expect(component.axisValues.single, closeTo(0.5, 1e-6));
    expect(component.transform[4], closeTo(50, 1e-6));
  });

  test('SVG, VORG and raw tables round trip through the reader', () async {
    final withSvg = await addSvgDocuments(
      bytes: interBytes(),
      documents: [
        SvgDocumentSpec(
          startCodePoint: 0x41,
          endCodePoint: 0x42,
          data: Uint8List.fromList('<svg><rect/></svg>'.codeUnits),
        ),
      ],
    );
    final withVorg = await addVerticalOrigins(
      bytes: withSvg,
      request: VerticalOriginRequest(
        defaultOriginY: 880,
        origins: const [VerticalOriginSpec(codePoint: 0x41, originY: 867)],
      ),
    );
    final bytes = await addRawTables(
      bytes: withVorg,
      tables: [
        PatchRawTableSpec(tag: 'CVAR', data: Uint8List.fromList([1, 2, 3, 4])),
      ],
    );

    final font = Font.fromBytes(bytes: bytes);
    expect(font.hasTable(tag: 'SVG '), isTrue);
    expect(font.hasTable(tag: 'VORG'), isTrue);
    expect(font.hasTable(tag: 'CVAR'), isTrue);
    expect(font.tableData(tag: 'CVAR'), [1, 2, 3, 4]);
    expect(
      font.verticalOrigin(glyphId: font.charToGlyph(codePoint: 0x41)!),
      867,
    );
    expect(
      font.verticalOrigin(glyphId: font.charToGlyph(codePoint: 0x43)!),
      880,
    );
    final extended = font.extendedTables();
    expect(extended.svgDocuments, hasLength(1));
    expect(
      extended.svgDocuments.single.preview,
      contains('<svg><rect/></svg>'),
    );
  });
}
