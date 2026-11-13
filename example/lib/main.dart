import 'package:fontations/fontations.dart';
import 'package:material_ui/material_ui.dart';

import 'demo_widgets.dart';
import 'font_info_page.dart';
import 'font_source.dart';
import 'font_tools_page.dart';
import 'glyph_browser_page.dart';
import 'glyph_editor_page.dart';
import 'l10n/app_localizations.dart';
import 'locale_switcher.dart';
import 'shaping_page.dart';
import 'theme_switcher.dart';

/// Localizations for the whole app: the generated catalog plus the Material,
/// Cupertino and Widgets delegates that now ship in `package:material_ui`.
///
/// `GlobalMaterialLocalizations.delegates` is the post-3.50 replacement for
/// `AppLocalizations.localizationsDelegates`. The latter still points at
/// `package:flutter_localizations`, which supplies the *legacy*
/// `MaterialLocalizations` type; mixing it with material_ui widgets makes
/// AppBar/Tooltip/etc. fail with "No MaterialLocalizations found".
/// See the "Decoupled localizations" section of the migration guide.
const List<LocalizationsDelegate<dynamic>> appLocalizationsDelegates = [
  AppLocalizations.delegate,
  ...GlobalMaterialLocalizations.delegates,
];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initFontations();
  // Start on the bundled font; the pages can open any other file afterwards.
  await fontSource.loadBundled();
  runApp(const FontationsExampleApp());
}

class FontationsExampleApp extends StatelessWidget {
  const FontationsExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Both settings live outside the widget tree so the AppBar menus can
    // change them; rebuild MaterialApp whenever either one changes.
    return ListenableBuilder(
      listenable: Listenable.merge([appLanguage, appThemeMode]),
      builder: (context, _) => MaterialApp(
        // The device locale / brightness win unless the user picked an
        // override in LanguageMenu or ThemeMenu.
        onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: localeOf(appLanguage.value),
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        themeMode: appThemeMode.value,
        home: const ExampleShell(),
      ),
    );
  }
}

ThemeData _theme(Brightness brightness) => ThemeData(
  colorScheme: ColorScheme.fromSeed(
    seedColor: const Color(0xFF6750A4),
    brightness: brightness,
  ),
  useMaterial3: true,
);

/// The pages, in navigation order.
const List<Widget> _pages = [
  FontInfoPage(),
  ShapingPage(),
  GlyphBrowserPage(),
  FontToolsPage(),
  GlyphEditorPage(),
];

/// Labels are resolved from the active locale, so these cannot be `const`.
List<({IconData icon, IconData selected, String label})> _destinations(
  AppLocalizations l,
) => [
  (
    icon: Icons.text_fields_outlined,
    selected: Icons.text_fields,
    label: l.navInfo,
  ),
  (
    icon: Icons.format_shapes_outlined,
    selected: Icons.format_shapes,
    label: l.navShaping,
  ),
  (
    icon: Icons.grid_view_outlined,
    selected: Icons.grid_view,
    label: l.navGlyphs,
  ),
  (icon: Icons.build_outlined, selected: Icons.build, label: l.navTools),
  (icon: Icons.brush_outlined, selected: Icons.brush, label: l.navEditor),
];

/// Shell with the five demos: reading a font, shaping a run of text,
/// inspecting glyphs, patching/subsetting a font, and writing a new one.
///
/// On a wide window the navigation becomes a rail and the pages lay their
/// content out in columns, which is what a desktop window expects.
class ExampleShell extends StatefulWidget {
  const ExampleShell({super.key});

  @override
  State<ExampleShell> createState() => _ExampleShellState();
}

class _ExampleShellState extends State<ExampleShell> {
  int _index = 0;

  void _select(int index) => setState(() => _index = index);

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final items = _destinations(l);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= wideBreakpoint;
        final body = IndexedStack(index: _index, children: _pages);

        if (!wide) {
          return Scaffold(
            body: SafeArea(child: body),
            bottomNavigationBar: NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: _select,
              destinations: [
                for (final destination in items)
                  NavigationDestination(
                    icon: Icon(destination.icon),
                    selectedIcon: Icon(destination.selected),
                    label: destination.label,
                  ),
              ],
            ),
          );
        }

        return Scaffold(
          body: SafeArea(
            child: Row(
              children: [
                NavigationRail(
                  selectedIndex: _index,
                  onDestinationSelected: _select,
                  // Labels come back once there is room for them, so a
                  // maximized window does not waste the strip.
                  extended: constraints.maxWidth >= 1240,
                  minExtendedWidth: 180,
                  groupAlignment: -0.9,
                  leading: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: FlutterLogo(size: 32),
                  ),
                  destinations: [
                    for (final destination in items)
                      NavigationRailDestination(
                        icon: Icon(destination.icon),
                        selectedIcon: Icon(destination.selected),
                        label: Text(destination.label),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: body),
              ],
            ),
          ),
        );
      },
    );
  }
}
