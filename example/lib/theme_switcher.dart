import 'package:material_ui/material_ui.dart';

import 'l10n/app_localizations.dart';

/// Shared by [ThemeMenu] and `MaterialApp`; follows the system brightness by
/// default.
final ValueNotifier<ThemeMode> appThemeMode = ValueNotifier<ThemeMode>(
  ThemeMode.system,
);

/// The AppBar icon doubles as a readout of the active mode.
IconData themeModeIcon(ThemeMode mode) => switch (mode) {
  ThemeMode.system => Icons.brightness_auto,
  ThemeMode.light => Icons.light_mode,
  ThemeMode.dark => Icons.dark_mode,
};

/// A compact brightness picker, placed in every page's AppBar next to the
/// language menu.
class ThemeMenu extends StatelessWidget {
  const ThemeMenu({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appThemeMode,
      builder: (context, mode, _) => PopupMenuButton<ThemeMode>(
        icon: Icon(themeModeIcon(mode)),
        tooltip: l.themeMenuTooltip,
        initialValue: mode,
        onSelected: (value) => appThemeMode.value = value,
        itemBuilder: (context) => [
          CheckedPopupMenuItem<ThemeMode>(
            value: ThemeMode.system,
            checked: mode == ThemeMode.system,
            child: Text(l.themeSystem),
          ),
          CheckedPopupMenuItem<ThemeMode>(
            value: ThemeMode.light,
            checked: mode == ThemeMode.light,
            child: Text(l.themeLight),
          ),
          CheckedPopupMenuItem<ThemeMode>(
            value: ThemeMode.dark,
            checked: mode == ThemeMode.dark,
            child: Text(l.themeDark),
          ),
        ],
      ),
    );
  }
}
