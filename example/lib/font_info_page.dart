import 'dart:ui' as ui;

import 'package:fontations/fontations.dart';
import 'package:material_ui/material_ui.dart';

import 'app_palette.dart';
import 'demo_widgets.dart';
import 'font_source.dart';
import 'font_source_controls.dart';
import 'github_button.dart';
import 'l10n/app_localizations.dart';
import 'locale_switcher.dart';
import 'theme_switcher.dart';

/// Reads a font the user picked: names, metrics, variation axes, the layout
/// tables, and which optional tables (`MATH`, `VARC`, `COLR`, bitmaps, …) it
/// carries.
class FontInfoPage extends StatefulWidget {
  const FontInfoPage({super.key});

  @override
  State<FontInfoPage> createState() => _FontInfoPageState();
}

class _FontInfoPageState extends State<FontInfoPage> {
  late AppLocalizations l;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    l = AppLocalizations.of(context);
  }

  static const double _fontSize = 72.0;

  /// Cached: the version never changes during the process.
  static final String _version = fontationsVersion();

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
  bool _scalerHinting = false;
  String _scalerStatus = 'unhinted';

  /// Invalidates outlines still being drawn when the font or the text changes.
  /// Without it a slow result can land after a newer one and overwrite it.
  int _layoutToken = 0;

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

  LoadedFont? _lastLoaded;

  void _onSourceChanged() => _load(fontSource.current);

  Future<void> _load(LoadedFont? loaded) async {
    if (!mounted || loaded == _lastLoaded) return;
    _lastLoaded = loaded;
    // A new font makes any in-flight outline request obsolete.
    _layoutToken++;
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
      final font = fontSource.font;
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

  /// Outline loading is a native call; keep the last good preview and show a
  /// banner instead of letting an async error go unhandled.
  Future<void> _layoutGlyphs() async {
    try {
      await _layoutGlyphsNow();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _layoutGlyphsNow() async {
    final font = _font;
    if (font == null) return;
    final token = ++_layoutToken;
    final text = _sampleController.text;

    final variations = _axisValues.entries
        .map((entry) => VariationSetting(tag: entry.key, value: entry.value))
        .toList(growable: false);

    // `hinting` selects the skrifa 0.50 scaler setup; without it outlines
    // are unhinted. `ScalerInfo` reports the engine that actually ran.
    final hinting = _scalerHinting
        ? const HintingSpec(
            engine: HintEngineKind.autoFallback,
            target: RasterTargetKind.lcd,
          )
        : null;

    // -1 marks a character the font does not cover; it still leaves a gap.
    final ids = <int>[
      for (final rune in text.runes) font.charToGlyph(codePoint: rune) ?? -1,
    ];
    final drawable = ids.where((id) => id > 0).toList(growable: false);

    // One scaler and one reusable draw buffer for the whole run, instead of
    // setting both up again for every character.
    final outlines = drawable.isEmpty
        ? <GlyphOutline>[]
        : await font.outlines(
            glyphIds: drawable,
            size: _fontSize,
            variations: variations,
            hinting: hinting,
          );
    if (!mounted || token != _layoutToken) return;

    final glyphs = <_LaidOutGlyph>[];
    var scalerStatus = 'unhinted';
    var penX = 0.0;
    var next = 0;
    for (final id in ids) {
      if (id <= 0) {
        penX += _fontSize * 0.3;
        continue;
      }
      final outline = outlines[next++];
      final engine = outline.scaler.hintEngine;
      scalerStatus = engine == null
          ? 'unhinted'
          : '$engine at ${outline.scaler.hintedPpem?.toStringAsFixed(0) ?? '?'} ppem';
      final advance = outline.advanceWidth ?? 0;
      glyphs.add(
        _LaidOutGlyph(path: outline.toPath(), offsetX: penX, advance: advance),
      );
      penX += advance;
    }

    setState(() {
      _glyphs = glyphs;
      _scalerStatus = scalerStatus;
      // Where the sliders actually land after `fvar` -> `avar` -> `avar2`.
      _normalized = font.normalizedCoords(variations: variations);
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'fontations',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          const GitHubButton(),
          const ThemeMenu(),
          const LanguageMenu(),
        ],
      ),
      body: info == null
          ? _NothingToShow(
              error: _error,
              onOpen: () =>
                  fontSource.openFile(dialogTitle: l.pickFontDialogTitle),
            )
          : _buildBody(context, info),
    );
  }

  Widget _buildBody(BuildContext context, FontInfo info) {
    final facts = _facts;
    final wide = MediaQuery.sizeOf(context).width >= wideBreakpoint;

    // The preview and the axes that drive it stay together; everything else is
    // reference material.
    final interactive = <Widget>[
      // The fontations version used to hide in the AppBar and got clipped on
      // narrow screens; it now lives in the page so the full string is readable.
      SectionCard(
        title: 'fontations',
        children: [InfoRow(l.infoLibraryVersion, _version)],
      ),
      // The last font that read fine stays on screen, with the failure on top,
      // so a bad file is not a dead end.
      if (_error != null)
        ErrorBanner(
          _error!,
          message: l.unreadableDetail(describeError(_error!)),
        ),
      const FontSourceControls(),
      TextField(
        controller: _sampleController,
        decoration: InputDecoration(
          labelText: l.infoPreviewTextLabel,
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
      const SizedBox(height: 12),
      _GlyphPreview(glyphs: _glyphs, fontSize: _fontSize),
      SwitchListTile(
        title: Text(l.infoHintingTitle),
        subtitle: Text(_scalerStatus),
        value: _scalerHinting,
        onChanged: (value) {
          setState(() => _scalerHinting = value);
          _layoutGlyphs();
        },
      ),
      const SizedBox(height: 16),
      if (info.axes.isNotEmpty) _buildAxes(info),
      if (info.instances.isNotEmpty) _buildInstances(info),
    ];

    final reference = <Widget>[
      SectionCard(
        title: l.infoNamesTitle,
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
        title: l.infoMetricsTitle,
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
        title: l.infoTablesTitle('${info.tables.length}'),
        children: [
          TagChips(
            info.tables,
            color: BrandColors.of(context).tint(context, 0),
          ),
        ],
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

  Widget _buildAttributes(_Facts facts) {
    final attributes = facts.attributes;
    return SectionCard(
      title: l.infoAttributesTitle,
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
      title: l.infoAxesTitle('${info.axes.length}'),
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
            l.infoNormalizedCoords,
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
      return l.infoAvarAbsent;
    }
    return avar.hasAvar2
        ? l.infoAvarPresentAvar2(avar.version)
        : l.infoAvarPresent(avar.version);
  }

  Widget _buildInstances(FontInfo info) {
    return SectionCard(
      title: l.infoInstancesTitle('${info.instances.length}'),
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
      title: l.infoLayoutTitle,
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
              TagChips(
                table.features.map((feature) => feature.tag),
                limit: 24,
                color: BrandColors.of(context).tint(context, 0),
              ),
              const SizedBox(height: 8),
            ],
          ),
        Text(l.infoLayoutNote, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  Widget _buildCharmap(_Facts facts) {
    final charmap = facts.charmap;
    return SectionCard(
      title: l.infoCharmapTitle,
      children: [
        InfoRow('mappings', '${charmap.mappingCount}'),
        InfoRow('symbol', '${charmap.isSymbol}'),
        InfoRow(
          'format 14',
          facts.variantMappings.isEmpty
              ? l.none
              : l.infoVariantMappings('${facts.variantMappings.length}'),
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
      title: l.infoCapabilitiesTitle,
      children: [
        InfoRow(
          'MATH',
          math == null
              ? l.none
              : l.infoMathConstants(
                  '${math.length}',
                  _constant(math, 'axisHeight'),
                ),
        ),
        InfoRow(
          'VARC',
          facts.varcSample == null
              ? l.none
              : l.infoVarcSample(
                  '${facts.varcSample!.glyphId}',
                  '${facts.varcSample!.components.length}',
                ),
        ),
        InfoRow(
          'COLR / CPAL',
          facts.palettes.isEmpty
              ? l.none
              : l.infoPaletteCount('${facts.palettes.length}'),
        ),
        InfoRow(
          l.infoEmbeddedBitmaps,
          facts.strikes.isEmpty
              ? l.none
              : l.infoStrikeCount('${facts.strikes.length}'),
        ),
        InfoRow(
          l.infoVerticalMetrics,
          facts.vertical == null
              ? l.none
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
    final l = AppLocalizations.of(context);
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
            Text(l.unreadableTitle, style: theme.textTheme.titleSmall),
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
              label: Text(l.chooseAnotherFont),
            ),
          ],
        ),
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
    final theme = Theme.of(context);
    return Container(
      height: fontSize * 2,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: CustomPaint(
        painter: _GlyphPainter(
          glyphs: glyphs,
          fontSize: fontSize,
          ink: theme.colorScheme.onSurface,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter({
    required this.glyphs,
    required this.fontSize,
    required this.ink,
  });

  final List<_LaidOutGlyph> glyphs;
  final double fontSize;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    if (glyphs.isEmpty) return;
    final paint = Paint()
      ..color = ink
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
      oldDelegate.glyphs != glyphs ||
      oldDelegate.fontSize != fontSize ||
      oldDelegate.ink != ink;
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
