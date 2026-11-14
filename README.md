# fontations

<div align="center">
   <a href="https://runoob-coder.github.io/fontations-flutter-plugin/" target="_blank" rel="noopener">
      <img src="https://github.com/runoob-coder/fontations-flutter-plugin/blob/main/googlefonts.svg" width="200" style="width: 200px;" alt="fontations">
   </a>
</div>

Flutter bindings for the [fontations](https://github.com/googlefonts/fontations) Rust font stack, generated with [flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge).

Dart can read OpenType fonts directly — names, metrics, glyphs, outlines and layout tables — and write fonts from contours you draw. No platform text stack is involved, and variable fonts work at any location.

[![Pub Version](https://img.shields.io/pub/v/fontations.svg)][pub]
[![API Reference](https://img.shields.io/badge/API-Reference-0175C2.svg)](https://pub.dev/documentation/fontations/latest/)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/runoob-coder/fontations-flutter-plugin)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![CI](https://img.shields.io/github/actions/workflow/status/runoob-coder/fontations-flutter-plugin/ci.yml?label=CI)](https://github.com/runoob-coder/fontations-flutter-plugin/actions/workflows/ci.yml)
[![Web preview](https://img.shields.io/badge/demo-Web-blue)](https://runoob-coder.github.io/fontations-flutter-plugin/)
[![GitHub stars](https://img.shields.io/github/stars/runoob-coder/fontations-flutter-plugin.svg?style=social)][GitHub]

English | [简体中文](https://github.com/runoob-coder/fontations-flutter-plugin/blob/main/README_CN.md)

## 🚀 Getting started

```dart
import 'package:flutter/services.dart' show rootBundle;
import 'package:fontations/fontations.dart';

await initFontations(); // once, before anything else

final bytes = await rootBundle
    .load('assets/fonts/Inter.ttf')
    .then((data) => data.buffer.asUint8List());

final font = Font.fromBytes(bytes: bytes);
print(font.info().names.family);        // Inter
print(font.info().metrics.unitsPerEm);  // 2048

final glyphId = font.charToGlyph(codePoint: 'A'.codeUnitAt(0))!;
final outline = await font.outline(
  glyphId: glyphId,
  size: 48,
  variations: const [VariationSetting(tag: 'wght', value: 700)],
);
final path = outline.toPath(); // draw it with a CustomPainter
```

> [!NOTE]
> - Pass `index` to `Font.fromBytes` to pick a face out of a `.ttc` file. `Font.countFonts` tells you how many there are.
> - `size: null` gives font units instead of pixels. Axis values are in **user space** (`wght: 700`), just like CSS `font-variation-settings`.
> - `outline` and `outlines` are async; other `Font` reads are synchronous. Every font-writing function is async.
> - A `Font` keeps the whole file in Rust. Reuse the handle instead of parsing the same bytes again.
> - `woff` / `woff2` are compressed containers; decompress them first.

## 📖 Reading a font

### ✒️ Outlines and hinting

`Font.outline` draws through the `skrifa` 0.50 scaler and returns path elements, bounds, advance width and a `scaler` field describing the hint engine that ran. `Font.outlines` handles a list of glyphs with one scaler. Use `hinting: HintingSpec(...)` to choose an engine and raster target; the older `hinted: true` still works.

Outlines stay linearly scaled: hinting never silently changes `bounds` or `advanceWidth`. The plugin returns paths, not pixels — rasterization is Flutter's canvas. `GlyphOutline.toPath()` flips Y for you.

### 🗂️ Any table

`tableData(tag)` returns the raw bytes of any table, offsets relative to the start of that table. `hasTable` and `tableLength` answer the obvious questions. For `GSUB` and `GPOS`, `layout()` gives a structured view of scripts, languages and features.

```dart
final gsub = font.tableData(tag: 'GSUB'); // null when absent
print(font.layout(table: 'GSUB').single.features.map((f) => f.tag));
```

`extendedTables()` structures `SVG ` documents, `gasp` ranges and `meta` entries, and reports whether `BASE`, the AAT tables, `cvar`, `VVAR`, `MVAR`, `DSIG` and `hdmx` are present.

### 🎨 Color, bitmaps and vertical text

- `colorPalettes()` / `colorGlyph()` flatten `COLR` glyphs into layers. `ColorGlyphInfo.paint(canvas, size:, unitsPerEm:)` draws them; gradients are already resolved against the palette.
- `bitmapStrikes()` / `bitmapGlyph()` read `sbix`, `CBDT` and `EBDT` strikes, decoded to RGBA (or raw PNG for `sbix`).
- `verticalMetrics()`, `verticalAdvance()` and `verticalOrigin()` read `vhea`, `vmtx` and `VORG`. `attributes()`, `glyphName()` and `nameRecords()` cover style info, glyph names and localized names.

### 🧮 MATH, VARC, variation selectors and axis maps

- `hasMath()`, `mathConstants({ppem})`, `mathGlyphInfo()` and `mathVariants(glyphId, axis, {ppem})` expose the `MATH` data: constants, per glyph corrections and kerns, ready-made delimiter sizes and assembly parts. `value` and `deltaPx` are separate because a device table adjusts by whole pixels. The plugin returns data, it does not lay out formulas.
- `hasVarc()` and `varcComponents()` return the parts of a `VARC` composite, with transforms, axis values and whether its condition holds. `outline()` already flattens the composite into its final outline.
- `mapVariant(codePoint:, selector:)` and `variantMappings()` read `cmap` format 14.
- `avarInfo()` and `normalizedCoords()` show how `avar` and `avar2` remap an axis. Every API that takes `variations` applies these steps internally, so these are mainly for inspection.

## 🔤 Shaping

`layout()` describes the layout tables; `shape()` applies them. It maps text through `cmap`, runs the selected `GSUB` and `GPOS` rules, and returns positioned glyphs.

```dart
final result = font.shape(
  text: 'ffi',
  size: 48,
  variations: const [],
  features: ['liga', 'kern'],
);
for (final glyph in result.glyphs) {
  // glyph.glyphId, glyph.xAdvance, glyph.xOffset, glyph.yOffset, glyph.cluster
}
```

`script` and `language` are four-character OpenType tags; omitted, the font's default script and language are used. `features: null` enables the usual defaults (`kern`, `liga`, `ccmp`, `mark`, `mkmk`, `calt`, …), a list names exactly the features to apply, and an empty list turns everything off — useful for comparing shaped and unshaped output. `cluster` is the index of the source character, so a ligature covers several and a decomposition shares one.

Covered: all `GSUB` substitutions (single, multiple, alternate, ligature, contextual, chained contextual, reverse chain) and `GPOS` positioning (single, pair, cursive, mark-to-base / ligature / mark, contextual). Both the original and the 2026 v2 subtable encodings are read. Feature variations are applied at the current variation location: condition sets (axis ranges, variable values, AND/OR/NOT) select a record that replaces the lookup lists of named features, and version 1.1 lookup variations are applied too.

This is a level 1 shaper, not HarfBuzz. There is no Unicode script detection, normalization or cluster splitting, and no vertical or right-to-left runs. Latin, Cyrillic and Greek scripts are supported; use the platform text stack for Arabic and Indic.

## ✍️ Writing a font

### 📐 From contours

`buildFont` compiles contours in font units (Y up) into a `.ttf`, which you can register with `FontLoader` and use directly in a `Text` widget:

```dart
final bytes = await buildFont(
  request: FontBuildRequest(
    familyName: 'MyHandwriting',
    unitsPerEm: 1000,
    ascender: 800,
    descender: -200,
    glyphs: [
      GlyphSpec(codePoint: '一'.runes.first, contours: myContours, advanceWidth: 1000),
    ],
  ),
);
await (FontLoader('MyHandwriting1')
      ..addFont(Future.value(ByteData.sublistView(bytes))))
    .load();
```

Consecutive off-curve points follow TrueType semantics (implied midpoints). The example glyph editor page ([live demo](https://runoob-coder.github.io/fontations-flutter-plugin/)) demonstrates the full draw-and-export flow.

What else `FontBuildRequest` can carry:

| Field | Result |
| --- | --- |
| `axes`, `instances`, `GlyphSpec.masters` | A variable font with `fvar`, `gvar` and `STAT`. |
| `kernPairs`, `ligatures` | `GPOS` kerning and `GSUB` ligatures. |
| `GlyphSpec.alternates` | Discrete `GSUB` substitutions such as `ss01` / `cv01`, turned on with `FontFeature`. |
| `GlyphSpec.components` | Composite glyphs that reuse other glyphs from the same request. |
| `palette`, `GlyphSpec.colorLayers` | `COLR` v0 color glyphs with a `CPAL` palette. |
| `verticalMetrics`, `GlyphSpec.instructions`, `rawTables`, `variationSelectors` | `vhea`/`vmtx`, TrueType hinting, verbatim tables, `cmap` format 14. |
| `subfamilyName`, `designer`, `license`, `version` | `name` and `OS/2` metadata. |

Variable fonts need **point compatible** masters: same contour count, same point count, same order. The example resamples every stroke to a fixed number of points to guarantee that; incompatible masters are rejected instead of producing a broken font. All axis values are in user space. `VariationAxisSpec.mappings` writes `avar`, and when every master declares `advanceWidth` the font also gets `HVAR` plus `MVAR` for global metrics (`hasc`, `hdsc`, `hlgp`, `hcla`).

### 🩹 Patching an existing font

`modifyFont` rewrites only what the request names — metadata, kerning, ligatures and substitutions — and keeps outlines, `cmap` and glyph ids untouched, so existing shaping data stays valid.

The `add*` functions install individual tables. They work on any font, including third-party ones, and leave every table they do not mention unchanged:

| Function | Writes |
| --- | --- |
| `addBitmapStrikes` | `sbix` bitmap strikes. |
| `addSubstitutions` | `GSUB` multiple / alternate / contextual / reverse-chain lookups, original or 2026 v2 form. |
| `addColorPaints` | `COLR` v1 paint graphs and `CPAL`. |
| `addFeatureVariations` | Version 1.1 `GSUB` / `GPOS` feature variations: condition sets and feature table substitutions. |
| `addMathTable` | `MATH` constants, glyph corrections and stretchy constructions. |
| `addVarcGlyphs` | `VARC` composites, conditions, transforms and a multi item variation store. |
| `addSvgDocuments`, `addVerticalOrigins` | `SVG ` documents and `VORG` vertical origins. |
| `addRawTables` | Arbitrary table bytes, e.g. hand-built `VVAR`, `CVAR` or `CBDT`. |

For example, this turns ligatures off once the first axis reaches the upper half of its normalized range (0.5 to 1.0), by substituting an empty lookup list:

```dart
final patched = await addFeatureVariations(
  bytes: original,
  request: FeatureVariationPatchRequest(
    table: 'GSUB',
    conditions: [
      FeatureConditionSpec(
        kind: 'axisRange', axisIndex: 0,
        minValue: 0.5, maxValue: 1.0,
        defaultValue: 0, varIndex: 0xFFFFFFFF,
        children: Uint32List(0),
      ),
    ],
    records: [
      FeatureVariationRecordSpec(
        conditionIndices: Uint32List.fromList([0]),
        substitutions: [
          FeatureSubstitutionSpec(featureTag: 'liga', lookupIndices: Uint32List(0)),
        ],
      ),
    ],
  ),
);
```

Conditions are a flat list; a compound condition may only refer to earlier entries, which keeps the set acyclic. Everything written by these functions can be read back through the corresponding `Font` methods.

### 🧰 Font utilities

`subsetFont` keeps only the characters or glyphs you ask for and rewrites `cmap`, layout, hinting and variation tables — the recommended approach for shipping a large CJK font. `withVariations()` returns a handle pinned to one variation location, so later reads need not repeat the settings; it is a view, not a smaller font file.

```dart
final subset = await subsetFont(
  bytes: original,
  request: FontSubsetRequest(
    codePoints: Uint32List.fromList('ABC'.runes.toList()),
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

final bold = font.withVariations(
  variations: const [VariationSetting(tag: 'wght', value: 700)],
);
```

## 🧭 [API at a glance](https://pub.dev/documentation/fontations/latest/)

| Dart | Description |
| --- | --- |
| `initFontations()` | Loads the native library. Call once. |
| `Font.fromBytes(bytes, {index})`, `Font.countFonts(bytes)`, `readFontInfo(bytes, {index})` | Parse a font (or one face of a `.ttc`), count faces, read metadata without keeping a handle. |
| `Font.info()`, `.names()`, `.metrics()`, `.axes()`, `.namedInstances()`, `.tables()` | Names, metrics, axes, instances and table tags. |
| `Font.charToGlyph()`, `.charmapInfo()`, `.charMappings()`, `.glyphToChar()` | `cmap` lookups in both directions. |
| `Font.advanceWidth()`, `.glyphMetrics()` | Advance width, side bearing and bounds. |
| `Font.outline()`, `.outlines()`, `.outlineFormat()`, `GlyphOutline.toPath()` | Scaled outlines and the `dart:ui` path. |
| `Font.tableData()`, `.tableLength()`, `.hasTable()`, `.layout()` | Raw table bytes and structured `GSUB` / `GPOS`. |
| `Font.attributes()`, `.glyphName()`, `.nameRecords()` | Style attributes, glyph names, localized names. |
| `Font.verticalMetrics()`, `.verticalAdvance()`, `.verticalOrigin()` | Vertical text data. |
| `Font.colorPalettes()`, `.hasColorGlyph()`, `.colorGlyph()`, `ColorGlyphInfo.paint()` | `CPAL` and `COLR` glyphs. |
| `Font.bitmapStrikes()`, `.bitmapGlyph()` | Embedded bitmap strikes. |
| `Font.shape()` | Applies `GSUB` / `GPOS`, returns positioned glyphs. |
| `Font.hasMath()`, `.mathConstants()`, `.mathGlyphInfo()`, `.mathVariants()` | `MATH` constants and stretchy glyphs. |
| `Font.hasVarc()`, `.varcComponents()` | `VARC` components. |
| `Font.mapVariant()`, `.variantMappings()`, `.avarInfo()`, `.normalizedCoords()` | `cmap` format 14 and axis remapping. |
| `Font.withVariations()`, `.pinnedVariations()`, `.extendedTables()` | Pinned handle and the less common tables. |
| `fontationsVersion()` | Versions of the linked fontations crates. |
| `buildFont(request)`, `modifyFont(bytes, request)`, `subsetFont(bytes, request)` | Write, patch and subset fonts. |
| `addBitmapStrikes`, `addSubstitutions`, `addColorPaints`, `addFeatureVariations`, `addMathTable`, `addVarcGlyphs`, `addSvgDocuments`, `addVerticalOrigins`, `addRawTables` | Install individual tables in an existing font. |

## 🛠️ Development

### 📦 Layout

```text
fontations/
├── lib/                          # public Dart API (fontations.dart)
│   └── src/                      # glyph_path, color_glyph, library loader
│       └── rust/                 # generated bindings — do not edit
├── rust/
│   ├── src/
│   │   ├── api/                  # single source of the Dart API
│   │   │   ├── fontations.rs         # read
│   │   │   ├── build.rs              # write
│   │   │   └── upstream.rs           # patches
│   │   ├── *.rs                  # implementations (shaping, math, varc, ...)
│   │   └── frb_generated.rs      # generated — do not edit
│   └── fuzz/                     # fuzz targets, seeds and tests
├── cargokit/                     # Rust build for Gradle, CMake and CocoaPods
├── android/, linux/, windows/    # platform runners
├── ios/, macos/                  # SwiftPM packages with prebuilt XCFrameworks
├── scripts/                      # XCFramework, wasm, test and COOP/COEP helpers
├── test/                         # Dart unit and integration tests
└── example/                      # demo app
```

### 🔄 Regenerating bindings

After changing `rust/src/api/`:

```sh
flutter_rust_bridge_codegen generate   # cargo install flutter_rust_bridge_codegen --version 2.13.0
./scripts/build_xcframework.sh
```

The codegen version must match `Cargo.toml`; CI checks that the committed binaries match `rust/`.

### 🖥️ Platform builds

| Platform | Build |
| --- | --- |
| Android | Gradle + NDK, needs `cargo-ndk`. |
| Linux / Windows | CMake. |
| iOS / macOS | SwiftPM prebuilt XCFrameworks, or CocoaPods from source. |

Flutter picks SwiftPM or CocoaPods automatically; no app-side configuration is needed.

### 🧪 Testing

`./scripts/test.sh` is the single entry point; CI calls the same script.

```sh
./scripts/test.sh                 # all suites except on-device
./scripts/test.sh --unit          # pure Dart only
./scripts/test.sh --integration   # Dart <-> Rust boundary
./scripts/test.sh --example       # example app widget tests
./scripts/test.sh --rust          # cargo test --all-targets
./scripts/test.sh --fuzz          # deterministic fuzz target tests
./scripts/test.sh --device macos  # on-device integration_test
./scripts/test.sh --coverage      # coverage/lcov.{unit,integration,example}.info
./scripts/test.sh --no-build      # reuse an existing host library
```

Flags can be combined. The web path is compile-checked, not browser-tested.

### ⚙️ CI

- `.github/workflows/ci.yml` — eight jobs: Rust, fuzz, Dart, web, artifacts, macOS, Windows and Linux.
- `.github/workflows/deploy_web.yml` — publishes `example/` to GitHub Pages (`main`, PR previews at `/pr-<number>/`).
- `.github/workflows/build_apps.yml` — builds release APK / Windows / Linux / Web bundles of `example/`.

### 🌐 Web

```sh
./scripts/build_web.sh                  # writes example/web/pkg
cd example && flutter build web --no-web-resources-cdn
```

Copy `pkg/` into your web root. The wasm module is threaded, so the page must be cross-origin isolated (`Cross-Origin-Opener-Policy: same-origin`, `Cross-Origin-Embedder-Policy: require-corp`); `example/web/coi_serviceworker.js` adds these headers when the server cannot.

## 🚧 What is not wired up yet

- **Writing**: `CFF` / `CFF2` output (upstream has no charstring encoder), `CBDT` / `EBDT` / `EBLC` / `CBLC` bitmaps, `gvar` deltas on composite glyphs, typed requests for `VVAR` / `CVAR` (use `addRawTables` for hand-built bytes), and structured v2 `GPOS` writing.
- **Reading**: complex-script shaping (use the platform text stack), formula layout from `MATH` data, and structured `BASE` / AAT parsing — those tables are only reported as present or absent.
- **Upstream crates**: `incremental-font-transfer` and the `ift` features of `read-fonts` / `write-fonts`.
- The plugin returns paths plus scaler settings; bitmap rasterization is left to the caller.

## 📄 License

See [LICENSE](LICENSE). The bundled example font `Inter` is licensed under the SIL Open Font License 1.1. The underlying [fontations](https://github.com/googlefonts/fontations) Rust crate is licensed under its own terms — see the [upstream repository](https://github.com/googlefonts/fontations/) for details.

## 💛 Support

If [`fontations`][pub] helps you read and write fonts in Flutter, please consider supporting it.  
It only takes a few seconds and helps other Flutter developers discover the library.

- ⭐ [Star on GitHub][GitHub]
- 👍 [Like on pub.dev][pub]

## [☕️ Buy Me a Coffee](https://www.noob-coder.com/buy-me-a-coffee)

|                                                                                   Buy Me a Coffee                                                                                   |                                                                                    Donate with PayPal                                                                                     |
|:-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------:|:-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------:|
| <a href="https://ko-fi.com/noob_coder" target="_blank"><img src="https://github.com/runoob-coder/runoob-coder/raw/main/public/kofi6.webp" alt="Buy Me a Coffee at ko-fi.com" /></a> | <a href="https://paypal.me/runoobcoder" target="_blank"><img src="https://github.com/runoob-coder/runoob-coder/raw/main/public/paypal-donate-button.avif" alt="Donate with PayPal" /></a> |

[pub]: https://pub.dev/packages/fontations
[GitHub]: https://github.com/runoob-coder/fontations-flutter-plugin
