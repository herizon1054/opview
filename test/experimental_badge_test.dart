// 實驗模式圖示：開啟時顯示在道路畫面左側中上（直向、橫向），關閉時不顯示
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/selfdrive/ui/onroad/experimental_badge.dart';
import 'golden/mock_ui_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final size in [const Size(844, 390), const Size(390, 844)]) {
    testWidgets('experimental badge at the upper-left-middle of the road view $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(() { tester.view.resetPhysicalSize(); tester.view.resetDevicePixelRatio(); });
      final state = createMockUIState(experimentalMode: true)..modernOverlay = true;
      await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(),
        home: AugmentedRoadView(uiState: state, onExit: () {})));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(ExperimentalBadge), findsOneWidget);
      final r = tester.getRect(find.byType(ExperimentalBadge));
      final portrait = size.height > size.width;
      final videoH = portrait ? 390 * 1208 / 1928 : size.height;
      // 直向：影像區左緣；橫向：左側側欄（寬 96）右邊的道路畫面左緣
      final roadLeft = portrait ? 0.0 : 96.0;
      expect(r.left - roadLeft, inInclusiveRange(0, 30), reason: '靠左');
      expect(r.center.dy, closeTo(videoH * .35, 6), reason: '中上（高度 35%）');

      state.experimentalMode = false;
      await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(),
        home: AugmentedRoadView(uiState: state, onExit: () {})));
      await tester.pump();
      expect(find.byType(ExperimentalBadge), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    });
  }
}
