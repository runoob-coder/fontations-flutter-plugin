import 'package:material_ui/material_ui.dart';

import 'l10n/app_localizations.dart';

/// Which language the demo uses.
///
/// `system` leaves `MaterialApp.locale` as `null`, which is the official
/// default: Flutter then resolves the device locale against
/// `AppLocalizations.supportedLocales`.
enum AppLanguage { system, chinese, english }

/// `null` means "follow the system locale".
Locale? localeOf(AppLanguage language) => switch (language) {
  AppLanguage.system => null,
  AppLanguage.chinese => const Locale('zh'),
  AppLanguage.english => const Locale('en'),
};

/// Shared by [LanguageMenu] and `MaterialApp` so a selection takes effect
/// without any page knowing about the app widget.
final ValueNotifier<AppLanguage> appLanguage = ValueNotifier<AppLanguage>(
  AppLanguage.system,
);

/// A compact language picker, placed in every page's AppBar.
///
/// Language names are written in their own language on purpose; only the
/// "follow system" entry needs a translation.
class LanguageMenu extends StatelessWidget {
  const LanguageMenu({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ValueListenableBuilder<AppLanguage>(
      valueListenable: appLanguage,
      builder: (context, language, _) => PopupMenuButton<AppLanguage>(
        icon: const Icon(Icons.translate),
        tooltip: l.languageMenuTooltip,
        initialValue: language,
        onSelected: (value) => appLanguage.value = value,
        itemBuilder: (context) => [
          CheckedPopupMenuItem<AppLanguage>(
            value: AppLanguage.system,
            checked: language == AppLanguage.system,
            child: Text(l.languageSystem),
          ),
          CheckedPopupMenuItem<AppLanguage>(
            value: AppLanguage.chinese,
            checked: language == AppLanguage.chinese,
            child: const Text('简体中文'),
          ),
          CheckedPopupMenuItem<AppLanguage>(
            value: AppLanguage.english,
            checked: language == AppLanguage.english,
            child: const Text('English'),
          ),
        ],
      ),
    );
  }
}
