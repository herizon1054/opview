import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/selfdrive/ui/onroad/dashboard_hud.dart';
import 'golden/mock_ui_state.dart';

void main() {
  test('headway is distance / ego speed; invalid or stale lead is absent', () {
    final state = UIState()..vEgo = 20;
    state.applyRadarState({'leadOne': {'status': true, 'dRel': 40}});
    expect(state.leadHeadway, 2);
    state.vEgo = 0;
    expect(state.leadHeadway, isNull);
    state.applyRadarState({'leadOne': {'status': false, 'dRel': 40}});
    expect(state.leadDistance, isNull);
    state.applyRadarState({'leadOne': {'status': true, 'dRel': double.nan}});
    expect(state.leadDistance, isNull);
    state.applyRadarState({'leadOne': {'status': true, 'dRel': 40}});
    state.lastRadarAt = DateTime.now().subtract(const Duration(seconds: 3));
    expect(state.leadDistance, isNull);
    state.dispose();
  });

  for (final size in [const Size(844, 390), const Size(1024, 768), const Size(1280, 480)]) {
    testWidgets('dashboard controls and alert priority $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(() { tester.view.resetPhysicalSize(); tester.view.resetDevicePixelRatio(); });
      final state = createMockUIState()..modernOverlay = true;
      await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(),
        home: AugmentedRoadView(uiState: state)));
      expect(find.byType(DashboardHud), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('連線資訊'));
      await tester.pump();
      expect(find.textContaining('傳輸：WebRTC'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.straighten));
      await tester.pump();
      expect(state.isMetric, isFalse);
      await tester.tap(find.text('全螢幕'));
      await tester.pump();
      expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);
      await tester.tap(find.byIcon(Icons.fullscreen_exit), warnIfMissed: false);
      await tester.pump();
      // 原本點擊被邊框 CustomPaint 吃掉，側欄不會回來
      expect(find.text('全螢幕'), findsOneWidget);
      state.alertSize = 3;
      state.alertStatus = 2;
      state.alertText1 = 'TAKE CONTROL';
      state.lastModelAt = DateTime.now().subtract(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('TAKE CONTROL'), findsOneWidget);
      expect(find.textContaining('傳輸：WebRTC'), findsNothing);
      expect(find.text('資料中斷'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    });
  }

  testWidgets('exit fullscreen works while disconnected with large system font', (tester) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2.2;
    // 橫向時左側挖孔安全區（實機約 45dp）
    tester.view.padding = const FakeViewPadding(left: 45);
    tester.view.viewPadding = const FakeViewPadding(left: 45);
    addTearDown(() {
      tester.view.resetPadding(); tester.view.resetViewPadding();
      tester.view.resetPhysicalSize(); tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    final state = createMockUIState()
      ..modernOverlay = true
      ..isConnected = false;
    state.connectionLog.add('[00:32:32] searching for comma device…');
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(),
      home: AugmentedRoadView(uiState: state)));
    expect(tester.takeException(), isNull);
    expect(find.text('Connecting…'), findsOneWidget);
    // 側欄標籤：單行（不換行）且實際顯示大小 >= 13dp（不被 FittedBox 縮到看不見）
    for (final text in ['儀表介面', 'km/h', '全螢幕']) {
      final rect = tester.getRect(find.text(text));
      expect(rect.height, inInclusiveRange(13, 30), reason: text);
      // 不可落在左側安全區內
      expect(rect.left, greaterThanOrEqualTo(45), reason: text);
    }
    await tester.tap(find.text('全螢幕'));
    await tester.pump();
    expect(find.text('全螢幕'), findsNothing);
    await tester.tap(find.byIcon(Icons.fullscreen_exit), warnIfMissed: false);
    await tester.pump();
    expect(find.text('全螢幕'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });
}
