import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:fontations/fontations.dart';

import 'demo_widgets.dart';
import 'font_source.dart';

/// The tags a shaper turns on when the caller names none, following HarfBuzz.
const Set<String> _defaultOnFeatures = {
  'abvm',
  'blwm',
  'ccmp',
  'locl',
  'mark',
  'mkmk',
  'rlig',
  'calt',
  'clig',
  'curs',
  'dist',
  'kern',
  'liga',
  'rclt',
};

/// Applies `GSUB` and `GPOS` to a run of text and draws the result.
///
/// `Font.layout` describes the layout tables; this page runs them. Every glyph
/// comes back with an advance and an offset, so a `CustomPainter` can place
/// them the same way a text engine would.
class ShapingPage extends StatefulWidget {
  const ShapingPage({super.key});

  @override
  State<ShapingPage> createState() => _ShapingPageState();
}

enum _FeatureMode { defaults, none, custom }

class _ShapingPageState extends State<ShapingPage> {
  final TextEditingController _textController = TextEditingController(
    text: 'To ffi fl AWAY',
  );

  Font? _font;
  FontInfo? _info;
  Object? _error;

  /// Every feature tag `GSUB` and `GPOS` declare, deduplicated and sorted.
  List<String> _availableFeatures = const [];

  _FeatureMode _mode = _FeatureMode.defaults;
  final Set<String> _selected = <String>{};

  double _fontSize = 72.0;
  bool _showMarkers = true;
  final Map<String, double> _axisValues = <String, double>{};

  List<_PlacedGlyph> _glyphs = const [];
  double _advance = 0;
  double _advanceRaw = 0;
  int _charCount = 0;

  @override
  void initState() {
    super.initState();
    _textController.addListener(_reshape);
    fontSource.addListener(_onSourceChanged);
    _onSourceChanged();
  }

  @override
  void dispose() {
    fontSource.removeListener(_onSourceChanged);
    _textController.removeListener(_reshape);
    _textController.dispose();
    super.dispose();
  }

  /// Shapes with whatever the reading page has open, so the two never drift.
  void _onSourceChanged() => _load(fontSource.current);

  Future<void> _load(LoadedFont? loaded) async {
    if (!mounted) return;
    if (loaded == null) {
      setState(() {
        _font = null;
        _info = null;
        _availableFeatures = const [];
        _glyphs = const [];
        _advance = 0;
        _advanceRaw = 0;
        _charCount = 0;
      });
      return;
    }
    try {
      final font = Font.fromBytes(bytes: loaded.bytes, index: loaded.index);
      final info = font.info();

      final features = {
        for (final table in font.layout())
          for (final feature in table.features) feature.tag,
      }.toList()..sort();

      _axisValues
        ..clear()
        ..addEntries(
          info.axes
              .where((axis) => !axis.hidden)
              .map((axis) => MapEntry(axis.tag, axis.defaultValue)),
        );

      setState(() {
        _font = font;
        _info = info;
        _availableFeatures = features;
        _selected.clear();
        _selected.addAll(features.where(_defaultOnFeatures.contains));
      });
      await _reshape();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  /// `null` asks for the defaults, an empty list turns everything off.
  List<String>? get _features => switch (_mode) {
    _FeatureMode.defaults => null,
    _FeatureMode.none => const <String>[],
    _FeatureMode.custom => _selected.toList()..sort(),
  };

  List<VariationSetting> get _variations => _axisValues.entries
      .map((entry) => VariationSetting(tag: entry.key, value: entry.value))
      .toList(growable: false);

  Future<void> _reshape() async {
    final font = _font;
    if (font == null) return;

    final variations = _variations;
    final result = font.shape(
      text: _textController.text,
      size: _fontSize,
      variations: variations,
      features: _features,
    );
    // The same run with every feature off, for comparison.
    final raw = font.shape(
      text: _textController.text,
      size: _fontSize,
      variations: variations,
      features: const <String>[],
    );

    final paths = <int, ui.Path>{};
    final glyphs = <_PlacedGlyph>[];
    var pen = 0.0;
    for (final glyph in result.glyphs) {
      final path = paths[glyph.glyphId] ??= (await font.outline(
        glyphId: glyph.glyphId,
        size: _fontSize,
        variations: variations,
      )).toPath();
      glyphs.add(_PlacedGlyph(path: path, pen: pen, glyph: glyph));
      pen += glyph.xAdvance;
    }

    if (!mounted) return;
    setState(() {
      _glyphs = glyphs;
      _advance = result.advance;
      _advanceRaw = raw.advance;
      _charCount = _textController.text.runes.length;
    });
  }

  void _toggleFeature(String tag) {
    setState(() {
      if (_mode == _FeatureMode.defaults) {
        // Leaving the defaults seeds the selection with what was on, so a
        // single tap turns one thing off instead of everything.
        _selected
          ..clear()
          ..addAll(_availableFeatures.where(_defaultOnFeatures.contains));
      } else if (_mode == _FeatureMode.none) {
        // Coming from "everything off", one tap turns exactly one thing on.
        _selected.clear();
      }
      _mode = _FeatureMode.custom;
      if (!_selected.remove(tag)) _selected.add(tag);
    });
    _reshape();
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    return Scaffold(
      appBar: AppBar(title: const Text('塑形：应用 GSUB / GPOS')),
      body: _error != null
          ? Message('无法解析这个字体文件\n\n${describeError(_error!)}')
          : info == null
          ? _EmptyFontHint(onOpen: fontSource.openFile)
          : _buildBody(context, info),
    );
  }

  Widget _buildBody(BuildContext context, FontInfo info) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final merged = _charCount - _glyphs.length;

    final input = TextField(
      controller: _textController,
      decoration: const InputDecoration(
        labelText: '待塑形的文本',
        helperText: '试试 fi / fl / ffi，或 AWAY 这类带字距的组合',
        border: OutlineInputBorder(),
      ),
    );

    final preview = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        input,
        const SizedBox(height: 12),
        _ShapedPreview(
          glyphs: _glyphs,
          fontSize: _fontSize,
          showMarkers: _showMarkers,
        ),
      ],
    );

    final stats = SectionCard(
      title: '结果',
      children: [
        InfoRow('字符数', '$_charCount'),
        InfoRow('字形数', '${_glyphs.length}'),
        InfoRow('连字合并', merged > 0 ? '$merged 个字符被合并' : '无'),
        InfoRow(
          '总步进',
          '${_advance.toStringAsFixed(1)} px'
              '${(_advance - _advanceRaw).abs() > 0.05 ? '（关闭全部特性时为 ${_advanceRaw.toStringAsFixed(1)}）' : ''}',
        ),
      ],
    );

    final sequence = SectionCard(
      title: '字形序列',
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final glyph in _glyphs.take(48))
              Chip(
                label: Text('${glyph.glyph.cluster}→${glyph.glyph.glyphId}'),
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'cluster→glyphId：多个字形可以共享一个 cluster（分解），'
          '一个字形也可以覆盖多个（连字）。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );

    final controls = <Widget>[
      _buildFeatures(context),
      _buildRendering(context),
      if (info.axes.isNotEmpty) _buildAxes(info),
    ];

    // Wide windows get the canvas next to the controls; a phone stacks them.
    if (!wide) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          preview,
          const SizedBox(height: 12),
          stats,
          ...controls,
          sequence,
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 6,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [preview, const SizedBox(height: 12), stats, sequence],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          flex: 5,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: controls,
          ),
        ),
      ],
    );
  }

  Widget _buildFeatures(BuildContext context) {
    return SectionCard(
      title: '特性（${_availableFeatures.length}）',
      children: [
        Wrap(
          spacing: 8,
          children: [
            ChoiceChip(
              label: const Text('默认'),
              selected: _mode == _FeatureMode.defaults,
              onSelected: (_) => setState(() {
                _mode = _FeatureMode.defaults;
              }),
            ),
            ChoiceChip(
              label: const Text('全部关闭'),
              selected: _mode == _FeatureMode.none,
              onSelected: (_) => setState(() {
                _mode = _FeatureMode.none;
              }),
            ),
            ChoiceChip(
              label: const Text('自定义'),
              selected: _mode == _FeatureMode.custom,
              onSelected: (_) => setState(() {
                _mode = _FeatureMode.custom;
              }),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final tag in _availableFeatures)
              FilterChip(
                label: Text(tag),
                selected: _effectiveSelection.contains(tag),
                onSelected: (_) => _toggleFeature(tag),
                visualDensity: VisualDensity.compact,
                avatar: _defaultOnFeatures.contains(tag)
                    ? const Icon(Icons.star, size: 14)
                    : null,
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '带 ★ 的是默认开启的特性。点任意标签即切到「自定义」；'
          '「全部关闭」可以看塑形之前的样子。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _buildRendering(BuildContext context) {
    return SectionCard(
      title: '渲染',
      children: [
        LabeledSlider(
          label: '字号',
          value: _fontSize,
          min: 24,
          max: 140,
          labelWidth: 72,
          onChanged: (value) => setState(() => _fontSize = value),
          onChangedEnd: (_) => _reshape(),
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('显示字形边界与 ID'),
          value: _showMarkers,
          onChanged: (value) => setState(() => _showMarkers = value),
        ),
      ],
    );
  }

  Widget _buildAxes(FontInfo info) {
    return SectionCard(
      title: '可变轴',
      children: [
        for (final axis in info.axes.where((axis) => !axis.hidden))
          LabeledSlider(
            label: '${axis.tag} (${axis.name ?? '?'})',
            value: _axisValues[axis.tag] ?? axis.defaultValue,
            min: axis.minValue,
            max: axis.maxValue,
            labelWidth: 140,
            onChanged: (value) => setState(() => _axisValues[axis.tag] = value),
            onChangedEnd: (_) => _reshape(),
          ),
      ],
    );
  }

  /// What is actually on, including the defaults the shaper would pick.
  Set<String> get _effectiveSelection => switch (_mode) {
    _FeatureMode.defaults =>
      _availableFeatures.where(_defaultOnFeatures.contains).toSet(),
    _FeatureMode.none => const <String>{},
    _FeatureMode.custom => _selected,
  };
}

/// Shown when no font is loaded yet: the bundled one is opened at startup, so
/// this only appears before that finishes.
class _EmptyFontHint extends StatelessWidget {
  const _EmptyFontHint({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('还没有打开任何字体'),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: onOpen,
            icon: const Icon(Icons.folder_open),
            label: const Text('打开字体文件…'),
          ),
        ],
      ),
    );
  }
}

class _ShapedPreview extends StatelessWidget {
  const _ShapedPreview({
    required this.glyphs,
    required this.fontSize,
    required this.showMarkers,
  });

  final List<_PlacedGlyph> glyphs;
  final double fontSize;
  final bool showMarkers;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: fontSize * 2,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: CustomPaint(
        painter: _ShapedPainter(
          glyphs: glyphs,
          fontSize: fontSize,
          showMarkers: showMarkers,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _ShapedPainter extends CustomPainter {
  _ShapedPainter({
    required this.glyphs,
    required this.fontSize,
    required this.showMarkers,
  });

  final List<_PlacedGlyph> glyphs;
  final double fontSize;
  final bool showMarkers;

  @override
  void paint(Canvas canvas, Size size) {
    final baseline = size.height * 0.72;
    canvas.drawLine(
      Offset(0, baseline),
      Offset(size.width, baseline),
      Paint()
        ..color = const Color(0x806750A4)
        ..strokeWidth = 1,
    );
    if (glyphs.isEmpty) return;

    final accent = Paint()
      ..color = const Color(0x996750A4)
      ..strokeWidth = 1;
    canvas.save();
    canvas.translate(0, baseline);
    for (final glyph in glyphs) {
      canvas.save();
      // GPOS offsets are y-up; the canvas is y-down.
      canvas.translate(glyph.pen + glyph.glyph.xOffset, -glyph.glyph.yOffset);
      canvas.drawPath(
        glyph.path,
        Paint()
          ..color = const Color(0xFF1D1B20)
          ..style = PaintingStyle.fill,
      );
      canvas.restore();

      if (showMarkers) {
        final x = glyph.pen;
        canvas.drawLine(Offset(x, 0), Offset(x, fontSize * 0.22), accent);
        canvas.drawLine(
          Offset(x + glyph.glyph.xAdvance, 0),
          Offset(x + glyph.glyph.xAdvance, fontSize * 0.22),
          accent,
        );
        if (glyph.glyph.xOffset != 0 || glyph.glyph.yOffset != 0) {
          // Mark attachment and kerns move a glyph off the pen.
          canvas.drawLine(
            Offset(x, 0),
            Offset(x + glyph.glyph.xOffset, -glyph.glyph.yOffset),
            accent,
          );
        }
      }
    }
    canvas.restore();

    if (showMarkers) {
      for (final glyph in glyphs) {
        final painter = TextPainter(
          text: TextSpan(
            text: '${glyph.glyph.glyphId}',
            style: const TextStyle(fontSize: 9, color: Color(0xCC6750A4)),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        painter.paint(
          canvas,
          Offset(glyph.pen + 2, baseline + fontSize * 0.24),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ShapedPainter old) =>
      old.glyphs != glyphs ||
      old.fontSize != fontSize ||
      old.showMarkers != showMarkers;
}

class _PlacedGlyph {
  const _PlacedGlyph({
    required this.path,
    required this.pen,
    required this.glyph,
  });

  final ui.Path path;
  final double pen;
  final ShapedGlyph glyph;
}
