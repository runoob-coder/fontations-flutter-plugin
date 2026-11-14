// ignore_for_file: deprecated_member_use

// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'fontations 示例';

  @override
  String get githubTooltip => '在 GitHub 上查看';

  @override
  String get languageMenuTooltip => '语言';

  @override
  String get languageSystem => '跟随系统';

  @override
  String get themeMenuTooltip => '主题模式';

  @override
  String get themeSystem => '跟随系统';

  @override
  String get themeLight => '浅色';

  @override
  String get themeDark => '深色';

  @override
  String get openFontFile => '打开字体文件…';

  @override
  String get bundledInter => '内置 Inter';

  @override
  String get pickFontDialogTitle => '选择字体文件';

  @override
  String get saveFontDialogTitle => '保存字体文件';

  @override
  String savedTo(String path) {
    return '已保存 $path';
  }

  @override
  String openFailed(String error) {
    return '打开失败：$error';
  }

  @override
  String get none => '无';

  @override
  String get emptyValue => '（空）';

  @override
  String bytesUnit(String value) {
    return '$value 字节';
  }

  @override
  String get labelGlyphCount => '字形数';

  @override
  String get labelAxes => '可变轴';

  @override
  String get labelTables => '表';

  @override
  String get labelSize => '大小';

  @override
  String get labelDefault => '默认';

  @override
  String get labelFamily => '家族名';

  @override
  String get labelLayoutFeatures => '布局特性';

  @override
  String get labelGlyphIdA => 'A 的 glyphId';

  @override
  String fontReadError(String error) {
    return '无法读取这个字体文件\n\n$error';
  }

  @override
  String fontParseError(String error) {
    return '无法解析这个字体文件：$error';
  }

  @override
  String get unreadableTitle => '无法解析这个字体文件';

  @override
  String unreadableDetail(String error) {
    return '这个文件读不了，仍显示上一个：$error';
  }

  @override
  String get noFontOpen => '还没有打开任何字体';

  @override
  String get chooseAnotherFont => '换一个字体文件…';

  @override
  String get navInfo => '解析字体';

  @override
  String get navShaping => '塑形';

  @override
  String get navGlyphs => '字形';

  @override
  String get navTools => '工具';

  @override
  String get navEditor => '绘制造字';

  @override
  String get sourceTitle => '字体';

  @override
  String get sourceTitleCompact => '当前字体';

  @override
  String get sourceCollection => '字体集合';

  @override
  String sourceFace(String index) {
    return '第 $index 个字体';
  }

  @override
  String sourceFaceCount(String count) {
    return '这个文件里有 $count 个字体（.ttc 集合）。';
  }

  @override
  String sourceFormats(String extensions) {
    return '支持 $extensions。woff / woff2 是压缩格式，需要先解压。';
  }

  @override
  String get infoHintingTitle => 'skrifa 0.50 ScalerFont 提示';

  @override
  String get infoLibraryVersion => '库';

  @override
  String get infoNamesTitle => '名称（name 表）';

  @override
  String get infoMetricsTitle => '度量';

  @override
  String infoTablesTitle(String count) {
    return '表（$count）';
  }

  @override
  String get infoAttributesTitle => '属性（OS/2）';

  @override
  String infoAxesTitle(String count) {
    return '可变轴（$count）';
  }

  @override
  String infoInstancesTitle(String count) {
    return '命名实例（$count）';
  }

  @override
  String get infoLayoutTitle => '布局表';

  @override
  String get infoCharmapTitle => '字符映射';

  @override
  String get infoPreviewTextLabel => '预览文本';

  @override
  String get infoNormalizedCoords => '归一化坐标';

  @override
  String get infoAvarAbsent => '经 fvar 线性归一化后的坐标；该字体没有 avar，gvar 增量按这个数缩放。';

  @override
  String infoAvarPresent(String version) {
    return '经 fvar → avar $version 后的坐标；gvar 增量按这个数缩放。';
  }

  @override
  String infoAvarPresentAvar2(String version) {
    return '经 fvar → avar $version（含 avar2 增量）后的坐标；gvar 增量按这个数缩放。';
  }

  @override
  String get infoLayoutNote => '这些只是「字体声明了什么」。要真正应用它们，请看「塑形」页。';

  @override
  String infoVariantMappings(String count) {
    return '$count 条';
  }

  @override
  String get infoCapabilitiesTitle => '字体能力';

  @override
  String infoMathConstants(String count, String axisHeight) {
    return '$count 个常量，axisHeight = $axisHeight';
  }

  @override
  String infoVarcSample(String glyphId, String components) {
    return '字形 $glyphId 由 $components 个部件组成';
  }

  @override
  String infoPaletteCount(String count) {
    return '$count 个调色板';
  }

  @override
  String get infoEmbeddedBitmaps => '嵌入位图';

  @override
  String infoStrikeCount(String count) {
    return '$count 个 strike';
  }

  @override
  String get infoVerticalMetrics => '竖排度量';

  @override
  String get shapingTitle => '塑形：应用 GSUB / GPOS';

  @override
  String get shapingTextLabel => '待塑形的文本';

  @override
  String get shapingTextHint => '试试 fi / fl / ffi，或 AWAY 这类带字距的组合';

  @override
  String get shapingResultsTitle => '结果';

  @override
  String get shapingCharCount => '字符数';

  @override
  String get shapingLigatures => '连字合并';

  @override
  String shapingLigatureMerged(String count) {
    return '$count 个字符被合并';
  }

  @override
  String get shapingTotalAdvance => '总步进';

  @override
  String shapingAdvanceRaw(String value) {
    return '（关闭全部特性时为 $value）';
  }

  @override
  String get shapingGlyphSequence => '字形序列';

  @override
  String get shapingClusterNote =>
      'cluster→glyphId：多个字形可以共享一个 cluster（分解），一个字形也可以覆盖多个（连字）。';

  @override
  String shapingFeaturesTitle(String count) {
    return '特性（$count）';
  }

  @override
  String get shapingModeDefault => '默认';

  @override
  String get shapingModeNone => '全部关闭';

  @override
  String get shapingModeCustom => '自定义';

  @override
  String get shapingFeaturesNote =>
      '带 ★ 的是默认开启的特性。点任意标签即切到「自定义」；「全部关闭」可以看塑形之前的样子。';

  @override
  String get shapingRenderingTitle => '渲染';

  @override
  String get shapingFontSize => '字号';

  @override
  String get shapingShowMarkers => '显示字形边界与 ID';

  @override
  String get shapingScriptLabel => 'script（4 字符）';

  @override
  String get shapingLanguageLabel => 'language（4 字符）';

  @override
  String get shapingTagNote =>
      '标签必须恰好 4 个字符，尾部空格也算（土耳其语是「TRK 」）。留空则使用字体的 DFLT/latn 默认语言系统，locl 等替换才会按所选语言生效。';

  @override
  String get browserTitle => '字形浏览器：cmap / COLR / 位图';

  @override
  String get browserSearchLabel => '搜索字符 / glyphId / U+ 码位';

  @override
  String get browserSearchHint => 'A、U+4E00、0x2764 或 36';

  @override
  String browserCmapSummary(String total, String truncated) {
    return '共 $total 条 cmap 映射$truncated。点击任意格子查看该字形。';
  }

  @override
  String browserTruncated(String count) {
    return '，仅显示前 $count 条';
  }

  @override
  String get browserModeOutline => '轮廓';

  @override
  String get browserModeBitmap => '位图';

  @override
  String get browserPreviewTitle => '字形预览';

  @override
  String browserGlyphTitle(String glyphId, String char) {
    return '字形 #$glyphId · $char';
  }

  @override
  String browserPalette(String index) {
    return '调色板 $index';
  }

  @override
  String get browserPreviewNote =>
      '轮廓用 GlyphOutline.toPath()，COLR 图层用 ColorGlyphInfo.paint()，位图用 sbix/CBDT/EBDT 的 RGBA 或 PNG 字节解码。蓝线是基线与 em 方框。';

  @override
  String browserMetricsTitle(String size) {
    return '字形度量（size = $size px）';
  }

  @override
  String get browserOptionalTitle => '可选表数据';

  @override
  String browserMath(String italic, String accent, String kerns) {
    return 'italic $italic，accent $accent，$kerns 组角标字距';
  }

  @override
  String get browserAssemblyParts => '伸展部件';

  @override
  String browserVariantsInfo(String sizes, String parts) {
    return '$sizes 个尺寸，$parts 个组装件';
  }

  @override
  String browserVarcComponents(String count) {
    return '$count 个部件';
  }

  @override
  String browserColorInfo(String format, String layers, String palettes) {
    return '$format，$layers 个图层，$palettes 个调色板';
  }

  @override
  String browserBitmapInfo(
    String format,
    String width,
    String height,
    String ppem,
    String origin,
  ) {
    return '$format $width×$height，$ppem ppem，origin $origin';
  }

  @override
  String get browserConditionUnmet => '(条件未满足)';

  @override
  String get browserVariantsTitle => '变体选择符（cmap format 14）';

  @override
  String get browserNoUvs => '这个字体没有 UVS 映射。';

  @override
  String get toolsTitle => '字体工具：表 / 子集 / 修补';

  @override
  String get toolsRawTablesTitle => '任意表原始字节';

  @override
  String get toolsRawTablesNote =>
      'tableData(tag:) 给出表自身的字节，表内偏移量都相对这段数据的起点；没有的类型返回 null。';

  @override
  String get toolsTableEmpty => '这个表为空或不存在。';

  @override
  String toolsHexMore(String count) {
    return '… 还有 $count 字节未显示';
  }

  @override
  String get toolsExtendedTitle => '扩展表（SVG / gasp / meta / BASE / AAT）';

  @override
  String get toolsTableTagCount => '表标签数';

  @override
  String get toolsFlags => '标志位';

  @override
  String get toolsSvgDocs => 'SVG 文档';

  @override
  String get toolsGaspRanges => 'gasp 范围';

  @override
  String get toolsMetaEntries => 'meta 条目';

  @override
  String get toolsAatTables => 'AAT 表';

  @override
  String get toolsNamesTitle => 'name 表记录（nameId = 1，家族名的每种本地化）';

  @override
  String get toolsNoNameRecords => '没有名字记录。';

  @override
  String get toolsSubsetTitle => '子集化（skera / subsetFont）';

  @override
  String get toolsSubsetCharsLabel => '要保留的字符';

  @override
  String get toolsSubsetCharsHint => '布局闭包会自动带进连字、变体、组合符号所需的字形';

  @override
  String get toolsNoHinting => '去掉 TrueType 指令（noHinting）';

  @override
  String get toolsRetainGlyphIds => '保留原 glyph id（retainGlyphIds）';

  @override
  String get toolsSubsetButton => '生成子集';

  @override
  String get toolsSaveSubset => '保存子集 .ttf';

  @override
  String get toolsModifyTitle => '修补已有字体（modifyFont）';

  @override
  String get toolsNewFamily => '新的家族名';

  @override
  String get toolsSubfamily => '子家族名（影响 OS/2 weight）';

  @override
  String get toolsDesignerLabel => '设计者（nameId 9）';

  @override
  String get toolsKernPair => '字偶距';

  @override
  String get toolsKernValue => 'kern 值（font units）';

  @override
  String get toolsPatchButton => '打补丁并读回';

  @override
  String toolsUnchangedOutlines(String before, String after) {
    return '$before → $after（轮廓未改）';
  }

  @override
  String get toolsSavePatched => '保存修补后的 .ttf';

  @override
  String get toolsPinnedTitle => '固定变体位置（withVariations）';

  @override
  String get toolsPinnedNote =>
      '这只是一个指向同一份字节、带着固定坐标的句柄，不会生成静态实例；需要真正变小请用上面的 subsetFont。';

  @override
  String get toolsNoVisibleAxes => '这个字体没有可见的可变轴。';

  @override
  String get toolsDefaultAAdvance => '默认 A 步进';

  @override
  String get toolsPinnedAAdvance => '句柄 A 步进';

  @override
  String get editorTitle => '绘制造字：buildFont';

  @override
  String editorDrawFirst(String char) {
    return '先在画板上写下「$char」';
  }

  @override
  String editorSetDefault(String char) {
    return '已设为 $char 的默认字形';
  }

  @override
  String editorSavedMaster(String char, String tag, String value) {
    return '已保存 $char 在 $tag $value 的母版';
  }

  @override
  String editorSavedVariant(String char, String set) {
    return '已把当前笔画存为 $char 的 $set';
  }

  @override
  String get editorNoGlyphs => '还没有任何字形，先画一笔再生成';

  @override
  String get editorCharLabel => '绑定字符';

  @override
  String get editorCharHint => '取第一个字，例如「一」';

  @override
  String get editorFamilyLabel => '字体家族名';

  @override
  String get editorStrokeWidth => '笔画粗细';

  @override
  String editorMastersTitle(String tag) {
    return '可变字体母版（$tag）';
  }

  @override
  String get editorSaveToPosition => '保存到位置';

  @override
  String get editorUndo => '撤销';

  @override
  String get editorClear => '清空';

  @override
  String get editorSetDefaultGlyph => '设为默认字形';

  @override
  String get editorSaveAsMaster => '存为母版';

  @override
  String editorDefaultValue(String value) {
    return '默认 $value';
  }

  @override
  String get editorVariantsTitle => '字符变体（ss01–ss20，GSUB 离散替换）';

  @override
  String get editorFeatureTag => '特性标签';

  @override
  String get editorSaveVariant => '存为变体';

  @override
  String editorCharsAdded(String count) {
    return '已加入 $count 个字符';
  }

  @override
  String get editorBuildButton => '生成字体';

  @override
  String get editorResultTitle => '生成结果';

  @override
  String get editorNoAxes => '无（静态字体）';

  @override
  String get editorResultInstances => '命名实例';

  @override
  String get editorResultGsubVariants => 'GSUB 变体';

  @override
  String get editorRenderCompare => '渲染对比';

  @override
  String get editorCustomFont => '自定义字体';

  @override
  String get editorSystemFont => '系统字体';

  @override
  String editorInterpolationPreview(String tag) {
    return '沿 $tag 插值预览';
  }

  @override
  String get editorDragSlider => '拖动滑块查看插值';

  @override
  String get editorVariantsPreview => '字符变体预览';

  @override
  String get editorVariantsPreviewNote =>
      '用 FontFeature 打开 ss01–ss20；若渲染无变化，说明当前平台的排版引擎不支持该特性。';

  @override
  String get editorExport => '导出 .ttf';

  @override
  String get editorFocusMode => '专注绘制（隐藏控件）';

  @override
  String get editorExitFocus => '退出专注绘制';
}
