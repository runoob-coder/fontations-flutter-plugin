import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fontations/fontations.dart';
import 'package:fontations_example/font_info_page.dart';
import 'package:fontations_example/font_source.dart';
import 'package:fontations_example/glyph_editor_page.dart';
import 'package:fontations_example/main.dart';
import 'package:fontations_example/shaping_page.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await initFontations();
    // `main()` does this before `runApp`; the pages expect a font to be open.
    await fontSource.loadBundled();
  });

  /// Makes the app see a [size] logical pixel window.
  ///
  /// `binding.setSurfaceSize` is not enough here: it only constrains the render
  /// view, while `MediaQuery` keeps reading the real window, so a page that
  /// branches on width would silently stay on the narrow layout. Overriding the
  /// view itself is what the pages actually look at.
  void setLogicalSize(WidgetTester tester, Size size) {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
  }

  Future<List<int>> fontBytes() => rootBundle
      .load('assets/fonts/Inter.ttf')
      .then((data) => data.buffer.asUint8List());

  test('reads metadata from a variable font', () async {
    final info = readFontInfo(bytes: await fontBytes());
    expect(info.names.family, 'Inter');
    expect(info.metrics.unitsPerEm, 2048);
    expect(info.metrics.isVariable, isTrue);
    expect(info.axes.map((axis) => axis.tag), contains('wght'));
    expect(info.tables, contains('glyf'));
  });

  test('maps characters and draws outlines', () async {
    final font = Font.fromBytes(bytes: await fontBytes());
    final glyphId = font.charToGlyph(codePoint: 'A'.codeUnitAt(0));
    expect(glyphId, isNotNull);

    final outline = await font.outline(
      glyphId: glyphId!,
      size: 100,
      variations: [VariationSetting(tag: 'wght', value: 700)],
    );
    expect(outline.elements, isNotEmpty);
    expect(outline.elements.first.verb, PathVerb.moveTo);
    expect(
      font.advanceWidth(glyphId: glyphId, size: 100, variations: const []),
      greaterThan(0),
    );
  });

  test('writes a font from drawn contours and reads it back', () async {
    // A horizontal bar, i.e. a hand drawn 「一」.
    const bar = GlyphContour(
      points: [
        ContourPoint(x: 80, y: 380, onCurve: true),
        ContourPoint(x: 920, y: 380, onCurve: true),
        ContourPoint(x: 920, y: 480, onCurve: true),
        ContourPoint(x: 80, y: 480, onCurve: true),
      ],
    );

    final bytes = await buildFont(
      request: FontBuildRequest(
        familyName: 'DrawnTest',
        unitsPerEm: 1000,
        ascender: 800,
        descender: -200,
        glyphs: [
          GlyphSpec(
            codePoint: 0x4E00,
            contours: [bar],
            advanceWidth: 1000,
            masters: [],
            alternates: [],
            components: const [],
            colorLayers: const [],
          ),
        ],
        axes: [],
        instances: [],
        kernPairs: [],
        ligatures: const [],
        palette: Uint32List(0),
        rawTables: const [],
        variationSelectors: const [],
      ),
    );

    expect(bytes.lengthInBytes, greaterThan(200));

    final info = readFontInfo(bytes: bytes);
    expect(info.names.family, 'DrawnTest');
    expect(info.metrics.unitsPerEm, 1000);
    expect(info.metrics.glyphCount, 2); // .notdef + 一
    expect(info.tables, containsAll(['glyf', 'loca', 'cmap', 'name', 'post']));

    final font = Font.fromBytes(bytes: bytes);
    expect(font.charToGlyph(codePoint: 0x4E00), 1);

    final outline = await font.outline(
      glyphId: 1,
      size: 100,
      variations: const [],
    );
    expect(outline.elements.first.verb, PathVerb.moveTo);
    expect(outline.advanceWidth, closeTo(100, 0.001));

    // The engine has to accept it as a real font too.
    await (FontLoader(
      'DrawnTestIt',
    )..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)))).load();
  });

  test('writes a variable font with masters for one character', () async {
    // Three drawings of 「一」: thin at wght 100, default at 400, thick at 900.
    GlyphContour bar(double half) => GlyphContour(
      points: [
        ContourPoint(x: 80, y: 430 - half, onCurve: true),
        ContourPoint(x: 920, y: 430 - half, onCurve: true),
        ContourPoint(x: 920, y: 430 + half, onCurve: true),
        ContourPoint(x: 80, y: 430 + half, onCurve: true),
      ],
    );

    final bytes = await buildFont(
      request: FontBuildRequest(
        familyName: 'VariableDrawn',
        unitsPerEm: 1000,
        ascender: 800,
        descender: -200,
        glyphs: [
          GlyphSpec(
            codePoint: 0x4E00,
            contours: [bar(20)],
            advanceWidth: 1000,
            alternates: [],
            masters: [
              VariationMaster(
                coordinates: Float64List.fromList([100]),
                contours: [bar(6)],
                globalMetrics: const [],
              ),
              VariationMaster(
                coordinates: Float64List.fromList([900]),
                contours: [bar(60)],
                globalMetrics: const [],
              ),
            ],
            components: const [],
            colorLayers: const [],
          ),
        ],
        axes: const [
          VariationAxisSpec(
            tag: 'wght',
            name: 'Weight',
            minValue: 100,
            defaultValue: 400,
            maxValue: 900,
            mappings: [],
          ),
        ],
        instances: [
          NamedInstanceSpec(
            name: 'Light',
            coordinates: Float64List.fromList([100]),
          ),
          NamedInstanceSpec(
            name: 'Black',
            coordinates: Float64List.fromList([900]),
          ),
        ],
        kernPairs: const [],
        ligatures: const [],
        palette: Uint32List(0),
        rawTables: const [],
        variationSelectors: const [],
      ),
    );

    final info = readFontInfo(bytes: bytes);
    expect(info.metrics.isVariable, isTrue);
    expect(info.axes.single.tag, 'wght');
    expect(info.axes.single.minValue, 100);
    expect(info.axes.single.maxValue, 900);
    expect(info.instances.length, 2);
    expect(info.tables, containsAll(['fvar', 'gvar']));

    // Interpolating along the axis has to change the outline.
    final font = Font.fromBytes(bytes: bytes);
    final glyphId = font.charToGlyph(codePoint: 0x4E00)!;
    Future<double> heightAt(double value) async {
      final outline = await font.outline(
        glyphId: glyphId,
        size: 100,
        variations: [VariationSetting(tag: 'wght', value: value)],
      );
      final bounds = outline.bounds!;
      return bounds.yMax - bounds.yMin;
    }

    final thin = await heightAt(100);
    final regular = await heightAt(400);
    final black = await heightAt(900);
    expect(thin, lessThan(regular));
    expect(regular, lessThan(black));

    await (FontLoader(
      'VariableDrawnIt',
    )..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)))).load();
  });

  test('writes stylistic sets (ss01/ss02) as GSUB alternates', () async {
    GlyphContour bar(double y, double half) => GlyphContour(
      points: [
        ContourPoint(x: 80, y: y - half, onCurve: true),
        ContourPoint(x: 920, y: y - half, onCurve: true),
        ContourPoint(x: 920, y: y + half, onCurve: true),
        ContourPoint(x: 80, y: y + half, onCurve: true),
      ],
    );

    final bytes = await buildFont(
      request: FontBuildRequest(
        familyName: 'StyleSets',
        unitsPerEm: 1000,
        ascender: 800,
        descender: -200,
        glyphs: [
          GlyphSpec(
            codePoint: 0x4E00,
            contours: [bar(300, 20)],
            advanceWidth: 1000,
            masters: [],
            alternates: [
              StylisticAlternate(
                featureTag: 'ss01',
                contours: [bar(300, 70)], // much thicker
                advanceWidth:
                    600, // distinct advance, so substitution is observable
              ),
              StylisticAlternate(
                featureTag: 'ss02',
                contours: [bar(620, 20)], // drawn near the ascender
                advanceWidth: 200,
              ),
            ],
            components: const [],
            colorLayers: const [],
          ),
        ],
        axes: [],
        instances: [],
        kernPairs: const [],
        ligatures: const [],
        palette: Uint32List(0),
        rawTables: const [],
        variationSelectors: const [],
      ),
    );

    final info = readFontInfo(bytes: bytes);
    expect(info.tables, contains('GSUB'));
    expect(info.metrics.glyphCount, 4); // .notdef + 一 + ss01 + ss02
    expect(info.metrics.isVariable, isFalse);

    // The alternates are extra glyphs; the cmap still points at glyph 1.
    final font = Font.fromBytes(bytes: bytes);
    expect(font.charToGlyph(codePoint: 0x4E00), 1);
    expect(font.tables(), contains('GSUB'));

    const family = 'StyleSetsIt';
    await (FontLoader(
      family,
    )..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)))).load();

    // The real question is whether the text engine substitutes the glyph. Each
    // alternate has a distinct advance width, so the shaped line width tells us
    // which glyph was picked.
    double widthOf(List<ui.FontFeature> features) {
      final builder = ui.ParagraphBuilder(
        ui.ParagraphStyle(fontFamily: family, fontSize: 200),
      );
      builder.pushStyle(
        ui.TextStyle(fontFamily: family, fontSize: 200, fontFeatures: features),
      );
      builder.addText('一');
      return (builder.build()
            ..layout(const ui.ParagraphConstraints(width: 2000)))
          .maxIntrinsicWidth;
    }

    // 1000 units per em -> 200 px at a 200 px font size.
    expect(widthOf(const []), closeTo(200, 1), reason: 'default advance');
    expect(
      widthOf(const [ui.FontFeature('ss01')]),
      closeTo(120, 1),
      reason: 'ss01 should swap in the 600 unit alternate',
    );
    expect(
      widthOf(const [ui.FontFeature('ss02')]),
      closeTo(40, 1),
      reason: 'ss02 should swap in the 200 unit alternate',
    );
  });

  test('exposes raw tables, layout features and style metadata', () async {
    final bytes = await fontBytes();
    final font = Font.fromBytes(bytes: Uint8List.fromList(bytes));

    // Any table can be read as raw bytes.
    expect(font.hasTable(tag: 'GSUB'), isTrue);
    expect(font.tableData(tag: 'GSUB'), isNotNull);
    expect(font.tableData(tag: 'COLR'), isNull);
    expect(() => font.tableData(tag: 'toolong'), throwsA(isA<Object>()));

    final layout = font.layout();
    final gsub = layout.firstWhere((table) => table.table == 'GSUB');
    expect(gsub.features.map((feature) => feature.tag), contains('ss01'));
    expect(gsub.scripts, contains('latn'));
    expect(gsub.languages, contains('dflt'));

    final attributes = font.attributes();
    expect(attributes.weight, greaterThan(0));
    expect(attributes.style, StyleKind.normal);

    // `Inter` has no vertical metrics, color glyphs or embedded bitmaps.
    expect(font.verticalMetrics(), isNull);
    expect(font.colorPalettes(), isEmpty);
    expect(font.bitmapStrikes(), isEmpty);

    final charmap = font.charmapInfo();
    expect(charmap.hasMap, isTrue);
    expect(charmap.mappingCount, greaterThan(100));
    expect(font.charMappings().length, charmap.mappingCount);
  });

  test('writes STAT, HVAR and kerning', () async {
    GlyphContour bar(double half) => GlyphContour(
      points: [
        ContourPoint(x: 80, y: 430 - half, onCurve: true),
        ContourPoint(x: 920, y: 430 - half, onCurve: true),
        ContourPoint(x: 920, y: 430 + half, onCurve: true),
        ContourPoint(x: 80, y: 430 + half, onCurve: true),
      ],
    );

    final bytes = await buildFont(
      request: FontBuildRequest(
        familyName: 'Kerned',
        // No weightClass: "Bold" has to be derived from the subfamily name.
        subfamilyName: 'Bold',
        vendorId: 'NOOB',
        designer: 'Integration Test',
        unitsPerEm: 1000,
        ascender: 800,
        descender: -200,
        glyphs: [
          GlyphSpec(
            codePoint: 0x41, // A
            contours: [bar(20)],
            masters: [
              VariationMaster(
                coordinates: Float64List.fromList([100]),
                contours: [bar(6)],
                advanceWidth: 600,
                globalMetrics: const [],
              ),
              VariationMaster(
                coordinates: Float64List.fromList([900]),
                contours: [bar(60)],
                advanceWidth: 1200,
                globalMetrics: const [],
              ),
            ],
            alternates: [],
            components: const [],
            colorLayers: const [],
          ),
          GlyphSpec(
            codePoint: 0x56, // V
            contours: [bar(20)],
            masters: [],
            alternates: [],
            components: const [],
            colorLayers: const [],
          ),
        ],
        axes: const [
          VariationAxisSpec(
            tag: 'wght',
            name: 'Weight',
            minValue: 100,
            defaultValue: 400,
            maxValue: 900,
            mappings: [],
          ),
        ],
        instances: const [],
        kernPairs: const [KernPair(left: 0x41, right: 0x56, value: -80)],
        ligatures: const [],
        palette: Uint32List(0),
        rawTables: const [],
        variationSelectors: const [],
      ),
    );

    final font = Font.fromBytes(bytes: bytes);

    // OS/2: "Bold" is mapped onto weight class 700 even without weightClass.
    expect(font.attributes().weight, 700);

    // STAT and HVAR are only written for variable fonts.
    expect(font.hasTable(tag: 'STAT'), isTrue);
    expect(font.hasTable(tag: 'HVAR'), isTrue);

    // The advance width now follows the axis instead of staying constant.
    double advanceAt(double value) => font
        .glyphMetrics(
          glyphId: 1,
          variations: [VariationSetting(tag: 'wght', value: value)],
        )
        .advanceWidth!;

    expect(advanceAt(100), closeTo(600, 1));
    expect(advanceAt(400), closeTo(1000, 1));
    expect(advanceAt(900), closeTo(1200, 1));

    // The kern pair becomes a GPOS feature.
    final gpos = font.layout(table: 'GPOS').single;
    expect(gpos.features.single.tag, 'kern');
    expect(
      font.nameRecords(nameId: 9).map((record) => record.value),
      contains('Integration Test'),
    );
  });

  test('a variable font with stylistic alternates stays consistent', () async {
    // The drawing app produces exactly this combination: a weight axis plus one
    // or more `ss01` variants of the same character. It used to yield a `gvar`
    // shorter than maxp.numGlyphs and an `HVAR` whose rows were shifted onto
    // the wrong glyph ids, both without any error.
    GlyphContour bar(double half) => GlyphContour(
      points: [
        ContourPoint(x: 80, y: 430 - half, onCurve: true),
        ContourPoint(x: 920, y: 430 - half, onCurve: true),
        ContourPoint(x: 920, y: 430 + half, onCurve: true),
        ContourPoint(x: 80, y: 430 + half, onCurve: true),
      ],
    );

    final bytes = await buildFont(
      request: FontBuildRequest(
        familyName: 'VarAlt',
        unitsPerEm: 1000,
        ascender: 800,
        descender: -200,
        glyphs: [
          // Glyph 1 owns the alternate, glyph 2 declares the advance width.
          GlyphSpec(
            codePoint: 0x4E00, // 一
            contours: [bar(20)],
            masters: [],
            alternates: [
              StylisticAlternate(featureTag: 'ss01', contours: [bar(70)]),
            ],
            components: const [],
            colorLayers: const [],
          ),
          GlyphSpec(
            codePoint: 0x4E8C, // 二
            contours: [bar(20)],
            masters: [
              VariationMaster(
                coordinates: Float64List.fromList([900]),
                contours: [bar(60)],
                advanceWidth: 1200,
                globalMetrics: const [],
              ),
            ],
            alternates: [],
            components: const [],
            colorLayers: const [],
          ),
        ],
        axes: const [
          VariationAxisSpec(
            tag: 'wght',
            name: 'Weight',
            minValue: 100,
            defaultValue: 400,
            maxValue: 900,
            mappings: [],
          ),
        ],
        instances: const [],
        kernPairs: const [],
        ligatures: const [],
        palette: Uint32List(0),
        rawTables: const [],
        variationSelectors: const [],
      ),
    );

    final font = Font.fromBytes(bytes: bytes);
    final info = font.info();

    // .notdef + 一 + 二 + the ss01 alternate.
    expect(info.metrics.glyphCount, 4);
    expect(info.tables, containsAll(['fvar', 'gvar', 'HVAR', 'GSUB']));

    // 二 (glyph 2) declared the master advance and must follow the axis.
    double advanceAt(double value) => font
        .glyphMetrics(
          glyphId: 2,
          variations: [VariationSetting(tag: 'wght', value: value)],
        )
        .advanceWidth!;

    expect(advanceAt(400), closeTo(1000, 1));
    expect(advanceAt(900), closeTo(1200, 1));

    // 一 declared no master advance, so it must not move.
    double advanceOfOne(double value) => font
        .glyphMetrics(
          glyphId: 1,
          variations: [VariationSetting(tag: 'wght', value: value)],
        )
        .advanceWidth!;

    expect(advanceOfOne(400), closeTo(1000, 1));
    expect(advanceOfOne(900), closeTo(1000, 1));

    // The alternate is still reachable through GSUB and the outline it swaps
    // in is the thicker one.
    expect(font.charToGlyph(codePoint: 0x4E00), 1);
    final alternate = await font.outline(
      glyphId: 3,
      size: 1000,
      variations: const [],
    );
    final one = await font.outline(
      glyphId: 1,
      size: 1000,
      variations: const [],
    );
    expect(
      alternate.bounds!.yMax - alternate.bounds!.yMin,
      greaterThan(one.bounds!.yMax - one.bounds!.yMin),
    );
  });
  test('writes composite glyphs, ligatures and color layers', () async {
    GlyphContour box(double x0, double x1, double y0, double y1) =>
        GlyphContour(
          points: [
            ContourPoint(x: x0, y: y0, onCurve: true),
            ContourPoint(x: x1, y: y0, onCurve: true),
            ContourPoint(x: x1, y: y1, onCurve: true),
            ContourPoint(x: x0, y: y1, onCurve: true),
          ],
        );

    final bytes = await buildFont(
      request: FontBuildRequest(
        familyName: 'Extras',
        unitsPerEm: 1000,
        ascender: 800,
        descender: -200,
        palette: Uint32List.fromList([0xFFFF0000, 0xFF0000FF]),
        glyphs: [
          // The component every composite reuses.
          GlyphSpec(
            codePoint: 0x41, // A
            contours: [box(80, 400, 400, 460)],
            masters: [],
            alternates: [],
            components: [],
            colorLayers: [],
          ),
          // A composite: the same box, drawn twice.
          GlyphSpec(
            codePoint: 0x42, // B
            contours: [],
            masters: [],
            alternates: [],
            components: [
              GlyphComponent(
                codePoint: 0x41,
                dx: 0,
                dy: 0,
                useMyMetrics: false,
              ),
              GlyphComponent(
                codePoint: 0x41,
                dx: 100,
                dy: 200,
                useMyMetrics: false,
              ),
            ],
            colorLayers: [],
          ),
        ],
        ligatures: [
          LigatureSpec(
            featureTag: 'liga',
            sequence: Uint32List.fromList([0x41, 0x42]),
            contours: [box(80, 800, 400, 460)],
          ),
        ],
        axes: [],
        instances: [],
        kernPairs: [],
        rawTables: [],
        variationSelectors: [],
        verticalMetrics: VerticalMetricsSpec(ascender: 880, descender: -120),
      ),
    );

    final font = Font.fromBytes(bytes: bytes);
    expect(font.charToGlyph(codePoint: 0x42), 2);

    // The composite has to place both copies of its component.
    final outline = await font.outline(
      glyphId: 2,
      size: 100,
      variations: const [],
    );
    final top = outline.elements
        .where((e) => e.verb != PathVerb.close)
        .map((e) => e.points[1])
        .reduce((a, b) => a > b ? a : b);
    expect(top, greaterThan(60));

    // `liga` is a GSUB feature, and the ligature glyph is a third glyph.
    final gsub = font.layout(table: 'GSUB').single;
    expect(gsub.features.single.tag, 'liga');
    expect(font.info().metrics.glyphCount, 4); // .notdef + A + B + ligature

    // Vertical metrics were requested, so `vhea`/`vmtx` exist.
    final vertical = font.verticalMetrics();
    expect(vertical, isNotNull);
    expect(vertical!.ascender, 880);
  });

  test('writes a color glyph and reads its layers back', () async {
    final bytes = await buildFont(
      request: FontBuildRequest(
        familyName: 'ColorGlyph',
        unitsPerEm: 1000,
        palette: Uint32List.fromList([0xFF00FF00, 0xFF0000FF]),
        glyphs: [
          GlyphSpec(
            codePoint: 0x2764,
            contours: [
              GlyphContour(
                points: [
                  ContourPoint(x: 80, y: 380, onCurve: true),
                  ContourPoint(x: 920, y: 380, onCurve: true),
                  ContourPoint(x: 920, y: 480, onCurve: true),
                  ContourPoint(x: 80, y: 480, onCurve: true),
                ],
              ),
            ],
            masters: [],
            alternates: [],
            components: [],
            colorLayers: [
              GlyphColorLayer(
                paletteIndex: 0,
                contours: [
                  GlyphContour(
                    points: [
                      ContourPoint(x: 100, y: 400, onCurve: true),
                      ContourPoint(x: 500, y: 400, onCurve: true),
                      ContourPoint(x: 500, y: 600, onCurve: true),
                      ContourPoint(x: 100, y: 600, onCurve: true),
                    ],
                  ),
                ],
              ),
              GlyphColorLayer(
                paletteIndex: 1,
                contours: [
                  GlyphContour(
                    points: [
                      ContourPoint(x: 500, y: 400, onCurve: true),
                      ContourPoint(x: 900, y: 400, onCurve: true),
                      ContourPoint(x: 900, y: 600, onCurve: true),
                      ContourPoint(x: 500, y: 600, onCurve: true),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
        axes: [],
        instances: [],
        kernPairs: [],
        ligatures: [],
        rawTables: [],
        variationSelectors: [],
      ),
    );

    final font = Font.fromBytes(bytes: bytes);
    final palettes = font.colorPalettes();
    expect(palettes.single.colors, [0xFF00FF00, 0xFF0000FF]);

    final glyphId = font.charToGlyph(codePoint: 0x2764)!;
    expect(font.hasColorGlyph(glyphId: glyphId), isTrue);
    final color = font.colorGlyph(glyphId: glyphId, variations: const [])!;
    expect(color.format, 'colrV0');
    expect(color.layers.length, 2);
  });

  test('shapes text: applies kerning and ligatures', () async {
    GlyphContour bar(double half) => GlyphContour(
      points: [
        ContourPoint(x: 80, y: 430 - half, onCurve: true),
        ContourPoint(x: 920, y: 430 - half, onCurve: true),
        ContourPoint(x: 920, y: 430 + half, onCurve: true),
        ContourPoint(x: 80, y: 430 + half, onCurve: true),
      ],
    );

    final bytes = await buildFont(
      request: FontBuildRequest(
        familyName: 'Shaped',
        unitsPerEm: 1000,
        ascender: 800,
        descender: -200,
        glyphs: [
          GlyphSpec(
            codePoint: 0x66, // f
            contours: [bar(20)],
            advanceWidth: 500,
            masters: [],
            alternates: [],
            components: [],
            colorLayers: [],
          ),
          GlyphSpec(
            codePoint: 0x69, // i
            contours: [bar(20)],
            advanceWidth: 400,
            masters: [],
            alternates: [],
            components: [],
            colorLayers: [],
          ),
        ],
        ligatures: [
          LigatureSpec(
            featureTag: 'liga',
            sequence: Uint32List.fromList([0x66, 0x69]),
            contours: [bar(20)],
          ),
        ],
        kernPairs: const [KernPair(left: 0x66, right: 0x69, value: -80)],
        axes: [],
        instances: [],
        palette: Uint32List(0),
        rawTables: [],
        variationSelectors: [],
      ),
    );
    final font = Font.fromBytes(bytes: bytes);

    // Kerning only: two glyphs, and the pair takes 80 off the first.
    final kerned = font.shape(
      text: 'fi',
      variations: const [],
      features: ['kern'],
    );
    expect(kerned.glyphs.length, 2);
    expect(kerned.glyphs.first.cluster, 0);
    expect(kerned.glyphs.last.cluster, 1);
    // 500 + 400 - 80, in font units because no size was asked for.
    expect(kerned.advance, closeTo(820, 0.5));

    // An empty list means "no features at all": both glyphs, no kerning.
    final off = font.shape(
      text: 'fi',
      variations: const [],
      features: const [],
    );
    expect(off.glyphs.length, 2);
    expect(off.advance, closeTo(900, 0.5));

    // `liga` merges the pair into the ligature glyph.
    final ligated = font.shape(
      text: 'fi',
      variations: const [],
      features: ['liga'],
    );
    expect(ligated.glyphs.length, 1);
    expect(ligated.glyphs.single.cluster, 0);

    // A size scales everything.
    final scaled = font.shape(
      text: 'fi',
      size: 50,
      variations: const [],
      features: ['kern'],
    );
    expect(scaled.advance, closeTo(41, 0.5));

    // Absent characters still come back: they map to .notdef.
    final missing = font.shape(text: 'z', variations: const []);
    expect(missing.glyphs.single.glyphId, 0);
  });

  test('shapes a real font and reports clusters', () async {
    final font = Font.fromBytes(bytes: await fontBytes());

    final result = font.shape(text: 'fontations', variations: const []);
    expect(result.glyphs.length, 10);
    for (var i = 0; i < result.glyphs.length; i++) {
      expect(result.glyphs[i].cluster, i);
      expect(result.glyphs[i].glyphId, isNot(0));
      expect(result.glyphs[i].xAdvance, greaterThan(0));
    }
    expect(result.advance, greaterThan(0));

    // `AV` is a classic kern pair: shaping it has to come out tighter than the
    // two glyphs on their own, which is what `GPOS` pair positioning does.
    double widthOf(String text) => font
        .shape(text: text, variations: const [], features: ['kern'])
        .advance;
    expect(widthOf('AV'), lessThan(widthOf('A') + widthOf('V')));

    // The shaping page draws every glyph it gets back, so each one has to be
    // resolvable to an outline.
    final shaped = font.shape(
      text: 'To ffi AWAY',
      size: 48,
      variations: const [],
    );
    expect(shaped.glyphs, isNotEmpty);
    var drawn = 0;
    for (final glyph in shaped.glyphs) {
      final outline = await font.outline(
        glyphId: glyph.glyphId,
        size: 48,
        variations: const [],
      );
      // A space has an advance but no contours, so count what actually draws.
      if (outline.elements.isNotEmpty) drawn++;
    }
    expect(drawn, greaterThanOrEqualTo(shaped.glyphs.length - 2));
  });

  test('reads cmap format 14 variation selectors', () async {
    final bytes = await buildFont(
      request: FontBuildRequest(
        familyName: 'Uvs',
        unitsPerEm: 1000,
        glyphs: [
          GlyphSpec(
            codePoint: 0x845B, // 葛
            contours: [
              GlyphContour(
                points: [
                  ContourPoint(x: 80, y: 380, onCurve: true),
                  ContourPoint(x: 900, y: 380, onCurve: true),
                  ContourPoint(x: 900, y: 480, onCurve: true),
                  ContourPoint(x: 80, y: 480, onCurve: true),
                ],
              ),
            ],
            masters: [],
            alternates: [],
            components: [],
            colorLayers: [],
          ),
          GlyphSpec(
            codePoint: 0xE0100, // the variant drawing
            contours: [
              GlyphContour(
                points: [
                  ContourPoint(x: 80, y: 100, onCurve: true),
                  ContourPoint(x: 900, y: 100, onCurve: true),
                  ContourPoint(x: 900, y: 200, onCurve: true),
                  ContourPoint(x: 80, y: 200, onCurve: true),
                ],
              ),
            ],
            masters: [],
            alternates: [],
            components: [],
            colorLayers: [],
          ),
        ],
        variationSelectors: [
          VariationSelectorSpec(
            selector: 0xE0100,
            variants: [
              CodePointVariant(codePoint: 0x845B, variantCodePoint: 0xE0100),
            ],
          ),
        ],
        axes: [],
        instances: [],
        kernPairs: [],
        ligatures: [],
        palette: Uint32List(0),
        rawTables: [],
      ),
    );
    final font = Font.fromBytes(bytes: bytes);

    expect(font.charmapInfo().hasVariantMap, isTrue);
    final mapped = font.mapVariant(codePoint: 0x845B, selector: 0xE0100)!;
    expect(mapped.kind, 'variant');
    expect(mapped.glyphId, 2);

    // A selector the font does not name is simply absent.
    expect(font.mapVariant(codePoint: 0x845B, selector: 0xE0101), isNull);

    final all = font.variantMappings();
    expect(
      all.any(
        (entry) =>
            entry.codePoint == 0x845B &&
            entry.selector == 0xE0100 &&
            entry.glyphId == 2,
      ),
      isTrue,
    );
  });

  test('reads avar mappings and normalized coordinates', () async {
    GlyphContour bar(double half) => GlyphContour(
      points: [
        ContourPoint(x: 80, y: 430 - half, onCurve: true),
        ContourPoint(x: 920, y: 430 - half, onCurve: true),
        ContourPoint(x: 920, y: 430 + half, onCurve: true),
        ContourPoint(x: 80, y: 430 + half, onCurve: true),
      ],
    );

    final bytes = await buildFont(
      request: FontBuildRequest(
        familyName: 'Avar',
        unitsPerEm: 1000,
        glyphs: [
          GlyphSpec(
            codePoint: 0x4E00,
            contours: [bar(20)],
            advanceWidth: 1000,
            alternates: [],
            components: [],
            colorLayers: [],
            masters: [
              VariationMaster(
                coordinates: Float64List.fromList([900]),
                contours: [bar(60)],
                globalMetrics: const [],
              ),
            ],
          ),
        ],
        axes: [
          VariationAxisSpec(
            tag: 'wght',
            name: 'Weight',
            minValue: 100,
            defaultValue: 400,
            maxValue: 900,
            // Pin every coordinate to the default.
            mappings: [
              AxisValueMapSpec(from: -1, to: 0),
              AxisValueMapSpec(from: 0, to: 0),
              AxisValueMapSpec(from: 1, to: 0),
            ],
          ),
        ],
        instances: [],
        kernPairs: [],
        ligatures: [],
        palette: Uint32List(0),
        rawTables: [],
        variationSelectors: [],
      ),
    );
    final font = Font.fromBytes(bytes: bytes);

    final avar = font.avarInfo()!;
    expect(avar.version, '1.0');
    expect(avar.hasAvar2, isFalse);
    expect(avar.axes.single.tag, 'wght');
    expect(avar.axes.single.maps.length, 3);
    expect(avar.axes.single.maps.last.from, 1);
    expect(avar.axes.single.maps.last.to, 0);

    // 900 is the axis maximum, i.e. 1.0 before `avar`; the mapping pins it to
    // the default, so the master is never reached.
    final coords = font.normalizedCoords(
      variations: [VariationSetting(tag: 'wght', value: 900)],
    );
    expect(coords.length, 1);
    expect(coords.single, closeTo(0, 0.01));
  });

  test('reports MATH and VARC as absent when the font has none', () async {
    final font = Font.fromBytes(bytes: await fontBytes());

    expect(font.hasMath(), isFalse);
    expect(font.mathConstants(), isNull);
    expect(font.mathGlyphInfo(glyphId: 1), isNull);
    expect(font.mathVariants(glyphId: 1, axis: 'vertical'), isNull);

    expect(font.hasVarc(), isFalse);
    expect(font.varcComponents(glyphId: 1, variations: const []), isNull);

    expect(font.variantMappings(), isEmpty);
  });

  test('modifies an existing font without touching its outlines', () async {
    final original = await buildFont(
      request: FontBuildRequest(
        familyName: 'Before',
        unitsPerEm: 1000,
        palette: Uint32List(0),
        glyphs: [
          GlyphSpec(
            codePoint: 0x41,
            contours: [
              GlyphContour(
                points: [
                  ContourPoint(x: 80, y: 380, onCurve: true),
                  ContourPoint(x: 400, y: 380, onCurve: true),
                  ContourPoint(x: 400, y: 480, onCurve: true),
                  ContourPoint(x: 80, y: 480, onCurve: true),
                ],
              ),
            ],
            masters: [],
            alternates: [],
            components: [],
            colorLayers: [],
          ),
          GlyphSpec(
            codePoint: 0x56,
            contours: [
              GlyphContour(
                points: [
                  ContourPoint(x: 80, y: 380, onCurve: true),
                  ContourPoint(x: 400, y: 380, onCurve: true),
                  ContourPoint(x: 400, y: 480, onCurve: true),
                  ContourPoint(x: 80, y: 480, onCurve: true),
                ],
              ),
            ],
            masters: [],
            alternates: [],
            components: [],
            colorLayers: [],
          ),
        ],
        axes: [],
        instances: [],
        kernPairs: [],
        ligatures: [],
        rawTables: [],
        variationSelectors: [],
      ),
    );

    final patched = await modifyFont(
      bytes: original,
      request: FontModificationRequest(
        familyName: 'After',
        subfamilyName: 'Bold',
        designer: 'Integration Test',
        kernPairs: const [KernPair(left: 0x41, right: 0x56, value: -80)],
        alternates: [
          ExistingAlternateSpec(
            featureTag: 'ss01',
            codePoint: 0x41,
            replacementCodePoint: 0x56,
          ),
        ],
        ligatures: [],
      ),
    );

    final font = Font.fromBytes(bytes: patched);
    final names = font.nameRecords(nameId: 1);
    expect(names.map((record) => record.value), contains('After'));
    expect(font.attributes().weight, 700);

    // The outlines are untouched: A is still glyph 1.
    expect(font.charToGlyph(codePoint: 0x41), 1);
    expect(font.charToGlyph(codePoint: 0x56), 2);

    final layout = font.layout();
    expect(
      layout.firstWhere((table) => table.table == 'GPOS').features.single.tag,
      'kern',
    );
    expect(
      layout.firstWhere((table) => table.table == 'GSUB').features.single.tag,
      'ss01',
    );
  });

  test('the font source switches what the pages read', () async {
    final bytes = Uint8List.fromList(await fontBytes());

    // What `openFile` does once the picker hands back a file.
    fontSource.select(
      LoadedFont(
        name: 'Inter copy.ttf',
        bytes: bytes,
        faceCount: Font.countFonts(bytes: bytes),
      ),
    );
    expect(fontSource.current!.name, 'Inter copy.ttf');
    expect(fontSource.current!.faceCount, 1);
    // A `.ttc` face is addressed by index, so the field has to survive.
    fontSource.selectFace(0);
    expect(fontSource.current!.index, 0);

    // Going back to the bundled font keeps the opened one around.
    await fontSource.loadBundled();
    expect(fontSource.current!.name, bundledFontName);
    expect(
      fontSource.opened.map((font) => font.name),
      contains('Inter copy.ttf'),
    );
  });

  testWidgets('a file that is not a font leaves the last one on screen', (
    tester,
  ) async {
    setLogicalSize(tester, const Size(1200, 800));
    addTearDown(fontSource.loadBundled);

    await fontSource.loadBundled();
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: FontInfoPage())),
    );
    await tester.pumpAndSettle();
    expect(find.text('Inter'), findsWidgets);

    // Pick something that is definitely not a font.
    fontSource.select(
      LoadedFont(
        name: 'not-a-font.ttf',
        bytes: Uint8List.fromList(List<int>.filled(64, 7)),
        faceCount: 1,
      ),
    );
    await tester.pumpAndSettle();

    // The failure is reported, but the page is not a dead end: the font that
    // did read still fills it, and the picker is still reachable.
    expect(find.textContaining('仍显示上一个'), findsOneWidget);
    expect(find.text('Inter'), findsWidgets);
    expect(find.text('打开字体文件…'), findsOneWidget);
  });

  // A phone sized window and a desktop sized one take different branches, and
  // only rendering both proves neither of them is broken. Widgets that throw
  // during layout fail the test, which is how a nested `Expanded` in the
  // stacked layout gets caught.
  testWidgets('lays every page out at phone and desktop sizes', (tester) async {
    Future<void> render(Size size) async {
      setLogicalSize(tester, size);
      for (final page in <Widget>[
        const ExampleShell(),
        const FontInfoPage(),
        const ShapingPage(),
        const GlyphEditorPage(),
      ]) {
        // The pages expect the shell's Scaffold around them: it is what
        // provides the `Material` their chips and dropdowns look for.
        await tester.pumpWidget(MaterialApp(home: Scaffold(body: page)));
        await tester.pumpAndSettle();
      }
    }

    await render(const Size(390, 844));
    await render(const Size(1440, 900));
  });
}
