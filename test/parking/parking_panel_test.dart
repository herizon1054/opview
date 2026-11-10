import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/onroad/portrait_panel.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/parking/parking_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => null,
        );
  });
  // (高度, LINE, 停車查詢開啟, 是否應顯示停車面板)
  for (final (height, line, parkingOn, showParking) in [
    (160.0, false, true, false), (300.0, false, true, true), (500.0, false, true, true),
    (160.0, true, true, false), (500.0, true, true, true), (500.0, true, false, false),
  ]) {
    testWidgets('portrait panel fits height $height (LINE $line, parking $parkingOn) and disposes timer', (
      tester,
    ) async {
      ParkingConfig.instance.enabled = parkingOn;
      addTearDown(() => ParkingConfig.instance.enabled = true);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 390,
                height: height,
                child: PortraitPanel(
                  state: UIState(),
                  stale: true,
                  lineEnabled: line,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      // LINE + 停車：LINE 佔剩餘 40%、停車拿其餘；只開 LINE（停車關閉）時剩餘高度全給 LINE
      expect(find.textContaining('請先設定 TDX 金鑰'), showParking ? findsWidgets : findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 16));
      expect(tester.takeException(), isNull);
    });
  }
}
