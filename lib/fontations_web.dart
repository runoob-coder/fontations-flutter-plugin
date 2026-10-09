// The web entry point of the plugin.
//
// On every other platform `cargokit` compiles the crate into a native library
// and `dart:ffi` links it. On the web there is nothing to link: the crate is
// compiled to WebAssembly by `scripts/build_web.sh`, and the generated bindings
// reach it through `dart:js_interop`.
//
// So this class has no work to do. It exists because Flutter requires every
// plugin that declares the web platform to name an entry point, which the
// generated `web_plugin_registrant.dart` calls at start up.
library;

import 'package:flutter_web_plugins/flutter_web_plugins.dart';

/// Registers the plugin on the web.
///
/// Deliberately empty: the WebAssembly module is loaded by
/// [RustLib.init](lib/src/rust/frb_generated.dart) when the app calls
/// `initFontations()`, not by the plugin registry.
class FontationsWebPlugin {
  /// Called by the generated web plugin registrant.
  static void registerWith(Registrar registrar) {
    // No method channel, no services: nothing to register.
  }
}
