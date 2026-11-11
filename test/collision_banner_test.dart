// 碰撞注意：近距離警示觸發時，事件位置（直向事件列 / 橫向上方跑馬燈）顯示「碰撞注意」，優先於 TDX 事件
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/services/proximity_alert.dart';
import 'package:opview/services/viewer_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'golden/mock_ui_state.dart';

const _hit = ProximityInput(vEgo: 30 / 3.6, leadX: 3.0, leadY: 0.1, leadProb: 0.3,
    pathX: [0, 10, 20], pathY: [0, 0, 0]);

void _trigger() {
  ProximityAlert.instance.configure(enabled: true);
  for (var i = 0; i < ProximityAlert.holdFrames; i++) {
    ProximityAlert.instance.update(_hit);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => ProximityAlert.instance.configure(enabled: false));

  test('banner priority: collision over TDX event', () {
    final s = createMockUIState()
      ..applyTdx({'nextSpeed': 62, 'congestion': 'smooth',
        'events': [{'description': '施工 外側車道', 'isCurrentSection': true}]});
    expect(s.eventBanner, (text: '目前: 施工 外側車道', collision: false));
    _trigger();
    expect(s.eventBanner.collision, isTrue);
    expect(s.eventBanner.text, '碰撞注意  前方 1.5 m');
    ProximityAlert.instance.configure(enabled: false);
    expect(s.eventBanner.collision, isFalse);
    s.dispose();
  });

  for (final (name, size) in [('landscape', const Size(844, 385)), ('portrait', const Size(390, 844))]) {
    testWidgets('collision banner replaces TDX event ($name)', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(() { tester.view.resetPhysicalSize(); tester.view.resetDevicePixelRatio(); });
      final settings = ViewerSettings();
      final state = createMockUIState()
        ..modernOverlay = true
        ..applyTdx({'nextSpeed': 62, 'congestion': 'smooth',
          'events': [{'description': '施工 外側車道', 'isCurrentSection': true}]});
      Widget app() => MaterialApp(theme: ThemeData.dark(),
          home: AugmentedRoadView(uiState: state, settings: settings));
      await tester.pumpWidget(app());
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('施工 外側車道'), findsWidgets);
      expect(find.textContaining('碰撞注意'), findsNothing);

      _trigger();
      await tester.pumpWidget(app());
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('碰撞注意'), findsWidgets);
      expect(find.textContaining('施工 外側車道'), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      settings.dispose();
      state.dispose();
    });
  }
}
