import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:fontations/fontations.dart';

import 'demo_widgets.dart';
import 'font_source.dart';

/// Reads a font the user picked: names, metrics, variation axes, the layout
/// tables, and which optional tables (`MATH`, `VARC`, `COLR`, bitmaps, …) it
/// carries.
class FontInfoPage extends StatefulWidget {
  const FontInfoPage({super.key});

  @override
  State<FontInfoPage> createState() => _FontInfoPageState();
}

class _FontInfoPageState extends State<FontInfoPage> {
  static const double _fontSize = 72.0;

  final TextEditingController _sampleController = TextEditingController(
    text: 'fontations',
  );

  Font? _font;
  FontInfo? _info;
  Object? _error;

  final Map<String, double> _axisValues = <String, double>{};
  List<_LaidOutGlyph> _glyphs = const <_LaidOutGlyph>[];
  List<double> _normalized = const [];
  _Facts? _facts;

  @override
  void initState() {
    super.initState();
    fontSource.addListener(_onSourceChanged);
    _sampleController.addListener(_layoutGlyphs);
    _onSourceChanged();
  }

  @override
  void dispose() {
    fontSource.removeListener(_onSourceChanged);
    _sampleController.removeListener(_layoutGlyphs);
    _sampleController.dispose();
    super.dispose();
  }

  void _onSourceChanged() => _load(fontSource.current);

  Future<void> _load(LoadedFont? loaded) async {
    if (!mounted) return;
    if (loaded == null) {
      setState(() {
        _font = null;
        _info = null;
        _facts = null;
        _glyphs = const <_LaidOutGlyph>[];
        _normalized = const [];
      });
      return;
    }
    try {
      final font = Font.fromBytes(bytes: loaded.bytes, index: loaded.index);
      final info = font.info();

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
        _facts = _Facts.of(font);
        _error = null;
      });
      await _layoutGlyphs();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  Future<void> _layoutGlyphs() async {
    final font = _font;
    if (font == null) return;

    final variations = _axisValues.entries
        .map((entry) => VariationSetting(tag: entry.key, value: entry.value))
        .toList(growable: false);

    final glyphs = <_LaidOutGlyph>[];
    var penX = 0.0;
    for (final rune in _sampleController.text.runes) {
      final glyphId = font.charToGlyph(codePoint: rune);
      if (glyphId == null || glyphId == 0) {
        penX += _fontSize * 0.3;
        continue;
      }
      final outline = await font.outline(
        glyphId: glyphId,
        size: _fontSize,
        variations: variations,
      );
      glyphs.add(
        _LaidOutGlyph(
          path: outline.toPath(),
          offsetX: penX,
          advance: outline.advanceWidth ?? 0,
        ),
      );
      penX += outline.advanceWidth ?? 0;
    }

    if (!mounted) return;
    setState(() {
      _glyphs = glyphs;
      // Where the sliders actually land after `fvar` -> `avar` -> `avar2`.
      _normalized = font.normalizedCoords(variations: variations);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final info = _info;

    return Scaffold(
      appBar: AppBar(
        title: const Text('fontations'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                fontationsVersion(),
                style: theme.textTheme.labelSmall,
              ),
            ),
          ),
        ],
      ),
      body: info == null
          ? _NothingToShow(error: _error, onOpen: fontSource.openFile)
          : _buildBody(context, info),
    );
  }

  Widget _buildBody(BuildContext context, FontInfo info) {
    final facts = _facts;
    final wide = MediaQuery.sizeOf(context).width >= 900;

    // The preview and the axes that drive it stay together; everything else is
    // reference material.
    final interactive = <Widget>[
      // The last font that read fine stays on screen, with the failure on top,
      // so a bad file is not a dead end.
      if (_error != null) _ErrorBanner(error: _error!),
      _buildSource(context),
      TextField(
        controller: _sampleController,
        decoration: const InputDecoration(
          labelText: '预览文本',
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
      const SizedBox(height: 12),
      _GlyphPreview(glyphs: _glyphs, fontSize: _fontSize),
      const SizedBox(height: 16),
      if (info.axes.isNotEmpty) _buildAxes(info),
      if (info.instances.isNotEmpty) _buildInstances(info),
    ];

    final reference = <Widget>[
      SectionCard(
        title: 'Names',
        children: [
          InfoRow('family', info.names.family),
          InfoRow('subfamily', info.names.subfamily),
          InfoRow('full name', info.names.fullName),
          InfoRow('postscript', info.names.postscriptName),
          InfoRow('version', info.names.version),
          InfoRow('designer', info.names.designer),
          InfoRow('license', info.names.license),
        ],
      ),
      SectionCard(
        title: 'Metrics',
        children: [
          InfoRow('units per em', '${info.metrics.unitsPerEm}'),
          InfoRow('glyph count', '${info.metrics.glyphCount}'),
          InfoRow('ascent', info.metrics.ascent.toStringAsFixed(1)),
          InfoRow('descent', info.metrics.descent.toStringAsFixed(1)),
          InfoRow('cap height', info.metrics.capHeight?.toStringAsFixed(1)),
          InfoRow('monospace', '${info.metrics.isMonospace}'),
        ],
      ),
      if (facts != null) ...[
        _buildAttributes(facts),
        _buildLayout(facts),
        _buildCharmap(facts),
        _buildCapabilities(facts),
      ],
      SectionCard(
        title: 'Tables (${info.tables.length})',
        children: [TagChips(info.tables)],
      ),
    ];

    if (!wide) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [...interactive, ...reference],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 5,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: interactive,
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          flex: 6,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: reference,
          ),
        ),
      ],
    );
  }

  /// Opens a font file, or picks another face of the one that is open.
  Widget _buildSource(BuildContext context) {
    final theme = Theme.of(context);
    final current = fontSource.current;
    final opened = fontSource.opened;

    return SectionCard(
      title: '字体',
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: fontSource.picking ? null : fontSource.openFile,
              icon: fontSource.picking
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.folder_open),
              label: const Text('打开字体文件…'),
            ),
            OutlinedButton.icon(
              onPressed: fontSource.loadBundled,
              icon: const Icon(Icons.restart_alt),
              label: const Text('内置 Inter'),
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
              const SizedBox(width: 110, child: Text('字体集合')),
              Expanded(
                child: DropdownButtonFormField<int>(
                  initialValue: current.index,
                  isDense: true,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                  items: [
                    for (var i = 0; i < current.faceCount; i++)
                      DropdownMenuItem(value: i, child: Text('第 $i 个字体')),
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
            '这个文件里有 ${current.faceCount} 个字体（.ttc 集合）。',
            style: theme.textTheme.bodySmall,
          ),
        ],
        if (opened.length > 1) ...[
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
        const SizedBox(height: 4),
        Text(
          '支持 ${fontExtensions.join(' / ')}。woff / woff2 是压缩格式，需要先解压。',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _buildAttributes(_Facts facts) {
    final attributes = facts.attributes;
    return SectionCard(
      title: 'Attributes (OS/2)',
      children: [
        InfoRow('weight', attributes.weight.toStringAsFixed(0)),
        InfoRow(
          'stretch',
          '${attributes.stretchPercentage.toStringAsFixed(0)}%',
        ),
        InfoRow('style', attributes.style.name),
        if (attributes.obliqueAngle != null)
          InfoRow('oblique', '${attributes.obliqueAngle!.toStringAsFixed(1)}°'),
      ],
    );
  }

  Widget _buildAxes(FontInfo info) {
    final axes = info.axes.where((axis) => !axis.hidden).toList();
    return SectionCard(
      title: 'Variation axes (${info.axes.length})',
      children: [
        for (final axis in axes)
          LabeledSlider(
            label: '${axis.tag} (${axis.name ?? '?'})',
            labelWidth: 140,
            value: _axisValues[axis.tag] ?? axis.defaultValue,
            min: axis.minValue,
            max: axis.maxValue,
            onChanged: (value) => setState(() => _axisValues[axis.tag] = value),
            onChangedEnd: (_) => _layoutGlyphs(),
          ),
        if (_normalized.isNotEmpty) ...[
          const SizedBox(height: 8),
          InfoRow(
            '归一化坐标',
            _normalized.map((v) => v.toStringAsFixed(3)).join('  '),
          ),
          const SizedBox(height: 4),
          Text(
            factsAvarNote(_facts),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  String factsAvarNote(_Facts? facts) {
    final avar = facts?.avar;
    if (avar == null) {
      return '经 fvar 线性归一化后的坐标；该字体没有 avar，gvar 增量按这个数缩放。';
    }
    return '经 fvar → avar ${avar.version}'
        '${avar.hasAvar2 ? '（含 avar2 增量）' : ''} 后的坐标；'
        'gvar 增量按这个数缩放。';
  }

  Widget _buildInstances(FontInfo info) {
    return SectionCard(
      title: 'Named instances (${info.instances.length})',
      children: [
        for (final instance in info.instances.take(12))
          InfoRow(
            instance.subfamilyName ?? '?',
            instance.userCoords
                .asMap()
                .entries
                .map(
                  (entry) =>
                      '${instance.axisTags[entry.key]}=${entry.value.toStringAsFixed(0)}',
                )
                .join(' '),
          ),
      ],
    );
  }

  Widget _buildLayout(_Facts facts) {
    return SectionCard(
      title: 'Layout tables',
      children: [
        for (final table in facts.layout)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InfoRow(
                table.table,
                '${table.lookupCount} lookups, '
                '${table.scripts.length} scripts, '
                '${table.languages.length} languages',
              ),
              const SizedBox(height: 4),
              TagChips(table.features.map((feature) => feature.tag), limit: 24),
              const SizedBox(height: 8),
            ],
          ),
        Text(
          '这些只是「字体声明了什么」。要真正应用它们，请看「塑形」页。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _buildCharmap(_Facts facts) {
    final charmap = facts.charmap;
    return SectionCard(
      title: 'Character map',
      children: [
        InfoRow('mappings', '${charmap.mappingCount}'),
        InfoRow('symbol', '${charmap.isSymbol}'),
        InfoRow(
          'format 14',
          facts.variantMappings.isEmpty
              ? '无'
              : '${facts.variantMappings.length} 条',
        ),
        InfoRow('glyph name', facts.glyphName),
        InfoRow('name source', facts.glyphNameSource),
        if (facts.variantMappings.isNotEmpty) ...[
          const SizedBox(height: 6),
          for (final entry in facts.variantMappings.take(4))
            InfoRow(
              'U+${entry.codePoint.toRadixString(16).toUpperCase()}',
              'selector U+${entry.selector.toRadixString(16).toUpperCase()}'
                  ' → ${entry.kind}${entry.glyphId == null ? '' : ' (${entry.glyphId})'}',
              width: 90,
            ),
        ],
      ],
    );
  }

  Widget _buildCapabilities(_Facts facts) {
    final math = facts.mathConstants;
    return SectionCard(
      title: '字体能力',
      children: [
        InfoRow(
          'MATH',
          math == null
              ? '无'
              : '${math.length} 个常量，axisHeight = ${_constant(math, 'axisHeight')}',
        ),
        InfoRow(
          'VARC',
          facts.varcSample == null
              ? '无'
              : '字形 ${facts.varcSample!.glyphId} 由 '
                    '${facts.varcSample!.components.length} 个部件组成',
        ),
        InfoRow(
          'COLR / CPAL',
          facts.palettes.isEmpty ? '无' : '${facts.palettes.length} 个调色板',
        ),
        InfoRow(
          '嵌入位图',
          facts.strikes.isEmpty ? '无' : '${facts.strikes.length} 个 strike',
        ),
        InfoRow(
          '竖排度量',
          facts.vertical == null
              ? '无'
              : 'ascender ${facts.vertical!.ascender.toStringAsFixed(0)}',
        ),
      ],
    );
  }

  String _constant(List<MathConstantInfo> constants, String name) {
    for (final constant in constants) {
      if (constant.name == name) return constant.value.toStringAsFixed(0);
    }
    return '-';
  }
}

/// Everything read once, so the page does not hit the font on every rebuild.
class _Facts {
  _Facts({
    required this.attributes,
    required this.layout,
    required this.charmap,
    required this.glyphName,
    required this.glyphNameSource,
    required this.variantMappings,
    required this.mathConstants,
    required this.varcSample,
    required this.palettes,
    required this.strikes,
    required this.vertical,
    required this.avar,
  });

  factory _Facts.of(Font font) {
    final glyphId = font.charToGlyph(codePoint: 'A'.codeUnitAt(0)) ?? 1;
    return _Facts(
      attributes: font.attributes(),
      layout: font.layout(),
      charmap: font.charmapInfo(),
      glyphName: font.glyphName(glyphId: glyphId) ?? '-',
      glyphNameSource: font.glyphNameSource(),
      variantMappings: font.variantMappings(),
      mathConstants: font.hasMath() ? font.mathConstants() : null,
      varcSample: font.hasVarc() ? _firstComposite(font) : null,
      palettes: font.colorPalettes(),
      strikes: font.bitmapStrikes(),
      vertical: font.verticalMetrics(),
      avar: font.avarInfo(),
    );
  }

  final FontAttributes attributes;
  final List<LayoutTableInfo> layout;
  final CharmapInfo charmap;
  final String glyphName;
  final String glyphNameSource;
  final List<VariantMappingInfo> variantMappings;
  final List<MathConstantInfo>? mathConstants;
  final _VarcSample? varcSample;
  final List<ColorPaletteInfo> palettes;
  final List<BitmapStrikeInfo> strikes;
  final VerticalMetrics? vertical;
  final AvarInfo? avar;
}

/// The first glyph the `VARC` table actually builds out of components.
_VarcSample? _firstComposite(Font font) {
  final count = font.info().metrics.glyphCount;
  for (var glyphId = 1; glyphId < count && glyphId < 256; glyphId++) {
    final glyph = font.varcComponents(glyphId: glyphId, variations: const []);
    if (glyph != null && glyph.components.isNotEmpty) {
      return _VarcSample(glyphId: glyphId, components: glyph.components);
    }
  }
  return null;
}

class _VarcSample {
  const _VarcSample({required this.glyphId, required this.components});

  final int glyphId;
  final List<VarcComponentInfo> components;
}

/// Shown when there is nothing to display: still starting up, or the very
/// first file failed to parse. Either way there is a way forward.
class _NothingToShow extends StatelessWidget {
  const _NothingToShow({required this.error, required this.onOpen});

  final Object? error;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    if (error == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text('无法解析这个字体文件', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Text(
              describeError(error!),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onOpen,
              icon: const Icon(Icons.folder_open),
              label: const Text('换一个字体文件…'),
            ),
          ],
        ),
      ),
    );
  }
}

/// A one line strip reporting that the latest file could not be read.
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.error});

  final Object error;

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
              '这个文件读不了，仍显示上一个：${describeError(error)}',
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

class _GlyphPreview extends StatelessWidget {
  const _GlyphPreview({required this.glyphs, required this.fontSize});

  final List<_LaidOutGlyph> glyphs;
  final double fontSize;

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
        painter: _GlyphPainter(glyphs: glyphs, fontSize: fontSize),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter({required this.glyphs, required this.fontSize});

  final List<_LaidOutGlyph> glyphs;
  final double fontSize;

  @override
  void paint(Canvas canvas, Size size) {
    if (glyphs.isEmpty) return;
    final paint = Paint()
      ..color = const Color(0xFF1D1B20)
      ..style = PaintingStyle.fill;
    canvas.save();
    canvas.translate(0, size.height * 0.72);
    for (final glyph in glyphs) {
      canvas.save();
      canvas.translate(glyph.offsetX, 0);
      canvas.drawPath(glyph.path, paint);
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GlyphPainter oldDelegate) =>
      oldDelegate.glyphs != glyphs || oldDelegate.fontSize != fontSize;
}

class _LaidOutGlyph {
  const _LaidOutGlyph({
    required this.path,
    required this.offsetX,
    required this.advance,
  });

  final ui.Path path;
  final double offsetX;
  final double advance;
}
