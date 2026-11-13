// Pure Dart tests for the IO library resolver; no RustLib.init().
@TestOn('vm')
library;

import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:fontations/src/native_library_io.dart' as loader;

void main() {
  // --- Error log -------------------------------------------------------------

  group('fontationsLibraryLoadErrors', () {
    test('is an unmodifiable view, not the internal list', () {
      expect(
        () => loader.fontationsLibraryLoadErrors.add('oops'),
        throwsUnsupportedError,
      );
      expect(
        () => loader.fontationsLibraryLoadErrors.clear(),
        throwsUnsupportedError,
      );
    });

    test('returns a fresh snapshot on every read', () {
      final first = loader.fontationsLibraryLoadErrors;
      final second = loader.fontationsLibraryLoadErrors;
      expect(first, second);
      expect(identical(first, second), isFalse);
    });
  });

  // --- Platform branches -----------------------------------------------------

  group('loadFontationsExternalLibrary', () {
    test('resolves on Apple platforms and defers to FRB elsewhere', () async {
      final library = await loader.loadFontationsExternalLibrary();
      if (Platform.isIOS || Platform.isMacOS) {
        expect(library, isNotNull);
      } else {
        // Non-Apple: FRB's own lookup.
        expect(library, isNull);
      }
    });

    test('can be called repeatedly without throwing', () async {
      await expectLater(loader.loadFontationsExternalLibrary(), completes);
      await expectLater(loader.loadFontationsExternalLibrary(), completes);
    });

    test('exposes a readable diagnostic list after a lookup', () {
      final errors = loader.fontationsLibraryLoadErrors;
      expect(errors, isA<List<Object>>());
      expect(() => errors.add('oops'), throwsUnsupportedError);
    });
  });
}
