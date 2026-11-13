import 'dart:async';
import 'dart:ui' as ui;

import 'package:fontations/fontations.dart';
import 'package:material_ui/material_ui.dart';

import 'demo_widgets.dart';
import 'font_source.dart';
import 'font_source_controls.dart';
import 'l10n/app_localizations.dart';
import 'locale_switcher.dart';
import 'theme_switcher.dart';

/// Which of the three representations of a glyph the canvas shows.
enum _PreviewMode { outline, color, bitmap }

/// Browses the character map and inspects one glyph at a time.
///
/// This is the reading-side companion to the info page: instead of listing
/// font-wide metadata it answers "what does glyph N look like, how wide is it,
/// and which optional tables describe it?". It also demonstrates the readers
/// that need a canvas: `ColorGlyphInfo.paint` for `COLR` layers and the RGBA /
/// PNG bytes of embedded bitmap strikes.
class GlyphBrowserPage extends StatefulWidget {
  const GlyphBrowserPage({super.key});

  @override
  State<GlyphBrowserPage> createState() => _GlyphBrowserPageState();
}

class _GlyphBrowserPageState extends State<GlyphBrowserPage> {
  late AppLocalizations l;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    l = AppLocalizations.of(context);
  }

  static const double _fontSize = 120.0;

  /// A CJK font can have tens of thousands of `cmap` entries. The grid only
  /// ever builds a page of them; the search field is how you reach the rest.
  static const int _maxTiles = 400;

  final TextEditingController _searchController = TextEditingController();

  Font? _font;
  FontInfo? _info;
  Object? _error;
  List<CharMapping> _mappings = const [];

  int? _glyphId;
  int? _codePoint;
  _PreviewMode _mode = _PreviewMode.outline;
  int _paletteIndex = 0;
  int _strikeIndex = 0;

  _GlyphFacts? _facts;
  ui.Path? _path;
  ui.Image? _bitmapImage;
  int _detailToken = 0;

  /// `cmap` can hold tens of thousands of entries, so the filtered page is
  /// computed once per debounced query instead of once per rebuild.
  List<CharMapping> _shown = const [];
  Timer? _searchTimer;

  @override
  void initState() {
    super.initState();
    fontSource.addListener(_onSourceChanged);
    _searchController.addListener(_onSearchChanged);
    _onSourceChanged();
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    fontSource.removeListener(_onSourceChanged);
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _bitmapImage?.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _searchTimer?.cancel();
    _searchTimer = Timer(const Duration(milliseconds: 180), () {
      if (!mounted) return;
      setState(() => _shown = _computeShown());
    });
  }

  LoadedFont? _lastLoaded;

  void _onSourceChanged() => _load(fontSource.current);

  Future<void> _load(LoadedFont? loaded) async {
    if (!mounted || loaded == _lastLoaded) return;
    _lastLoaded = loaded;
    _detailToken++;
    if (loaded == null) {
      setState(() {
        _font = null;
        _info = null;
        _mappings = const [];
        _facts = null;
        _path = null;
        _glyphId = null;
        _codePoint = null;
      });
      return;
    }
    try {
      final font = fontSource.font;
      final info = font.info();
      final mappings = font.charMappings();
      setState(() {
        _font = font;
        _info = info;
        _mappings = mappings;
        _shown = _computeShown();
        _error = null;
        _facts = null;
        _path = null;
        _mode = _PreviewMode.outline;
        _paletteIndex = 0;
        _strikeIndex = 0;
        _bitmapImage?.dispose();
        _bitmapImage = null;
      });
      // Start on 'A' when the font has one: a letter is easier to recognize
      // than whatever happens to be the first cmap entry.
      final first = mappings.firstWhere(
        (mapping) => mapping.codePoint == 0x41,
        orElse: () => mappings.isEmpty
            ? const CharMapping(codePoint: 0x41, glyphId: 0)
            : mappings.first,
      );
      await _select(first.glyphId, first.codePoint);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  /// Reads everything about one glyph. Outline drawing and image decoding are
  /// asynchronous; the token stops a slow result from replacing a newer pick.
  Future<void> _select(int glyphId, int codePoint) async {
    final font = _font;
    final info = _info;
    if (font == null || info == null) return;
    final token = ++_detailToken;
    setState(() {
      _glyphId = glyphId;
      _codePoint = codePoint;
    });
    try {
      final outline = await font.outline(
        glyphId: glyphId,
        size: _fontSize,
        variations: const [],
      );
      if (!mounted || token != _detailToken) return;

      final palettes = font.colorPalettes();
      final color = font.hasColorGlyph(glyphId: glyphId)
          ? font.colorGlyph(
              glyphId: glyphId,
              paletteIndex: _paletteIndex,
              variations: const [],
            )
          : null;
      final strikes = font.bitmapStrikes();
      final strikeIndex = (_strikeIndex >= 0 && _strikeIndex < strikes.length)
          ? _strikeIndex
          : 0;
      final strike = strikes.isEmpty ? null : strikes[strikeIndex];
      final bitmap = strike == null
          ? null
          : font.bitmapGlyph(glyphId: glyphId, ppem: strike.ppemX);

      ui.Image? image;
      if (bitmap != null) {
        try {
          image = await _decodeBitmap(bitmap);
        } catch (_) {
          image = null; // An unsupported strike should not hide the glyph.
        }
      }
      if (!mounted || token != _detailToken) {
        image?.dispose();
        return;
      }

      final facts = _GlyphFacts(
        metrics: font.glyphMetrics(
          glyphId: glyphId,
          size: _fontSize,
          variations: const [],
        ),
        glyphName: font.glyphName(glyphId: glyphId),
        glyphNameSource: font.glyphNameSource(),
        outline: outline,
        outlineFormat: font.outlineFormat(),
        verticalOrigin: font.verticalOrigin(glyphId: glyphId),
        verticalAdvance: font.verticalAdvance(glyphId: glyphId),
        color: color,
        palettes: palettes,
        strikes: strikes,
        bitmap: image == null ? null : bitmap,
        math: font.hasMath()
            ? font.mathGlyphInfo(glyphId: glyphId, ppem: _fontSize.toInt())
            : null,
        mathVariants: font.hasMath()
            ? font.mathVariants(glyphId: glyphId, axis: 'vertical')
            : null,
        varc: font.hasVarc()
            ? font.varcComponents(glyphId: glyphId, variations: const [])
            : null,
        variants: font.variantMappings(),
      );

      setState(() {
        _path = outline.toPath();
        _facts = facts;
        _error = null;
        _bitmapImage?.dispose();
        _bitmapImage = image;
        if (_mode == _PreviewMode.color && color == null ||
            _mode == _PreviewMode.bitmap && image == null) {
          _mode = _PreviewMode.outline;
        }
      });
    } catch (error) {
      // A slow request that failed must not replace a newer successful pick.
      if (mounted && token == _detailToken) {
        setState(() => _error = error);
      }
    }
  }

  /// `sbix` strikes carry PNG bytes; `CBDT` / `EBDT` and masks are raw RGBA.
  Future<ui.Image?> _decodeBitmap(BitmapGlyphInfo bitmap) async {
    if (bitmap.width <= 0 || bitmap.height <= 0) return null;
    if (bitmap.pixelFormat == 'png') {
      final codec = await ui.instantiateImageCodec(bitmap.pixels);
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    }
    if (bitmap.pixels.length < bitmap.width * bitmap.height * 4) return null;
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      bitmap.pixels,
      bitmap.width,
      bitmap.height,
      ui.PixelFormat.rgba8888,
      (image) => completer.complete(image),
    );
    return completer.future;
  }

  /// Accepts a literal character, a decimal number, or `U+4E00` / `0x4E00`.
  int? _parseCodePoint(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final hex = RegExp(r'^(U\+|0x)', caseSensitive: false).hasMatch(text);
    final digits = hex ? text.substring(2) : text;
    return hex ? int.tryParse(digits, radix: 16) : int.tryParse(digits);
  }

  List<CharMapping> _computeShown() {
    final query = _searchController.text.trim();
    final number = _parseCodePoint(query);
    final upper = query.toUpperCase();
    var count = 0;
    final result = <CharMapping>[];
    for (final mapping in _mappings) {
      final matches =
          query.isEmpty ||
          (number != null &&
              (mapping.codePoint == number || mapping.glyphId == number)) ||
          (query.length == 1 && mapping.codePoint == query.runes.first) ||
          mapping.glyphId.toString() == query ||
          'U+${mapping.codePoint.toRadixString(16).toUpperCase()}'.contains(
            upper,
          );
      if (matches) {
        result.add(mapping);
        if (++count >= _maxTiles) break;
      }
    }
    return result;
  }

  String _charLabel(int codePoint) {
    if (codePoint < 0x20 || (codePoint >= 0x7F && codePoint < 0xA0)) {
      return 'U+${codePoint.toRadixString(16).toUpperCase()}';
    }
    return String.fromCharCode(codePoint);
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.browserTitle),
        actions: const [ThemeMenu(), LanguageMenu()],
      ),
      body: info == null ? _buildNoFont(context) : _buildBody(context, info),
    );
  }

  /// A failed parse keeps the picker reachable instead of leaving a bare
  /// message with no way back to a readable font.
  Widget _buildNoFont(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const FontSourceControls(compact: true),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: ErrorBanner(_error!),
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
    final shown = _shown;

    final search = TextField(
      controller: _searchController,
      decoration: InputDecoration(
        labelText: l.browserSearchLabel,
        hintText: l.browserSearchHint,
        prefixIcon: const Icon(Icons.search),
        isDense: true,
        border: const OutlineInputBorder(),
        suffixIcon: _searchController.text.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => _searchController.clear(),
              ),
      ),
    );

    final grid = GridView.builder(
      padding: const EdgeInsets.only(top: 8),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 74,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
      ),
      itemCount: shown.length,
      itemBuilder: (context, index) {
        final mapping = shown[index];
        final selected =
            mapping.glyphId == _glyphId && mapping.codePoint == _codePoint;
        return Tooltip(
          message:
              'U+${mapping.codePoint.toRadixString(16).toUpperCase()}'
              ' → #${mapping.glyphId}',
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _select(mapping.glyphId, mapping.codePoint),
            child: Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected
                    ? Theme.of(context).colorScheme.primaryContainer
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _charLabel(mapping.codePoint),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 22),
                  ),
                  Text(
                    '#${mapping.glyphId}',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    final browser = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        search,
        const SizedBox(height: 4),
        Text(
          l.browserCmapSummary(
            '${_mappings.length}',
            shown.length == _maxTiles ? l.browserTruncated('$_maxTiles') : '',
          ),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        Expanded(child: grid),
      ],
    );

    final details = <Widget>[
      const FontSourceControls(compact: true),
      if (_error != null) ErrorBanner(_error!),
      _buildPreview(context, info),
      if (_facts != null) ...[
        _buildMetrics(_facts!),
        _buildScaler(_facts!),
        _buildOptional(_facts!),
        _buildVariants(_facts!),
      ],
    ];

    if (!wide) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          ...details.take(1),
          SizedBox(height: 320, child: browser),
          const SizedBox(height: 12),
          ...details.skip(1),
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 5,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: browser,
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          flex: 6,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: details,
          ),
        ),
      ],
    );
  }

  Widget _buildPreview(BuildContext context, FontInfo info) {
    final facts = _facts;
    final theme = Theme.of(context);
    final segments = <ButtonSegment<_PreviewMode>>[
      ButtonSegment<_PreviewMode>(
        value: _PreviewMode.outline,
        label: Text(l.browserModeOutline),
        icon: Icon(Icons.pentagon_outlined, size: 16),
      ),
      if (facts?.color != null)
        const ButtonSegment<_PreviewMode>(
          value: _PreviewMode.color,
          label: Text('COLR'),
          icon: Icon(Icons.palette_outlined, size: 16),
        ),
      if (_bitmapImage != null)
        ButtonSegment<_PreviewMode>(
          value: _PreviewMode.bitmap,
          label: Text(l.browserModeBitmap),
          icon: Icon(Icons.image_outlined, size: 16),
        ),
    ];

    return SectionCard(
      title: _glyphId == null
          ? l.browserPreviewTitle
          : l.browserGlyphTitle('$_glyphId', _charLabel(_codePoint ?? 0)),
      children: [
        Container(
          height: _fontSize * 1.9,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          clipBehavior: Clip.antiAlias,
          child: CustomPaint(
            painter: _GlyphPainter(
              mode: _mode,
              path: _path,
              color: facts?.color,
              bitmap: _bitmapImage,
              advance: facts?.outline.advanceWidth ?? _fontSize,
              fontSize: _fontSize,
              unitsPerEm: info.metrics.unitsPerEm,
              ink: theme.colorScheme.onSurface,
              guide: theme.colorScheme.primary,
            ),
            child: const SizedBox.expand(),
          ),
        ),
        const SizedBox(height: 10),
        if (segments.length > 1)
          SegmentedButton<_PreviewMode>(
            segments: segments,
            selected: <_PreviewMode>{_mode},
            showSelectedIcon: false,
            onSelectionChanged: (set) => setState(() => _mode = set.first),
          ),
        if (_mode == _PreviewMode.color &&
            (facts?.palettes.length ?? 0) > 1) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            children: [
              for (final palette in facts!.palettes)
                ChoiceChip(
                  label: Text(l.browserPalette('${palette.index}')),
                  selected: palette.index == _paletteIndex,
                  onSelected: (_) {
                    setState(() => _paletteIndex = palette.index);
                    _select(_glyphId!, _codePoint!);
                  },
                ),
            ],
          ),
        ],
        if (_mode == _PreviewMode.bitmap &&
            (facts?.strikes.length ?? 0) > 1) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            children: [
              for (var i = 0; i < facts!.strikes.length; i++)
                ChoiceChip(
                  label: Text('${facts.strikes[i].ppemX.toInt()} ppem'),
                  selected: i == _strikeIndex,
                  onSelected: (_) {
                    setState(() => _strikeIndex = i);
                    _select(_glyphId!, _codePoint!);
                  },
                ),
            ],
          ),
        ],
        const SizedBox(height: 6),
        Text(l.browserPreviewNote, style: theme.textTheme.bodySmall),
      ],
    );
  }

  Widget _buildMetrics(_GlyphFacts facts) {
    final metrics = facts.metrics;
    final bounds = facts.outline.bounds;
    return SectionCard(
      title: l.browserMetricsTitle('${_fontSize.toInt()}'),
      children: [
        InfoRow('glyph name', facts.glyphName ?? '-'),
        InfoRow('name source', facts.glyphNameSource),
        InfoRow('advance', _num(metrics.advanceWidth)),
        InfoRow('left bearing', _num(metrics.leftSideBearing)),
        InfoRow(
          'bounds',
          bounds == null
              ? '-'
              : '[${bounds.xMin.toStringAsFixed(0)}, ${bounds.yMin.toStringAsFixed(0)}]'
                    ' → [${bounds.xMax.toStringAsFixed(0)}, ${bounds.yMax.toStringAsFixed(0)}]',
        ),
        InfoRow('vertical origin', _num(facts.verticalOrigin)),
        InfoRow('vertical advance', _num(facts.verticalAdvance)),
        InfoRow('outline format', facts.outlineFormat ?? '-'),
      ],
    );
  }

  Widget _buildScaler(_GlyphFacts facts) {
    final scaler = facts.outline.scaler;
    return SectionCard(
      title: 'skrifa scaler',
      children: [
        InfoRow('outline source', scaler.outlineSource ?? '-'),
        InfoRow('hint engine', scaler.hintEngine ?? 'none'),
        InfoRow('is hinted', '${scaler.isHinted}'),
        InfoRow('hinted ppem', _num(scaler.hintedPpem)),
        InfoRow('drawn advance', _num(scaler.drawnAdvance)),
        InfoRow('dropout control', scaler.dropoutControl),
        InfoRow('path elements', '${facts.outline.elements.length}'),
        InfoRow('overlaps', '${facts.outline.hasOverlaps}'),
      ],
    );
  }

  Widget _buildOptional(_GlyphFacts facts) {
    final math = facts.math;
    final variants = facts.mathVariants;
    final varc = facts.varc;
    final color = facts.color;
    final bitmap = facts.bitmap;
    return SectionCard(
      title: l.browserOptionalTitle,
      children: [
        InfoRow(
          'MATH',
          math == null
              ? l.none
              : l.browserMath(
                  _num(math.italicsCorrection),
                  _num(math.topAccentAttachment),
                  '${math.kerns.length}',
                ),
        ),
        InfoRow(
          l.browserAssemblyParts,
          variants == null
              ? l.none
              : l.browserVariantsInfo(
                  '${variants.variants.length}',
                  '${variants.assembly?.parts.length ?? 0}',
                ),
        ),
        InfoRow(
          'VARC',
          varc == null
              ? l.none
              : l.browserVarcComponents('${varc.components.length}'),
        ),
        InfoRow(
          'COLR',
          color == null
              ? l.none
              : l.browserColorInfo(
                  color.format,
                  '${color.layers.length}',
                  '${facts.palettes.length}',
                ),
        ),
        InfoRow(
          l.browserModeBitmap,
          bitmap == null
              ? l.none
              : l.browserBitmapInfo(
                  bitmap.pixelFormat,
                  '${bitmap.width}',
                  '${bitmap.height}',
                  '${bitmap.ppemX.toInt()}',
                  bitmap.placementOrigin,
                ),
        ),
        if (varc != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              varc.components
                  .take(6)
                  .map(
                    (c) =>
                        '#${c.glyphId}${c.conditionMet ? '' : l.browserConditionUnmet}',
                  )
                  .join('  '),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  Widget _buildVariants(_GlyphFacts facts) {
    return SectionCard(
      title: l.browserVariantsTitle,
      children: [
        if (facts.variants.isEmpty)
          Text(l.browserNoUvs)
        else
          for (final entry in facts.variants.take(8))
            InfoRow(
              'U+${entry.codePoint.toRadixString(16).toUpperCase()}'
                  ' + U+${entry.selector.toRadixString(16).toUpperCase()}',
              '${entry.kind}${entry.glyphId == null ? '' : ' → #${entry.glyphId}'}',
              width: 150,
            ),
      ],
    );
  }

  String _num(double? value) => value == null ? '-' : value.toStringAsFixed(1);
}

/// Everything read about the selected glyph, so a rebuild never hits Rust.
class _GlyphFacts {
  const _GlyphFacts({
    required this.metrics,
    required this.glyphName,
    required this.glyphNameSource,
    required this.outline,
    required this.outlineFormat,
    required this.verticalOrigin,
    required this.verticalAdvance,
    required this.color,
    required this.palettes,
    required this.strikes,
    required this.bitmap,
    required this.math,
    required this.mathVariants,
    required this.varc,
    required this.variants,
  });

  final GlyphMetrics metrics;
  final String? glyphName;
  final String glyphNameSource;
  final GlyphOutline outline;
  final String? outlineFormat;
  final double? verticalOrigin;
  final double? verticalAdvance;
  final ColorGlyphInfo? color;
  final List<ColorPaletteInfo> palettes;
  final List<BitmapStrikeInfo> strikes;
  final BitmapGlyphInfo? bitmap;
  final MathGlyphInfoInfo? math;
  final MathVariantsInfo? mathVariants;
  final VarcGlyphInfo? varc;
  final List<VariantMappingInfo> variants;
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter({
    required this.mode,
    required this.path,
    required this.color,
    required this.bitmap,
    required this.advance,
    required this.fontSize,
    required this.unitsPerEm,
    required this.ink,
    required this.guide,
  });

  final _PreviewMode mode;
  final ui.Path? path;
  final ColorGlyphInfo? color;
  final ui.Image? bitmap;
  final double advance;
  final double fontSize;
  final int unitsPerEm;
  final Color ink;
  final Color guide;

  @override
  void paint(Canvas canvas, Size size) {
    final baseline = size.height * 0.72;
    final guides = Paint()
      ..color = guide.withValues(alpha: 0.45)
      ..strokeWidth = 1;

    canvas.drawLine(Offset(0, baseline), Offset(size.width, baseline), guides);
    canvas.drawLine(
      Offset(0, baseline - fontSize),
      Offset(size.width, baseline - fontSize),
      guides,
    );

    final x = (size.width - advance) / 2;
    switch (mode) {
      case _PreviewMode.outline:
        final outline = path;
        if (outline != null) {
          canvas.save();
          canvas.translate(x, baseline);
          canvas.drawPath(
            outline,
            Paint()
              ..color = ink
              ..style = PaintingStyle.fill,
          );
          canvas.restore();
          final bounds = outline.getBounds().shift(Offset(x, baseline));
          if (!bounds.isEmpty) {
            canvas.drawRect(
              bounds,
              Paint()
                ..color = guide.withValues(alpha: 0.4)
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1,
            );
          }
        }
      case _PreviewMode.color:
        final glyph = color;
        if (glyph != null) {
          // Layer geometry is in font units with y up; `paint` scales it by
          // size / unitsPerEm and flips y, with `offset` as the baseline.
          glyph.paint(
            canvas,
            size: fontSize,
            unitsPerEm: unitsPerEm,
            offset: ui.Offset(x, baseline),
          );
        }
      case _PreviewMode.bitmap:
        final image = bitmap;
        if (image != null) {
          final scale = fontSize / image.height;
          final width = image.width * scale;
          final dst = ui.Rect.fromLTWH(
            (size.width - width) / 2,
            baseline - fontSize,
            width,
            fontSize,
          );
          // `drawImageRect`'s src needs real image dimensions, not Rect.largest.
          canvas.drawImageRect(
            image,
            ui.Rect.fromLTWH(
              0,
              0,
              image.width.toDouble(),
              image.height.toDouble(),
            ),
            dst,
            Paint()..filterQuality = FilterQuality.medium,
          );
        }
    }
  }

  @override
  bool shouldRepaint(covariant _GlyphPainter old) =>
      old.mode != mode ||
      old.path != path ||
      old.color != color ||
      old.bitmap != bitmap ||
      old.advance != advance ||
      old.fontSize != fontSize ||
      old.unitsPerEm != unitsPerEm ||
      old.ink != ink ||
      old.guide != guide;
}
