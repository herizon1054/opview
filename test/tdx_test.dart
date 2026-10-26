import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/selfdrive/ui/onroad/tdx_marquee.dart';
import 'package:opview/selfdrive/ui/onroad/blindspot_glow.dart';
import 'package:opview/selfdrive/ui/onroad/alert_renderer.dart';
import 'package:opview/services/impl/cereal_adapter.dart';
import 'package:opview/services/viewer_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'golden/mock_ui_state.dart';

// webrtcd 送出的 tdx JSON（pycapnp to_dict：enum 為名稱字串）
Map<String, dynamic> _tdx({int nextSpeed = 62, String congestion = 'slow',
    List<Map<String, dynamic>> events = const []}) => {
  'sectionId': '0001', 'speed': 85, 'nextSectionId': '0002',
  'nextSpeed': nextSpeed, 'congestion': congestion, 'events': events,
};

void main() {
  // ViewerSettings.load() 會走 MethodChannel（亮度），需要 binding
  TestWidgetsFlutterBinding.ensureInitialized();

  test('applyTdx: speed range, units, event text (same format as tici)', () {
    final s = UIState();
    expect(s.tdxNextSpeedKph, isNull);
    expect(s.tdxEventText, '');

    s.applyTdx(_tdx(events: [
      {'eventType': 1, 'description': '施工 外側車道', 'isCurrentSection': false},
      {'eventType': 2, 'description': '車禍', 'isCurrentSection': false},
    ]));
    expect(s.tdxNextSpeedKph, 62);
    expect(s.tdxNextSpeedDisplay, 62);
    expect(s.tdxCongestion, 'slow');
    expect(s.tdxEventText, '前方: 施工 外側車道 / 車禍');

    s.isMetric = false;
    expect(s.tdxNextSpeedDisplay, (62 * kmToMile).round());

    // tici: 只有 0 < v <= 150 才顯示
    for (final v in [-1, 0, 151]) {
      s.applyTdx(_tdx(nextSpeed: v));
      expect(s.tdxNextSpeedKph, isNull, reason: '$v');
    }

    s.applyTdx(_tdx(events: [{'description': '落石', 'isCurrentSection': true}]));
    expect(s.tdxEventText, '目前: 落石');

    // 超過 SubMaster alive 時間（1Hz → 10s）視為過期
    s.lastTdxAt = DateTime.now().subtract(const Duration(seconds: 11));
    expect(s.tdxNextSpeedKph, isNull);
    expect(s.tdxEventText, '');

    s.applyTdx(_tdx());
    s.resetTdx();
    expect(s.tdxNextSpeedKph, isNull);
    s.dispose();
  });

  test('cereal adapter dispatches tdx', () {
    final s = UIState();
    CerealAdapter().apply(s, '{"type":"tdx","logMonoTime":1,"valid":true,'
        '"data":{"nextSpeed":45,"congestion":"congested","events":[]}}');
    expect(s.tdxNextSpeedKph, 45);
    expect(s.tdxCongestion, 'congested');
    s.dispose();
  });

  testWidgets('dashboard: car icon becomes 前方車速 when TDX speed present; marquee on top', (tester) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(() { tester.view.resetPhysicalSize(); tester.view.resetDevicePixelRatio(); });
    final state = createMockUIState()..modernOverlay = true;
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(),
      home: AugmentedRoadView(uiState: state)));
    expect(find.byIcon(Icons.directions_car_outlined), findsOneWidget);
    expect(find.text('前方車速'), findsNothing);
    expect(find.byType(TdxMarquee), findsNothing);

    state.applyTdx(_tdx(nextSpeed: 62, events: [
      {'description': '國道1號 北向 25K 施工 封閉內側車道 請減速慢行 注意前方車流', 'isCurrentSection': false},
    ]));
    state.notifyNow();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byIcon(Icons.directions_car_outlined), findsNothing);
    expect(find.text('前方車速'), findsOneWidget);
    expect(find.text('62'), findsOneWidget);
    expect(find.byType(TdxMarquee), findsOneWidget);
    // 跑馬燈在畫面上半部
    expect(tester.getRect(find.byType(TdxMarquee)).top, lessThan(60));
    expect(tester.takeException(), isNull);

    // 側欄 TDX 開關：關閉 → 前方車速與跑馬燈都隱藏、小車回來；再開 → 恢復
    await tester.ensureVisible(find.text('TDX 開'));
    await tester.tap(find.text('TDX 開'));
    await tester.pump();
    expect(state.tdxEnabled, isFalse);
    expect(find.text('TDX 關'), findsOneWidget);
    expect(find.text('前方車速'), findsNothing);
    expect(find.byType(TdxMarquee), findsNothing);
    expect(find.byIcon(Icons.directions_car_outlined), findsOneWidget);
    await tester.tap(find.text('TDX 關'));
    await tester.pump();
    expect(find.text('前方車速'), findsOneWidget);
    expect(find.byType(TdxMarquee), findsOneWidget);

    // 斷線 → 清掉
    state.resetTdx();
    state.notifyNow();
    await tester.pump();
    expect(find.text('前方車速'), findsNothing);
    expect(find.byType(TdxMarquee), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  test('TDX toggle persists in ViewerSettings (default on)', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = ViewerSettings();
    await settings.load();
    expect(settings.tdx, isTrue);
    settings.setTdx(false);
    final restored = ViewerSettings();
    await restored.load();
    expect(restored.tdx, isFalse);
    settings.dispose();
    restored.dispose();
  });

  testWidgets('short event: compact centered pill, small font', (tester) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(() { tester.view.resetPhysicalSize(); tester.view.resetDevicePixelRatio(); });
    final state = createMockUIState()..modernOverlay = true;
    state.applyTdx(_tdx(events: [{'description': '施工', 'isCurrentSection': true}]));
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(),
      home: AugmentedRoadView(uiState: state)));
    await tester.pump();
    final text = tester.widget<Text>(find.text('目前: 施工'));
    expect(text.style!.fontSize, closeTo(12.5 * 1.15, .1));
    // 膠囊寬度貼合文字，不是整條橫幅；且水平置中於右側畫面
    final pill = tester.getRect(find.descendant(of: find.byType(TdxMarquee),
        matching: find.byType(Container)).first);
    expect(pill.width, lessThan(200));
    final view = tester.getRect(find.byType(TdxMarquee));
    expect((pill.center.dx - view.center.dx).abs(), lessThan(2));
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('blinker arrows beside the dashboard card', (tester) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(() { tester.view.resetPhysicalSize(); tester.view.resetDevicePixelRatio(); });
    final state = createMockUIState()..modernOverlay = true;
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(),
      home: AugmentedRoadView(uiState: state)));
    expect(find.byIcon(Icons.keyboard_double_arrow_left_rounded), findsNothing);
    expect(find.byIcon(Icons.keyboard_double_arrow_right_rounded), findsNothing);
    state.leftBlinker = true;
    state.notifyNow();
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(),
      home: AugmentedRoadView(uiState: state)));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byIcon(Icons.keyboard_double_arrow_left_rounded), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_double_arrow_right_rounded), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('blindspot: edge glow per side, fast blink when same-side blinker on', (tester) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(() { tester.view.resetPhysicalSize(); tester.view.resetDevicePixelRatio(); });
    final state = createMockUIState()..modernOverlay = true;
    Future<void> show() async {
      await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(),
        home: AugmentedRoadView(uiState: state)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await show();
    expect(find.byType(BlindspotGlow), findsNothing);

    state.rightBlindspot = true;
    await show();
    final glow = tester.widget<BlindspotGlow>(find.byType(BlindspotGlow));
    expect(glow.left, isFalse);
    expect(glow.fastBlink, isFalse);
    // 光暈貼右邊緣、只佔窄窄一段（不是整片）
    final r = tester.getRect(find.byType(BlindspotGlow));
    expect(r.right, closeTo(844, 4));
    expect(r.width, lessThan(844 * .12));

    state.rightBlinker = true;
    await show();
    expect(tester.widget<BlindspotGlow>(find.byType(BlindspotGlow)).fastBlink, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('events.py small alert stays stock bottom banner; TDX stays on top', (tester) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(() { tester.view.resetPhysicalSize(); tester.view.resetDevicePixelRatio(); });
    final state = createMockUIState(alertText1: 'Changing Lanes', alertSize: 1, alertStatus: 0)
      ..modernOverlay = true;
    state.applyTdx(_tdx(events: [{'description': '施工', 'isCurrentSection': false}]));
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(),
      home: AugmentedRoadView(uiState: state)));
    await tester.pump();
    expect(tester.getRect(find.byType(TdxMarquee)).top, lessThan(60));
    expect(tester.getRect(find.text('Changing Lanes')).top, greaterThan(390 / 2));
    // 儀表介面：字級 ×0.85，黑底寬度貼合文字（遠小於整條）且水平置中
    final t = tester.widget<Text>(find.text('Changing Lanes'));
    expect(t.style!.fontSize, closeTo(74 * (390 / 1080) * .85, .1));
    final bg = tester.getRect(find.ancestor(of: find.text('Changing Lanes'),
        matching: find.byType(Container)).first);
    expect(bg.width, lessThan(844 * .6));
    // 側欄開著，比較基準用 alert 區域本身的中心
    final area = tester.getRect(find.byType(AlertRenderer));
    expect((bg.center.dx - area.center.dx).abs(), lessThan(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });
}
