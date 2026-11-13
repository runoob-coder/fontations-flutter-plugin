import 'dart:typed_data';

import 'package:flutter/services.dart' show FontLoader;
import 'package:fontations/fontations.dart';
import 'package:material_ui/material_ui.dart';

import 'demo_widgets.dart';
import 'font_source.dart';
import 'font_source_controls.dart';
import 'github_button.dart';
import 'l10n/app_localizations.dart';
import 'locale_switcher.dart';
import 'theme_switcher.dart';

/// Raw tables, structured tables and the upstream write/patch entry points.
class FontToolsPage extends StatefulWidget {
  const FontToolsPage({super.key});

  @override
  State<FontToolsPage> createState() => _FontToolsPageState();
}

class _FontToolsPageState extends State<FontToolsPage> {
  late AppLocalizations l;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    l = AppLocalizations.of(context);
  }

  final TextEditingController _subsetTextController = TextEditingController(
    text: 'Hello fontations',
  );
  final TextEditingController _familyController = TextEditingController(
    text: 'Patched Inter',
  );
  final TextEditingController _subfamilyController = TextEditingController(
    text: 'Bold',
  );
  final TextEditingController _designerController = TextEditingController(
    text: 'fontations example',
  );
  final TextEditingController _kernLeftController = TextEditingController(
    text: 'A',
  );
  final TextEditingController _kernRightController = TextEditingController(
    text: 'V',
  );
  final TextEditingController _kernValueController = TextEditingController(
    text: '-80',
  );

  Font? _font;
  FontInfo? _info;
  LoadedFont? _loaded;
  Object? _error;

  ExtendedTableInfo? _extended;
  List<NameRecordInfo> _nameRecords = const [];
  String? _selectedTable;
  Uint8List? _tableBytes;
  // Cached so rebuilds (theme/locale switches, errors, busy flags) do not
  // repeat synchronous FFI calls into the font.
  bool? _tableHas;
  int? _tableLength;

  bool _noHinting = false;
  bool _retainGlyphIds = false;
  bool _subsetBusy = false;
  bool _modifyBusy = false;
  _SubsetResult? _subset;
  _ModifyResult? _modified;

  double _pinValue = 700;
  ({String axis, double base, double pinned, List<VariationSetting> settings})?
  _pin;
  int _familyCounter = 0;

  /// Bumped whenever the open font changes. Long-running writes (subset,
  /// patch, save dialog) capture it and discard results for an older font.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    fontSource.addListener(_onSourceChanged);
    _onSourceChanged();
  }

  @override
  void dispose() {
    fontSource.removeListener(_onSourceChanged);
    for (final controller in [
      _subsetTextController,
      _familyController,
      _subfamilyController,
      _designerController,
      _kernLeftController,
      _kernRightController,
      _kernValueController,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  LoadedFont? _lastLoaded;

  void _onSourceChanged() => _load(fontSource.current);

  Future<void> _load(LoadedFont? loaded) async {
    if (!mounted || loaded == _lastLoaded) return;
    _lastLoaded = loaded;
    _generation++;
    if (loaded == null) {
      setState(() {
        _font = null;
        _info = null;
        _loaded = null;
        _extended = null;
        _nameRecords = const [];
        _tableBytes = null;
      });
      return;
    }
    try {
      final font = fontSource.font;
      final info = font.info();
      final extended = font.extendedTables();
      final records = font.nameRecords(nameId: 1);
      final table = info.tables.contains('GSUB')
          ? 'GSUB'
          : (info.tables.isEmpty ? '' : info.tables.first);
      setState(() {
        _font = font;
        _info = info;
        _loaded = loaded;
        _extended = extended;
        _nameRecords = records;
        _subset = null;
        _modified = null;
        _subsetBusy = false;
        _modifyBusy = false;
        _error = null;
        _pinValue = 700;
      });
      _readTable(table);
      _computePin();
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  /// Reads the selected table once per selection rather than once per build.
  /// A read failure is reported instead of looking like an empty table.
  void _readTable(String tag) {
    final font = _font;
    bool? has;
    int? length;
    Uint8List? bytes;
    Object? failure;
    try {
      if (tag.isNotEmpty) {
        has = font?.hasTable(tag: tag);
        length = font?.tableLength(tag: tag);
        bytes = font?.tableData(tag: tag);
      }
    } catch (error) {
      failure = error;
    }
    setState(() {
      _selectedTable = tag;
      _tableHas = has;
      _tableLength = length;
      _tableBytes = bytes;
      if (failure != null) _error = failure;
    });
  }

  void _selectTable(String tag) => _readTable(tag);

  /// A pinned handle is a view of the same bytes at a fixed location.
  void _computePin() {
    final font = _font;
    final info = _info;
    if (font == null || info == null) return;
    final axes = info.axes.where((axis) => !axis.hidden).toList();
    if (axes.isEmpty) {
      setState(() => _pin = null);
      return;
    }
    final axis = axes.first;
    final value = _pinValue.clamp(axis.minValue, axis.maxValue).toDouble();
    final pinned = font.withVariations(
      variations: [VariationSetting(tag: axis.tag, value: value)],
    );
    final glyphId = font.charToGlyph(codePoint: 0x41) ?? 1;
    setState(() {
      _pin = (
        axis: axis.tag,
        base:
            font.advanceWidth(
              glyphId: glyphId,
              size: 48,
              variations: const [],
            ) ??
            0,
        pinned:
            pinned.advanceWidth(
              glyphId: glyphId,
              size: 48,
              variations: const [],
            ) ??
            0,
        settings: pinned.pinnedVariations(),
      );
    });
  }

  Future<void> _runSubset() async {
    final loaded = _loaded;
    if (loaded == null) return;
    final generation = _generation;
    setState(() {
      _subsetBusy = true;
      _error = null;
    });
    try {
      final text = _subsetTextController.text;
      final bytes = await subsetFont(
        bytes: loaded.bytes,
        index: loaded.index,
        request: FontSubsetRequest(
          codePoints: Uint32List.fromList(text.runes.toList()),
          glyphIds: Uint32List(0),
          retainGlyphIds: _retainGlyphIds,
          noHinting: _noHinting,
          passthroughUnrecognized: false,
          glyphNames: false,
          keepEverything: false,
          layoutFeatures: const [],
          dropTables: const [],
        ),
      );
      final info = readFontInfo(bytes: bytes);
      final family = 'SubsetPreview${++_familyCounter}';
      await (FontLoader(
        family,
      )..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)))).load();
      if (!mounted || generation != _generation) return;
      setState(
        () => _subset = _SubsetResult(
          bytes: bytes,
          info: info,
          family: family,
          sample: text,
        ),
      );
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = error);
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _subsetBusy = false);
      }
    }
  }

  Future<void> _runModify() async {
    final loaded = _loaded;
    final before = _font;
    if (loaded == null || before == null) return;
    final generation = _generation;
    setState(() {
      _modifyBusy = true;
      _error = null;
    });
    try {
      final left = _kernLeftController.text.trim().isEmpty
          ? 0x41
          : _kernLeftController.text.trim().runes.first;
      final right = _kernRightController.text.trim().isEmpty
          ? 0x56
          : _kernRightController.text.trim().runes.first;
      final kern = double.tryParse(_kernValueController.text.trim()) ?? -80;
      final bytes = await modifyFont(
        bytes: loaded.bytes,
        request: FontModificationRequest(
          familyName: _familyController.text.trim(),
          subfamilyName: _subfamilyController.text.trim(),
          designer: _designerController.text.trim(),
          kernPairs: [KernPair(left: left, right: right, value: kern)],
          ligatures: const [],
          alternates: const [],
        ),
      );
      final after = Font.fromBytes(bytes: bytes);
      final features = <String>{
        for (final table in after.layout())
          for (final feature in table.features) feature.tag,
      }.toList()..sort();
      if (!mounted || generation != _generation) return;
      setState(
        () => _modified = _ModifyResult(
          bytes: bytes,
          family: after.info().names.family ?? '-',
          weight: after.attributes().weight,
          glyphCount: after.info().metrics.glyphCount,
          beforeGlyphId: before.charToGlyph(codePoint: 0x41),
          afterGlyphId: after.charToGlyph(codePoint: 0x41),
          features: features,
          designers: after
              .nameRecords(nameId: 9)
              .map((record) => record.value)
              .toSet()
              .toList(),
        ),
      );
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = error);
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _modifyBusy = false);
      }
    }
  }

  Future<void> _save(
    String name,
    Uint8List bytes,
    void Function(String) onSaved,
  ) async {
    final generation = _generation;
    try {
      final path = await saveFontBytes(
        fileName: name,
        bytes: bytes,
        dialogTitle: l.saveFontDialogTitle,
      );
      if (!mounted || generation != _generation) return;
      if (path != null) {
        onSaved(path);
        _showSnack(l.savedTo(path));
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = error);
      }
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.toolsTitle),
        actions: const [GitHubButton(), ThemeMenu(), LanguageMenu()],
      ),
      body: _error != null && info == null
          ? Message(l.fontReadError(describeError(_error!)))
          : info == null
          ? const Center(child: CircularProgressIndicator())
          : _buildBody(context, info),
    );
  }

  Widget _buildBody(BuildContext context, FontInfo info) {
    final wide = MediaQuery.sizeOf(context).width >= wideBreakpoint;
    final inspection = <Widget>[
      const FontSourceControls(compact: true),
      if (_error != null) ErrorBanner(_error!),
      _buildTables(info),
      _buildExtended(),
      _buildNames(),
    ];
    final writing = <Widget>[
      // Writing actions fail too, and on wide screens their column is
      // scrolled independently of the inspection banner.
      if (wide && _error != null) ErrorBanner(_error!),
      _buildSubset(),
      _buildModify(),
      _buildPinned(info),
    ];

    if (!wide) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [...inspection, ...writing],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 6,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: inspection,
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          flex: 5,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: writing,
          ),
        ),
      ],
    );
  }

  Widget _buildTables(FontInfo info) {
    final bytes = _tableBytes;
    final tag = _selectedTable;
    return SectionCard(
      title: l.toolsRawTablesTitle,
      children: [
        Text(
          l.toolsRawTablesNote,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final table in info.tables)
              ChoiceChip(
                label: Text(table),
                selected: table == tag,
                onSelected: (_) => _selectTable(table),
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
        const SizedBox(height: 10),
        InfoRow('hasTable', tag == null ? '-' : '${_tableHas ?? '-'}'),
        InfoRow(
          'tableLength',
          tag == null ? '-' : l.bytesUnit('${_tableLength ?? '-'}'),
        ),
        if (bytes == null || bytes.isEmpty)
          Text(l.toolsTableEmpty)
        else ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              _hexDump(bytes, l),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildExtended() {
    final extended = _extended;
    if (extended == null) return const SizedBox.shrink();
    return SectionCard(
      title: l.toolsExtendedTitle,
      children: [
        InfoRow(l.toolsTableTagCount, '${extended.tables.length}'),
        InfoRow(l.toolsFlags, _extendedFlags(extended, l)),
        InfoRow(l.toolsSvgDocs, '${extended.svgDocuments.length}'),
        InfoRow(l.toolsGaspRanges, '${extended.gaspRanges.length}'),
        InfoRow(l.toolsMetaEntries, '${extended.metaEntries.length}'),
        InfoRow(
          l.toolsAatTables,
          extended.aatTables.isEmpty ? l.none : extended.aatTables.join(' '),
        ),
        for (final gasp in extended.gaspRanges.take(6))
          InfoRow('≤ ${gasp.maxPpem} ppem', gasp.behavior, width: 120),
        for (final meta in extended.metaEntries.take(6))
          InfoRow(meta.tag, meta.value, width: 120),
        for (final svg in extended.svgDocuments.take(3))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'SVG #${svg.startGlyphId}–${svg.endGlyphId} (${svg.length} B): '
              '${_clip(svg.preview, 90)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  Widget _buildNames() {
    return SectionCard(
      title: l.toolsNamesTitle,
      children: [
        if (_nameRecords.isEmpty)
          Text(l.toolsNoNameRecords)
        else
          for (final record in _nameRecords.take(10))
            InfoRow(
              record.language ??
                  '${record.platformId}/${record.encodingId}/${record.languageId}',
              record.value,
              width: 120,
            ),
      ],
    );
  }

  Widget _buildSubset() {
    final result = _subset;
    return SectionCard(
      title: l.toolsSubsetTitle,
      children: [
        TextField(
          controller: _subsetTextController,
          decoration: InputDecoration(
            labelText: l.toolsSubsetCharsLabel,
            helperText: l.toolsSubsetCharsHint,
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        // Material switches everywhere; never `SwitchListTile.adaptive`,
        // which would turn these into CupertinoSwitch on Apple platforms.
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l.toolsNoHinting),
          value: _noHinting,
          onChanged: (value) => setState(() => _noHinting = value),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l.toolsRetainGlyphIds),
          value: _retainGlyphIds,
          onChanged: (value) => setState(() => _retainGlyphIds = value),
        ),
        FilledButton.icon(
          onPressed: _subsetBusy ? null : _runSubset,
          icon: _subsetBusy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.compress),
          label: Text(l.toolsSubsetButton),
        ),
        if (result != null) ...[
          const SizedBox(height: 12),
          InfoRow(
            l.labelSize,
            '${_loaded?.bytes.length ?? 0} → ${result.bytes.length} B'
            '（${_percent(result.bytes.length, _loaded?.bytes.length ?? 1)}）',
          ),
          InfoRow(l.labelGlyphCount, '${result.info.metrics.glyphCount}'),
          InfoRow(l.labelAxes, _axesLabel(result.info.axes, l)),
          InfoRow(l.labelTables, result.info.tables.join(' ')),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              result.sample.isEmpty ? l.emptyValue : result.sample,
              style: TextStyle(fontFamily: result.family, fontSize: 32),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _save('subset.ttf', result.bytes, (path) {
              setState(() => result.savedPath = path);
            }),
            icon: const Icon(Icons.save_alt),
            label: Text(l.toolsSaveSubset),
          ),
          if (result.savedPath != null)
            SelectableText(
              result.savedPath!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ],
    );
  }

  Widget _buildModify() {
    final result = _modified;
    return SectionCard(
      title: l.toolsModifyTitle,
      children: [
        TextField(
          controller: _familyController,
          decoration: InputDecoration(
            labelText: l.toolsNewFamily,
            isDense: true,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _subfamilyController,
                decoration: InputDecoration(
                  labelText: l.toolsSubfamily,
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _designerController,
                decoration: InputDecoration(
                  labelText: l.toolsDesignerLabel,
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            SizedBox(width: 56, child: Text(l.toolsKernPair)),
            SizedBox(
              width: 44,
              child: TextField(
                controller: _kernLeftController,
                textAlign: TextAlign.center,
                decoration: InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(
              width: 44,
              child: TextField(
                controller: _kernRightController,
                textAlign: TextAlign.center,
                decoration: InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _kernValueController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: l.toolsKernValue,
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: _modifyBusy ? null : _runModify,
          icon: _modifyBusy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.build_outlined),
          label: Text(l.toolsPatchButton),
        ),
        if (result != null) ...[
          const SizedBox(height: 12),
          InfoRow('family', result.family),
          InfoRow('weight', result.weight.toStringAsFixed(0)),
          InfoRow(l.labelGlyphCount, '${result.glyphCount}'),
          InfoRow(
            l.labelGlyphIdA,
            l.toolsUnchangedOutlines(
              '${result.beforeGlyphId}',
              '${result.afterGlyphId}',
            ),
          ),
          InfoRow('designer', result.designers.join(' / ')),
          InfoRow(l.labelLayoutFeatures, result.features.join(' ')),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _save('patched.ttf', result.bytes, (path) {
              setState(() => result.savedPath = path);
            }),
            icon: const Icon(Icons.save_alt),
            label: Text(l.toolsSavePatched),
          ),
          if (result.savedPath != null)
            SelectableText(
              result.savedPath!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ],
    );
  }

  Widget _buildPinned(FontInfo info) {
    final axes = info.axes.where((axis) => !axis.hidden).toList();
    final pin = _pin;
    return SectionCard(
      title: l.toolsPinnedTitle,
      children: [
        Text(l.toolsPinnedNote, style: Theme.of(context).textTheme.bodySmall),
        if (axes.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(l.toolsNoVisibleAxes),
          )
        else ...[
          const SizedBox(height: 8),
          LabeledSlider(
            label: axes.first.tag,
            value: _pinValue
                .clamp(axes.first.minValue, axes.first.maxValue)
                .toDouble(),
            min: axes.first.minValue,
            max: axes.first.maxValue,
            labelWidth: 72,
            onChanged: (value) => setState(() => _pinValue = value),
            onChangedEnd: (_) => _computePin(),
          ),
          if (pin != null) ...[
            InfoRow(
              'pinnedVariations',
              pin.settings
                  .map((s) => '${s.tag}=${s.value.toStringAsFixed(0)}')
                  .join(' '),
            ),
            InfoRow(
              l.toolsDefaultAAdvance,
              '${pin.base.toStringAsFixed(1)} px',
            ),
            InfoRow(
              l.toolsPinnedAAdvance,
              '${pin.pinned.toStringAsFixed(1)} px',
            ),
          ],
        ],
      ],
    );
  }

  String _percent(int part, int total) =>
      total <= 0 ? '-' : '${(part * 100 / total).toStringAsFixed(1)}%';

  String _clip(String text, int limit) =>
      text.length <= limit ? text : '${text.substring(0, limit)}…';

  /// A short hex dump: offset, 16 bytes of hex, and the printable ASCII view.
  String _hexDump(Uint8List bytes, AppLocalizations l, {int limit = 256}) {
    final length = bytes.length < limit ? bytes.length : limit;
    final buffer = StringBuffer();
    for (var offset = 0; offset < length; offset += 16) {
      final end = offset + 16 > length ? length : offset + 16;
      final line = bytes.sublist(offset, end);
      final hex = line
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join(' ')
          .padRight(47);
      final ascii = line
          .map(
            (byte) =>
                (byte >= 32 && byte < 127) ? String.fromCharCode(byte) : '.',
          )
          .join();
      buffer.writeln(
        '${offset.toRadixString(16).padLeft(6, '0')}  $hex  $ascii',
      );
    }
    if (bytes.length > length) {
      buffer.writeln(l.toolsHexMore('${bytes.length - length}'));
    }
    return buffer.toString();
  }
}

String _extendedFlags(ExtendedTableInfo info, AppLocalizations l) {
  final flags = <String>[
    if (info.hasBase) 'BASE',
    if (info.hasCvar) 'CVAR',
    if (info.hasVvar) 'VVAR',
    if (info.hasMvar) 'MVAR',
    if (info.hasDsig) 'DSIG',
    if (info.hasHdmx) 'hdmx',
  ];
  return flags.isEmpty ? l.none : flags.join(' ');
}

String _axesLabel(List<VariationAxis> axes, AppLocalizations l) =>
    axes.isEmpty ? l.none : axes.map((axis) => axis.tag).join(' ');

class _SubsetResult {
  _SubsetResult({
    required this.bytes,
    required this.info,
    required this.family,
    required this.sample,
  });

  final Uint8List bytes;
  final FontInfo info;
  final String family;
  final String sample;
  String? savedPath;
}

class _ModifyResult {
  _ModifyResult({
    required this.bytes,
    required this.family,
    required this.weight,
    required this.glyphCount,
    required this.beforeGlyphId,
    required this.afterGlyphId,
    required this.features,
    required this.designers,
  });

  final Uint8List bytes;
  final String family;
  final double weight;
  final int glyphCount;
  final int? beforeGlyphId;
  final int? afterGlyphId;
  final List<String> features;
  final List<String> designers;
  String? savedPath;
}
