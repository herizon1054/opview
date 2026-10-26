import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/selfdrive/ui/onroad/tdx_marquee.dart';
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
}
