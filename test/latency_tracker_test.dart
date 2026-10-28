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
}
