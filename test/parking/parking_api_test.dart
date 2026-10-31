import 'package:flutter_test/flutter_test.dart';

import 'parking_core_cases.dart';

void main() {
  for (final e in parkingCoreCases.entries) {
    test(e.key, e.value);
  }
}
