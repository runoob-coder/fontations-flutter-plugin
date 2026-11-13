// Matchers shared by the native-backed suites.
library;

import 'package:flutter_test/flutter_test.dart';

/// Match the anyhow message, not the FRB exception class.
Matcher throwsFontError(String fragment) => throwsA(
  isA<Object>().having(
    (error) => error.toString(),
    'message',
    contains(fragment),
  ),
);
