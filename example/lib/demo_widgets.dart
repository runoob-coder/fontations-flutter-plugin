import 'package:flutter/material.dart';

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

/// A readable version of a failure.
///
/// The Rust side reports through `anyhow`, whose message carries a full stack
/// backtrace in debug builds. Only the first line says anything a user needs.
String describeError(Object error) {
  final firstLine = error.toString().trim().split('\n').first.trim();
  if (firstLine.length <= 200) return firstLine;
  return '${firstLine.substring(0, 200)}…';
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
