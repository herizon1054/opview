import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';

void main() {
  test('dragonpilot 的 status 與 sunnypilot 的 present 都視為有前車', () {
    expect(leadPresent({'status': true, 'dRel': 20}), isTrue);
    expect(leadPresent({'present': true, 'dRel': 20}), isTrue);
    expect(leadPresent({'status': false}), isFalse);
    expect(leadPresent({'present': false}), isFalse);
    expect(leadPresent(null), isFalse);
  });

  test('sunnypilot（present）也能取得前車距離', () {
    final s = UIState();
    s.applyRadarState({'leadOne': {'present': true, 'dRel': 40}});
    expect(s.leadDistance, 40);
    s.dispose();
  });

  test('leadTwo 與 leadOne 同一台時不算不同目標', () {
    final one = {'status': true, 'dRel': 20.0, 'yRel': 0.2};
    expect(leadTwoSeparate(one, {'status': true, 'dRel': 21.5, 'yRel': 0.5}), isFalse);
    expect(leadTwoSeparate(one, {'status': true, 'dRel': 35.0, 'yRel': 0.3}), isTrue);  // 更前面一台
    expect(leadTwoSeparate(one, {'status': true, 'dRel': 20.5, 'yRel': 3.4}), isTrue);  // 隔壁車道
    expect(leadTwoSeparate(one, {'status': false, 'dRel': 35.0, 'yRel': 0.3}), isFalse);
  });
}
