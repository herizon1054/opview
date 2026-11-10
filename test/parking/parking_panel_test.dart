import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/onroad/portrait_panel.dart';
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
    (500.0, true, true, true, true, true), // 兩者共用：LINE 至少四行（或 40%）、停車其餘
    (300.0, true, true, true, false, true), // 停車放不下 100 → LINE 補滿
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

  testWidgets('EXP badge on the card in experimental mode; LINE gets four lines beside parking', (tester) async {
    ParkingConfig.instance.enabled = true;
    final state = UIState()..experimentalMode = true;
    LineNotifications.instance.add('小明',
        '第一行第一行第一行第一行第一行第一行第二行第二行第二行第二行第二行第二行第三行第三行第三行第三行第三行第三行第四行第四行第四行第四行');
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: Center(
      child: SizedBox(width: 390, height: 420,
        child: PortraitPanel(state: state, lineEnabled: true))))));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('EXP'), findsOneWidget);
    // EXP 在卡片範圍內（不另外佔高度）
    final card = tester.getRect(find.byType(DashboardCard));
    final exp = tester.getRect(find.text('EXP'));
    expect(card.contains(exp.topLeft) && card.contains(exp.bottomRight), isTrue);
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
