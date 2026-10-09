// This is the web implementation of the native library lookup.
// See lib/src/native_library.dart.
library;

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_web.dart'
    show ExternalLibrary;

/// Nothing to do: on the web the wasm module is loaded by the generated code.
Future<ExternalLibrary?> loadFontationsExternalLibrary() async => null;
