// ignore_for_file: deprecated_member_use

// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'fontations demo';

  @override
  String get githubTooltip => 'View on GitHub';

  @override
  String get languageMenuTooltip => 'Language';

  @override
  String get languageSystem => 'Follow system';

  @override
  String get themeMenuTooltip => 'Theme mode';

  @override
  String get themeSystem => 'Follow system';

  @override
  String get themeLight => 'Light';

  @override
  String get themeDark => 'Dark';

  @override
  String get openFontFile => 'Open font file…';

  @override
  String get bundledInter => 'Bundled Inter';

  @override
  String get pickFontDialogTitle => 'Select a font file';

  @override
  String get saveFontDialogTitle => 'Save font file';

  @override
  String savedTo(String path) {
    return 'Saved to $path';
  }

  @override
  String openFailed(String error) {
    return 'Could not open: $error';
  }

  @override
  String get none => 'None';

  @override
  String get emptyValue => '(empty)';

  @override
  String bytesUnit(String value) {
    return '$value bytes';
  }

  @override
  String get labelGlyphCount => 'Glyph count';

  @override
  String get labelAxes => 'Variation axes';

  @override
  String get labelTables => 'Tables';

  @override
  String get labelSize => 'Size';

  @override
  String get labelDefault => 'Default';

  @override
  String get labelFamily => 'Family';

  @override
  String get labelLayoutFeatures => 'Layout features';

  @override
  String get labelGlyphIdA => 'glyphId of A';

  @override
  String fontReadError(String error) {
    return 'Could not read this font file\n\n$error';
  }

  @override
  String fontParseError(String error) {
    return 'Could not parse this font file: $error';
  }

  @override
  String get unreadableTitle => 'Could not parse this font file';

  @override
  String unreadableDetail(String error) {
    return 'This file could not be read, showing the previous one: $error';
  }

  @override
  String get noFontOpen => 'No font is open yet';

  @override
  String get chooseAnotherFont => 'Choose another font file…';

  @override
  String get navInfo => 'Font info';

  @override
  String get navShaping => 'Shaping';

  @override
  String get navGlyphs => 'Glyphs';

  @override
  String get navTools => 'Tools';

  @override
  String get navEditor => 'Draw a font';

  @override
  String get sourceTitle => 'Font';

  @override
  String get sourceTitleCompact => 'Current font';

  @override
  String get sourceCollection => 'Collection';

  @override
  String sourceFace(String index) {
    return 'Face $index';
  }

  @override
  String sourceFaceCount(String count) {
    return 'This file holds $count faces (.ttc collection).';
  }

  @override
  String sourceFormats(String extensions) {
    return 'Supports $extensions. woff / woff2 are compressed and must be unpacked first.';
  }

  @override
  String get infoHintingTitle => 'skrifa 0.50 ScalerFont hinting';

  @override
  String get infoLibraryVersion => 'Library';

  @override
  String get infoNamesTitle => 'Names (name table)';

  @override
  String get infoMetricsTitle => 'Metrics';

  @override
  String infoTablesTitle(String count) {
    return 'Tables ($count)';
  }

  @override
  String get infoAttributesTitle => 'Attributes (OS/2)';

  @override
  String infoAxesTitle(String count) {
    return 'Variation axes ($count)';
  }

  @override
  String infoInstancesTitle(String count) {
    return 'Named instances ($count)';
  }

  @override
  String get infoLayoutTitle => 'Layout tables';

  @override
  String get infoCharmapTitle => 'Character map';

  @override
  String get infoPreviewTextLabel => 'Preview text';

  @override
  String get infoNormalizedCoords => 'Normalized coordinates';

  @override
  String get infoAvarAbsent =>
      'Linearly normalized from fvar; this font has no avar, so gvar deltas scale by this number.';

  @override
  String infoAvarPresent(String version) {
    return 'Normalized via fvar → avar $version; gvar deltas scale by this number.';
  }

  @override
  String infoAvarPresentAvar2(String version) {
    return 'Normalized via fvar → avar $version (including avar2 deltas); gvar deltas scale by this number.';
  }

  @override
  String get infoLayoutNote =>
      'These only say what the font declares. See the Shaping page to actually apply them.';

  @override
  String infoVariantMappings(String count) {
    return '$count entries';
  }

  @override
  String get infoCapabilitiesTitle => 'Font capabilities';

  @override
  String infoMathConstants(String count, String axisHeight) {
    return '$count constants, axisHeight = $axisHeight';
  }

  @override
  String infoVarcSample(String glyphId, String components) {
    return 'Glyph $glyphId is built from $components components';
  }

  @override
  String infoPaletteCount(String count) {
    return '$count palettes';
  }

  @override
  String get infoEmbeddedBitmaps => 'Embedded bitmaps';

  @override
  String infoStrikeCount(String count) {
    return '$count strikes';
  }

  @override
  String get infoVerticalMetrics => 'Vertical metrics';

  @override
  String get shapingTitle => 'Shaping: applying GSUB / GPOS';

  @override
  String get shapingTextLabel => 'Text to shape';

  @override
  String get shapingTextHint => 'Try fi / fl / ffi, or AWAY for a kern pair';

  @override
  String get shapingResultsTitle => 'Results';

  @override
  String get shapingCharCount => 'Characters';

  @override
  String get shapingLigatures => 'Ligatures';

  @override
  String shapingLigatureMerged(String count) {
    return '$count characters merged';
  }

  @override
  String get shapingTotalAdvance => 'Total advance';

  @override
  String shapingAdvanceRaw(String value) {
    return ' ($value with all features off)';
  }

  @override
  String get shapingGlyphSequence => 'Glyph sequence';

  @override
  String get shapingClusterNote =>
      'cluster→glyphId: several glyphs can share a cluster (decomposition), and one glyph can cover several (ligature).';

  @override
  String shapingFeaturesTitle(String count) {
    return 'Features ($count)';
  }

  @override
  String get shapingModeDefault => 'Defaults';

  @override
  String get shapingModeNone => 'All off';

  @override
  String get shapingModeCustom => 'Custom';

  @override
  String get shapingFeaturesNote =>
      '★ marks features enabled by default. Tap any tag to switch to Custom; All off shows the text before shaping.';

  @override
  String get shapingRenderingTitle => 'Rendering';

  @override
  String get shapingFontSize => 'Font size';

  @override
  String get shapingShowMarkers => 'Show glyph bounds and IDs';

  @override
  String get shapingScriptLabel => 'script (4 characters)';

  @override
  String get shapingLanguageLabel => 'language (4 characters)';

  @override
  String get shapingTagNote =>
      'Tags must be exactly 4 characters, including trailing spaces (Turkish is \'TRK \'). Leave empty to use the font\'s DFLT/latn default language system; only then do locale-specific substitutions such as locl apply.';

  @override
  String get browserTitle => 'Glyph browser: cmap / COLR / bitmaps';

  @override
  String get browserSearchLabel => 'Search character / glyphId / U+ codepoint';

  @override
  String get browserSearchHint => 'A, U+4E00, 0x2764 or 36';

  @override
  String browserCmapSummary(String total, String truncated) {
    return '$total cmap mappings$truncated. Tap a tile to inspect that glyph.';
  }

  @override
  String browserTruncated(String count) {
    return ' (showing the first $count)';
  }

  @override
  String get browserModeOutline => 'Outline';

  @override
  String get browserModeBitmap => 'Bitmap';

  @override
  String get browserPreviewTitle => 'Glyph preview';

  @override
  String browserGlyphTitle(String glyphId, String char) {
    return 'Glyph #$glyphId · $char';
  }

  @override
  String browserPalette(String index) {
    return 'Palette $index';
  }

  @override
  String get browserPreviewNote =>
      'Outlines use GlyphOutline.toPath(), COLR layers use ColorGlyphInfo.paint(), bitmaps are decoded from sbix/CBDT/EBDT RGBA or PNG bytes. The blue lines mark the baseline and the em box.';

  @override
  String browserMetricsTitle(String size) {
    return 'Glyph metrics (size = $size px)';
  }

  @override
  String get browserOptionalTitle => 'Optional table data';

  @override
  String browserMath(String italic, String accent, String kerns) {
    return 'italic $italic, accent $accent, $kerns corner kern sets';
  }

  @override
  String get browserAssemblyParts => 'Stretchy parts';

  @override
  String browserVariantsInfo(String sizes, String parts) {
    return '$sizes sizes, $parts assembly parts';
  }

  @override
  String browserVarcComponents(String count) {
    return '$count components';
  }

  @override
  String browserColorInfo(String format, String layers, String palettes) {
    return '$format, $layers layers, $palettes palettes';
  }

  @override
  String browserBitmapInfo(
    String format,
    String width,
    String height,
    String ppem,
    String origin,
  ) {
    return '$format $width×$height, $ppem ppem, origin $origin';
  }

  @override
  String get browserConditionUnmet => '(condition unmet)';

  @override
  String get browserVariantsTitle => 'Variation selectors (cmap format 14)';

  @override
  String get browserNoUvs => 'This font has no UVS mappings.';

  @override
  String get toolsTitle => 'Font tools: tables / subset / patch';

  @override
  String get toolsRawTablesTitle => 'Raw table bytes';

  @override
  String get toolsRawTablesNote =>
      'tableData(tag:) returns the bytes of that table. Offsets inside a table are relative to the start of this data; an absent tag returns null.';

  @override
  String get toolsTableEmpty => 'This table is empty or missing.';

  @override
  String toolsHexMore(String count) {
    return '… $count more bytes not shown';
  }

  @override
  String get toolsExtendedTitle =>
      'Extended tables (SVG / gasp / meta / BASE / AAT)';

  @override
  String get toolsTableTagCount => 'Table tags';

  @override
  String get toolsFlags => 'Flags';

  @override
  String get toolsSvgDocs => 'SVG documents';

  @override
  String get toolsGaspRanges => 'gasp ranges';

  @override
  String get toolsMetaEntries => 'meta entries';

  @override
  String get toolsAatTables => 'AAT tables';

  @override
  String get toolsNamesTitle =>
      'name table records (nameId = 1, every localized family name)';

  @override
  String get toolsNoNameRecords => 'No name records.';

  @override
  String get toolsSubsetTitle => 'Subsetting (skera / subsetFont)';

  @override
  String get toolsSubsetCharsLabel => 'Characters to keep';

  @override
  String get toolsSubsetCharsHint =>
      'The layout closure brings in glyphs needed by ligatures, variants and combining marks';

  @override
  String get toolsNoHinting => 'Strip TrueType instructions (noHinting)';

  @override
  String get toolsRetainGlyphIds => 'Keep original glyph ids (retainGlyphIds)';

  @override
  String get toolsSubsetButton => 'Build subset';

  @override
  String get toolsSaveSubset => 'Save subset .ttf';

  @override
  String get toolsModifyTitle => 'Patch an existing font (modifyFont)';

  @override
  String get toolsNewFamily => 'New family name';

  @override
  String get toolsSubfamily => 'Subfamily (affects OS/2 weight)';

  @override
  String get toolsDesignerLabel => 'Designer (nameId 9)';

  @override
  String get toolsKernPair => 'Kern pair';

  @override
  String get toolsKernValue => 'kern value (font units)';

  @override
  String get toolsPatchButton => 'Patch and read back';

  @override
  String toolsUnchangedOutlines(String before, String after) {
    return '$before → $after (outlines unchanged)';
  }

  @override
  String get toolsSavePatched => 'Save patched .ttf';

  @override
  String get toolsPinnedTitle => 'Pinned variation location (withVariations)';

  @override
  String get toolsPinnedNote =>
      'This is just a handle over the same bytes with a fixed location; it does not produce a static instance. Use subsetFont above to actually make the font smaller.';

  @override
  String get toolsNoVisibleAxes => 'This font has no visible variation axes.';

  @override
  String get toolsDefaultAAdvance => 'Default A advance';

  @override
  String get toolsPinnedAAdvance => 'Pinned A advance';

  @override
  String get editorTitle => 'Draw a font: buildFont';

  @override
  String editorDrawFirst(String char) {
    return 'Draw something for $char on the board first';
  }

  @override
  String editorSetDefault(String char) {
    return 'Set $char as the default glyph';
  }

  @override
  String editorSavedMaster(String char, String tag, String value) {
    return 'Saved $char as a master at $tag $value';
  }

  @override
  String editorSavedVariant(String char, String set) {
    return 'Saved the strokes as $set for $char';
  }

  @override
  String get editorNoGlyphs => 'No glyphs yet — draw a stroke before building';

  @override
  String get editorCharLabel => 'Character to bind';

  @override
  String get editorCharHint => 'Only the first rune is used';

  @override
  String get editorFamilyLabel => 'Font family name';

  @override
  String get editorStrokeWidth => 'Stroke width';

  @override
  String editorMastersTitle(String tag) {
    return 'Variable font masters ($tag)';
  }

  @override
  String get editorSaveToPosition => 'Save to position';

  @override
  String get editorUndo => 'Undo';

  @override
  String get editorClear => 'Clear';

  @override
  String get editorSetDefaultGlyph => 'Set as default glyph';

  @override
  String get editorSaveAsMaster => 'Save as master';

  @override
  String editorDefaultValue(String value) {
    return 'Default $value';
  }

  @override
  String get editorVariantsTitle =>
      'Character variants (ss01–ss20, GSUB discrete substitutions)';

  @override
  String get editorFeatureTag => 'Feature tag';

  @override
  String get editorSaveVariant => 'Save as variant';

  @override
  String editorCharsAdded(String count) {
    return '$count characters added';
  }

  @override
  String get editorBuildButton => 'Build font';

  @override
  String get editorResultTitle => 'Build result';

  @override
  String get editorNoAxes => 'None (static font)';

  @override
  String get editorResultInstances => 'Named instances';

  @override
  String get editorResultGsubVariants => 'GSUB variants';

  @override
  String get editorRenderCompare => 'Render comparison';

  @override
  String get editorCustomFont => 'Custom font';

  @override
  String get editorSystemFont => 'System font';

  @override
  String editorInterpolationPreview(String tag) {
    return 'Interpolate along $tag';
  }

  @override
  String get editorDragSlider => 'Drag the slider to interpolate';

  @override
  String get editorVariantsPreview => 'Character variant preview';

  @override
  String get editorVariantsPreviewNote =>
      'Enable ss01–ss20 with FontFeature; if nothing changes, the platform\'s text engine does not support the feature.';

  @override
  String get editorExport => 'Export .ttf';

  @override
  String get editorFocusMode => 'Focus mode (hide controls)';

  @override
  String get editorExitFocus => 'Exit focus mode';
}
