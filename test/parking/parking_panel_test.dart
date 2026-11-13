import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/onroad/portrait_panel.dart';
import 'package:opview/selfdrive/ui/onroad/parking_panel.dart';
import 'package:opview/selfdrive/ui/onroad/dashboard_hud.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/parking/parking_config.dart';
import 'package:opview/services/line_notifications.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => null,
        );
  });
  // (高度, LINE 開關, LINE 有訊息, 停車查詢開啟, 應顯示停車面板, 應顯示 LINE)
  // v21：LINE 與停車共用剩餘高度，任一方沒有內容時另一方補滿；上方徽章列移除、卡片變矮
  for (final (height, line, msg, parkingOn, showParking, showLine) in [
    (160.0, false, false, true, false, false),
    (300.0, false, false, true, true, false),
    (500.0, false, false, true, true, false),
    (160.0, true, false, true, false, false), // 卡片以 LINE 兩行預留計算後，停車放不下 100
    (500.0, true, false, true, true, false),
    (500.0, true, false, false, false, false), // 開 LINE、停車關閉 → 不顯示停車面板
    (500.0, true, true, true, true, true), // 兩者共用：停車沒查詢 → 精簡版 90，LINE 拿其餘
    (300.0, true, true, true, true, true), // 精簡版停車 90 + LINE 約 94（兩行以上）
    (500.0, true, true, false, false, true), // 停車關閉 → LINE 補滿
  ]) {
    testWidgets('portrait panel $height (LINE $line msg $msg, parking $parkingOn) fits and disposes timer', (
      tester,
    ) async {
      ParkingConfig.instance.enabled = parkingOn;
      addTearDown(() => ParkingConfig.instance.enabled = true);
      if (msg) LineNotifications.instance.add('小明', '到了嗎');
      addTearDown(LineNotifications.instance.clear);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 390,
                height: height,
                child: PortraitPanel(
                  state: UIState(),
                  stale: true,
                  lineEnabled: line,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('請先設定 TDX 金鑰'), showParking ? findsWidgets : findsNothing);
      expect(find.textContaining('到了嗎'), showLine ? findsOneWidget : findsNothing);
      // 上方徽章列已移除
      expect(find.text('opview'), findsNothing);
      expect(find.text('資料中斷'), findsNothing);
      LineNotifications.instance.clear(); // 取消 30 秒到期計時器
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 16));
      expect(tester.takeException(), isNull);
    });
  }

  test('splitRest: idle parking shrinks to the compact bar; active parking leaves LINE two lines', () {
    const idle = ParkingPanel.idleHeight, two = PortraitPanel.lineMinH;
    (double, double) split(double rest, {bool line = true, bool msg = true, bool on = true, bool active = false}) =>
        PortraitPanel.splitRest(rest, lineEnabled: line, hasMessages: msg, parkingOn: on, parkingActive: active);
    // LINE 沒訊息：停車全拿（LINE 開著但停車關閉 → 都不顯示）
    expect(split(300, msg: false), (0.0, 300.0));
    expect(split(300, msg: false, on: false), (0.0, 0.0));
    expect(split(300, line: false, msg: false), (0.0, 300.0));
    // LINE 有訊息、停車關閉：LINE 全拿
    expect(split(300, on: false), (300.0, 0.0));
    // 沒查詢：停車精簡版，LINE 拿其餘
    expect(split(300), (300 - idle - 8, idle));
    // 精簡版放不下時只顯示 LINE
    expect(split(idle + 8 + two - 1), (idle + 8 + two - 1, 0.0));
    // 查詢中 / 有結果：LINE 只留兩行，停車拿其餘
    expect(split(300, active: true), (two, 300 - two - 8));
    // 停車放不下 100 時 LINE 讓出
    expect(split(two + 8 + 99, active: true), (0.0, two + 8 + 99));
  });

  testWidgets('idle parking panel compact bar (90) fits without overflow', (tester) async {
    ParkingConfig.instance.enabled = true;
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: Center(
      child: SizedBox(width: 358, height: ParkingPanel.idleHeight,
        child: ParkingPanel(state: UIState(), stale: true))))));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('請先設定 TDX 金鑰'), findsWidgets);
    expect(ParkingPanel.active.value, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 16));
  });

  // 2026-11-12 版面統一：卡片角落的 EXP 拿掉（實驗模式看道路畫面上的圖示），卡片內不再有 EXP
  testWidgets('no EXP on the card in experimental mode; LINE gets four lines beside parking', (tester) async {
    ParkingConfig.instance.enabled = true;
    final state = UIState()..experimentalMode = true;
    LineNotifications.instance.add('小明',
        '第一行第一行第一行第一行第一行第一行第二行第二行第二行第二行第二行第二行第三行第三行第三行第三行第三行第三行第四行第四行第四行第四行');
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: Center(
      child: SizedBox(width: 390, height: 420,
        child: PortraitPanel(state: state, lineEnabled: true))))));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('EXP'), findsNothing);
    expect(find.byType(DashboardCard), findsOneWidget);
    // LINE：至少四行（字級 14 × 1.3、行高 1.3）
    final line = tester.getRect(find.textContaining('第一行'));
    expect(line.height, greaterThanOrEqualTo(14 * 1.3 * 1.3 * 4 - 1));
    expect(find.textContaining('請先設定 TDX 金鑰'), findsWidgets); // 停車面板仍在
    LineNotifications.instance.clear();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 16));
    state.dispose();
  });

  testWidgets('no HUD card: card space goes to LINE and parking', (tester) async {
    ParkingConfig.instance.enabled = true;
    final state = UIState()..hideHudCard = true;
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: Center(
      child: SizedBox(width: 390, height: 160,
        child: PortraitPanel(state: state, stale: true))))));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(DashboardCard), findsNothing);
    // 有卡片時 160 高放不下停車面板（見上方矩陣）；無卡片時停車面板補滿
    expect(find.textContaining('請先設定 TDX 金鑰'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 16));
    state.dispose();
  });
}
