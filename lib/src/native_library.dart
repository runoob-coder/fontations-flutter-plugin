// Conditional export keeps `dart:io` out of the web build.
export 'native_library_io.dart'
    if (dart.library.js_interop) 'native_library_web.dart';
