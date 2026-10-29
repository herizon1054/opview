// LINE 通知：30 秒到期、新的在前、重複合併；直向畫面第三層顯示
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/selfdrive/ui/onroad/dashboard_hud.dart';
import 'package:opview/services/line_notifications.dart';
import 'package:opview/services/viewer_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'golden/mock_ui_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('messages expire after 30 s, newest first, duplicates merged', () {
    final n = LineNotifications.instance;
    var t = DateTime(2026, 10, 30, 1, 0, 0);
    n.now = () => t;
    n.add('小明', '到了嗎');
    n.add('小明', '到了嗎'); // LINE 更新同一則通知
    expect(n.messages.length, 1);
    t = t.add(const Duration(seconds: 10));
    n.add('家人 · 媽', '回家吃飯');
    expect(n.messages.map((m) => m.text).toList(), ['回家吃飯', '到了嗎']);
    t = t.add(const Duration(seconds: 21)); // 第一則已 31 秒
    n.expire();
    expect(n.messages.map((m) => m.text).toList(), ['回家吃飯']);
    t = t.add(const Duration(seconds: 10));
    n.expire();
    expect(n.messages, isEmpty);
    n.clear();
    n.now = DateTime.now;
  });

  testWidgets('portrait: LINE box is the third layer below TDX speed and event', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() { tester.view.resetPhysicalSize(); tester.view.resetDevicePixelRatio(); });
    final settings = ViewerSettings()..setLineNotify(true);
    final state = createMockUIState()..modernOverlay = true;
    state.applyTdx({'nextSpeed': 62, 'congestion': 'smooth',
      'events': [{'description': '施工：內側車道封閉', 'isCurrentSection': false}]});
    LineNotifications.instance.add('小明', '我到停車場了，你在幾樓？等等直接上去找你');
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(),
      home: AugmentedRoadView(uiState: state, settings: settings, onExit: () {})));
    await tester.pump();
    expect(tester.takeException(), isNull);
    final card = tester.getRect(find.byType(DashboardCard));
    final speed = tester.getRect(find.text('前方車速'));
    final event = tester.getRect(find.textContaining('施工'));
    final line = tester.getRect(find.textContaining('我到停車場了'));
    expect(speed.top, greaterThan(card.bottom));
    expect(event.top, greaterThan(speed.bottom));
    expect(line.top, greaterThan(event.bottom));
    expect(line.height, greaterThanOrEqualTo(14 * 1.3 * 2 - 1)); // 至少兩行
    LineNotifications.instance.clear(); // 取消 30 秒到期計時器
    await tester.pumpWidget(const SizedBox.shrink());
    settings.dispose();
    state.dispose();
  });
}
