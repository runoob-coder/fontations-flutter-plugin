import 'package:material_ui/material_ui.dart';
import 'package:simple_icons/simple_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import 'l10n/app_localizations.dart';

/// The repository this demo belongs to.
const String repositoryUrl =
    'https://github.com/runoob-coder/fontations-flutter-plugin';

/// An AppBar action that opens [repositoryUrl] in the browser.
class GitHubButton extends StatelessWidget {
  const GitHubButton({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return IconButton(
      icon: const Icon(SimpleIcons.github),
      tooltip: l.githubTooltip,
      onPressed: () => launchUrl(
        Uri.parse(repositoryUrl),
        mode: LaunchMode.externalApplication,
      ),
    );
  }
}
