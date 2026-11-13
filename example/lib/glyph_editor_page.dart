import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:fontations/fontations.dart';
import 'package:material_ui/material_ui.dart';

import 'demo_widgets.dart';
import 'github_button.dart';
import 'l10n/app_localizations.dart';
import 'locale_switcher.dart';
import 'theme_switcher.dart';

/// The em square used for the generated font.
const int _unitsPerEm = 1000;
const double _ascender = 800.0;
const double _descender = -200.0;

/// The single axis exposed by this demo. 「一」 can be drawn several times and
/// each drawing becomes a master somewhere along it.
const String _axisTag = 'wght';
const double _axisMin = 100.0;
const double _axisDefault = 400.0;
const double _axisMax = 900.0;

/// Every stroke is resampled to this many points so that masters drawn at
/// different times stay point compatible (a `gvar` requirement).
const int _strokeSamples = 24;

/// Stylistic sets offered by the editor. These become `GSUB` features, so they
/// are discrete swaps rather than interpolation.
const List<String> _stylisticSets = [
  'ss01',
  'ss02',
  'ss03',
  'ss04',
  'ss05',
  'ss06',
  'ss07',
  'ss08',
  'ss09',
  'ss10',
  'ss11',
  'ss12',
  'ss13',
  'ss14',
  'ss15',
  'ss16',
  'ss17',
  'ss18',
  'ss19',
  'ss20',
];

/// Builds a font from hand drawn strokes: draw a character, bind it to a code
/// point, compile a `.ttf` with `write-fonts`, then render it with Flutter.
class GlyphEditorPage extends StatefulWidget {
  const GlyphEditorPage({super.key});

  @override
  State<GlyphEditorPage> createState() => _GlyphEditorPageState();
}

class _GlyphEditorPageState extends State<GlyphEditorPage> {
  late AppLocalizations l;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    l = AppLocalizations.of(context);
  }

  final TextEditingController _charController = TextEditingController(
    text: '一',
  );
  final TextEditingController _familyController = TextEditingController(
    text: 'MyHandwriting',
  );

  /// Character -> the strokes drawn for it.
  final Map<String, _GlyphEntry> _glyphs = <String, _GlyphEntry>{};

  List<List<Offset>> _strokes = <List<Offset>>[];
  List<Offset>? _current;
  double _strokeWidth = 26.0;
  double _masterValue = _axisMax;
  String _selectedSet = _stylisticSets.first;

  Uint8List? _fontBytes;
  FontInfo? _builtInfo;
  Font? _builtFont;
  int? _builtGlyphId;
  Path? _previewPath;
  double _previewValue = _axisDefault;
  String? _fontFamily;
  String? _builtSample;
  List<String> _builtVariants = const [];
  String? _exportedPath;
  String? _error;
  bool _busy = false;
  int _familyCounter = 0;

  /// Dragging the interpolation slider must not let a slow outline overwrite
  /// the position the user has since moved to.
  int _previewToken = 0;

  /// Board edge length in pixels; kept in sync by the layout.
  double _boardSize = 320.0;

  String get _char {
    final text = _charController.text;
    if (text.isEmpty) return '一';
    return String.fromCharCode(text.runes.first);
  }

  @override
  void initState() {
    super.initState();
    _charController.addListener(_onCharChanged);
  }

  @override
  void dispose() {
    _charController.removeListener(_onCharChanged);
    _charController.dispose();
    _familyController.dispose();
    super.dispose();
  }

  /// Switching characters swaps in whatever was drawn for it before.
  void _onCharChanged() {
    final saved = _glyphs[_char];
    setState(() {
      _strokes = saved?.strokes.copy() ?? <List<Offset>>[];
      _strokeWidth = saved?.strokeWidth ?? _strokeWidth;
      _current = null;
    });
  }

  // --- drawing ------------------------------------------------------------

  void _onPanStart(DragStartDetails details) {
    setState(() => _current = <Offset>[details.localPosition]);
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final current = _current;
    if (current == null) return;
    final point = details.localPosition;
    if ((point - current.last).distance < 2.5) return;
    setState(() => current.add(point));
  }

  void _onPanEnd() {
    final current = _current;
    if (current == null) return;
    setState(() {
      _strokes = <List<Offset>>[..._strokes, current];
      _current = null;
    });
  }

  void _undo() => setState(() {
    if (_current != null) {
      _current = null;
    } else if (_strokes.isNotEmpty) {
      _strokes = _strokes.sublist(0, _strokes.length - 1);
    }
  });

  void _clear() => setState(() {
    _strokes = <List<Offset>>[];
    _current = null;
  });

  /// Saves the current strokes either as the default outline or as a master.
  void _saveShape() {
    if (_strokes.isEmpty) {
      _showSnack(l.editorDrawFirst(_char));
      return;
    }
    final entry = _glyphs[_char] ?? _GlyphEntry(strokeWidth: _strokeWidth);
    final strokes = _strokes.copy();
    final isDefault = (_masterValue - _axisDefault).abs() < 1;

    setState(() {
      if (isDefault) {
        _glyphs[_char] = entry.copyWith(
          strokes: strokes,
          strokeWidth: _strokeWidth,
        );
      } else {
        final masters = <_Master>[
          ...entry.masters.where((m) => (m.value - _masterValue).abs() >= 1),
          _Master(
            value: _masterValue,
            strokes: strokes,
            strokeWidth: _strokeWidth,
          ),
        ]..sort((a, b) => a.value.compareTo(b.value));
        _glyphs[_char] = entry.copyWith(masters: masters);
      }
      _strokes = <List<Offset>>[];
      _current = null;
    });
    _showSnack(
      isDefault
          ? l.editorSetDefault(_char)
          : l.editorSavedMaster(_char, _axisTag, '${_masterValue.toInt()}'),
    );
  }

  /// Saves the current strokes as a discrete alternate under `ss01`..`ss20`.
  void _saveVariant() {
    if (_strokes.isEmpty) {
      _showSnack(l.editorDrawFirst(_char));
      return;
    }
    final entry = _glyphs[_char] ?? const _GlyphEntry();
    setState(() {
      _glyphs[_char] = entry.copyWith(
        variants: <_Variant>[
          ...entry.variants.where((v) => v.tag != _selectedSet),
          _Variant(
            tag: _selectedSet,
            strokes: _strokes.copy(),
            strokeWidth: _strokeWidth,
          ),
        ],
      );
      _strokes = <List<Offset>>[];
      _current = null;
    });
    _showSnack(l.editorSavedVariant(_char, _selectedSet));
  }

  // --- font building ------------------------------------------------------

  Future<void> _buildFont() async {
    final entries = _collectEntries();
    if (entries.isEmpty) {
      _showSnack(l.editorNoGlyphs);
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _previewToken++;
    });

    try {
      final variable = entries.values.any((e) => e.masters.isNotEmpty);
      final request = FontBuildRequest(
        familyName: _familyController.text.trim().isEmpty
            ? 'MyHandwriting'
            : _familyController.text.trim(),
        subfamilyName: 'Regular',
        unitsPerEm: _unitsPerEm,
        ascender: _ascender,
        descender: _descender,
        axes: variable
            ? [
                const VariationAxisSpec(
                  tag: _axisTag,
                  name: 'Weight',
                  minValue: _axisMin,
                  defaultValue: _axisDefault,
                  maxValue: _axisMax,
                  mappings: [],
                ),
              ]
            : const [],
        instances: variable
            ? [
                NamedInstanceSpec(
                  name: 'Light',
                  coordinates: Float64List.fromList([_axisMin]),
                ),
                NamedInstanceSpec(
                  name: 'Black',
                  coordinates: Float64List.fromList([_axisMax]),
                ),
              ]
            : const [],
        glyphs: [
          for (final entry in entries.entries)
            GlyphSpec(
              codePoint: entry.key.runes.first,
              contours: _toContours(
                entry.value.defaultStrokes,
                entry.value.defaultWidth,
              ),
              advanceWidth: _unitsPerEm.toDouble(),
              masters: [
                for (final master in entry.value.masters)
                  VariationMaster(
                    coordinates: Float64List.fromList([master.value]),
                    contours: _toContours(master.strokes, master.strokeWidth),
                    globalMetrics: const [],
                  ),
              ],
              alternates: [
                for (final variant in entry.value.variants)
                  StylisticAlternate(
                    featureTag: variant.tag,
                    contours: _toContours(variant.strokes, variant.strokeWidth),
                  ),
              ],
              components: const [],
              colorLayers: const [],
            ),
        ],
        kernPairs: const [],
        ligatures: const [],
        palette: Uint32List(0),
        rawTables: const [],
        variationSelectors: const [],
      );

      final bytes = await buildFont(request: request);

      // Register the freshly built font with the Flutter engine, so that a
      // plain `Text` widget renders with it.
      final family = '${request.familyName}${++_familyCounter}';
      await (FontLoader(
        family,
      )..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)))).load();

      // Read it straight back with fontations as a round-trip check.
      final info = readFontInfo(bytes: bytes);
      final font = Font.fromBytes(bytes: bytes);
      final glyphId = font.charToGlyph(
        codePoint: entries.keys.first.runes.first,
      );

      setState(() {
        _fontBytes = bytes;
        _builtInfo = info;
        _builtFont = font;
        _builtGlyphId = glyphId;
        _fontFamily = family;
        _builtSample = entries.keys.join();
        _builtVariants = {
          for (final entry in entries.values)
            for (final variant in entry.variants) variant.tag,
        }.toList()..sort();
        _exportedPath = null;
        _previewValue = _axisDefault;
        _previewPath = null;
      });

      if (glyphId != null) {
        await _renderPreview(_axisDefault);
      }
    } catch (error) {
      if (mounted) setState(() => _error = describeError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Every character that has at least one shape, plus the strokes on the board.
  Map<String, _GlyphEntry> _collectEntries() {
    final result = <String, _GlyphEntry>{};
    for (final entry in _glyphs.entries) {
      result[entry.key] = entry.key == _char && _strokes.isNotEmpty
          ? entry.value.copyWith(strokes: _strokes, strokeWidth: _strokeWidth)
          : entry.value;
    }
    if (!result.containsKey(_char) && _strokes.isNotEmpty) {
      result[_char] = _GlyphEntry(strokes: _strokes, strokeWidth: _strokeWidth);
    }
    return result;
  }

  /// Re-renders the generated glyph at [_previewValue] to show interpolation.
  Future<void> _renderPreview(double value) async {
    final font = _builtFont;
    final glyphId = _builtGlyphId;
    if (font == null || glyphId == null) return;
    final token = ++_previewToken;
    try {
      final outline = await font.outline(
        glyphId: glyphId,
        size: 100,
        variations: [VariationSetting(tag: _axisTag, value: value)],
      );
      if (!mounted || token != _previewToken) return;
      setState(() {
        _previewValue = value;
        _previewPath = outline.toPath();
      });
    } catch (error) {
      if (mounted && token == _previewToken) {
        setState(() => _error = describeError(error));
      }
    }
  }

  Future<void> _export() async {
    final bytes = _fontBytes;
    if (bytes == null) return;
    try {
      final name = _familyController.text.trim().isEmpty
          ? 'MyHandwriting'
          : _familyController.text.trim();
      // `dart:io` is unavailable on the web, where this downloads the file
      // instead; on desktop/mobile the user picks where to put it.
      final path = await saveFontBytes(
        fileName: '$name.ttf',
        bytes: bytes,
        dialogTitle: l.saveFontDialogTitle,
      );
      if (path == null || !mounted) return; // Cancelled or widget gone.
      setState(() => _exportedPath = path);
      _showSnack(l.savedTo(path));
    } catch (error) {
      if (mounted) setState(() => _error = describeError(error));
    }
  }

  /// Converts board-space strokes into font-unit contours (y flipped).
  List<GlyphContour> _toContours(
    List<List<Offset>> strokes,
    double strokeWidth,
  ) {
    final scale = _unitsPerEm / _boardSize;
    final half = strokeWidth * scale / 2;
    final contours = <GlyphContour>[];
    for (final stroke in strokes) {
      final resampled = _resample(stroke, _strokeSamples);
      final outline = _strokeOutline(resampled, half);
      if (outline.length < 3) continue;
      contours.add(
        GlyphContour(
          points: [
            for (final point in outline)
              ContourPoint(
                x: point.dx * scale,
                y: _ascender - point.dy * scale,
                onCurve: true,
              ),
          ],
        ),
      );
    }
    return contours;
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(l.editorTitle),
        actions: const [GitHubButton(), ThemeMenu(), LanguageMenu()],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= wideBreakpoint;

          // Keep this `Expanded` separate to avoid competing ParentDataWidgets.
          final boardContent = Center(
            child: LayoutBuilder(
              builder: (context, box) {
                final size = math.min(box.maxWidth, box.maxHeight);
                _boardSize = size;
                return SizedBox(
                  width: size,
                  height: size,
                  child: _Board(
                    strokes: _strokes,
                    current: _current,
                    strokeWidth: _strokeWidth,
                    onPanStart: _onPanStart,
                    onPanUpdate: _onPanUpdate,
                    onPanEnd: _onPanEnd,
                  ),
                );
              },
            ),
          );
          final board = Expanded(flex: 5, child: boardContent);

          // Cap the panel width for wide screens and phones.
          const maxControlWidth = 560.0;
          final controls = Expanded(
            flex: 4,
            child: LayoutBuilder(
              builder: (context, box) => Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: box.maxWidth > maxControlWidth
                      ? maxControlWidth
                      : box.maxWidth,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.only(bottom: 24),
                    child: _Controls(
                      charController: _charController,
                      familyController: _familyController,
                      strokeWidth: _strokeWidth,
                      onStrokeWidthChanged: (v) =>
                          setState(() => _strokeWidth = v),
                      masterValue: _masterValue,
                      onMasterValueChanged: (v) =>
                          setState(() => _masterValue = v),
                      onUndo: _undo,
                      onClear: _clear,
                      onSave: _saveShape,
                      selectedSet: _selectedSet,
                      onSelectedSetChanged: (tag) =>
                          setState(() => _selectedSet = tag),
                      onSaveVariant: _saveVariant,
                      variants: _glyphs[_char]?.variants ?? const [],
                      onDeleteVariant: (tag) => setState(
                        () => _glyphs[_char] =
                            (_glyphs[_char] ?? const _GlyphEntry()).copyWith(
                              variants: (_glyphs[_char]?.variants ?? const [])
                                  .where((v) => v.tag != tag)
                                  .toList(),
                            ),
                      ),
                      onBuild: _busy ? null : _buildFont,
                      glyphChars: _glyphs.keys.toList(),
                      activeChar: _char,
                      masters: _glyphs[_char]?.masters ?? const [],
                      hasDefault:
                          (_glyphs[_char]?.strokes ?? const []).isNotEmpty,
                      onDeleteChar: (char) =>
                          setState(() => _glyphs.remove(char)),
                      busy: _busy,
                      error: _error,
                      result: _builtInfo == null || _fontBytes == null
                          ? null
                          : _Result(
                              bytes: _fontBytes!,
                              info: _builtInfo!,
                              family: _fontFamily,
                              sample: _builtSample ?? _char,
                              exportedPath: _exportedPath,
                              onExport: _export,
                              previewPath: _previewPath,
                              previewValue: _previewValue,
                              onPreviewDrag: (value) =>
                                  setState(() => _previewValue = value),
                              onPreviewChanged: _renderPreview,
                              variants: _builtVariants,
                            ),
                    ),
                  ),
                ),
              ),
            ),
          );

          return Padding(
            padding: const EdgeInsets.all(16),
            child: wide
                ? Row(children: [board, const SizedBox(width: 20), controls])
                : Column(
                    children: [
                      Expanded(child: boardContent),
                      controls,
                    ],
                  ),
          );
        },
      ),
    );
  }
}

/// The strokes drawn for one character, plus its variation masters.
class _GlyphEntry {
  const _GlyphEntry({
    this.strokes = const <List<Offset>>[],
    this.strokeWidth = 26.0,
    this.masters = const <_Master>[],
    this.variants = const <_Variant>[],
  });

  final List<List<Offset>> strokes;
  final double strokeWidth;
  final List<_Master> masters;

  /// Discrete alternates, exposed as `ss01`..`ss20`.
  final List<_Variant> variants;

  /// The default outline: the strokes saved at the axis default.
  List<List<Offset>> get defaultStrokes => strokes.isNotEmpty
      ? strokes
      : (masters.isEmpty ? const [] : masters.first.strokes);

  double get defaultWidth => strokes.isNotEmpty
      ? strokeWidth
      : (masters.isEmpty ? 26.0 : masters.first.strokeWidth);

  _GlyphEntry copyWith({
    List<List<Offset>>? strokes,
    double? strokeWidth,
    List<_Master>? masters,
    List<_Variant>? variants,
  }) => _GlyphEntry(
    strokes: strokes ?? this.strokes,
    strokeWidth: strokeWidth ?? this.strokeWidth,
    masters: masters ?? this.masters,
    variants: variants ?? this.variants,
  );
}

/// One discrete alternate of a character, under a stylistic set tag.
class _Variant {
  const _Variant({
    required this.tag,
    required this.strokes,
    required this.strokeWidth,
  });

  final String tag;
  final List<List<Offset>> strokes;
  final double strokeWidth;
}

/// One extra drawing of a character, pinned to a spot on the axis.
class _Master {
  const _Master({
    required this.value,
    required this.strokes,
    required this.strokeWidth,
  });

  final double value;
  final List<List<Offset>> strokes;
  final double strokeWidth;
}

extension on List<List<Offset>> {
  List<List<Offset>> copy() => map((s) => List<Offset>.from(s)).toList();
}

/// Resamples a stroke to [count] evenly spaced points, as `gvar` requires.
List<Offset> _resample(List<Offset> points, int count) {
  if (points.isEmpty || count < 2) return const <Offset>[];
  if (points.length == 1) return List<Offset>.filled(count, points.first);

  final distances = <double>[0];
  for (var i = 1; i < points.length; i++) {
    distances.add(distances[i - 1] + (points[i] - points[i - 1]).distance);
  }
  final total = distances.last;
  if (total == 0) return List<Offset>.filled(count, points.first);

  final result = <Offset>[];
  var segment = 0;
  for (var i = 0; i < count; i++) {
    final target = total * i / (count - 1);
    while (segment < distances.length - 2 && distances[segment + 1] < target) {
      segment++;
    }
    final span = distances[segment + 1] - distances[segment];
    final t = span == 0 ? 0.0 : (target - distances[segment]) / span;
    result.add(
      Offset(
        points[segment].dx + (points[segment + 1].dx - points[segment].dx) * t,
        points[segment].dy + (points[segment + 1].dy - points[segment].dy) * t,
      ),
    );
  }
  return result;
}

/// Converts a polyline into a closed thick-stroke outline with round caps.
List<Offset> _strokeOutline(List<Offset> points, double half) {
  const capSegments = 10;
  if (points.isEmpty) return const <Offset>[];
  if (points.length == 1) {
    return [
      for (var k = 0; k < capSegments; k++)
        points.first +
            Offset(
              math.cos(2 * math.pi * k / capSegments) * half,
              math.sin(2 * math.pi * k / capSegments) * half,
            ),
    ];
  }

  final left = <Offset>[];
  final right = <Offset>[];
  for (var i = 0; i < points.length; i++) {
    final previous = i > 0 ? points[i - 1] : points[i];
    final next = i < points.length - 1 ? points[i + 1] : points[i];
    var dx = next.dx - previous.dx;
    var dy = next.dy - previous.dy;
    final length = math.sqrt(dx * dx + dy * dy);
    if (length < 1e-6) {
      dx = 1;
      dy = 0;
    } else {
      dx /= length;
      dy /= length;
    }
    left.add(points[i] + Offset(-dy * half, dx * half));
    right.add(points[i] + Offset(dy * half, -dx * half));
  }

  final outline = <Offset>[...left];

  // Round cap at the end: sweep from +normal through the forward direction.
  final end = points.last;
  final endAngle = math.atan2(left.last.dy - end.dy, left.last.dx - end.dx);
  for (var k = 1; k < capSegments; k++) {
    final angle = endAngle - math.pi * k / capSegments;
    outline.add(end + Offset(math.cos(angle) * half, math.sin(angle) * half));
  }

  outline.addAll(right.reversed);

  // Round cap at the start: sweep from -normal through the backward direction.
  final start = points.first;
  final startAngle = math.atan2(
    right.first.dy - start.dy,
    right.first.dx - start.dx,
  );
  for (var k = 1; k < capSegments; k++) {
    final angle = startAngle - math.pi * k / capSegments;
    outline.add(start + Offset(math.cos(angle) * half, math.sin(angle) * half));
  }

  return outline;
}

// ---------------------------------------------------------------------------
// Widgets
// ---------------------------------------------------------------------------

class _Board extends StatelessWidget {
  const _Board({
    required this.strokes,
    required this.current,
    required this.strokeWidth,
    required this.onPanStart,
    required this.onPanUpdate,
    required this.onPanEnd,
  });

  final List<List<Offset>> strokes;
  final List<Offset>? current;
  final double strokeWidth;
  final ValueChanged<DragStartDetails> onPanStart;
  final ValueChanged<DragUpdateDetails> onPanUpdate;
  final VoidCallback onPanEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: GestureDetector(
          onPanStart: onPanStart,
          onPanUpdate: onPanUpdate,
          onPanEnd: (_) => onPanEnd(),
          child: CustomPaint(
            painter: _BoardPainter(
              strokes: strokes,
              current: current,
              strokeWidth: strokeWidth,
              ink: theme.colorScheme.onSurface,
              guideColor: theme.colorScheme.onSurface.withValues(alpha: 0.12),
              accentColor: theme.colorScheme.primary,
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}

class _BoardPainter extends CustomPainter {
  const _BoardPainter({
    required this.strokes,
    required this.current,
    required this.strokeWidth,
    required this.ink,
    required this.guideColor,
    required this.accentColor,
  });

  final List<List<Offset>> strokes;
  final List<Offset>? current;
  final double strokeWidth;
  final Color ink;
  final Color guideColor;
  final Color accentColor;

  @override
  void paint(Canvas canvas, Size size) {
    final guide = Paint()
      ..color = guideColor
      ..strokeWidth = 1;
    final baselinePaint = Paint()
      ..color = accentColor.withValues(alpha: 0.5)
      ..strokeWidth = 1;

    // Ascender / baseline / descender, mapped into board coordinates.
    double lineFor(double fontY) =>
        (_ascender - fontY) / _unitsPerEm * size.height;

    for (final y in [lineFor(_ascender), lineFor(_descender)]) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), guide);
    }
    canvas.drawLine(
      Offset(0, lineFor(0)),
      Offset(size.width, lineFor(0)),
      baselinePaint,
    );
    canvas.drawLine(
      Offset(size.width / 2, 0),
      Offset(size.width / 2, size.height),
      guide,
    );

    final paint = Paint()
      ..color = ink
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    for (final stroke in strokes) {
      canvas.drawPath(_pathOf(stroke), paint);
    }
    final pending = current;
    if (pending != null) {
      canvas.drawPath(_pathOf(pending), paint);
    }
  }

  static Path _pathOf(List<Offset> points) {
    final path = Path();
    if (points.isEmpty) return path;
    path.moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx, points[i].dy);
    }
    return path;
  }

  @override
  bool shouldRepaint(covariant _BoardPainter old) =>
      old.strokes != strokes ||
      old.current != current ||
      old.strokeWidth != strokeWidth ||
      old.ink != ink ||
      old.guideColor != guideColor ||
      old.accentColor != accentColor;
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.charController,
    required this.familyController,
    required this.strokeWidth,
    required this.onStrokeWidthChanged,
    required this.masterValue,
    required this.onMasterValueChanged,
    required this.onUndo,
    required this.onClear,
    required this.onSave,
    required this.selectedSet,
    required this.onSelectedSetChanged,
    required this.onSaveVariant,
    required this.variants,
    required this.onDeleteVariant,
    required this.onBuild,
    required this.glyphChars,
    required this.activeChar,
    required this.masters,
    required this.hasDefault,
    required this.onDeleteChar,
    required this.busy,
    required this.error,
    required this.result,
  });

  final TextEditingController charController;
  final TextEditingController familyController;
  final double strokeWidth;
  final ValueChanged<double> onStrokeWidthChanged;
  final double masterValue;
  final ValueChanged<double> onMasterValueChanged;
  final VoidCallback onUndo;
  final VoidCallback onClear;
  final VoidCallback onSave;
  final String selectedSet;
  final ValueChanged<String> onSelectedSetChanged;
  final VoidCallback onSaveVariant;
  final List<_Variant> variants;
  final ValueChanged<String> onDeleteVariant;
  final VoidCallback? onBuild;
  final List<String> glyphChars;
  final String activeChar;
  final List<_Master> masters;
  final bool hasDefault;
  final ValueChanged<String> onDeleteChar;
  final bool busy;
  final String? error;
  final _Result? result;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: charController,
          decoration: InputDecoration(
            labelText: l.editorCharLabel,
            helperText: l.editorCharHint,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: familyController,
          decoration: InputDecoration(
            labelText: l.editorFamilyLabel,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            SizedBox(width: 96, child: Text(l.editorStrokeWidth)),
            Expanded(
              child: Slider(
                min: 6,
                max: 60,
                value: strokeWidth,
                onChanged: onStrokeWidthChanged,
              ),
            ),
            SizedBox(
              width: 40,
              child: Text(
                strokeWidth.toInt().toString(),
                textAlign: TextAlign.end,
              ),
            ),
          ],
        ),
        const Divider(height: 20),
        Text(l.editorMastersTitle(_axisTag), style: theme.textTheme.labelLarge),
        const SizedBox(height: 4),
        Row(
          children: [
            SizedBox(width: 96, child: Text(l.editorSaveToPosition)),
            Expanded(
              child: Slider(
                min: _axisMin,
                max: _axisMax,
                divisions: 8,
                value: masterValue,
                label: masterValue.toInt().toString(),
                onChanged: onMasterValueChanged,
              ),
            ),
            SizedBox(
              width: 40,
              child: Text(
                masterValue.toInt().toString(),
                textAlign: TextAlign.end,
              ),
            ),
          ],
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: onUndo,
              icon: const Icon(Icons.undo),
              label: Text(l.editorUndo),
            ),
            OutlinedButton.icon(
              onPressed: onClear,
              icon: const Icon(Icons.clear),
              label: Text(l.editorClear),
            ),
            FilledButton.icon(
              onPressed: onSave,
              icon: const Icon(Icons.save),
              label: Text(
                (masterValue - _axisDefault).abs() < 1
                    ? l.editorSetDefaultGlyph
                    : l.editorSaveAsMaster,
              ),
            ),
          ],
        ),
        if (hasDefault || masters.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              if (hasDefault)
                Chip(
                  avatar: const Icon(Icons.star, size: 16),
                  label: Text(l.editorDefaultValue('${_axisDefault.toInt()}')),
                ),
              for (final master in masters)
                Chip(label: Text('$_axisTag ${master.value.toInt()}')),
            ],
          ),
        ],
        const Divider(height: 20),
        Text(l.editorVariantsTitle, style: theme.textTheme.labelLarge),
        const SizedBox(height: 4),
        Row(
          children: [
            SizedBox(width: 72, child: Text(l.editorFeatureTag)),
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: selectedSet,
                isDense: true,
                items: [
                  for (final tag in _stylisticSets)
                    DropdownMenuItem(value: tag, child: Text(tag)),
                ],
                onChanged: (tag) {
                  if (tag != null) onSelectedSetChanged(tag);
                },
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonalIcon(
              onPressed: onSaveVariant,
              icon: const Icon(Icons.swap_horiz),
              label: Text(l.editorSaveVariant),
            ),
          ],
        ),
        if (variants.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final variant in variants)
                Chip(
                  label: Text(variant.tag),
                  onDeleted: () => onDeleteVariant(variant.tag),
                ),
            ],
          ),
        ],
        if (glyphChars.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            l.editorCharsAdded('${glyphChars.length}'),
            style: theme.textTheme.labelLarge,
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              for (final char in glyphChars)
                InputChip(
                  label: Text(char),
                  selected: char == activeChar,
                  onPressed: () => charController.text = char,
                  onDeleted: () => onDeleteChar(char),
                ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: onBuild,
          child: busy
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l.editorBuildButton),
        ),
        if (error != null) ...[
          const SizedBox(height: 12),
          Text(error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
        if (result != null) ...[const SizedBox(height: 16), result!],
      ],
    );
  }
}

class _Result extends StatelessWidget {
  const _Result({
    required this.bytes,
    required this.info,
    required this.family,
    required this.sample,
    required this.exportedPath,
    required this.onExport,
    required this.previewPath,
    required this.previewValue,
    required this.onPreviewDrag,
    required this.onPreviewChanged,
    required this.variants,
  });

  final Uint8List bytes;
  final FontInfo info;
  final String? family;
  final String sample;
  final String? exportedPath;
  final VoidCallback onExport;
  final Path? previewPath;
  final double previewValue;
  final ValueChanged<double> onPreviewDrag;
  final ValueChanged<double> onPreviewChanged;
  final List<String> variants;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final axes = info.axes;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l.editorResultTitle, style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            _Line(l.labelFamily, info.names.family),
            _Line(l.labelGlyphCount, '${info.metrics.glyphCount}'),
            _Line('units per em', '${info.metrics.unitsPerEm}'),
            _Line(
              l.labelAxes,
              axes.isEmpty ? l.editorNoAxes : axes.map((a) => a.tag).join(' '),
            ),
            _Line(l.editorResultInstances, '${info.instances.length}'),
            _Line(
              l.editorResultGsubVariants,
              variants.isEmpty ? l.none : variants.join(' '),
            ),
            _Line(l.labelTables, info.tables.join(' ')),
            _Line(l.labelSize, '${bytes.lengthInBytes} bytes'),
            const Divider(height: 24),
            Text(l.editorRenderCompare, style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _Preview(
                    label: l.editorCustomFont,
                    child: Text(
                      sample,
                      style: TextStyle(fontFamily: family, fontSize: 88),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _Preview(
                    label: l.editorSystemFont,
                    child: Text(sample, style: const TextStyle(fontSize: 88)),
                  ),
                ),
              ],
            ),
            if (axes.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                l.editorInterpolationPreview(_axisTag),
                style: theme.textTheme.labelLarge,
              ),
              Row(
                children: [
                  const SizedBox(width: 96, child: Text(_axisTag)),
                  Expanded(
                    child: Slider(
                      min: _axisMin,
                      max: _axisMax,
                      value: previewValue,
                      label: previewValue.toInt().toString(),
                      onChanged: onPreviewDrag,
                      onChangeEnd: onPreviewChanged,
                    ),
                  ),
                  SizedBox(
                    width: 40,
                    child: Text(
                      previewValue.toInt().toString(),
                      textAlign: TextAlign.end,
                    ),
                  ),
                ],
              ),
              SizedBox(
                height: 120,
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: previewPath == null
                      ? Text(l.editorDragSlider)
                      : CustomPaint(
                          painter: _GlyphPainter(
                            previewPath!,
                            ink: theme.colorScheme.onSurface,
                          ),
                          child: const SizedBox.expand(),
                        ),
                ),
              ),
            ],
            if (variants.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(l.editorVariantsPreview, style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              Text(l.editorVariantsPreviewNote, style: TextStyle(fontSize: 11)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _Preview(
                    label: l.labelDefault,
                    child: Text(
                      sample,
                      style: TextStyle(fontFamily: family, fontSize: 72),
                    ),
                  ),
                  for (final tag in variants)
                    _Preview(
                      label: tag,
                      child: Text(
                        sample,
                        style: TextStyle(
                          fontFamily: family,
                          fontSize: 72,
                          fontFeatures: [FontFeature(tag)],
                        ),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onExport,
              icon: const Icon(Icons.save_alt),
              label: Text(l.editorExport),
            ),
            if (exportedPath != null) ...[
              const SizedBox(height: 8),
              SelectableText(exportedPath!, style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(this.path, {required this.ink});

  final Path path;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = path.getBounds();
    if (bounds.isEmpty) return;
    final scale = math.min(
      (size.width - 24) / bounds.width,
      (size.height - 24) / bounds.height,
    );
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(scale);
    canvas.translate(-bounds.center.dx, -bounds.center.dy);
    canvas.drawPath(
      path,
      Paint()
        ..color = ink
        ..style = PaintingStyle.fill,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GlyphPainter old) =>
      old.path != path || old.ink != ink;
}

class _Preview extends StatelessWidget {
  const _Preview({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Text(label, style: theme.textTheme.labelSmall),
        const SizedBox(height: 4),
        Container(
          height: 130,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: FittedBox(child: child),
        ),
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value);

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 110,
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
