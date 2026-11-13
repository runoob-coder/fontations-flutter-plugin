library;

import 'package:flutter_web_plugins/flutter_web_plugins.dart';

/// Web entry point required by the plugin registry; the wasm module is loaded
/// by `RustLib.init` instead.
class FontationsWebPlugin {
  static void registerWith(Registrar registrar) {}
}
