## 0.1.0

### 📖 Read

- 📐 **Outlines & hinting** through the `skrifa` 0.50 scaler. Hinting never silently changes linear bounds or advance; `outline` returns the scaler that ran, `outlines` draws a run through one scaler.
- 📄 **Any table**: raw bytes plus a structured `GSUB` / `GPOS` view. `extendedTables()` structures `SVG `, `gasp`, `meta`, `BASE` and AAT and reports which optional tables are present.
- 🎨 **Color & bitmap**: `COLR`/`CPAL` glyphs (with a Dart `paint` helper) and `sbix` / `CBDT` / `EBDT` strikes. Vertical metrics come from `vhea` / `vmtx` / `VORG`.
- ∑ **`MATH`**, **`VARC`** composites, **`cmap` format 14** variation selectors, and **`avar` / `avar2`** coordinate remapping.

### 🧩 Shape

- 🪄 `shape()` applies `GSUB` and `GPOS` instead of only describing them: every substitution and positioning type, original and 2026 v2 subtables, with feature variations resolved at the current variation location.
- 🐞 Shaping fixes: mark-filtering sets are honoured, ligatures no longer reach across ignored glyphs, cursive attachment writes its correction to `yOffset` (not `yAdvance`), and mark lookups respect the lookup flags.

### ✍️ Write

- 🏗 `buildFont` compiles contours into a `.ttf`: variable fonts (`fvar` / `gvar` / `STAT`), ligatures, `ss01`/`cv01` alternates, composite glyphs, `COLR` v0, `avar`, `MVAR`, `vhea`/`vmtx`, TrueType hinting, verbatim tables and `cmap` format 14.
- 🔧 `modifyFont` patches metadata, kerning, ligatures and substitutions while leaving outlines and `cmap` untouched.
- ✂️ `subsetFont` keeps only chosen code points or glyphs; `withVariations()` returns a handle pinned to one variation location.
- 🧩 **Typed patch APIs** for existing fonts: `addBitmapStrikes`, `addSubstitutions` (with 2026 v2 output), `addColorPaints`, `addFeatureVariations`, `addMathTable`, `addVarcGlyphs`, `addSvgDocuments`, `addVerticalOrigins` and `addRawTables`.

### 🌐 Web

- ⚡ The crate compiles to WebAssembly and the API is unchanged. The threaded module needs cross-origin isolation (`COOP`/`COEP`); `example/web/coi_serviceworker.js` or `scripts/coop_server.py` provides it, and the app must be built with `--no-web-resources-cdn`.

### 📦 Packaging

- 🍎 Added SwiftPM support for iOS and macOS: apps link a committed prebuilt `fontations.xcframework` instead of compiling Rust during the Xcode build. CocoaPods still compiles from source when SwiftPM is off.

### 🤖 CI & Dev

- 🛠 CI runs six jobs — `rust`, `dart`, `web`, `fuzz`, `artifacts` and `macos` — and fails when the committed XCFramework no longer matches `rust/`.
- ⬆️ Upgraded to the fontations 2026-11-10 release (`read-fonts` 0.47, `skrifa` 0.50, `write-fonts` 0.56).