// This is the io implementation of the native library lookup.
// See lib/src/native_library.dart.
library;

import 'dart:io' as io;

import 'package:flutter_rust_bridge/flutter_rust_bridge.dart'
    show loadExternalLibrary;
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart'
    show ExternalLibrary;

import 'rust/frb_generated.dart';

/// Rust library inside a prebuilt framework, see `scripts/build_xcframework.sh`.
const String _framework = 'fontations.framework/fontations';

/// Same thing as a plain dynamic library, the shape used on macOS.
const String _dylib = 'libfontations.dylib';

/// Resolves the Rust library on Apple platforms, `null` anywhere else - there
/// flutter_rust_bridge's own lookup already does the right thing.
///
/// An Apple app can contain the Rust library in two very different shapes:
/// * SwiftPM cannot run cargo, so it links the prebuilt binary built by
///   `scripts/build_xcframework.sh` (a framework on iOS, a dylib on macOS) - it
///   has to be opened from the app bundle.
/// * CocoaPods compiles Rust from source and statically links it (see the
///   `-force_load` in the podspecs), so its symbols are part of the app binary
///   and can only be reached with `DynamicLibrary.process()`.
Future<ExternalLibrary?> loadFontationsExternalLibrary() async {
  if (!io.Platform.isIOS && !io.Platform.isMacOS) {
    return null;
  }

  // Non-packaged runs (`flutter test`, `dart run`): the dylib next to the
  // sources.
  try {
    return await loadExternalLibrary(
      RustLib.kDefaultExternalLibraryLoaderConfig,
    );
  } on Object {
    // Try the packaged locations below.
  }

  for (final String candidate in _bundleCandidates()) {
    try {
      return ExternalLibrary.open(candidate);
    } on Object {
      // Try the next location.
    }
  }

  // Statically linked Rust library, i.e. the CocoaPods integration.
  return ExternalLibrary.process(iKnowHowToUseIt: true);
}

/// Where the prebuilt Rust library can sit inside an app bundle.
List<String> _bundleCandidates() {
  final String executableDir = io.File(io.Platform.resolvedExecutable)
      .parent
      .path;
  // App.app/Contents/MacOS on macOS, App.app on iOS.
  final String frameworks = io.Platform.isMacOS
      ? '$executableDir/../Frameworks'
      : '$executableDir/Frameworks';
  return <String>[
    _framework,
    _dylib,
    '@rpath/$_framework',
    '@rpath/$_dylib',
    '$frameworks/$_framework',
    '$frameworks/$_dylib',
  ];
}
