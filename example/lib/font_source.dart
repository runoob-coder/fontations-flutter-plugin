import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:fontations/fontations.dart';

/// The bundled font the example starts with.
const String bundledFontAsset = 'assets/fonts/Inter.ttf';
const String bundledFontName = 'Inter.ttf';

/// Extensions `read-fonts` can parse. `woff`/`woff2` are compressed and would
/// need decompressing first, so they are not offered.
const List<String> fontExtensions = ['ttf', 'otf', 'ttc', 'otc'];

/// One open font file, and which face of it is on screen.
class LoadedFont {
  const LoadedFont({
    required this.name,
    required this.bytes,
    required this.faceCount,
    this.index = 0,
  });

  final String name;
  final Uint8List bytes;

  /// How many faces the file holds: more than one for a `.ttc` collection.
  final int faceCount;

  /// Index of the face being read, passed straight to `Font.fromBytes`.
  final int index;

  LoadedFont withIndex(int index) =>
      LoadedFont(name: name, bytes: bytes, faceCount: faceCount, index: index);

  @override
  bool operator ==(Object other) =>
      other is LoadedFont &&
      other.name == name &&
      other.index == index &&
      identical(other.bytes, bytes);

  @override
  int get hashCode => Object.hash(name, index, identityHashCode(bytes));
}

/// The font the example pages read.
///
/// Both the reading page and the shaping page follow this, so opening a file
/// switches both instead of leaving one of them on the bundled font.
class FontSource extends ChangeNotifier {
  LoadedFont? _current;
  final List<LoadedFont> _opened = <LoadedFont>[];
  Object? _error;
  bool _picking = false;

  LoadedFont? get current => _current;
  List<LoadedFont> get opened => List.unmodifiable(_opened);
  Object? get error => _error;
  bool get picking => _picking;

  /// Loads the bundled font. Called once before the app starts, and again if
  /// the user wants to go back to it.
  Future<void> loadBundled() async {
    try {
      final bytes = await rootBundle
          .load(bundledFontAsset)
          .then((data) => data.buffer.asUint8List());
      _add(
        LoadedFont(
          name: bundledFontName,
          bytes: bytes,
          faceCount: Font.countFonts(bytes: bytes),
        ),
      );
    } catch (error) {
      _fail(error);
    }
  }

  /// Shows the system open panel and reads whatever the user picks.
  Future<void> openFile() async {
    if (_picking) return;
    _picking = true;
    notifyListeners();
    try {
      final picked = await FilePicker.pickFile(
        dialogTitle: '选择字体文件',
        type: FileType.custom,
        allowedExtensions: fontExtensions,
      );
      if (picked == null) return;

      // `PlatformFile` knows how to read itself on every platform, so this
      // works whether the picker hands back a path, a blob or a stream.
      final bytes = await picked.readAsBytes();
      _add(
        LoadedFont(
          name: picked.name,
          bytes: bytes,
          faceCount: Font.countFonts(bytes: bytes),
        ),
      );
    } catch (error) {
      _fail(error);
    } finally {
      _picking = false;
      notifyListeners();
    }
  }

  /// Shows [font]: a face of the current file, or a file opened before.
  ///
  /// It also joins the list of open files, so switching back later does not
  /// need the picker again.
  void select(LoadedFont font) => _add(font);

  void selectFace(int index) {
    final current = _current;
    if (current == null) return;
    select(current.withIndex(index));
  }

  void _add(LoadedFont font) {
    _opened.removeWhere((existing) => existing.name == font.name);
    _opened.insert(0, font);
    if (_opened.length > 6) _opened.removeLast();
    _current = font;
    _error = null;
    notifyListeners();
  }

  void _fail(Object error) {
    _error = error;
    notifyListeners();
  }
}

/// The one instance the example shares.
final FontSource fontSource = FontSource();
