// 實驗模式圖示（openpilot HUD 圖案）：直向在道路畫面左側中上；橫向在右上角；關閉時不顯示
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
      if (portrait) {
        expect(r.left, inInclusiveRange(0, 30), reason: '直向：靠左');
        expect(r.center.dy, closeTo(videoH * .35, 6), reason: '直向：中上（高度 35%）');
      } else {
        // 橫向：右上角（同 openpilot HUD）
        expect(size.width - r.right, inInclusiveRange(0, 30), reason: '橫向：靠右');
        expect(r.top, lessThan(40), reason: '橫向：上方');
      }
      // openpilot HUD 的實驗模式圖案
      expect(find.byWidgetPredicate((w) => w is Image && w.image is AssetImage &&
          (w.image as AssetImage).assetName == experimentalIconAsset), findsOneWidget);

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
