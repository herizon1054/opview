// 前車起步 / 綠燈起步 / 停等計時（移植自 sunnypilot e2e_alerts_helper.py）
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/stop_go_alerts.dart';

void main() {
  // 以 0.05 s（20 Hz，同 modelV2）推進
  ({StopGoAlerts a, UIState s, List<StopGoKind> fired, double Function(double, [void Function()?]) run}) setup(
      {bool greenLight = true, bool leadDepart = true}) {
    final a = StopGoAlerts()..configure(greenLight: greenLight, leadDepart: leadDepart, standstillTimer: true);
    final s = UIState();
    final fired = <StopGoKind>[];
    a.events.listen(fired.add);
    var t = 0.0;
    double run(double seconds, [void Function()? each]) {
      final end = t + seconds;
      while (t < end - 1e-9) {
        each?.call();
        a.update(s, nowSec: t);
        t += 0.05;
      }
      return t;
    }
    return (a: a, s: s, fired: fired, run: run);
  }

  void driveThenStop(UIState s, void Function(double) run) {
    s..standstill = false..vEgo = 5;
    run(0.5);
    s..standstill = true..vEgo = 0;
  }

  test('green light: stopped, no lead, model path opens up beyond 30 m for > 0.3 s', () async {
    final x = setup();
    x.s.pathX..clear()..addAll([0, 5, 10]); // 紅燈：路徑很短
    driveThenStop(x.s, (d) => x.run(d));
    x.run(3);                                // 停穩 > 2 s → 允許
    expect(x.a.allowed, isTrue);
    expect(x.fired, isEmpty);
    x.s.pathX..clear()..addAll([0, 20, 45]); // 轉綠：路徑延伸
    x.run(0.6);
    await Future<void>.delayed(Duration.zero);
    expect(x.fired, [StopGoKind.greenLight]);
    x.run(1);
    await Future<void>.delayed(Duration.zero);
    expect(x.fired.length, 1);               // CONSUMED：同一次停等只提醒一次
  });

  test('lead departure: stopped within 8 m behind a lead, lead pulls away > 1 m for > 0.3 s', () async {
    final x = setup(greenLight: false);
    x.s.leadOne = {'status': true, 'dRel': 4.0};
    x.s.pathX..clear()..addAll([0, 4, 8]);
    driveThenStop(x.s, (d) => x.run(d));
    x.run(3.5);                              // 停穩、前車在 8 m 內 1 s 以上 → armed
    expect(x.fired, isEmpty);
    x.s.leadOne = {'status': true, 'dRel': 5.6};
    x.run(0.6);
    await Future<void>.delayed(Duration.zero);
    expect(x.fired, [StopGoKind.leadDepart]);
  });

  test('no alerts while openpilot is engaged or gas pressed', () async {
    final x = setup();
    x.s.pathX..clear()..addAll([0, 5, 10]);
    driveThenStop(x.s, (d) => x.run(d));
    x.s.enabled = true;
    x.run(3);
    x.s.pathX..clear()..addAll([0, 20, 45]);
    x.run(1);
    await Future<void>.delayed(Duration.zero);
    expect(x.fired, isEmpty);
    expect(x.a.allowed, isFalse);
  });

  test('standstill timer format', () {
    expect(formatStandstill(0), '0:00');
    expect(formatStandstill(65.9), '1:05');
    expect(formatStandstill(600), '10:00');
  });
}
