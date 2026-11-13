// 巡航解除提示（2026-11-14）：行駛中 selfdriveState.enabled true → false → 滴滴兩聲事件 + 警示列「巡航解除」2 秒
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/proximity_alert.dart';
import 'package:opview/services/viewer_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'golden/mock_ui_state.dart';

Map<String, dynamic> _sd(bool on, [String state = '']) =>
    {'enabled': on, 'state': state.isEmpty ? (on ? 'enabled' : 'disabled') : state};

/// 可控時間的 UIState；先送一筆 enabled（建立「上一筆」）
(UIState, List<void>, void Function(Duration)) _setup({double vEgo = 18, bool modern = false}) {
  var t = DateTime(2026, 11, 14, 1, 0);
  final s = createMockUIState(vEgo: vEgo)
    ..modernOverlay = modern
    ..disengageAlert = true; // 設定預設關閉，測試時打開
  s.clock = () => t;
  final events = <void>[];
  s.disengageEvents.listen(events.add);
  s.applySelfdriveState(_sd(true));
  return (s, events, (d) => t = t.add(d));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('moving: enabled → disabled fires once and shows banner for 2 s', () async {
    final (s, events, advance) = _setup();
    advance(const Duration(milliseconds: 50));
    s.applySelfdriveState(_sd(false));
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(1));
    expect(s.eventBanner, (text: '巡航解除', collision: false, warn: false, disengage: true));
    // 之後持續 disabled 不再觸發
    advance(const Duration(milliseconds: 50));
    s.applySelfdriveState(_sd(false));
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(1));
    advance(const Duration(milliseconds: 1950));
    expect(s.disengageText, isEmpty);
    s.dispose();
  });

  test('modern overlay also shows the banner', () {
    final (s, _, advance) = _setup(modern: true);
    advance(const Duration(milliseconds: 50));
    s.applySelfdriveState(_sd(false));
    expect(s.eventBannerFor(portrait: true).disengage, isTrue);
    expect(s.eventBannerFor(portrait: false).text, '巡航解除');
    s.dispose();
  });

  test('no alert: standstill, gas override, reconnect, setting off', () async {
    // 停車中
    final (s1, e1, a1) = _setup(vEgo: 0.2);
    a1(const Duration(milliseconds: 50));
    s1.applySelfdriveState(_sd(false));
    // 踩油門介入：enabled 仍為 true
    final (s2, e2, a2) = _setup();
    a2(const Duration(milliseconds: 50));
    s2.applySelfdriveState(_sd(true, 'overriding'));
    expect(s2.status, UIStatus.override_);
    // 斷線重連：距上一筆超過 2 秒
    final (s3, e3, a3) = _setup();
    a3(const Duration(seconds: 5));
    s3.applySelfdriveState(_sd(false));
    // 設定關閉
    final (s4, e4, a4) = _setup();
    s4.disengageAlert = false;
    a4(const Duration(milliseconds: 50));
    s4.applySelfdriveState(_sd(false));
    await Future<void>.delayed(Duration.zero);
    for (final (s, e) in [(s1, e1), (s2, e2), (s3, e3), (s4, e4)]) {
      expect(e, isEmpty);
      expect(s.disengageText, isEmpty);
      s.dispose();
    }
  });

  test('collision has priority over disengage', () {
    final (s, _, advance) = _setup();
    advance(const Duration(milliseconds: 50));
    s.applySelfdriveState(_sd(false));
    expect(s.eventBanner.disengage, isTrue);
    ProximityAlert.instance.configure(enabled: true);
    const hit = ProximityInput(vEgo: 30 / 3.6, leadX: 3.0, leadY: 0.1, leadProb: 0.3,
        pathX: [0, 10, 20], pathY: [0, 0, 0]);
    for (var i = 0; i < ProximityAlert.holdFrames; i++) {
      ProximityAlert.instance.update(hit);
    }
    expect(s.eventBanner.collision, isTrue);
    expect(s.eventBanner.disengage, isFalse);
    ProximityAlert.instance.configure(enabled: false);
    expect(s.eventBanner.disengage, isTrue);
    s.dispose();
  });

  test('setting persists (default off)', () async {
    final v = ViewerSettings();
    await v.load();
    expect(v.disengageAlert, isFalse);
    final u = UIState();
    expect(u.disengageAlert, isFalse);
    u.dispose();
    v.setDisengageAlert(true);
    final p = await SharedPreferences.getInstance();
    expect(p.getBool('viewer_disengage_alert'), isTrue);
    v.dispose();
  });

  for (final (name, size) in [('landscape', const Size(844, 385)), ('portrait', const Size(390, 844))]) {
    testWidgets('disengage banner on road view ($name)', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(() { tester.view.resetPhysicalSize(); tester.view.resetDevicePixelRatio(); });
      final settings = ViewerSettings();
      final (state, _, advance) = _setup(modern: true);
      advance(const Duration(milliseconds: 50));
      state.applySelfdriveState(_sd(false));
      await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(),
          home: AugmentedRoadView(uiState: state, settings: settings)));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('巡航解除'), findsWidgets);
      expect(find.byIcon(Icons.pause_circle_filled_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      settings.dispose();
      state.dispose();
    });
  }
}
