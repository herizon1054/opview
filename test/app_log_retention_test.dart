// opview log 只保留最近 3 天
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/services/app_log.dart';

void main() {
  test('pruneLogLines drops lines older than cutoff, untimestamped lines follow the previous line', () {
    final lines = [
      'codec c2.qti.avc.decoder [hw]',                     // 檔頭沒有時間戳：跟著第一個有時間戳的行（舊 → 刪）
      '2026-10-26 23:59:59.000 [opview] old',
      'Server got itself in trouble',                       // 舊行的續行 → 刪
      '',
      '========== opview start 2026-10-27 10:00:00.000 ==========',
      'app 0.1.1 (1) · Xiaomi',                             // 新 start 的續行 → 留
      'prev exit 2026-10-27 09:00:00.000 CRASH_NATIVE',     // 不是行首時間戳 → 跟著 start 行 → 留
      '2026-10-30 12:00:00.000 [opview] new',
    ];
    final kept = pruneLogLines(lines, DateTime(2026, 10, 27));
    expect(kept, [
      '========== opview start 2026-10-27 10:00:00.000 ==========',
      'app 0.1.1 (1) · Xiaomi',
      'prev exit 2026-10-27 09:00:00.000 CRASH_NATIVE',
      '2026-10-30 12:00:00.000 [opview] new',
    ]);
    expect(logRetention, const Duration(days: 3));
  });

  test('leading untimestamped lines are kept when the first timestamped line is recent', () {
    final kept = pruneLogLines(['codec x', '2026-10-30 08:00:00.000 [opview] a'], DateTime(2026, 10, 27));
    expect(kept, ['codec x', '2026-10-30 08:00:00.000 [opview] a']);
  });
}
