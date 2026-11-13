library;

import 'dart:io' as io;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart'
    show loadExternalLibrary;
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart'
    show ExternalLibrary;

import 'rust/frb_generated.dart';

/// Rust library inside a prebuilt framework.
const String _framework = 'fontations.framework/fontations';

/// Rust library as a plain dynamic library (macOS).
const String _dylib = 'libfontations.dylib';

final List<Object> _libraryLoadErrors = <Object>[];

/// Failures from the last library lookup, for diagnosing a missing library.
List<Object> get fontationsLibraryLoadErrors =>
    List<Object>.unmodifiable(_libraryLoadErrors);

/// Resolves the Rust library on Apple platforms; `null` elsewhere, where
/// flutter_rust_bridge's own lookup applies.
Future<ExternalLibrary?> loadFontationsExternalLibrary() async {
  if (!io.Platform.isIOS && !io.Platform.isMacOS) {
    return null;
  }
  _libraryLoadErrors.clear();

  // Unpackaged runs: the dylib next to the sources.
  try {
    return await loadExternalLibrary(
      RustLib.kDefaultExternalLibraryLoaderConfig,
    );
  } on Object catch (error) {
    _libraryLoadErrors.add(error);
  }

  for (final String candidate in _bundleCandidates()) {
    try {
      return ExternalLibrary.open(candidate);
    } on Object catch (error) {
      _libraryLoadErrors.add(error);
    }
  }

  // Statically linked Rust library, i.e. the CocoaPods integration.
  if (_libraryLoadErrors.isNotEmpty) {
    debugPrint(
      'fontations: falling back to the statically linked Rust library after '
      '${_libraryLoadErrors.length} failed dynamic load(s). First failure: '
      '${_libraryLoadErrors.first}',
    );
  }
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
