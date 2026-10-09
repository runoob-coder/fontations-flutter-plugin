// Unit tests for the package itself.
//
// They run on the Dart VM, which means the Rust library has to be built for the
// host first:
//
//   (cd rust && cargo build --release) && flutter test
//
// They are *not* run in a browser. The web build of the crate needs the
// `pkg/fontations.js` and `pkg/fontations_bg.wasm` files to be served next to
// the page *and* the two cross origin isolation headers (see
// `scripts/coop_server.py`); the `flutter test --platform chrome` harness does
// neither, so `initFontations()` there never resolves. The browser path is
// checked by hand instead:
//
//   ./scripts/build_web.sh
//   cd example && flutter build web --no-web-resources-cdn
//   python3 ../scripts/coop_server.py build/web 8080
//
// `example/integration_test/` covers the same ground on native platforms, since
// integration tests cannot run on a web device at all.
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

void main() {
  setUpAll(initFontations);

  test('reports the versions it was built against', () {
    expect(fontationsVersion(), contains('skrifa'));
  });

  test('builds a font and reads it back', () async {
    final bytes = await buildFont(
      request: FontBuildRequest(
        familyName: 'UnitTest',
        unitsPerEm: 1000,
        ascender: 800,
        descender: -200,
        glyphs: [
          GlyphSpec(
            codePoint: 0x41,
            contours: [bar(430)],
            advanceWidth: 600,
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
}
