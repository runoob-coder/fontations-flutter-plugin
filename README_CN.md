# fontations

<div align="center">
   <a href="https://runoob-coder.github.io/fontations-flutter-plugin/">
      <img src="https://github.com/runoob-coder/fontations-flutter-plugin/blob/main/googlefonts.svg" width="200" style="width: 200px;" alt="fontations">
   </a>
</div>

为 Flutter 提供 [fontations](https://github.com/googlefonts/fontations) Rust 字体库的绑定，绑定代码由 [flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge) 自动生成。

Dart 可直接读取 OpenType 字体——名称、度量、字形、轮廓与布局表，也可将手绘轮廓编译为字体文件。全程不经过平台文本栈，可变字体可取任意坐标位置的字形。

[![Pub Version](https://img.shields.io/pub/v/fontations.svg)][pub]
[![API Reference](https://img.shields.io/badge/API-Reference-0175C2.svg)](https://pub.dev/documentation/fontations/latest/)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/runoob-coder/fontations-flutter-plugin)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![CI](https://img.shields.io/github/actions/workflow/status/runoob-coder/fontations-flutter-plugin/ci.yml?label=CI)](https://github.com/runoob-coder/fontations-flutter-plugin/actions/workflows/ci.yml)
[![Web preview](https://img.shields.io/badge/demo-Web-blue)](https://runoob-coder.github.io/fontations-flutter-plugin/)
[![GitHub stars](https://img.shields.io/github/stars/runoob-coder/fontations-flutter-plugin.svg?style=social)][GitHub]

[English](README.md) | 简体中文

## 🚀 快速开始

```dart
import 'package:flutter/services.dart' show rootBundle;
import 'package:fontations/fontations.dart';

await initFontations(); // 只需调用一次，置于其他调用之前

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
final path = outline.toPath(); // 交由 CustomPainter 绘制
```

使用须知：

- 给 `Font.fromBytes` 传 `index` 可选取 `.ttc` 集合中的某一款字体，`Font.countFonts` 用于查询字体数量。
- `size` 传 `null` 时返回字体单位而非像素。可变轴采用**用户坐标**（如 `wght = 700`），与 CSS 的 `font-variation-settings` 一致。
- `outline` / `outlines` 为异步方法，其余 `Font` 读取方法均为同步；所有写字体函数均为异步。
- `Font` 会在 Rust 侧保存整份字体。同一文件应复用句柄，避免重复解析。
- `woff` / `woff2` 为压缩容器，使用前需先解压。

## 📖 读取字体

### ✒️ 轮廓与 hinting

`Font.outline` 经由 `skrifa` 0.50 的 scaler 绘制，返回路径元素、包围盒、步进宽度，以及记录实际所用 hinting 引擎的 `scaler` 字段。`Font.outlines` 通过单一 scaler 处理一组字形。`hinting: HintingSpec(...)` 用于指定引擎与光栅目标；旧版 `hinted: true` 仍可使用。

轮廓始终按线性缩放，hinting 不会静默修改 `bounds` 与 `advanceWidth`。本插件返回路径而非像素，光栅化由 Flutter 画布负责；`GlyphOutline.toPath()` 会自动翻转 Y 轴方向。

### 🗂️ 任意表

`tableData(tag)` 返回指定表的原始字节，表内偏移相对该表起始位置；`hasTable` 与 `tableLength` 用于判断表是否存在及其大小。`GSUB` 与 `GPOS` 还可通过 `layout()` 获取结构化的 script、language 与 feature 列表。

```dart
final gsub = font.tableData(tag: 'GSUB'); // 字体缺少该表时返回 null
print(font.layout(table: 'GSUB').single.features.map((f) => f.tag));
```

`extendedTables()` 解析 `SVG ` 文档、`gasp` 区间与 `meta` 条目，并报告 `BASE`、AAT、`cvar`、`VVAR`、`MVAR`、`DSIG`、`hdmx` 等表是否存在。

### 🎨 彩色字形、位图与竖排

- `colorPalettes()` / `colorGlyph()` 将 `COLR` 字形拆分为图层，`ColorGlyphInfo.paint(canvas, size:, unitsPerEm:)` 直接绘制；渐变已按调色板解析完成。
- `bitmapStrikes()` / `bitmapGlyph()` 读取 `sbix`、`CBDT`、`EBDT` 位图并解码为 RGBA（`sbix` 亦可返回原始 PNG）。
- `verticalMetrics()`、`verticalAdvance()`、`verticalOrigin()` 读取 `vhea` / `vmtx` / `VORG`；`attributes()`、`glyphName()`、`nameRecords()` 读取样式属性、字形名与多语言名称。

### 🧮 MATH、VARC、变体选择符与轴重映射

- `hasMath()`、`mathConstants({ppem})`、`mathGlyphInfo()`、`mathVariants(glyphId, axis, {ppem})` 提供 `MATH` 表的常量、逐字形修正、kern、定界符的现成尺寸与拼装部件。`value` 与 `deltaPx` 分别返回，因为 device 表按整像素调整。本插件仅提供数据，不负责公式排版。
- `hasVarc()` / `varcComponents()` 返回 `VARC` 复合字形的部件、变换、可变坐标及其条件是否成立；`outline()` 已将复合字形展平为最终轮廓。
- `mapVariant(codePoint:, selector:)` 与 `variantMappings()` 读取 `cmap` 格式 14。
- `avarInfo()` / `normalizedCoords()` 展示 `avar` 与 `avar2` 如何重映射坐标。所有接受 `variations` 的接口内部均会完成归一化，这两个方法主要用于检视。

## 🔤 塑形

`layout()` 仅描述布局表，`shape()` 负责应用：文本经 `cmap` 映射为字形，依次应用所选的 `GSUB` / `GPOS` 规则，并返回带位置与步进的字形。

```dart
final result = font.shape(
  text: 'ffi',
  size: 48,
  variations: const [],
  features: ['liga', 'kern'],
);
for (final glyph in result.glyphs) {
  // glyph.glyphId、xAdvance、xOffset、yOffset、cluster
}
```

`script` / `language` 为四字符的 OpenType 标签，省略时采用字体的默认 script 与语言。`features: null` 启用常用默认特性（`kern`、`liga`、`ccmp`、`mark`、`mkmk`、`calt` 等）；传入列表则仅应用所列特性；传入空列表 `[]` 则全部关闭，便于对比塑形前后的差异。`cluster` 为源字符的索引，因此连字会覆盖多个字符，而一个字符也可能被拆为多个字形。

支持的规则：`GSUB` 的单替换、多替换、交替替换、连字、上下文、链式上下文、反向链替换，以及 `GPOS` 的单定位、成对定位、草书连接、mark-to-base / ligature / mark 与上下文定位。原始编码与 2026 v2 子表均支持。塑形器亦会根据当前变体位置应用 feature variations：条件集（轴区间、可变值、AND/OR/NOT）选中一条记录，替换指定特征的 lookup 列表；1.1 版的 lookup variations 同样生效。

本插件为 level 1 的 OpenType 塑形器，并非 HarfBuzz：不进行 Unicode 脚本判定、正规化与簇拆分，也不支持竖排或从右到左的行。拉丁、西里尔与希腊文字均受支持；阿拉伯文与印度文需交由平台文本栈处理。

## ✍️ 字体生成与修改

### 📐 从轮廓生成

`buildFont` 将字体单位（Y 轴朝上）下的轮廓编译为 `.ttf`，配合 `FontLoader` 注册后可直接用于 `Text` 组件渲染：

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

连续的离曲线点按 TrueType 语义处理，会自动补入隐含的中点。示例的字形编辑器页面完整演示了绘制与导出流程。

`FontBuildRequest` 还可写入以下内容：

| 字段 | 生成内容 |
| --- | --- |
| `axes`、`instances`、`GlyphSpec.masters` | 可变字体，含 `fvar`、`gvar`、`STAT`。 |
| `kernPairs`、`ligatures` | `GPOS` 字距与 `GSUB` 连字。 |
| `GlyphSpec.alternates` | `ss01` / `cv01` 等离散替换，由 `FontFeature` 启用。 |
| `GlyphSpec.components` | 复用同一请求中其他字形的复合字形。 |
| `palette`、`GlyphSpec.colorLayers` | 带 `CPAL` 调色板的 `COLR` v0 彩色字形。 |
| `verticalMetrics`、`GlyphSpec.instructions`、`rawTables`、`variationSelectors` | `vhea` / `vmtx`、TrueType hinting 指令、原样写入的表、`cmap` 格式 14。 |
| `subfamilyName`、`designer`、`license`、`version` | `name` 与 `OS/2` 元数据。 |

可变字体要求母版满足**点兼容**：轮廓数相同，且每个轮廓的点数与顺序也相同。示例通过将每一笔画重采样至固定点数来满足该要求；不满足时插件报错，不会生成损坏的字体。所有轴坐标均为用户坐标。`VariationAxisSpec.mappings` 会写入 `avar`；当每个母版均声明 `advanceWidth` 时，还将写入 `HVAR` 与 `MVAR`（支持 `hasc`、`hdsc`、`hlgp`、`hcla`）。

### 🩹 修改已有字体

`modifyFont` 仅重写请求所指定的部分——元数据、字距、连字与替换规则。轮廓、`cmap` 与字形 ID 保持不变，从而保留原有塑形数据的有效性。

`add*` 系列用于单独写入单张表，同样适用于第三方字体，未指定的表均原样保留：

| 函数 | 写入内容 |
| --- | --- |
| `addBitmapStrikes` | `sbix` 位图 strike。 |
| `addSubstitutions` | `GSUB` 多替换 / 交替替换 / 上下文 / 反向链 lookup，支持 2026 v2 编码输出。 |
| `addColorPaints` | `COLR` v1 paint graph 与 `CPAL`。 |
| `addFeatureVariations` | `GSUB` / `GPOS` 的 1.1 版 feature variations：条件集与特征表替换。 |
| `addMathTable` | `MATH` 常量、逐字形修正与拉伸构造。 |
| `addVarcGlyphs` | `VARC` 复合字形、条件、变换与 MultiItemVariationStore。 |
| `addSvgDocuments`、`addVerticalOrigins` | `SVG ` 文档与 `VORG` 竖排原点。 |
| `addRawTables` | 任意表的原始字节，例如手工构造的 `VVAR`、`CVAR`、`CBDT`。 |

以下示例在第一个可变轴走到归一化坐标 0.5 以上时，将 `liga` 的 lookup 列表替换为空列表，即关闭连字：

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

条件以扁平列表表示；复合条件只能引用排在它前面的条目，因此不会出现环。这些函数写入的表均可通过对应的 `Font` 方法读回。

### 🧰 字体工具

`subsetFont` 仅保留指定的字符或字形，并重写 `cmap`、布局、hinting 与变体表，适用于精简中文字体。`withVariations()` 返回固定在某一变体位置的句柄，后续读取无需重复传入变体设置；它仅为视图，不会生成更小的字体文件。

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

## 🧭 API 一览

| Dart | 说明 |
| --- | --- |
| `initFontations()` | 加载原生库，只需调用一次。 |
| `Font.fromBytes(bytes, {index})`、`Font.countFonts(bytes)`、`readFontInfo(bytes, {index})` | 解析字体（可选 `.ttc` 面孔）、查询面孔数、一次性读取元数据。 |
| `Font.info()`、`.names()`、`.metrics()`、`.axes()`、`.namedInstances()`、`.tables()` | 名称、度量、可变轴、命名实例与表清单。 |
| `Font.charToGlyph()`、`.charmapInfo()`、`.charMappings()`、`.glyphToChar()` | `cmap` 正向与反向查询。 |
| `Font.advanceWidth()`、`.glyphMetrics()` | 步进宽度、左边界与包围盒。 |
| `Font.outline()`、`.outlines()`、`.outlineFormat()`、`GlyphOutline.toPath()` | 缩放后的轮廓与 `dart:ui` 路径。 |
| `Font.tableData()`、`.tableLength()`、`.hasTable()`、`.layout()` | 任意表原始字节，以及结构化的 `GSUB` / `GPOS`。 |
| `Font.attributes()`、`.glyphName()`、`.nameRecords()` | 样式属性、字形名、多语言名称。 |
| `Font.verticalMetrics()`、`.verticalAdvance()`、`.verticalOrigin()` | 竖排数据。 |
| `Font.colorPalettes()`、`.hasColorGlyph()`、`.colorGlyph()`、`ColorGlyphInfo.paint()` | `CPAL` 与 `COLR` 彩色字形。 |
| `Font.bitmapStrikes()`、`.bitmapGlyph()` | 内嵌位图 strike。 |
| `Font.shape()` | 应用 `GSUB` / `GPOS`，返回定位后的字形。 |
| `Font.hasMath()`、`.mathConstants()`、`.mathGlyphInfo()`、`.mathVariants()` | `MATH` 常量与可拉伸字形。 |
| `Font.hasVarc()`、`.varcComponents()` | `VARC` 部件。 |
| `Font.mapVariant()`、`.variantMappings()`、`.avarInfo()`、`.normalizedCoords()` | `cmap` 格式 14 与轴重映射。 |
| `Font.withVariations()`、`.pinnedVariations()`、`.extendedTables()` | 固定变体位置的句柄，以及较少见的表。 |
| `fontationsVersion()` | 当前链接的 fontations 各 crate 版本。 |
| `buildFont(request)`、`modifyFont(bytes, request)`、`subsetFont(bytes, request)` | 生成、修改、子集化字体。 |
| `addBitmapStrikes`、`addSubstitutions`、`addColorPaints`、`addFeatureVariations`、`addMathTable`、`addVarcGlyphs`、`addSvgDocuments`、`addVerticalOrigins`、`addRawTables` | 为已有字体补写单张表。 |

## 🛠️ 开发说明

### 📦 项目结构

```text
fontations/
├── lib/                          # 对外公开 API（fontations.dart）
│   └── src/                      # glyph_path、color_glyph、原生库加载
│       └── rust/                 # 生成的绑定代码，勿手动修改
├── rust/
│   ├── src/
│   │   ├── api/                  # Dart API 的唯一来源
│   │   │   ├── fontations.rs         # 读
│   │   │   ├── build.rs              # 写
│   │   │   └── upstream.rs           # 补丁
│   │   ├── *.rs                  # 实现（shaping、math、varc 等）
│   │   └── frb_generated.rs      # 生成代码，勿手动修改
│   └── fuzz/                     # fuzz 目标、种子语料与测试
├── cargokit/                     # 为 Gradle、CMake、CocoaPods 编译 Rust
├── android/, linux/, windows/    # 各平台运行目录
├── ios/, macos/                  # SwiftPM 包（含预编译 XCFramework）
├── scripts/                      # XCFramework、wasm、测试与跨域隔离脚本
├── test/                         # Dart 单元与集成测试
└── example/                      # 示例应用
```

### 🔄 重新生成绑定

修改 `rust/src/api/` 后执行：

```sh
flutter_rust_bridge_codegen generate   # cargo install flutter_rust_bridge_codegen --version 2.13.0
./scripts/build_xcframework.sh
```

codegen 版本须与 `Cargo.toml` 一致；CI 会校验提交的产物是否与 `rust/` 匹配。

### 🖥️ 各平台构建

| 平台 | 构建方式 |
| --- | --- |
| Android | Gradle + NDK，需要 `cargo-ndk`。 |
| Linux / Windows | CMake。 |
| iOS / macOS | SwiftPM 预编译 XCFramework，或 CocoaPods 编译源码。 |

使用 SwiftPM 还是 CocoaPods 由 Flutter 自动决定，应用侧无需配置。

### 🧪 测试

`./scripts/test.sh` 是统一入口，CI 调用同一脚本。

```sh
./scripts/test.sh                 # 除真机外的全部套件
./scripts/test.sh --unit          # 仅纯 Dart 测试
./scripts/test.sh --integration   # Dart <-> Rust 边界
./scripts/test.sh --example       # 示例应用 Widget 测试
./scripts/test.sh --rust          # cargo test --all-targets
./scripts/test.sh --fuzz          # fuzz target 确定性测试
./scripts/test.sh --device macos  # 真机/模拟器集成测试
./scripts/test.sh --coverage      # coverage/lcov.{unit,integration,example}.info
./scripts/test.sh --no-build      # 复用已有原生库，跳过编译
```

多个参数可组合使用。Web 路径仅做编译校验，无自动化浏览器测试。

### ⚙️ 持续集成

- `.github/workflows/ci.yml` — 八个 job：Rust、fuzz、Dart、web、artifacts、macOS、Windows、Linux。
- `.github/workflows/deploy_web.yml` — 将 `example/` 发布到 GitHub Pages（`main` 及 `/pr-<number>/` PR 预览）。
- `.github/workflows/build_apps.yml` — 构建 `example/` 的 APK / Windows / Linux / Web release 包。

### 🌐 Web

```sh
./scripts/build_web.sh                  # 产物写入 example/web/pkg
cd example && flutter build web --no-web-resources-cdn
```

将 `pkg/` 部署到 Web 根目录即可。wasm 模块采用多线程，页面必须跨域隔离（`Cross-Origin-Opener-Policy: same-origin`、`Cross-Origin-Embedder-Policy: require-corp`）；服务器无法设置响应头时，可用 `example/web/coi_serviceworker.js` 补齐。

## 🚧 尚未对接的部分

- **写**：`CFF` / `CFF2` 输出（上游缺少 charstring 编码器）、`CBDT` / `EBDT` / `EBLC` / `CBLC` 位图、复合字形上的 `gvar` 增量、`VVAR` / `CVAR` 的类型化请求（可借助 `addRawTables` 写入手工构造的字节），以及结构化的 v2 `GPOS` 写入。
- **读**：复杂脚本塑形（需使用平台文本栈）、`MATH` 公式排版、`BASE` / AAT 表的结构化解析——这些表目前仅报告是否存在。
- **上游 crate**：`incremental-font-transfer` 以及 `read-fonts` / `write-fonts` 的 `ift` 特性。
- 本插件返回路径与 scaler 设置，位图光栅化由调用方完成。

## 📄 许可证

参见 [LICENSE](LICENSE)。示例内置的 Inter 字体遵循 SIL Open Font License 1.1。底层 [fontations](https://github.com/googlefonts/fontations) Rust crate 遵循其自身的许可条款，详见[上游仓库](https://github.com/googlefonts/fontations/)。

## 💛 支持

如果 [`fontations`][pub] 帮你更轻松地在 Flutter 中读写字体，欢迎支持这个项目。  
只需几秒钟，也能帮助更多 Flutter 开发者发现这个库。

- ⭐ [在 GitHub 上 Star][GitHub]
- 👍 [在 pub.dev 上点赞][pub]

## [☕️ 请我喝奶茶](https://www.noob-coder.com/buy-me-a-coffee)

<table>
<thead>
<tr>
    <th style="text-align:center;">赞赏码 WeChat</th>
    <th style="text-align:center;">支付宝 Alipay</th>
</tr>
</thead>
<tbody>
<tr>
    <td width="50%"><img src="https://raw.githubusercontent.com/runoob-coder/runoob-coder/main/public/appreciate.avif" alt="赞赏码WeChat" /></td>
    <td width="50%"><img src="https://raw.githubusercontent.com/runoob-coder/runoob-coder/main/public/alipay.avif" alt="支付宝Alipay" /></td>
  </tr>
</tbody>
</table>

[pub]: https://pub.dev/packages/fontations
[GitHub]: https://github.com/runoob-coder/fontations-flutter-plugin
