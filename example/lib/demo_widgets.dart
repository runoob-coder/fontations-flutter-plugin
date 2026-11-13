import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

/// A titled card holding rows of label/value pairs or arbitrary children.
class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

/// One `label: value` line.
class InfoRow extends StatelessWidget {
  const InfoRow(this.label, this.value, {super.key, this.width = 110});

  final String label;
  final String? value;
  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: width,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value ?? '-',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A wrapped row of small tags.
class TagChips extends StatelessWidget {
  const TagChips(this.tags, {super.key, this.color, this.limit});

  final Iterable<String> tags;
  final Color? color;
  final int? limit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    var shown = tags.toList();
    final hidden = limit != null && shown.length > limit!
        ? shown.length - limit!
        : 0;
    if (hidden > 0) shown = shown.sublist(0, limit);
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final tag in shown)
          Chip(
            label: Text(tag),
            visualDensity: VisualDensity.compact,
            backgroundColor: color ?? theme.colorScheme.surfaceContainerHighest,
            side: BorderSide.none,
          ),
        if (hidden > 0) Chip(label: Text('+$hidden')),
      ],
    );
  }
}

/// A readable version of a failure (first line of an `anyhow` message).
String describeError(Object error) {
  final firstLine = error.toString().trim().split('\n').first.trim();
  if (firstLine.length <= 200) return firstLine;
  return '${firstLine.substring(0, 200)}…';
}

/// Saves font bytes; returns the chosen path, or `null` when cancelled.
Future<String?> saveFontBytes({
  required String fileName,
  required Uint8List bytes,
  String dialogTitle = 'Save font file',
}) async {
  final uri = await FilePicker.saveFile(
    dialogTitle: dialogTitle,
    fileName: fileName,
    bytes: bytes,
    // `type`/`allowedExtensions` are no-ops in saveFile().
    mimeType: 'font/ttf',
  );
  return uri?.toString();
}

/// Breakpoint shared by the shell and all pages.
const double wideBreakpoint = 900.0;

/// A compact strip describing the most recent failure.
class ErrorBanner extends StatelessWidget {
  const ErrorBanner(this.error, {super.key, this.message});

  final Object error;

  /// Optional localized context in front of the raw error.
  final String? message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
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
              message ?? describeError(error),
              maxLines: 3,
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

/// Shown when no font could be loaded.
class EmptyFontHint extends StatelessWidget {
  const EmptyFontHint({
    super.key,
    required this.label,
    required this.buttonLabel,
    required this.onOpen,
  });

  final String label;
  final String buttonLabel;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: onOpen,
          icon: const Icon(Icons.folder_open),
          label: Text(buttonLabel),
        ),
      ],
    ),
  );
}

/// A centred message, used for loading and error states.
class Message extends StatelessWidget {
  const Message(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Center(child: Text(text));
}

/// A labelled numeric slider with a value readout.
class LabeledSlider extends StatelessWidget {
  const LabeledSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.onChangedEnd,
    this.labelWidth = 96,
    this.valueWidth = 48,
    this.divisions,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangedEnd;
  final double labelWidth;
  final double valueWidth;
  final int? divisions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(width: labelWidth, child: Text(label)),
          Expanded(
            child: Slider(
              min: min,
              max: max,
              divisions: divisions,
              value: value.clamp(min, max),
              label: value.toStringAsFixed(0),
              onChanged: onChanged,
              onChangeEnd: onChangedEnd,
            ),
          ),
          SizedBox(
            width: valueWidth,
            child: Text(value.toStringAsFixed(0), textAlign: TextAlign.end),
          ),
        ],
      ),
    );
  }
}
