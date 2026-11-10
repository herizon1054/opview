// 彩虹模式路徑：直向、橫向、有 / 無前車（路徑被截短）都能畫出來且不丟例外
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/selfdrive/ui/onroad/model_renderer.dart';
import 'package:opview/services/viewer_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'golden/mock_ui_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final (name, size) in [('landscape', const Size(844, 385)), ('portrait', const Size(390, 844))]) {
    for (final lead in [true, false]) {
      testWidgets('rainbow path paints ($name, lead=$lead)', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(() { tester.view.resetPhysicalSize(); tester.view.resetDevicePixelRatio(); });
        final settings = ViewerSettings();
        final state = createMockUIState(leadDRel: 25)
          ..modernOverlay = true
          ..rainbowPath = true;
        if (!lead) state.leadOne = null;
        await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(),
            home: AugmentedRoadView(uiState: state, settings: settings)));
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byWidgetPredicate((w) => w is CustomPaint && w.painter is ModelRendererPainter),
            findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        settings.dispose();
        state.dispose();
      });
    }
  }
}
