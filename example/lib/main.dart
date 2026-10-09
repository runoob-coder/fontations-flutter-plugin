import 'package:flutter/material.dart';
import 'package:fontations/fontations.dart';

import 'font_info_page.dart';
import 'font_source.dart';
import 'glyph_editor_page.dart';
import 'shaping_page.dart';

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
    return MaterialApp(
      title: 'fontations',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
        useMaterial3: true,
      ),
      home: const ExampleShell(),
    );
  }
}

/// Below this width the shell is a phone: content stacked, navigation at the
/// bottom. At or above it there is room for a rail and side by side columns.
const double _wideBreakpoint = 900.0;

/// The pages, in navigation order.
const List<Widget> _pages = [FontInfoPage(), ShapingPage(), GlyphEditorPage()];

const List<({IconData icon, IconData selected, String label})> _destinations = [
  (
    icon: Icons.text_fields_outlined,
    selected: Icons.text_fields,
    label: '解析字体',
  ),
  (
    icon: Icons.format_shapes_outlined,
    selected: Icons.format_shapes,
    label: '塑形',
  ),
  (icon: Icons.brush_outlined, selected: Icons.brush, label: '绘制造字'),
];

/// Shell with the three demos: reading a real font, shaping a run of text,
/// and writing a new one.
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= _wideBreakpoint;
        final body = IndexedStack(index: _index, children: _pages);

        if (!wide) {
          return Scaffold(
            body: SafeArea(child: body),
            bottomNavigationBar: NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: _select,
              destinations: [
                for (final destination in _destinations)
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
                    for (final destination in _destinations)
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
