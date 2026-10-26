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

  testWidgets('all 7 rail buttons fit on a landscape phone without scrolling', (tester) async {
    phone(tester);
    system.pipSupported.value = true;
    final settings = ViewerSettings()..pictureInPicture = true;
    final state = createMockUIState()..modernOverlay = true;
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(),
      home: AugmentedRoadView(uiState: state, settings: settings)));
    for (final label in ['儀表介面', '連線資訊', 'km/h', 'TDX 開', '顯示設定', '子母畫面', '全螢幕']) {
      final rect = tester.getRect(find.text(label));
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
    await tester.tap(find.text('連線資訊'));
    await tester.pump(const Duration(seconds: 6));
    expect(find.text('全螢幕'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    settings.dispose();
    state.dispose();
  });
}
