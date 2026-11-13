import 'package:material_ui/material_ui.dart';

import 'demo_widgets.dart';
import 'font_source.dart';
import 'l10n/app_localizations.dart';

/// The one place every demo offers the question "which font am I looking at?".
///
/// The reading, shaping, glyph and tools pages all follow [fontSource], so all
/// of them need to be able to open a file without a trip back to the first tab.
/// Listening here (rather than in each page's state) keeps the picker spinner
/// and the most recent failure in sync everywhere.
class FontSourceControls extends StatelessWidget {
  const FontSourceControls({super.key, this.compact = false});

  /// Hides the long explanation and the list of already opened files.
  final bool compact;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([fontSource, fontSource.picking]),
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final current = fontSource.current;
    final opened = fontSource.opened;
    final error = fontSource.error;

    return SectionCard(
      title: compact ? l.sourceTitleCompact : l.sourceTitle,
      children: [
        if (error != null) ...[
          _OpenError(error: error),
          const SizedBox(height: 8),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: fontSource.picking.value
                  ? null
                  : () =>
                        fontSource.openFile(dialogTitle: l.pickFontDialogTitle),
              icon: fontSource.picking.value
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.folder_open),
              label: Text(l.openFontFile),
            ),
            OutlinedButton.icon(
              onPressed: fontSource.loadBundled,
              icon: const Icon(Icons.restart_alt),
              label: Text(l.bundledInter),
            ),
            if (current != null)
              Chip(
                avatar: const Icon(Icons.description_outlined, size: 16),
                label: Text(current.name),
              ),
          ],
        ),
        if (current != null && current.faceCount > 1) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              SizedBox(width: 110, child: Text(l.sourceCollection)),
              Expanded(
                child: DropdownButtonFormField<int>(
                  // The face index lives on `LoadedFont`, so a rebuilt page
                  // must not keep the previous file's selection.
                  key: ValueKey('${current.name}:${current.index}'),
                  initialValue: current.index,
                  isDense: true,
                  decoration: InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                  items: [
                    for (var i = 0; i < current.faceCount; i++)
                      DropdownMenuItem(
                        value: i,
                        child: Text(l.sourceFace('$i')),
                      ),
                  ],
                  onChanged: (index) {
                    if (index != null) fontSource.selectFace(index);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            l.sourceFaceCount('${current.faceCount}'),
            style: theme.textTheme.bodySmall,
          ),
        ],
        if (!compact && opened.length > 1) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final font in opened)
                ChoiceChip(
                  label: Text(font.name),
                  selected: font == current,
                  onSelected: (_) => fontSource.select(font),
                ),
            ],
          ),
        ],
        if (!compact) ...[
          const SizedBox(height: 4),
          Text(
            l.sourceFormats(fontExtensions.join(' / ')),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}

/// `FontSource.error` used to be write-only: a failed pick changed nothing on
/// screen, so it looked like the button simply did not work.
class _OpenError extends StatelessWidget {
  const _OpenError({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            Icons.error_outline,
            size: 18,
            color: theme.colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l.openFailed(describeError(error)),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
