// 顯示設定（2026-11-14 重新整理）：分組、說明改成 ⓘ 按鈕、窄螢幕不溢出
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/settings/viewer_settings_dialog.dart';
import 'package:opview/services/viewer_settings.dart';
import 'package:opview/services/viewer_system.dart' as system;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('org.dragonpilot.opview/system');
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    system.brightnessSupported.value = false;
  });

  Future<ViewerSettings> open(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(() { tester.view.resetPhysicalSize(); tester.view.resetDevicePixelRatio(); });
    final settings = ViewerSettings();
    await settings.load();
    system.brightnessSupported.value = true;
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(),
        home: Scaffold(body: ViewerSettingsDialog(settings: settings, opHost: () => '192.168.1.10'))));
    await tester.pump();
    return settings;
  }

  for (final (name, size) in [('portrait', const Size(390, 844)), ('landscape', const Size(844, 390))]) {
    testWidgets('grouped, no overflow ($name)', (tester) async {
      final settings = await open(tester, size);
      expect(tester.takeException(), isNull);
      for (final s in ['畫面', '行車提醒', '停等與起步', '交通部 TDX', '通知', '啟動', '工具']) {
        expect(find.text(s), findsOneWidget, reason: s);
      }
      // 長說明不再直接列在清單上
      expect(find.textContaining('模型信心度'), findsNothing);
      expect(find.textContaining('省電策略'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      settings.dispose();
    });
  }

  testWidgets('info button shows the description; row tap toggles the switch', (tester) async {
    final settings = await open(tester, const Size(390, 844));
    final info = find.byTooltip('說明：近距離警示');
    await tester.ensureVisible(info);
    await tester.tap(info);
    await tester.pumpAndSettle();
    expect(find.textContaining('模型信心度'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.textContaining('模型信心度'), findsNothing);

    expect(settings.proximityAlert, isFalse);
    await tester.ensureVisible(find.text('近距離警示'));
    await tester.tap(find.text('近距離警示'));
    await tester.pump();
    expect(settings.proximityAlert, isTrue);

    expect(settings.disengageAlert, isFalse); // 預設關閉
    await tester.ensureVisible(find.text('巡航解除提示'));
    await tester.tap(find.text('巡航解除提示'));
    await tester.pump();
    expect(settings.disengageAlert, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    settings.dispose();
  });
}
