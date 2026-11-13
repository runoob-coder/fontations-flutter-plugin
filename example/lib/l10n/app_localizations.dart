// ignore_for_file: deprecated_member_use
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('zh'),
    Locale('en'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'fontations demo'**
  String get appTitle;

  /// No description provided for @languageMenuTooltip.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get languageMenuTooltip;

  /// No description provided for @languageSystem.
  ///
  /// In en, this message translates to:
  /// **'Follow system'**
  String get languageSystem;

  /// No description provided for @themeMenuTooltip.
  ///
  /// In en, this message translates to:
  /// **'Theme mode'**
  String get themeMenuTooltip;

  /// No description provided for @themeSystem.
  ///
  /// In en, this message translates to:
  /// **'Follow system'**
  String get themeSystem;

  /// No description provided for @themeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get themeLight;

  /// No description provided for @themeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get themeDark;

  /// No description provided for @openFontFile.
  ///
  /// In en, this message translates to:
  /// **'Open font file…'**
  String get openFontFile;

  /// No description provided for @bundledInter.
  ///
  /// In en, this message translates to:
  /// **'Bundled Inter'**
  String get bundledInter;

  /// No description provided for @pickFontDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Select a font file'**
  String get pickFontDialogTitle;

  /// No description provided for @saveFontDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Save font file'**
  String get saveFontDialogTitle;

  /// No description provided for @savedTo.
  ///
  /// In en, this message translates to:
  /// **'Saved to {path}'**
  String savedTo(String path);

  /// No description provided for @openFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not open: {error}'**
  String openFailed(String error);

  /// No description provided for @none.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get none;

  /// No description provided for @emptyValue.
  ///
  /// In en, this message translates to:
  /// **'(empty)'**
  String get emptyValue;

  /// No description provided for @bytesUnit.
  ///
  /// In en, this message translates to:
  /// **'{value} bytes'**
  String bytesUnit(String value);

  /// No description provided for @labelGlyphCount.
  ///
  /// In en, this message translates to:
  /// **'Glyph count'**
  String get labelGlyphCount;

  /// No description provided for @labelAxes.
  ///
  /// In en, this message translates to:
  /// **'Variation axes'**
  String get labelAxes;

  /// No description provided for @labelTables.
  ///
  /// In en, this message translates to:
  /// **'Tables'**
  String get labelTables;

  /// No description provided for @labelSize.
  ///
  /// In en, this message translates to:
  /// **'Size'**
  String get labelSize;

  /// No description provided for @labelDefault.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get labelDefault;

  /// No description provided for @labelFamily.
  ///
  /// In en, this message translates to:
  /// **'Family'**
  String get labelFamily;

  /// No description provided for @labelLayoutFeatures.
  ///
  /// In en, this message translates to:
  /// **'Layout features'**
  String get labelLayoutFeatures;

  /// No description provided for @labelGlyphIdA.
  ///
  /// In en, this message translates to:
  /// **'glyphId of A'**
  String get labelGlyphIdA;

  /// No description provided for @fontReadError.
  ///
  /// In en, this message translates to:
  /// **'Could not read this font file\n\n{error}'**
  String fontReadError(String error);

  /// No description provided for @fontParseError.
  ///
  /// In en, this message translates to:
  /// **'Could not parse this font file: {error}'**
  String fontParseError(String error);

  /// No description provided for @unreadableTitle.
  ///
  /// In en, this message translates to:
  /// **'Could not parse this font file'**
  String get unreadableTitle;

  /// No description provided for @unreadableDetail.
  ///
  /// In en, this message translates to:
  /// **'This file could not be read, showing the previous one: {error}'**
  String unreadableDetail(String error);

  /// No description provided for @noFontOpen.
  ///
  /// In en, this message translates to:
  /// **'No font is open yet'**
  String get noFontOpen;

  /// No description provided for @chooseAnotherFont.
  ///
  /// In en, this message translates to:
  /// **'Choose another font file…'**
  String get chooseAnotherFont;

  /// No description provided for @navInfo.
  ///
  /// In en, this message translates to:
  /// **'Font info'**
  String get navInfo;

  /// No description provided for @navShaping.
  ///
  /// In en, this message translates to:
  /// **'Shaping'**
  String get navShaping;

  /// No description provided for @navGlyphs.
  ///
  /// In en, this message translates to:
  /// **'Glyphs'**
  String get navGlyphs;

  /// No description provided for @navTools.
  ///
  /// In en, this message translates to:
  /// **'Tools'**
  String get navTools;

  /// No description provided for @navEditor.
  ///
  /// In en, this message translates to:
  /// **'Draw a font'**
  String get navEditor;

  /// No description provided for @sourceTitle.
  ///
  /// In en, this message translates to:
  /// **'Font'**
  String get sourceTitle;

  /// No description provided for @sourceTitleCompact.
  ///
  /// In en, this message translates to:
  /// **'Current font'**
  String get sourceTitleCompact;

  /// No description provided for @sourceCollection.
  ///
  /// In en, this message translates to:
  /// **'Collection'**
  String get sourceCollection;

  /// No description provided for @sourceFace.
  ///
  /// In en, this message translates to:
  /// **'Face {index}'**
  String sourceFace(String index);

  /// No description provided for @sourceFaceCount.
  ///
  /// In en, this message translates to:
  /// **'This file holds {count} faces (.ttc collection).'**
  String sourceFaceCount(String count);

  /// No description provided for @sourceFormats.
  ///
  /// In en, this message translates to:
  /// **'Supports {extensions}. woff / woff2 are compressed and must be unpacked first.'**
  String sourceFormats(String extensions);

  /// No description provided for @infoHintingTitle.
  ///
  /// In en, this message translates to:
  /// **'skrifa 0.50 ScalerFont hinting'**
  String get infoHintingTitle;

  /// No description provided for @infoNamesTitle.
  ///
  /// In en, this message translates to:
  /// **'Names (name table)'**
  String get infoNamesTitle;

  /// No description provided for @infoMetricsTitle.
  ///
  /// In en, this message translates to:
  /// **'Metrics'**
  String get infoMetricsTitle;

  /// No description provided for @infoTablesTitle.
  ///
  /// In en, this message translates to:
  /// **'Tables ({count})'**
  String infoTablesTitle(String count);

  /// No description provided for @infoAttributesTitle.
  ///
  /// In en, this message translates to:
  /// **'Attributes (OS/2)'**
  String get infoAttributesTitle;

  /// No description provided for @infoAxesTitle.
  ///
  /// In en, this message translates to:
  /// **'Variation axes ({count})'**
  String infoAxesTitle(String count);

  /// No description provided for @infoInstancesTitle.
  ///
  /// In en, this message translates to:
  /// **'Named instances ({count})'**
  String infoInstancesTitle(String count);

  /// No description provided for @infoLayoutTitle.
  ///
  /// In en, this message translates to:
  /// **'Layout tables'**
  String get infoLayoutTitle;

  /// No description provided for @infoCharmapTitle.
  ///
  /// In en, this message translates to:
  /// **'Character map'**
  String get infoCharmapTitle;

  /// No description provided for @infoPreviewTextLabel.
  ///
  /// In en, this message translates to:
  /// **'Preview text'**
  String get infoPreviewTextLabel;

  /// No description provided for @infoNormalizedCoords.
  ///
  /// In en, this message translates to:
  /// **'Normalized coordinates'**
  String get infoNormalizedCoords;

  /// No description provided for @infoAvarAbsent.
  ///
  /// In en, this message translates to:
  /// **'Linearly normalized from fvar; this font has no avar, so gvar deltas scale by this number.'**
  String get infoAvarAbsent;

  /// No description provided for @infoAvarPresent.
  ///
  /// In en, this message translates to:
  /// **'Normalized via fvar → avar {version}; gvar deltas scale by this number.'**
  String infoAvarPresent(String version);

  /// No description provided for @infoAvarPresentAvar2.
  ///
  /// In en, this message translates to:
  /// **'Normalized via fvar → avar {version} (including avar2 deltas); gvar deltas scale by this number.'**
  String infoAvarPresentAvar2(String version);

  /// No description provided for @infoLayoutNote.
  ///
  /// In en, this message translates to:
  /// **'These only say what the font declares. See the Shaping page to actually apply them.'**
  String get infoLayoutNote;

  /// No description provided for @infoVariantMappings.
  ///
  /// In en, this message translates to:
  /// **'{count} entries'**
  String infoVariantMappings(String count);

  /// No description provided for @infoCapabilitiesTitle.
  ///
  /// In en, this message translates to:
  /// **'Font capabilities'**
  String get infoCapabilitiesTitle;

  /// No description provided for @infoMathConstants.
  ///
  /// In en, this message translates to:
  /// **'{count} constants, axisHeight = {axisHeight}'**
  String infoMathConstants(String count, String axisHeight);

  /// No description provided for @infoVarcSample.
  ///
  /// In en, this message translates to:
  /// **'Glyph {glyphId} is built from {components} components'**
  String infoVarcSample(String glyphId, String components);

  /// No description provided for @infoPaletteCount.
  ///
  /// In en, this message translates to:
  /// **'{count} palettes'**
  String infoPaletteCount(String count);

  /// No description provided for @infoEmbeddedBitmaps.
  ///
  /// In en, this message translates to:
  /// **'Embedded bitmaps'**
  String get infoEmbeddedBitmaps;

  /// No description provided for @infoStrikeCount.
  ///
  /// In en, this message translates to:
  /// **'{count} strikes'**
  String infoStrikeCount(String count);

  /// No description provided for @infoVerticalMetrics.
  ///
  /// In en, this message translates to:
  /// **'Vertical metrics'**
  String get infoVerticalMetrics;

  /// No description provided for @shapingTitle.
  ///
  /// In en, this message translates to:
  /// **'Shaping: applying GSUB / GPOS'**
  String get shapingTitle;

  /// No description provided for @shapingTextLabel.
  ///
  /// In en, this message translates to:
  /// **'Text to shape'**
  String get shapingTextLabel;

  /// No description provided for @shapingTextHint.
  ///
  /// In en, this message translates to:
  /// **'Try fi / fl / ffi, or AWAY for a kern pair'**
  String get shapingTextHint;

  /// No description provided for @shapingResultsTitle.
  ///
  /// In en, this message translates to:
  /// **'Results'**
  String get shapingResultsTitle;

  /// No description provided for @shapingCharCount.
  ///
  /// In en, this message translates to:
  /// **'Characters'**
  String get shapingCharCount;

  /// No description provided for @shapingLigatures.
  ///
  /// In en, this message translates to:
  /// **'Ligatures'**
  String get shapingLigatures;

  /// No description provided for @shapingLigatureMerged.
  ///
  /// In en, this message translates to:
  /// **'{count} characters merged'**
  String shapingLigatureMerged(String count);

  /// No description provided for @shapingTotalAdvance.
  ///
  /// In en, this message translates to:
  /// **'Total advance'**
  String get shapingTotalAdvance;

  /// No description provided for @shapingAdvanceRaw.
  ///
  /// In en, this message translates to:
  /// **' ({value} with all features off)'**
  String shapingAdvanceRaw(String value);

  /// No description provided for @shapingGlyphSequence.
  ///
  /// In en, this message translates to:
  /// **'Glyph sequence'**
  String get shapingGlyphSequence;

  /// No description provided for @shapingClusterNote.
  ///
  /// In en, this message translates to:
  /// **'cluster→glyphId: several glyphs can share a cluster (decomposition), and one glyph can cover several (ligature).'**
  String get shapingClusterNote;

  /// No description provided for @shapingFeaturesTitle.
  ///
  /// In en, this message translates to:
  /// **'Features ({count})'**
  String shapingFeaturesTitle(String count);

  /// No description provided for @shapingModeDefault.
  ///
  /// In en, this message translates to:
  /// **'Defaults'**
  String get shapingModeDefault;

  /// No description provided for @shapingModeNone.
  ///
  /// In en, this message translates to:
  /// **'All off'**
  String get shapingModeNone;

  /// No description provided for @shapingModeCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom'**
  String get shapingModeCustom;

  /// No description provided for @shapingFeaturesNote.
  ///
  /// In en, this message translates to:
  /// **'★ marks features enabled by default. Tap any tag to switch to Custom; All off shows the text before shaping.'**
  String get shapingFeaturesNote;

  /// No description provided for @shapingRenderingTitle.
  ///
  /// In en, this message translates to:
  /// **'Rendering'**
  String get shapingRenderingTitle;

  /// No description provided for @shapingFontSize.
  ///
  /// In en, this message translates to:
  /// **'Font size'**
  String get shapingFontSize;

  /// No description provided for @shapingShowMarkers.
  ///
  /// In en, this message translates to:
  /// **'Show glyph bounds and IDs'**
  String get shapingShowMarkers;

  /// No description provided for @shapingScriptLabel.
  ///
  /// In en, this message translates to:
  /// **'script (4 characters)'**
  String get shapingScriptLabel;

  /// No description provided for @shapingLanguageLabel.
  ///
  /// In en, this message translates to:
  /// **'language (4 characters)'**
  String get shapingLanguageLabel;

  /// No description provided for @shapingTagNote.
  ///
  /// In en, this message translates to:
  /// **'Tags must be exactly 4 characters, including trailing spaces (Turkish is \'TRK \'). Leave empty to use the font\'s DFLT/latn default language system; only then do locale-specific substitutions such as locl apply.'**
  String get shapingTagNote;

  /// No description provided for @browserTitle.
  ///
  /// In en, this message translates to:
  /// **'Glyph browser: cmap / COLR / bitmaps'**
  String get browserTitle;

  /// No description provided for @browserSearchLabel.
  ///
  /// In en, this message translates to:
  /// **'Search character / glyphId / U+ codepoint'**
  String get browserSearchLabel;

  /// No description provided for @browserSearchHint.
  ///
  /// In en, this message translates to:
  /// **'A, U+4E00, 0x2764 or 36'**
  String get browserSearchHint;

  /// No description provided for @browserCmapSummary.
  ///
  /// In en, this message translates to:
  /// **'{total} cmap mappings{truncated}. Tap a tile to inspect that glyph.'**
  String browserCmapSummary(String total, String truncated);

  /// No description provided for @browserTruncated.
  ///
  /// In en, this message translates to:
  /// **' (showing the first {count})'**
  String browserTruncated(String count);

  /// No description provided for @browserModeOutline.
  ///
  /// In en, this message translates to:
  /// **'Outline'**
  String get browserModeOutline;

  /// No description provided for @browserModeBitmap.
  ///
  /// In en, this message translates to:
  /// **'Bitmap'**
  String get browserModeBitmap;

  /// No description provided for @browserPreviewTitle.
  ///
  /// In en, this message translates to:
  /// **'Glyph preview'**
  String get browserPreviewTitle;

  /// No description provided for @browserGlyphTitle.
  ///
  /// In en, this message translates to:
  /// **'Glyph #{glyphId} · {char}'**
  String browserGlyphTitle(String glyphId, String char);

  /// No description provided for @browserPalette.
  ///
  /// In en, this message translates to:
  /// **'Palette {index}'**
  String browserPalette(String index);

  /// No description provided for @browserPreviewNote.
  ///
  /// In en, this message translates to:
  /// **'Outlines use GlyphOutline.toPath(), COLR layers use ColorGlyphInfo.paint(), bitmaps are decoded from sbix/CBDT/EBDT RGBA or PNG bytes. The blue lines mark the baseline and the em box.'**
  String get browserPreviewNote;

  /// No description provided for @browserMetricsTitle.
  ///
  /// In en, this message translates to:
  /// **'Glyph metrics (size = {size} px)'**
  String browserMetricsTitle(String size);

  /// No description provided for @browserOptionalTitle.
  ///
  /// In en, this message translates to:
  /// **'Optional table data'**
  String get browserOptionalTitle;

  /// No description provided for @browserMath.
  ///
  /// In en, this message translates to:
  /// **'italic {italic}, accent {accent}, {kerns} corner kern sets'**
  String browserMath(String italic, String accent, String kerns);

  /// No description provided for @browserAssemblyParts.
  ///
  /// In en, this message translates to:
  /// **'Stretchy parts'**
  String get browserAssemblyParts;

  /// No description provided for @browserVariantsInfo.
  ///
  /// In en, this message translates to:
  /// **'{sizes} sizes, {parts} assembly parts'**
  String browserVariantsInfo(String sizes, String parts);

  /// No description provided for @browserVarcComponents.
  ///
  /// In en, this message translates to:
  /// **'{count} components'**
  String browserVarcComponents(String count);

  /// No description provided for @browserColorInfo.
  ///
  /// In en, this message translates to:
  /// **'{format}, {layers} layers, {palettes} palettes'**
  String browserColorInfo(String format, String layers, String palettes);

  /// No description provided for @browserBitmapInfo.
  ///
  /// In en, this message translates to:
  /// **'{format} {width}×{height}, {ppem} ppem, origin {origin}'**
  String browserBitmapInfo(
    String format,
    String width,
    String height,
    String ppem,
    String origin,
  );

  /// No description provided for @browserConditionUnmet.
  ///
  /// In en, this message translates to:
  /// **'(condition unmet)'**
  String get browserConditionUnmet;

  /// No description provided for @browserVariantsTitle.
  ///
  /// In en, this message translates to:
  /// **'Variation selectors (cmap format 14)'**
  String get browserVariantsTitle;

  /// No description provided for @browserNoUvs.
  ///
  /// In en, this message translates to:
  /// **'This font has no UVS mappings.'**
  String get browserNoUvs;

  /// No description provided for @toolsTitle.
  ///
  /// In en, this message translates to:
  /// **'Font tools: tables / subset / patch'**
  String get toolsTitle;

  /// No description provided for @toolsRawTablesTitle.
  ///
  /// In en, this message translates to:
  /// **'Raw table bytes'**
  String get toolsRawTablesTitle;

  /// No description provided for @toolsRawTablesNote.
  ///
  /// In en, this message translates to:
  /// **'tableData(tag:) returns the bytes of that table. Offsets inside a table are relative to the start of this data; an absent tag returns null.'**
  String get toolsRawTablesNote;

  /// No description provided for @toolsTableEmpty.
  ///
  /// In en, this message translates to:
  /// **'This table is empty or missing.'**
  String get toolsTableEmpty;

  /// No description provided for @toolsHexMore.
  ///
  /// In en, this message translates to:
  /// **'… {count} more bytes not shown'**
  String toolsHexMore(String count);

  /// No description provided for @toolsExtendedTitle.
  ///
  /// In en, this message translates to:
  /// **'Extended tables (SVG / gasp / meta / BASE / AAT)'**
  String get toolsExtendedTitle;

  /// No description provided for @toolsTableTagCount.
  ///
  /// In en, this message translates to:
  /// **'Table tags'**
  String get toolsTableTagCount;

  /// No description provided for @toolsFlags.
  ///
  /// In en, this message translates to:
  /// **'Flags'**
  String get toolsFlags;

  /// No description provided for @toolsSvgDocs.
  ///
  /// In en, this message translates to:
  /// **'SVG documents'**
  String get toolsSvgDocs;

  /// No description provided for @toolsGaspRanges.
  ///
  /// In en, this message translates to:
  /// **'gasp ranges'**
  String get toolsGaspRanges;

  /// No description provided for @toolsMetaEntries.
  ///
  /// In en, this message translates to:
  /// **'meta entries'**
  String get toolsMetaEntries;

  /// No description provided for @toolsAatTables.
  ///
  /// In en, this message translates to:
  /// **'AAT tables'**
  String get toolsAatTables;

  /// No description provided for @toolsNamesTitle.
  ///
  /// In en, this message translates to:
  /// **'name table records (nameId = 1, every localized family name)'**
  String get toolsNamesTitle;

  /// No description provided for @toolsNoNameRecords.
  ///
  /// In en, this message translates to:
  /// **'No name records.'**
  String get toolsNoNameRecords;

  /// No description provided for @toolsSubsetTitle.
  ///
  /// In en, this message translates to:
  /// **'Subsetting (skera / subsetFont)'**
  String get toolsSubsetTitle;

  /// No description provided for @toolsSubsetCharsLabel.
  ///
  /// In en, this message translates to:
  /// **'Characters to keep'**
  String get toolsSubsetCharsLabel;

  /// No description provided for @toolsSubsetCharsHint.
  ///
  /// In en, this message translates to:
  /// **'The layout closure brings in glyphs needed by ligatures, variants and combining marks'**
  String get toolsSubsetCharsHint;

  /// No description provided for @toolsNoHinting.
  ///
  /// In en, this message translates to:
  /// **'Strip TrueType instructions (noHinting)'**
  String get toolsNoHinting;

  /// No description provided for @toolsRetainGlyphIds.
  ///
  /// In en, this message translates to:
  /// **'Keep original glyph ids (retainGlyphIds)'**
  String get toolsRetainGlyphIds;

  /// No description provided for @toolsSubsetButton.
  ///
  /// In en, this message translates to:
  /// **'Build subset'**
  String get toolsSubsetButton;

  /// No description provided for @toolsSaveSubset.
  ///
  /// In en, this message translates to:
  /// **'Save subset .ttf'**
  String get toolsSaveSubset;

  /// No description provided for @toolsModifyTitle.
  ///
  /// In en, this message translates to:
  /// **'Patch an existing font (modifyFont)'**
  String get toolsModifyTitle;

  /// No description provided for @toolsNewFamily.
  ///
  /// In en, this message translates to:
  /// **'New family name'**
  String get toolsNewFamily;

  /// No description provided for @toolsSubfamily.
  ///
  /// In en, this message translates to:
  /// **'Subfamily (affects OS/2 weight)'**
  String get toolsSubfamily;

  /// No description provided for @toolsDesignerLabel.
  ///
  /// In en, this message translates to:
  /// **'Designer (nameId 9)'**
  String get toolsDesignerLabel;

  /// No description provided for @toolsKernPair.
  ///
  /// In en, this message translates to:
  /// **'Kern pair'**
  String get toolsKernPair;

  /// No description provided for @toolsKernValue.
  ///
  /// In en, this message translates to:
  /// **'kern value (font units)'**
  String get toolsKernValue;

  /// No description provided for @toolsPatchButton.
  ///
  /// In en, this message translates to:
  /// **'Patch and read back'**
  String get toolsPatchButton;

  /// No description provided for @toolsUnchangedOutlines.
  ///
  /// In en, this message translates to:
  /// **'{before} → {after} (outlines unchanged)'**
  String toolsUnchangedOutlines(String before, String after);

  /// No description provided for @toolsSavePatched.
  ///
  /// In en, this message translates to:
  /// **'Save patched .ttf'**
  String get toolsSavePatched;

  /// No description provided for @toolsPinnedTitle.
  ///
  /// In en, this message translates to:
  /// **'Pinned variation location (withVariations)'**
  String get toolsPinnedTitle;

  /// No description provided for @toolsPinnedNote.
  ///
  /// In en, this message translates to:
  /// **'This is just a handle over the same bytes with a fixed location; it does not produce a static instance. Use subsetFont above to actually make the font smaller.'**
  String get toolsPinnedNote;

  /// No description provided for @toolsNoVisibleAxes.
  ///
  /// In en, this message translates to:
  /// **'This font has no visible variation axes.'**
  String get toolsNoVisibleAxes;

  /// No description provided for @toolsDefaultAAdvance.
  ///
  /// In en, this message translates to:
  /// **'Default A advance'**
  String get toolsDefaultAAdvance;

  /// No description provided for @toolsPinnedAAdvance.
  ///
  /// In en, this message translates to:
  /// **'Pinned A advance'**
  String get toolsPinnedAAdvance;

  /// No description provided for @editorTitle.
  ///
  /// In en, this message translates to:
  /// **'Draw a font: buildFont'**
  String get editorTitle;

  /// No description provided for @editorDrawFirst.
  ///
  /// In en, this message translates to:
  /// **'Draw something for {char} on the board first'**
  String editorDrawFirst(String char);

  /// No description provided for @editorSetDefault.
  ///
  /// In en, this message translates to:
  /// **'Set {char} as the default glyph'**
  String editorSetDefault(String char);

  /// No description provided for @editorSavedMaster.
  ///
  /// In en, this message translates to:
  /// **'Saved {char} as a master at {tag} {value}'**
  String editorSavedMaster(String char, String tag, String value);

  /// No description provided for @editorSavedVariant.
  ///
  /// In en, this message translates to:
  /// **'Saved the strokes as {set} for {char}'**
  String editorSavedVariant(String char, String set);

  /// No description provided for @editorNoGlyphs.
  ///
  /// In en, this message translates to:
  /// **'No glyphs yet — draw a stroke before building'**
  String get editorNoGlyphs;

  /// No description provided for @editorCharLabel.
  ///
  /// In en, this message translates to:
  /// **'Character to bind'**
  String get editorCharLabel;

  /// No description provided for @editorCharHint.
  ///
  /// In en, this message translates to:
  /// **'Only the first rune is used'**
  String get editorCharHint;

  /// No description provided for @editorFamilyLabel.
  ///
  /// In en, this message translates to:
  /// **'Font family name'**
  String get editorFamilyLabel;

  /// No description provided for @editorStrokeWidth.
  ///
  /// In en, this message translates to:
  /// **'Stroke width'**
  String get editorStrokeWidth;

  /// No description provided for @editorMastersTitle.
  ///
  /// In en, this message translates to:
  /// **'Variable font masters ({tag})'**
  String editorMastersTitle(String tag);

  /// No description provided for @editorSaveToPosition.
  ///
  /// In en, this message translates to:
  /// **'Save to position'**
  String get editorSaveToPosition;

  /// No description provided for @editorUndo.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get editorUndo;

  /// No description provided for @editorClear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get editorClear;

  /// No description provided for @editorSetDefaultGlyph.
  ///
  /// In en, this message translates to:
  /// **'Set as default glyph'**
  String get editorSetDefaultGlyph;

  /// No description provided for @editorSaveAsMaster.
  ///
  /// In en, this message translates to:
  /// **'Save as master'**
  String get editorSaveAsMaster;

  /// No description provided for @editorDefaultValue.
  ///
  /// In en, this message translates to:
  /// **'Default {value}'**
  String editorDefaultValue(String value);

  /// No description provided for @editorVariantsTitle.
  ///
  /// In en, this message translates to:
  /// **'Character variants (ss01–ss20, GSUB discrete substitutions)'**
  String get editorVariantsTitle;

  /// No description provided for @editorFeatureTag.
  ///
  /// In en, this message translates to:
  /// **'Feature tag'**
  String get editorFeatureTag;

  /// No description provided for @editorSaveVariant.
  ///
  /// In en, this message translates to:
  /// **'Save as variant'**
  String get editorSaveVariant;

  /// No description provided for @editorCharsAdded.
  ///
  /// In en, this message translates to:
  /// **'{count} characters added'**
  String editorCharsAdded(String count);

  /// No description provided for @editorBuildButton.
  ///
  /// In en, this message translates to:
  /// **'Build font'**
  String get editorBuildButton;

  /// No description provided for @editorResultTitle.
  ///
  /// In en, this message translates to:
  /// **'Build result'**
  String get editorResultTitle;

  /// No description provided for @editorNoAxes.
  ///
  /// In en, this message translates to:
  /// **'None (static font)'**
  String get editorNoAxes;

  /// No description provided for @editorResultInstances.
  ///
  /// In en, this message translates to:
  /// **'Named instances'**
  String get editorResultInstances;

  /// No description provided for @editorResultGsubVariants.
  ///
  /// In en, this message translates to:
  /// **'GSUB variants'**
  String get editorResultGsubVariants;

  /// No description provided for @editorRenderCompare.
  ///
  /// In en, this message translates to:
  /// **'Render comparison'**
  String get editorRenderCompare;

  /// No description provided for @editorCustomFont.
  ///
  /// In en, this message translates to:
  /// **'Custom font'**
  String get editorCustomFont;

  /// No description provided for @editorSystemFont.
  ///
  /// In en, this message translates to:
  /// **'System font'**
  String get editorSystemFont;

  /// No description provided for @editorInterpolationPreview.
  ///
  /// In en, this message translates to:
  /// **'Interpolate along {tag}'**
  String editorInterpolationPreview(String tag);

  /// No description provided for @editorDragSlider.
  ///
  /// In en, this message translates to:
  /// **'Drag the slider to interpolate'**
  String get editorDragSlider;

  /// No description provided for @editorVariantsPreview.
  ///
  /// In en, this message translates to:
  /// **'Character variant preview'**
  String get editorVariantsPreview;

  /// No description provided for @editorVariantsPreviewNote.
  ///
  /// In en, this message translates to:
  /// **'Enable ss01–ss20 with FontFeature; if nothing changes, the platform\'s text engine does not support the feature.'**
  String get editorVariantsPreviewNote;

  /// No description provided for @editorExport.
  ///
  /// In en, this message translates to:
  /// **'Export .ttf'**
  String get editorExport;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
