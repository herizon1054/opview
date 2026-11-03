// 起步提醒 / 停等計時的圓形不可蓋住 comma 的底部橫幅警示（events.py，例如「自動煞車維持中」）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/onroad/alert_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/services/stop_go_alerts.dart';
import 'golden/mock_ui_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final size in const [Size(390, 844), Size(844, 390)]) {
    testWidgets('stop-go circle stays clear of a banner alert $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(() { tester.view.resetPhysicalSize(); tester.view.resetDevicePixelRatio(); });

      final state = createMockUIState()..modernOverlay = true;
      state.alertSize = 2; // mid：兩行，副標故意很長（直向會換行、橫幅變高）
      state.alertStatus = 0;
      state.alertText1 = '自動煞車維持中';
      state.alertText2 = '放開煞車踏板後即可起步，起步前請注意前方路況並與前車保持安全距離';
      state.standstill = true;
      final alerts = StopGoAlerts.instance
        ..reset()
        ..configure(greenLight: false, leadDepart: false, standstillTimer: true)
        ..update(state);
      addTearDown(() => alerts
        ..configure(greenLight: false, leadDepart: false, standstillTimer: false)
        ..reset());

      await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(),
        home: AugmentedRoadView(uiState: state, onExit: () {})));
      await tester.pump(); // 第一幀：橫幅回報位置
      await tester.pump(); // 第二幀：圓形依橫幅位置重新擺放
      expect(tester.takeException(), isNull);

      final banner = alertBannerRect.value;
      expect(banner, isNotNull, reason: '橫幅應回報位置');
      final circle = tester.getRect(find.ancestor(of: find.text('停等中'),
        matching: find.byWidgetPredicate((w) => w is Container && w.decoration is BoxDecoration &&
            (w.decoration! as BoxDecoration).shape == BoxShape.circle)).first);
      expect(circle.overlaps(banner!), isFalse, reason: 'circle $circle 與橫幅 $banner 重疊');

      await tester.pumpWidget(const SizedBox.shrink());
      expect(alertBannerRect.value, isNull, reason: '橫幅移除後清掉位置');
      state.dispose();
    });
  }
}
