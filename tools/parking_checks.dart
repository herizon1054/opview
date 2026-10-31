import '../test/parking/parking_core_cases.dart';

Future<void> main() async {
  for (final e in parkingCoreCases.entries) {
    await e.value();
    print('PASS ${e.key}');
  }
  print('All ${parkingCoreCases.length} parking checks passed.');
}
