/// Flutter bindings for the [fontations](https://github.com/googlefonts/fontations)
/// font stack. Call [initFontations] once before using any other API.
library;

import 'src/native_library.dart';
import 'src/rust/frb_generated.dart';

export 'src/color_glyph.dart';
export 'src/glyph_path.dart';
export 'src/rust/api/build.dart';
export 'src/rust/api/fontations.dart';
export 'src/rust/api/upstream.dart';
export 'src/rust/frb_generated.dart' show RustLib;

/// Loads and initializes the native Rust library. Safe to call repeatedly.
Future<void> initFontations() async {
  await RustLib.init(externalLibrary: await loadFontationsExternalLibrary());
}
