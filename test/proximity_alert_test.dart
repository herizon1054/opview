// 近距離低信心目標警示：條件判斷與觸發狀態機
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/services/proximity_alert.dart';

// 預設：30 km/h、目標車頭距離 1.48 m（x 3.0）、機率 0.3、在路徑上 → 成立
ProximityInput _in({double kph = 30, double? x = 3.0, double? y = 0.1, double? prob = 0.3,
    double pathY = 0}) => ProximityInput(
  vEgo: kph / 3.6, leadX: x, leadY: y, leadProb: prob,
  pathX: const [0, 10, 20, 40], pathY: [pathY, pathY, pathY, pathY]);

void main() {
  test('speed 20–60 km/h', () {
    expect(proximityCheck(_in())!.dRel, closeTo(1.48, 1e-9));
    expect(proximityCheck(_in(kph: 19.9)), isNull);
    expect(proximityCheck(_in(kph: 20.0)), isNotNull);
    expect(proximityCheck(_in(kph: 20.1)), isNotNull);
    expect(proximityCheck(_in(kph: 49.9)), isNotNull);
    expect(proximityCheck(_in(kph: 59.9)), isNotNull);
    expect(proximityCheck(_in(kph: 60.1)), isNull);
  });

  test('confidence band 0.2 ≤ prob < 0.5 (≥ 0.5 is already a lead for openpilot)', () {
    expect(proximityCheck(_in(prob: 0.199)), isNull);
    expect(proximityCheck(_in(prob: 0.2)), isNotNull);
    expect(proximityCheck(_in(prob: 0.21)), isNotNull);
    expect(proximityCheck(_in(prob: 0.49)), isNotNull);
    expect(proximityCheck(_in(prob: 0.5)), isNull);
    expect(proximityCheck(_in(prob: 0.95)), isNull);
    expect(proximityCheck(_in(x: null)), isNull); // comma 端沒送 leadsV3
  });

  test('distance threshold: 20 km/h 2 m → 60 km/h 3 m, linear', () {
    expect(proximityMaxDist(20), closeTo(2.0, 1e-9));
    expect(proximityMaxDist(40), closeTo(2.5, 1e-9));
    expect(proximityMaxDist(60), closeTo(3.0, 1e-9));
    // 20 km/h：1.98 m 成立、2.01 m 不成立
    expect(proximityCheck(_in(kph: 20.0, x: 3.5)), isNotNull);
    expect(proximityCheck(_in(kph: 20.0, x: 3.53)), isNull);
    // 40 km/h（門檻 2.5 m）：2.45 成立、2.55 不成立
    expect(proximityCheck(_in(kph: 40, x: 2.45 + 1.52)), isNotNull);
    expect(proximityCheck(_in(kph: 40, x: 2.55 + 1.52)), isNull);
    // 59.9 km/h（門檻約 3.0 m）：2.95 成立、3.05 不成立
    expect(proximityCheck(_in(kph: 59.9, x: 2.95 + 1.52)), isNotNull);
    expect(proximityCheck(_in(kph: 59.9, x: 3.05 + 1.52)), isNull);
  });

  test('lateral: model path ±0.9 m', () {
    expect(proximityCheck(_in(y: 0.89)), isNotNull);
    expect(proximityCheck(_in(y: -0.89)), isNotNull);
    expect(proximityCheck(_in(y: 0.95)), isNull);
    expect(proximityCheck(_in(y: 1.9, pathY: 1.2)), isNotNull);
  });

  ({ProximityAlert a, List<ProximityTarget> fired, void Function(double, ProximityInput Function(int)) run}) setup() {
    final a = ProximityAlert()..configure(enabled: true);
    final fired = <ProximityTarget>[];
    a.events.listen(fired.add);
    var t = 0.0;
    var i = 0;
    void run(double sec, ProximityInput Function(int) m) {
      final end = t + sec;
      while (t < end - 1e-9) { a.update(m(i++), nowSec: t); t += 0.05; }
    }
    return (a: a, fired: fired, run: run);
  }

  test('5 consecutive frames → beep; no second beep within 30 s', () {
    final x = setup();
    x.run(0.2, (_) => _in()); // 4 幀
    expect(x.fired, isEmpty);
    x.run(0.05, (_) => _in()); // 第 5 幀
    expect(x.fired.length, 1);
    expect(x.a.activeAt(0.25), isNotNull);
    x.run(2, (_) => _in());
    expect(x.fired.length, 1); // 持續中不重複嗶
    x.run(2, (_) => _in(prob: 0.1)); // 解除後再出現（20 秒內）→ 箭頭會顯示但不嗶
    x.run(0.3, (_) => _in());
    expect(x.fired.length, 1);
    expect(x.a.activeAt(4.5), isNotNull);
    x.run(26, (_) => _in(prob: 0.1)); // 距第一次嗶超過 30 秒
    x.run(0.3, (_) => _in());
    expect(x.fired.length, 2);
  });

  test('a gap resets the count', () {
    final x = setup();
    for (var k = 0; k < 10; k++) {
      x.run(0.2, (_) => _in()); // 4 幀
      x.run(0.05, (_) => _in(prob: 0.1)); // 中斷 1 幀
    }
    expect(x.fired, isEmpty);
  });

  test('model ghost: lateral jumping never fires', () {
    // rlog 012 / 016：失去前車時機率 0.2–0.3、位置左右亂跳、距離忽遠忽近
    final x = setup();
    x.run(3, (i) => _in(y: i.isEven ? -0.7 : 0.7));
    expect(x.fired, isEmpty);
    x.run(3, (i) => _in(x: i.isEven ? 1.6 : 3.5)); // 車頭 0.08 / 1.98 m，距離每幀跳 1.9 m 以內 → 仍算穩定
    expect(x.fired.length, 1);
  });

  test('approaching car stays stable → fires', () {
    final x = setup();
    x.run(1, (i) => _in(x: 3.5 - i * 0.05, y: 0.1 + i * 0.01)); // 每幀接近 5 cm、橫向緩慢漂移
    expect(x.fired.length, 1);
  });

  test('disabled: never fires', () {
    final a = ProximityAlert();
    final fired = <ProximityTarget>[];
    a.events.listen(fired.add);
    for (var t = 0.0; t < 1; t += .05) { a.update(_in(), nowSec: t); }
    expect(fired, isEmpty);
  });
}
