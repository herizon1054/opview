import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/services/viewer_settings.dart';
import 'package:opview/services/viewer_system.dart' as system;
import 'golden/mock_ui_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(844, 385);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(left: 45);
    tester.view.viewPadding = const FakeViewPadding(left: 45);
    addTearDown(() {
      tester.view.resetPhysicalSize(); tester.view.resetDevicePixelRatio();
      tester.view.resetPadding(); tester.view.resetViewPadding();
      system.pipSupported.value = false;
    });
  }

  testWidgets('all rail buttons fit on a landscape phone without scrolling', (tester) async {
    phone(tester);
    system.pipSupported.value = true;
    final settings = ViewerSettings()..pictureInPicture = true;
    final state = createMockUIState()..modernOverlay = true;
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(),
      home: AugmentedRoadView(uiState: state, settings: settings, onExit: () {})));
    // 連線資訊、TDX 開關已移除（TDX 開關改到顯示設定）；新增「退出」
    for (final label in ['儀表介面', 'km/h', '顯示設定', '子母畫面', '全螢幕', '退出']) {
      // 只找側欄按鈕（InkWell 內），儀表板的速度單位也叫 km/h
      final rect = tester.getRect(find.descendant(of: find.byType(InkWell), matching: find.text(label)));
      expect(rect.bottom, lessThanOrEqualTo(385), reason: label);
      expect(rect.height, greaterThanOrEqualTo(11), reason: '$label 字太小');
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    settings.dispose();
    state.dispose();
  });

  testWidgets('auto fullscreen hides rail after delay; off by default', (tester) async {
    phone(tester);
    final settings = ViewerSettings();
    expect(settings.autoFullscreen, isFalse);
    settings.setAutoFullscreen(true);
    final state = createMockUIState()..modernOverlay = true;
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(),
      home: AugmentedRoadView(uiState: state, settings: settings)));
    expect(find.text('全螢幕'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 2500));
    expect(find.text('全螢幕'), findsOneWidget);   // 3 秒前仍顯示
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('全螢幕'), findsNothing);
    expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);

    // 手動叫回後不再自動收起
    await tester.tap(find.byIcon(Icons.fullscreen_exit), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(find.text('全螢幕'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    settings.dispose();
    state.dispose();
  });

  testWidgets('tapping a rail button cancels the pending auto fullscreen', (tester) async {
    phone(tester);
    final settings = ViewerSettings()..setAutoFullscreen(true);
    final state = createMockUIState()..modernOverlay = true;
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(),
      home: AugmentedRoadView(uiState: state, settings: settings)));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('km/h'));
    await tester.pump(const Duration(seconds: 6));
    expect(find.text('全螢幕'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    settings.dispose();
    state.dispose();
  });

  testWidgets('exit button calls onExit', (tester) async {
    phone(tester);
    var exited = 0;
    final state = createMockUIState()..modernOverlay = true..isConnected = false;
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(),
      home: AugmentedRoadView(uiState: state, onExit: () => exited++, opHost: () => '192.168.43.10')));
    expect(find.text('OP 設定'), findsNothing); // 側欄已移除（未連線、有 comma IP 也不顯示）
    expect(find.text('連線資訊'), findsNothing);
    expect(find.text('TDX 開'), findsNothing);
    await tester.tap(find.text('退出'));
    expect(exited, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });
}
