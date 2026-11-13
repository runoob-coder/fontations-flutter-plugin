import 'dart:io' show Directory, File, Platform;
import 'dart:typed_data' show Uint8List, Uint32List;

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:fontations/fontations.dart';
import 'package:fontations_example/demo_widgets.dart';
import 'package:fontations_example/font_info_page.dart';
import 'package:fontations_example/font_source.dart';
import 'package:fontations_example/font_tools_page.dart';
import 'package:fontations_example/glyph_browser_page.dart';
import 'package:fontations_example/glyph_editor_page.dart';
import 'package:fontations_example/l10n/app_localizations.dart';
import 'package:fontations_example/locale_switcher.dart';
import 'package:fontations_example/main.dart';
import 'package:fontations_example/shaping_page.dart';
import 'package:fontations_example/theme_switcher.dart';
import 'package:material_ui/material_ui.dart';

/// Fast, device-free counterpart to `integration_test/simple_test.dart`.
///
/// It loads the real Rust library (so a wrong API call fails here, not only on
/// a device) and checks that every demo page can lay itself out at a phone and
/// a desktop size, plus the interactions that used to be silent no-ops.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final exampleDir = Directory.current.path;
    final root = Directory('$exampleDir/..').resolveSymbolicLinksSync();
    final libraryName = Platform.isMacOS
        ? 'libfontations.dylib'
        : Platform.isLinux
        ? 'libfontations.so'
        : 'fontations.dll';
    // The generated loader looks for `rust/target/release/` relative to the
    // working directory, but `flutter test` starts in example/. Point it at
    // the repo root for the duration of the (async) library load.
    if (File('$root/rust/target/release/$libraryName').existsSync()) {
      Directory.current = root;
    }
    try {
      await initFontations();
    } finally {
      Directory.current = exampleDir;
    }
    await fontSource.loadBundled();
  });

  void setLogicalSize(WidgetTester tester, Size size) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
  }

  /// The pages call `AppLocalizations.of(context)`, so tests must provide the
  /// generated delegates. Chinese is the default here to keep the assertions
  /// readable; pass `Locale('en')` to check the English strings instead.
  Widget localizedApp(Widget body, {Locale locale = const Locale('zh')}) =>
      MaterialApp(
        locale: locale,
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: body),
      );

  /// The brightness a page actually sees, not just the configured mode.
  Brightness brightnessOf(WidgetTester tester) =>
      Theme.of(tester.element(find.byType(Scaffold).first)).brightness;

  Future<void> pickThemeMode(WidgetTester tester, int itemIndex) async {
    // IndexedStack builds every page, so restrict taps to the first (visible)
    // AppBar menu. Tap the menu row rather than its inner Text.
    await tester.tap(find.byType(PopupMenuButton<ThemeMode>).first);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byType(CheckedPopupMenuItem<ThemeMode>).at(itemIndex),
    );
    await tester.pumpAndSettle();
  }

  test('the design-system migration stays complete', () {
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      expect(
        source.contains('package:flutter/material.dart'),
        isFalse,
        reason: '${entity.path} must use package:material_ui/material_ui.dart',
      );
      expect(
        source.contains('SwitchListTile.adaptive('),
        isFalse,
        reason: '${entity.path} must not use platform-adaptive switches',
      );
      expect(
        source.contains('>= 900') || source.contains('>= 820'),
        isFalse,
        reason: '${entity.path} must use the shared wideBreakpoint',
      );
    }
    expect(wideBreakpoint, 900.0);
  });

  testWidgets('every page lays out at phone and desktop sizes', (tester) async {
    addTearDown(tester.view.reset);
    for (final size in const [Size(390, 844), Size(1440, 900)]) {
      setLogicalSize(tester, size);
      for (final page in const <Widget>[
        ExampleShell(),
        FontInfoPage(),
        ShapingPage(),
        GlyphBrowserPage(),
        FontToolsPage(),
        GlyphEditorPage(),
      ]) {
        await tester.pumpWidget(localizedApp(page));
        await tester.pumpAndSettle();
      }
    }
  });

  group('the glyph editor board on small screens', () {
    const phone = Size(390, 844);
    const landscape = Size(844, 390);
    const desktop = Size(1440, 900);

    double boardSide(WidgetTester tester) =>
        tester.getSize(find.byKey(const Key('glyph-board'))).width;

    testWidgets('the board fills the phone width instead of being squeezed', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      setLogicalSize(tester, phone);
      await tester.pumpWidget(localizedApp(const GlyphEditorPage()));
      await tester.pumpAndSettle();

      // 390 - 2 * 16 padding = 358. The old 1:4 flex split left only ~150.
      expect(boardSide(tester), greaterThan(300));
      expect(boardSide(tester), lessThanOrEqualTo(phone.width - 32 + 0.01));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a short landscape window keeps a usable board', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      setLogicalSize(tester, landscape);
      await tester.pumpWidget(localizedApp(const GlyphEditorPage()));
      await tester.pumpAndSettle();

      expect(boardSide(tester), greaterThan(250));
      expect(tester.takeException(), isNull);
    });

    testWidgets('focus mode hides the controls and can be left', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      setLogicalSize(tester, phone);
      await tester.pumpWidget(localizedApp(const GlyphEditorPage()));
      await tester.pumpAndSettle();
      expect(find.text('笔画粗细'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.fullscreen));
      await tester.pumpAndSettle();
      expect(find.text('笔画粗细'), findsNothing);
      expect(find.byKey(const Key('glyph-board')), findsOneWidget);
      expect(find.byIcon(Icons.undo), findsOneWidget);
      expect(find.byIcon(Icons.clear), findsOneWidget);

      await tester.tap(find.byIcon(Icons.fullscreen_exit));
      await tester.pumpAndSettle();
      expect(find.text('笔画粗细'), findsOneWidget);
    });

    testWidgets('drawing keeps working when the board is resized', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      setLogicalSize(tester, phone);
      await tester.pumpWidget(localizedApp(const GlyphEditorPage()));
      await tester.pumpAndSettle();

      final board = find.byKey(const Key('glyph-board'));
      final phoneSide = boardSide(tester);
      await tester.drag(board, const Offset(60, 40));
      await tester.pumpAndSettle();

      // Strokes are size-independent, so the board can grow freely.
      setLogicalSize(tester, desktop);
      await tester.pumpAndSettle();
      expect(boardSide(tester), greaterThan(phoneSide));

      await tester.drag(board, const Offset(-40, 20));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('the glyph browser reads cmap and one glyph', (tester) async {
    addTearDown(tester.view.reset);
    setLogicalSize(tester, const Size(1440, 900));
    await tester.pumpWidget(localizedApp(const GlyphBrowserPage()));
    await tester.pumpAndSettle();
    // `Font.outline` runs on the real async zone; give the FFI future a real
    // moment to complete before asking for the cards it populates.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('条 cmap 映射'), findsOneWidget);
    // These cards only appear once the asynchronous outline load finished.
    expect(find.text('字形度量（size = 120 px）'), findsOneWidget);
    expect(find.text('skrifa scaler'), findsOneWidget);
  });

  testWidgets('the tools page exposes raw tables and pinned variations', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    setLogicalSize(tester, const Size(1440, 900));
    await tester.pumpWidget(localizedApp(const FontToolsPage()));
    await tester.pumpAndSettle();

    expect(find.text('任意表原始字节'), findsOneWidget);
    expect(find.text('hasTable'), findsOneWidget);
    expect(find.text('固定变体位置（withVariations）'), findsOneWidget);
    expect(find.text('pinnedVariations'), findsOneWidget);
  });

  test('subsetting and patching the bundled font both round-trip', () async {
    final data = await rootBundle.load('assets/fonts/Inter.ttf');
    final bytes = data.buffer.asUint8List();

    final subset = await subsetFont(
      bytes: bytes,
      request: FontSubsetRequest(
        codePoints: Uint32List.fromList('Hello'.runes.toList()),
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
    expect(readFontInfo(bytes: subset).metrics.glyphCount, greaterThan(0));

    final patched = await modifyFont(
      bytes: bytes,
      request: const FontModificationRequest(
        familyName: 'Patched',
        subfamilyName: 'Bold',
        designer: 'example',
        kernPairs: [KernPair(left: 0x41, right: 0x56, value: -80)],
        ligatures: [],
        alternates: [],
      ),
    );
    final patchedFont = Font.fromBytes(bytes: patched);
    expect(patchedFont.info().names.family, 'Patched');
    expect(patchedFont.attributes().weight, 700);
    expect(patchedFont.layout().expand((table) => table.features), isNotEmpty);
  });

  testWidgets('switching feature modes reshapes instead of doing nothing', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    setLogicalSize(tester, const Size(1440, 900));
    await tester.pumpWidget(localizedApp(const ShapingPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('全部关闭'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ChoiceChip>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is ChoiceChip &&
                  widget.label is Text &&
                  (widget.label as Text).data == '全部关闭',
            ),
          )
          .selected,
      isTrue,
    );

    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('默认'));
    await tester.pumpAndSettle();
    expect(find.text('字形序列'), findsOneWidget);
    // The shared font picker is reachable from every page, not just the first.
    expect(find.text('打开字体文件…'), findsOneWidget);
  });

  testWidgets('switches stay Material on Apple platforms too', (tester) async {
    addTearDown(tester.view.reset);
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    // A tall viewport makes the pages' ListViews build all of their children.
    setLogicalSize(tester, const Size(1440, 4000));

    // `SwitchListTile.adaptive` would build a CupertinoSwitch on iOS/macOS.
    final cupertinoSwitch = find.byWidgetPredicate(
      (widget) => widget.runtimeType.toString().contains('CupertinoSwitch'),
    );
    for (final page in const <Widget>[
      FontInfoPage(),
      ShapingPage(),
      FontToolsPage(),
    ]) {
      await tester.pumpWidget(localizedApp(page));
      await tester.pumpAndSettle();

      final tiles = find.byType(SwitchListTile).evaluate().length;
      expect(tiles, greaterThan(0), reason: '$page should have a switch');
      expect(find.byType(Switch), findsNWidgets(tiles));
      expect(cupertinoSwitch, findsNothing);
    }
  });

  testWidgets('both locales resolve their own catalog', (tester) async {
    addTearDown(tester.view.reset);
    setLogicalSize(tester, const Size(1440, 900));

    await tester.pumpWidget(localizedApp(const ShapingPage()));
    await tester.pumpAndSettle();
    expect(find.text('全部关闭'), findsOneWidget);
    expect(find.text('All off'), findsNothing);

    await tester.pumpWidget(
      localizedApp(const ShapingPage(), locale: const Locale('en')),
    );
    await tester.pumpAndSettle();
    expect(find.text('All off'), findsOneWidget);
    expect(find.text('全部关闭'), findsNothing);
  });

  testWidgets('the language menu switches the app without a restart', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    addTearDown(() => appLanguage.value = AppLanguage.system);
    setLogicalSize(tester, const Size(1440, 900));
    appLanguage.value = AppLanguage.chinese;

    await tester.pumpWidget(const FontationsExampleApp());
    await tester.pumpAndSettle();
    expect(find.text('解析字体'), findsWidgets);

    // Every page has the menu, so pick the one that is actually on screen.
    await tester.tap(find.byIcon(Icons.translate).first);
    await tester.pumpAndSettle();
    // Tap the menu row rather than its inner Text: the popup transform can
    // make a text-centre tap miss the hit-test target.
    await tester.tap(find.byType(CheckedPopupMenuItem<AppLanguage>).last);
    await tester.pumpAndSettle();
    expect(find.text('Font info'), findsWidgets);
    expect(find.text('解析字体'), findsNothing);
  });

  testWidgets('the theme menu picks light and dark without a restart', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    addTearDown(() => appThemeMode.value = ThemeMode.system);
    setLogicalSize(tester, const Size(1440, 900));
    appThemeMode.value = ThemeMode.system;
    // Keep the platform brightness deterministic for the assertions below.
    tester.view.platformDispatcher.platformBrightnessTestValue =
        Brightness.light;
    addTearDown(
      () => tester.view.platformDispatcher.clearPlatformBrightnessTestValue(),
    );

    await tester.pumpWidget(const FontationsExampleApp());
    await tester.pumpAndSettle();
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.system,
    );
    expect(brightnessOf(tester), Brightness.light);
    expect(find.byIcon(Icons.brightness_auto), findsWidgets);

    await pickThemeMode(tester, 1); // 浅色 / Light
    expect(appThemeMode.value, ThemeMode.light);
    expect(brightnessOf(tester), Brightness.light);
    expect(find.byIcon(Icons.light_mode), findsWidgets);

    await pickThemeMode(tester, 2); // 深色 / Dark
    expect(appThemeMode.value, ThemeMode.dark);
    expect(brightnessOf(tester), Brightness.dark);
    expect(find.byIcon(Icons.dark_mode), findsWidgets);
  });

  testWidgets('system mode follows the platform brightness live', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    addTearDown(() => appThemeMode.value = ThemeMode.system);
    addTearDown(
      () => tester.view.platformDispatcher.clearPlatformBrightnessTestValue(),
    );
    setLogicalSize(tester, const Size(1440, 900));
    appThemeMode.value = ThemeMode.system;
    tester.view.platformDispatcher.platformBrightnessTestValue =
        Brightness.light;

    await tester.pumpWidget(const FontationsExampleApp());
    await tester.pumpAndSettle();
    expect(brightnessOf(tester), Brightness.light);

    // A change in the OS setting is picked up without rebuilding the app.
    tester.view.platformDispatcher.platformBrightnessTestValue =
        Brightness.dark;
    await tester.pumpAndSettle();
    expect(brightnessOf(tester), Brightness.dark);

    // An explicit override ignores the platform until "Follow system" is
    // picked again.
    appThemeMode.value = ThemeMode.light;
    await tester.pumpAndSettle();
    expect(brightnessOf(tester), Brightness.light);

    await pickThemeMode(tester, 0); // 跟随系统 / Follow system
    expect(appThemeMode.value, ThemeMode.system);
    expect(brightnessOf(tester), Brightness.dark);
  });

  test(
    'fontSource caches the Font handle and notifies only on real changes',
    () {
      var notifications = 0;
      void listener() => notifications++;
      fontSource.addListener(listener);
      addTearDown(() => fontSource.removeListener(listener));
      addTearDown(fontSource.loadBundled);

      final current = fontSource.current!;
      // All four reading pages share one Rust handle instead of parsing the
      // same bytes four times.
      expect(identical(fontSource.font, fontSource.font), isTrue);

      fontSource.select(current);
      fontSource.selectFace(current.index);
      expect(notifications, 0, reason: 're-selecting the same face is a no-op');

      fontSource.select(
        LoadedFont(name: 'other-face.ttf', bytes: current.bytes, faceCount: 1),
      );
      expect(notifications, 1);
      expect(identical(fontSource.font, fontSource.font), isTrue);
    },
  );

  testWidgets('a bad font never leaves a page without a way back', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    addTearDown(fontSource.loadBundled);
    setLogicalSize(tester, const Size(1440, 900));
    await fontSource.loadBundled();

    for (final page in const <Widget>[
      FontInfoPage(),
      ShapingPage(),
      GlyphBrowserPage(),
    ]) {
      await tester.pumpWidget(localizedApp(page));
      await tester.pumpAndSettle();

      fontSource.select(
        LoadedFont(
          name: 'not-a-font.ttf',
          bytes: Uint8List.fromList(List<int>.filled(64, 7)),
          faceCount: 1,
        ),
      );
      await tester.pumpAndSettle();
      // The failure is visible, but the picker stays reachable.
      expect(find.byType(ErrorBanner), findsWidgets);
      expect(find.text('打开字体文件…'), findsWidgets);

      await fontSource.loadBundled();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pumpAndSettle();
      // A good font clears the stale error instead of trapping the page.
      expect(find.byType(ErrorBanner), findsNothing);
    }
  });

  testWidgets('glyph search debounces and filters cmap entries', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    setLogicalSize(tester, const Size(1440, 900));
    await tester.pumpWidget(localizedApp(const GlyphBrowserPage()));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();

    // Each grid tile carries a Tooltip whose message starts with "U+".
    int tileCount() => find
        .byWidgetPredicate(
          (widget) =>
              widget is Tooltip && (widget.message ?? '').startsWith('U+'),
        )
        .evaluate()
        .length;
    expect(tileCount(), greaterThan(10));

    await tester.enterText(find.byType(TextField), 'U+0041');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(tileCount(), greaterThan(0));
    expect(tileCount(), lessThan(10));
  });
}
