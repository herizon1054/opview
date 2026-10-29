// 直向 / 橫向排版：opview 畫面（直向操作列在下方）與主畫面（直向按鈕 2×2）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/home/home_page.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/selfdrive/ui/onroad/dashboard_hud.dart';
import 'package:opview/selfdrive/ui/onroad/portrait_panel.dart';
import 'package:opview/services/viewer_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'golden/mock_ui_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  void setSize(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(() { tester.view.resetPhysicalSize(); tester.view.resetDevicePixelRatio(); });
  }

  testWidgets('opview portrait: controls move to a bottom bar, nothing overflows', (tester) async {
    setSize(tester, const Size(390, 844));
    final settings = ViewerSettings();
    final state = createMockUIState(experimentalMode: true)..modernOverlay = true
      ..leftBlinker = true..rightBlinker = true;
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(),
      home: AugmentedRoadView(uiState: state, settings: settings, onExit: () {})));
    await tester.pump();
    expect(tester.takeException(), isNull);

    // 操作列在畫面下方、全部在畫面內
    for (final label in ['儀表介面', 'km/h', '顯示設定', '全螢幕', '退出']) {
      final r = tester.getRect(find.text(label));
      expect(r.top, greaterThan(844 * .8), reason: '$label 應在下方操作列');
      expect(r.bottom, lessThanOrEqualTo(844), reason: label);
      expect(r.left, greaterThanOrEqualTo(0), reason: label);
      expect(r.right, lessThanOrEqualTo(390), reason: label);
    }

    // 方案 B：影像依相機比例（1928×1208）完整顯示在上方，儀表卡片在影像下方、不蓋影像
    expect(find.byType(DashboardHud), findsNothing);
    expect(find.byType(PortraitPanel), findsOneWidget);
    final videoH = 390 * 1208 / 1928;
    final panel = tester.getRect(find.byType(PortraitPanel));
    expect(panel.top, closeTo(videoH, 1));
    final card = tester.getRect(find.textContaining('TELEMETRY').first);
    expect(card.top, greaterThan(videoH));
    expect(card.center.dx, closeTo(195, 30));
    final cardRect = tester.getRect(find.byType(DashboardCard));
    expect(cardRect.width, greaterThan(390 * .6));
    // 方向燈在儀表卡片左右兩側（與橫向相同），不在影像上
    final arrows = find.byType(BlinkerArrow);
    expect(arrows, findsNWidgets(2));
    final rects = arrows.evaluate().map((e) => tester.getRect(find.byWidget(e.widget))).toList()
      ..sort((a, b) => a.left.compareTo(b.left));
    expect(rects[0].right, lessThanOrEqualTo(cardRect.left + 1));
    expect(rects[1].left, greaterThanOrEqualTo(cardRect.right - 1));
    for (final r in rects) {
      expect(r.top, greaterThan(videoH));
      expect(r.center.dy, closeTo(cardRect.center.dy, 2));
      expect(r.left, greaterThanOrEqualTo(0));
      expect(r.right, lessThanOrEqualTo(390));
    }

    // 全螢幕：操作列收起、右上角出現叫回按鈕
    await tester.tap(find.text('全螢幕'));
    await tester.pump();
    expect(find.text('退出'), findsNothing);
    expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    settings.dispose();
    state.dispose();
  });

  testWidgets('opview portrait: TDX row and event in the panel, alert at panel bottom', (tester) async {
    setSize(tester, const Size(390, 844));
    final state = createMockUIState()..modernOverlay = true;
    state.applyTdx({'nextSpeed': 62, 'congestion': 'smooth',
      'events': [{'description': '施工：內側車道封閉', 'isCurrentSection': false}]});
    state.alertSize = 1; state.alertStatus = 1; state.alertText1 = '請握住方向盤';
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(),
      home: AugmentedRoadView(uiState: state, onExit: () {})));
    await tester.pump();
    expect(tester.takeException(), isNull);
    final videoH = 390 * 1208 / 1928;
    expect(tester.getRect(find.text('前方車速')).top, greaterThan(videoH));
    expect(find.text('TDX 順暢'), findsOneWidget);
    expect(tester.getRect(find.textContaining('施工').first).top, greaterThan(videoH));
    final alert = tester.getRect(find.text('請握住方向盤'));
    expect(alert.top, greaterThan(tester.getRect(find.text('前方車速')).bottom));
    expect(alert.bottom, lessThan(844 - 64));   // 在操作列上方
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('opview landscape keeps the left rail', (tester) async {
    setSize(tester, const Size(844, 390));
    final state = createMockUIState()..modernOverlay = true;
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(),
      home: AugmentedRoadView(uiState: state, onExit: () {})));
    await tester.pump();
    final exit = tester.getRect(find.text('退出'));
    expect(exit.left, lessThan(100)); // 左側側欄
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('home portrait: buttons in a 2x2 grid, model dropdowns stacked', (tester) async {
    setSize(tester, const Size(390, 844));
    final settings = ViewerSettings();
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: HomePage(
      settings: settings, hostGetter: () => null, onEnterOpview: () {})));
    await tester.pump();
    expect(tester.takeException(), isNull);
    final a = tester.getRect(find.text('進入 opview'));
    final b = tester.getRect(find.text('顯示設定'));
    final c = tester.getRect(find.text('裝置設定'));
    final d = tester.getRect(find.text('離開程式'));
    expect(a.center.dy, closeTo(b.center.dy, 1));   // 第一排
    expect(c.center.dy, closeTo(d.center.dy, 1));   // 第二排
    expect(c.center.dy, greaterThan(a.center.dy + 40));
    expect(a.center.dx, closeTo(c.center.dx, 1));   // 同一欄
    // 品牌 / 車型下拉上下排
    final brand = tester.getRect(find.text('品牌'));
    final model = tester.getRect(find.textContaining('自動偵測（不指定車型）'));
    expect(model.top, greaterThan(brand.bottom));
    await tester.pumpWidget(const SizedBox.shrink());
    settings.dispose();
  });
}
