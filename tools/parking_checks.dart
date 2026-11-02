// 命令列檢查工具：輸出結果用 print。
// ignore_for_file: avoid_print

import '../test/parking/parking_core_cases.dart';

Future<void> main() async {
  for (final e in parkingCoreCases.entries) {
    await e.value();
    print('PASS ${e.key}');
  }
  print('All ${parkingCoreCases.length} parking checks passed.');
}
