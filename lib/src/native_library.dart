// The native library lookup has an io and a web implementation; this file only
// picks one so that `dart:io` is never imported on the web.
export 'native_library_io.dart'
    if (dart.library.js_interop) 'native_library_web.dart';
