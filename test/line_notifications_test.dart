// LINE 通知：30 秒到期、新的在前、重複合併；直向畫面第三層顯示
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/selfdrive/ui/onroad/dashboard_hud.dart';
import 'package:opview/services/line_notifications.dart';
import 'package:opview/services/parking/parking_config.dart';
import 'package:opview/selfdrive/ui/onroad/portrait_panel.dart';
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

  test('group sender label does not repeat the group name', () {
    expect(lineSenderLabel('Sp修改項目: 林秉麻', 'Sp修改項目'), 'Sp修改項目 · 林秉麻');
    expect(lineSenderLabel('Sp修改項目：林秉麻', 'Sp修改項目'), 'Sp修改項目 · 林秉麻');
    expect(lineSenderLabel('林秉麻', 'Sp修改項目'), 'Sp修改項目 · 林秉麻');
    expect(lineSenderLabel('帥哥宗1779', null), '帥哥宗1779');
    expect(lineSenderLabel('帥哥宗1779', '帥哥宗1779'), '帥哥宗1779');
  });

  // 2026-11-12 版面統一：事件改疊在道路畫面上方，下方依序是 卡片 → 路況卡 → LINE
  // 2026-11-13：直向 TDX 事件收進路況卡（前方車速下一行）
  testWidgets('portrait: LINE box below the route card; event inside the route card', (tester) async {
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
    final videoH = 390 * 1208 / 1928;
    expect(speed.top, greaterThan(card.bottom));
    expect(line.top, greaterThan(speed.bottom));
    expect(event.top, greaterThan(speed.bottom - 1)); // 事件在路況卡裡、前方車速下面
    expect(line.top, greaterThan(event.bottom));
    expect(event.top, greaterThan(videoH));
    // v20：字級 14 × 1.3；空間足夠時這則（約 3 行）完整顯示，不截斷
    expect(line.height, greaterThanOrEqualTo(14 * 1.3 * 1.3 * 2 - 1));
    final t = tester.widget<Text>(find.textContaining('我到停車場了'));
    expect(t.style!.fontSize, closeTo(14 * 1.3, .01));
    LineNotifications.instance.clear(); // 取消 30 秒到期計時器
    await tester.pumpWidget(const SizedBox.shrink());
    settings.dispose();
    state.dispose();
  });

  testWidgets('LINE tag keeps a gap below the HUD card', (tester) async {
    ParkingConfig.instance.enabled = false;
    addTearDown(() => ParkingConfig.instance.enabled = true);
    addTearDown(LineNotifications.instance.clear); // 失敗時也清掉，不影響下一個測試
    LineNotifications.instance.add('小明', '到了嗎');
    LineNotifications.instance.add('小華', '快到了');
    // 模擬狀態預設是原版介面（modernOverlay = false）→ 沒有儀表卡片
    final state = createMockUIState()..modernOverlay = true..isConnected = false;
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: Align(
      alignment: Alignment.topCenter,
      child: SizedBox(width: 390, height: 400, child: PortraitPanel(state: state, lineEnabled: true))))));
    await tester.pump();
    expect(tester.takeException(), isNull);
    final card = tester.getRect(find.byType(DashboardCard));
    final tag = tester.getRect(find.text('LINE · 2 則'));
    expect(tag.top - card.bottom, greaterThanOrEqualTo(5)); // 標籤與卡片之間留空隙（原本 0）
    LineNotifications.instance.clear();
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('message gaps cost pixels, not whole lines: three 2-line messages all fit', (tester) async {
    // 無卡片、停車關閉 → LINE 拿下方全部；高度剛好放得下 2 + 2 + 2 行與兩個 6 px 間距
    // （原本每個間距算成一整行，第三則會被截掉、底下空兩行）
    ParkingConfig.instance.enabled = false;
    addTearDown(() => ParkingConfig.instance.enabled = true);
    final n = LineNotifications.instance;
    addTearDown(n.clear);
    final body = '一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十'; // 30 字 + 寄件者 2 字 = 兩行
    n.add('甲', '第一則$body');
    n.add('乙', '第二則$body');
    n.add('丙', '第三則$body');
    const rowH = PortraitPanel.lineFont * PortraitPanel.lineHeight;
    const boxH = PortraitPanel.lineChrome + 6 * rowH + 2 * PortraitPanel.lineMsgGap;
    final state = createMockUIState()..hideHudCard = true..isConnected = false;
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: Align(
      alignment: Alignment.topCenter,
      child: SizedBox(width: 390, height: PortraitPanel.topPad + 8 + PortraitPanel.lineTagSpace + boxH + 8 + 1,
        child: PortraitPanel(state: state, lineEnabled: true))))));
    await tester.pump();
    expect(tester.takeException(), isNull);
    for (final t in ['第一則', '第二則', '第三則']) {
      expect(tester.getRect(find.textContaining(t)).height, greaterThanOrEqualTo(2 * rowH - 1), reason: t);
    }
    n.clear();
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
}
