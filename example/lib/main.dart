import 'package:fontations/fontations.dart';
import 'package:material_ui/material_ui.dart';

import 'app_palette.dart';
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

/// Localizations for the app; `GlobalMaterialLocalizations.delegates` matches
/// `package:material_ui`'s widgets.
const List<LocalizationsDelegate<dynamic>> appLocalizationsDelegates = [
  AppLocalizations.delegate,
  ...GlobalMaterialLocalizations.delegates,
];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initFontations();
  await fontSource.loadBundled();
  runApp(const FontationsExampleApp());
}

class FontationsExampleApp extends StatelessWidget {
  const FontationsExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([appLanguage, appThemeMode]),
      builder: (context, _) => MaterialApp(
        onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: localeOf(appLanguage.value),
        theme: appTheme(Brightness.light),
        darkTheme: appTheme(Brightness.dark),
        themeMode: appThemeMode.value,
        debugShowCheckedModeBanner: false,
        home: const ExampleShell(),
      ),
    );
  }
}

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

/// Shell with the five demos; wide windows use a navigation rail.
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
    final brand = BrandColors.of(context);
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
              indicatorColor: brand.tint(context, _index),
              destinations: [
                for (var i = 0; i < items.length; i++)
                  NavigationDestination(
                    icon: Icon(
                      items[i].icon,
                      color: brand.ink(context, i).withValues(alpha: 0.6),
                    ),
                    selectedIcon: Icon(
                      items[i].selected,
                      color: brand.ink(context, i),
                    ),
                    label: items[i].label,
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
                  indicatorColor: brand.tint(context, _index),
                  extended: constraints.maxWidth >= 1240,
                  minExtendedWidth: 180,
                  groupAlignment: -0.9,
                  leading: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Image.asset('assets/app_icon.png', width: 32),
                  ),
                  destinations: [
                    for (var i = 0; i < items.length; i++)
                      NavigationRailDestination(
                        icon: Icon(
                          items[i].icon,
                          color: brand.ink(context, i).withValues(alpha: 0.6),
                        ),
                        selectedIcon: Icon(
                          items[i].selected,
                          color: brand.ink(context, i),
                        ),
                        label: Text(items[i].label),
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
