import 'package:flutter_test/flutter_test.dart';
import 'package:opview/services/latency_tracker.dart';

void main() {
  // comma 時鐘比手機時鐘晚 5 秒開機：固定差 5,000,000 µs，不應影響「額外延遲」
  const offsetUs = 5000000;

  test('excess latency is measured against the best (minimum) delay', () {
    final t = LatencyTracker();
    // 每 50 ms 一筆，網路延遲 10 ms，其中一筆延遲 110 ms（多 100 ms）
    for (var i = 0; i < 20; i++) {
      final sentUs = i * 50000;
      final delay = i == 7 ? 110000 : 10000;
      t.onMessage(sentUs * 1000, arrivalUs: sentUs + offsetUs + delay);
    }
    final w = t.takeWindow()!;
    expect(w.count, 20);
    expect(w.maxMs, closeTo(100, .01));
    expect(w.avgMs, closeTo(5, .01));       // 100 ms / 20 筆
    expect(w.p95Ms, closeTo(0, .01));
    expect(w.maxGapMs, closeTo(150, .01));  // 第 6→7 筆到達間隔 50+100
  });

  test('baseline carries over windows, so a uniformly slow window shows up', () {
    final t = LatencyTracker();
    for (var i = 0; i < 10; i++) {
      t.onMessage(i * 50000 * 1000, arrivalUs: i * 50000 + offsetUs + 10000);
    }
    expect(t.takeWindow()!.avgMs, closeTo(0, .01));
    // 下一個視窗整體慢了 80 ms
    for (var i = 10; i < 20; i++) {
      t.onMessage(i * 50000 * 1000, arrivalUs: i * 50000 + offsetUs + 90000);
    }
    final w = t.takeWindow()!;
    expect(w.avgMs, closeTo(80, .01));
    expect(w.maxMs, closeTo(80, .01));
  });

  test('empty window returns null; reset clears baseline', () {
    final t = LatencyTracker();
    expect(t.takeWindow(), isNull);
    t.onMessage(0, arrivalUs: offsetUs);
    t.takeWindow();
    t.reset();
    t.onMessage(0, arrivalUs: offsetUs + 50000);
    expect(t.takeWindow()!.maxMs, closeTo(0, .01));  // 基準已重設
  });

  test('lastExcessMs flags a growing backlog (old data arriving late)', () {
    final t = LatencyTracker();
    // 前 20 筆正常（延遲 10 ms），之後每筆多晚 100 ms：手機收到的是越來越舊的資料
    for (var i = 0; i < 40; i++) {
      final sentUs = i * 50000;
      final extra = i < 20 ? 0 : (i - 19) * 100000;
      t.onMessage(sentUs * 1000, arrivalUs: sentUs + offsetUs + 10000 + extra);
    }
    expect(t.lastExcessMs, 2000);  // 第 40 筆晚 20×100 ms
  });

  test('lastExcessMs uses the whole-session baseline, not just 60 s', () {
    final t = LatencyTracker();
    t.onMessage(0, arrivalUs: offsetUs + 10000);
    for (var w = 0; w < 10; w++) {
      t.takeWindow();                      // 經過 100 秒：統計基準已換過，連線基準只放寬 10 ms
      t.onMessage((w + 1) * 1000000000, arrivalUs: (w + 1) * 1000000 + offsetUs + 3010000);
    }
    expect(t.lastExcessMs, greaterThan(2900)); // 一直晚 3 秒，仍判定為延遲
  });
}
