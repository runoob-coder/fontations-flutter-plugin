import 'dart:async';
import 'dart:ui' as ui;

import 'package:fontations/fontations.dart';
import 'package:material_ui/material_ui.dart';

import 'demo_widgets.dart';
import 'font_source.dart';
import 'font_source_controls.dart';
import 'github_button.dart';
import 'l10n/app_localizations.dart';
import 'locale_switcher.dart';
import 'theme_switcher.dart';

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
class ShapingPage extends StatefulWidget {
  const ShapingPage({super.key});

  @override
  State<ShapingPage> createState() => _ShapingPageState();
}

enum _FeatureMode { defaults, none, custom }

class _ShapingPageState extends State<ShapingPage> {
  late AppLocalizations l;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    l = AppLocalizations.of(context);
  }

  final TextEditingController _textController = TextEditingController(
    text: 'To ffi fl AWAY',
  );
  final TextEditingController _scriptController = TextEditingController();
  final TextEditingController _languageController = TextEditingController();

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

  /// Shaping is asynchronous (outlines come from Rust). A result that arrives
  /// after the user has typed or switched modes must not win.
  int _shapeToken = 0;

  /// Typing reshapes on a short debounce: `shape()` is synchronous Rust work
  /// and must not run for every keystroke.
  Timer? _reshapeTimer;

  List<_PlacedGlyph> _glyphs = const [];
  double _advance = 0;
  double _advanceRaw = 0;
  int _charCount = 0;

  @override
  void initState() {
    super.initState();
    _textController.addListener(_scheduleReshape);
    _scriptController.addListener(_scheduleReshape);
    _languageController.addListener(_scheduleReshape);
    fontSource.addListener(_onSourceChanged);
    _onSourceChanged();
  }

  @override
  void dispose() {
    _reshapeTimer?.cancel();
    fontSource.removeListener(_onSourceChanged);
    _textController.removeListener(_scheduleReshape);
    _scriptController.removeListener(_scheduleReshape);
    _languageController.removeListener(_scheduleReshape);
    _textController.dispose();
    _scriptController.dispose();
    _languageController.dispose();
    super.dispose();
  }

  void _scheduleReshape() {
    _reshapeTimer?.cancel();
    _reshapeTimer = Timer(const Duration(milliseconds: 180), _reshape);
  }

  /// Shapes with whatever the reading page has open, so the two never drift.
  LoadedFont? _lastLoaded;

  void _onSourceChanged() => _load(fontSource.current);

  Future<void> _load(LoadedFont? loaded) async {
    if (!mounted || loaded == _lastLoaded) return;
    _lastLoaded = loaded;
    // A new font invalidates outlines that are still being drawn.
    _shapeToken++;
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
      final font = fontSource.font;
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
        _error = null;
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

  /// An OpenType tag is exactly four characters (trailing space included);
  /// a half-typed one falls back to the font's default language system.
  String? _tag(TextEditingController controller) {
    final tag = controller.text;
    return tag.length == 4 && tag.trim().isNotEmpty ? tag : null;
  }

  /// Keeps the last good drawing on screen when a native call fails.
  Future<void> _reshape() async {
    try {
      await _reshapeNow();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  Future<void> _reshapeNow() async {
    final font = _font;
    if (font == null) return;
    final token = ++_shapeToken;
    final text = _textController.text;
    final script = _tag(_scriptController);
    final language = _tag(_languageController);

    final variations = _variations;
    final result = font.shape(
      text: text,
      size: _fontSize,
      variations: variations,
      script: script,
      language: language,
      features: _features,
    );
    // The same run with every feature off, for comparison.
    final raw = font.shape(
      text: text,
      size: _fontSize,
      variations: variations,
      script: script,
      language: language,
      features: const <String>[],
    );

    // Shape once, then draw every distinct glyph through one `outlines` call:
    // one scaler and one reusable draw buffer for the whole run.
    final ids = result.glyphs.map((glyph) => glyph.glyphId).toSet().toList();
    final outlines = ids.isEmpty
        ? <GlyphOutline>[]
        : await font.outlines(
            glyphIds: ids,
            size: _fontSize,
            variations: variations,
          );
    if (!mounted || token != _shapeToken) return;

    final paths = <int, ui.Path>{
      for (var i = 0; i < ids.length; i++) ids[i]: outlines[i].toPath(),
    };
    final glyphs = <_PlacedGlyph>[];
    var pen = 0.0;
    for (final glyph in result.glyphs) {
      glyphs.add(
        _PlacedGlyph(path: paths[glyph.glyphId]!, pen: pen, glyph: glyph),
      );
      pen += glyph.xAdvance;
    }

    setState(() {
      _glyphs = glyphs;
      _advance = result.advance;
      _advanceRaw = raw.advance;
      _charCount = text.runes.length;
      _error = null;
    });
  }

  /// Changing modes has to reshape: `features` is passed to Rust, so a mode
  /// that only changes a field leaves the canvas showing the previous run.
  void _setMode(_FeatureMode mode) {
    setState(() {
      if (mode == _FeatureMode.custom) {
        if (_mode == _FeatureMode.defaults) {
          _selected
            ..clear()
            ..addAll(_availableFeatures.where(_defaultOnFeatures.contains));
        } else if (_mode == _FeatureMode.none) {
          _selected.clear();
        }
      }
      _mode = mode;
    });
    _reshape();
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
      appBar: AppBar(
        title: Text(l.shapingTitle),
        actions: const [GitHubButton(), ThemeMenu(), LanguageMenu()],
      ),
      body: info == null ? _buildNoFont(context) : _buildBody(context, info),
    );
  }

  /// A failed parse must not become a dead end: the picker stays reachable and
  /// loading a good font clears the banner on the next successful reshape.
  Widget _buildNoFont(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const FontSourceControls(compact: true),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: ErrorBanner(
            _error!,
            message: l.fontParseError(describeError(_error!)),
          ),
        ),
      Expanded(
        child: EmptyFontHint(
          label: l.noFontOpen,
          buttonLabel: l.openFontFile,
          onOpen: () => fontSource.openFile(dialogTitle: l.pickFontDialogTitle),
        ),
      ),
    ],
  );

  Widget _buildBody(BuildContext context, FontInfo info) {
    final wide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
    final merged = _charCount - _glyphs.length;

    final input = TextField(
      controller: _textController,
      decoration: InputDecoration(
        labelText: l.shapingTextLabel,
        helperText: l.shapingTextHint,
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
      title: l.shapingResultsTitle,
      children: [
        InfoRow(l.shapingCharCount, '$_charCount'),
        InfoRow(l.labelGlyphCount, '${_glyphs.length}'),
        InfoRow(
          l.shapingLigatures,
          merged > 0 ? l.shapingLigatureMerged('$merged') : l.none,
        ),
        InfoRow(
          l.shapingTotalAdvance,
          '${_advance.toStringAsFixed(1)} px'
          '${(_advance - _advanceRaw).abs() > 0.05 ? l.shapingAdvanceRaw(_advanceRaw.toStringAsFixed(1)) : ''}',
        ),
      ],
    );

    final sequence = SectionCard(
      title: l.shapingGlyphSequence,
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
          l.shapingClusterNote,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );

    final controls = <Widget>[
      const FontSourceControls(compact: true),
      if (_error != null)
        ErrorBanner(_error!, message: l.fontParseError(describeError(_error!))),
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
    // Compute the chip selection once per build instead of once per chip.
    final selection = _effectiveSelection;
    return SectionCard(
      title: l.shapingFeaturesTitle('${_availableFeatures.length}'),
      children: [
        Wrap(
          spacing: 8,
          children: [
            ChoiceChip(
              label: Text(l.shapingModeDefault),
              selected: _mode == _FeatureMode.defaults,
              onSelected: (_) => _setMode(_FeatureMode.defaults),
            ),
            ChoiceChip(
              label: Text(l.shapingModeNone),
              selected: _mode == _FeatureMode.none,
              onSelected: (_) => _setMode(_FeatureMode.none),
            ),
            ChoiceChip(
              label: Text(l.shapingModeCustom),
              selected: _mode == _FeatureMode.custom,
              onSelected: (_) => _setMode(_FeatureMode.custom),
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
                selected: selection.contains(tag),
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
          l.shapingFeaturesNote,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _buildRendering(BuildContext context) {
    return SectionCard(
      title: l.shapingRenderingTitle,
      children: [
        LabeledSlider(
          label: l.shapingFontSize,
          value: _fontSize,
          min: 24,
          max: 140,
          labelWidth: 72,
          onChanged: (value) => setState(() => _fontSize = value),
          onChangedEnd: (_) => _reshape(),
        ),
        // Plain SwitchListTile: the example deliberately uses Material
        // switches on every platform, including iOS and macOS.
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l.shapingShowMarkers),
          value: _showMarkers,
          onChanged: (value) => setState(() => _showMarkers = value),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _scriptController,
                decoration: InputDecoration(
                  labelText: l.shapingScriptLabel,
                  hintText: 'latn',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _languageController,
                decoration: InputDecoration(
                  labelText: l.shapingLanguageLabel,
                  hintText: 'TRK ',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(l.shapingTagNote, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  Widget _buildAxes(FontInfo info) {
    return SectionCard(
      title: l.labelAxes,
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
        painter: _ShapedPainter(
          glyphs: glyphs,
          fontSize: fontSize,
          showMarkers: showMarkers,
          ink: theme.colorScheme.onSurface,
          accent: theme.colorScheme.primary,
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
    required this.ink,
    required this.accent,
  });

  final List<_PlacedGlyph> glyphs;
  final double fontSize;
  final bool showMarkers;
  final Color ink;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final baseline = size.height * 0.72;
    canvas.drawLine(
      Offset(0, baseline),
      Offset(size.width, baseline),
      Paint()
        ..color = accent.withValues(alpha: 0.5)
        ..strokeWidth = 1,
    );
    if (glyphs.isEmpty) return;

    final marker = Paint()
      ..color = accent.withValues(alpha: 0.6)
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
          ..color = ink
          ..style = PaintingStyle.fill,
      );
      canvas.restore();

      if (showMarkers) {
        final x = glyph.pen;
        canvas.drawLine(Offset(x, 0), Offset(x, fontSize * 0.22), marker);
        canvas.drawLine(
          Offset(x + glyph.glyph.xAdvance, 0),
          Offset(x + glyph.glyph.xAdvance, fontSize * 0.22),
          marker,
        );
        if (glyph.glyph.xOffset != 0 || glyph.glyph.yOffset != 0) {
          // Mark attachment and kerns move a glyph off the pen.
          canvas.drawLine(
            Offset(x, 0),
            Offset(x + glyph.glyph.xOffset, -glyph.glyph.yOffset),
            marker,
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
            style: TextStyle(
              fontSize: 9,
              color: accent.withValues(alpha: 0.85),
            ),
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
      old.showMarkers != showMarkers ||
      old.ink != ink ||
      old.accent != accent;
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
