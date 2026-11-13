// Clean isolate: no setUpAll, so this covers concurrent first init.
// Needs the host Rust library.
@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fontations/fontations.dart';

void main() {
  test('concurrent startup calls share a single initialization', () async {
    await Future.wait<void>(<Future<void>>[
      initFontations(),
      initFontations(),
      initFontations(),
    ]);
    await initFontations();
    expect(fontationsVersion(), contains('skrifa'));
  });
}
