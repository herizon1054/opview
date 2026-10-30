import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:opview/services/viewer_settings.dart';
import 'package:opview/services/viewer_system.dart' as system;
import 'package:opview/selfdrive/ui/onroad/throttled_hud.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/selfdrive/ui/onroad/compact_hud.dart';
import 'golden/mock_ui_state.dart';
import 'package:opview/selfdrive/ui/settings/viewer_settings_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('org.dragonpilot.opview/system');
  final calls = <MethodCall>[];
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'setBrightness' ? null : true;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  testWidgets('unsupported native controls are hidden, not disabled', (tester) async {
    final settings = ViewerSettings();
    await settings.load();
    system.pipSupported.value = false;
    system.brightnessSupported.value = false;
    await tester.pumpWidget(MaterialApp(home: ViewerSettingsDialog(settings: settings)));
    expect(find.text('子母畫面 PiP'), findsNothing);
    expect(find.text('亮度跟隨系統'), findsNothing);
    expect(find.byType(Slider), findsNothing);
    expect(find.text('公制 km/h'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    settings.dispose();
  });

  test('settings persist and brightness affects only the native window channel', () async {
    final settings = ViewerSettings();
    await settings.load();
    settings.setLayout(ViewerLayout.detailed);
    settings.setMetric(false);
    settings.setPip(true);
    settings.setBrightness(.3);
    settings.setHudEvery(1);
    await Future<void>.delayed(Duration.zero);
    final restored = ViewerSettings();
    await restored.load();
    expect(restored.layout, ViewerLayout.detailed);
    expect(restored.metric, false);
    expect(restored.pictureInPicture, true);
    expect(restored.brightness, .3);
    expect(restored.hudEvery, 1);
    restored.setBrightness(null);
    await Future<void>.delayed(Duration.zero);
    expect(calls.last.method, 'setBrightness');
    expect(calls.last.arguments, -1.0);
    settings.dispose(); restored.dispose();
  });

  test('PiP capability and entry use native methods', () async {
    await system.setPipEnabled(true);
    expect(system.pipSupported.value, true);
    expect(await system.enterPip(), true);
    expect(await system.isInPip(), true);
    expect(calls.map((c) => c.method), ['setPipEnabled', 'enterPip', 'isInPip']);
  });

  testWidgets('HUD skips intermediate samples and invalidates for important state', (tester) async {
    var builds = 0;
    Future<void> frame(int version, String status) => tester.pumpWidget(
      MaterialApp(home: ThrottledHud(version: version, every: 4, invalidateKey: status,
        builder: () { builds++; return Text('$version:$status'); })),
    );
    await frame(0, 'engaged');
    for (var i = 1; i < 4; i++) { await frame(i, 'engaged'); }
    expect(builds, 1);
    await frame(4, 'engaged'); expect(builds, 2);
    await frame(5, 'disengaged'); expect(builds, 3);
    expect(find.text('5:disengaged'), findsOneWidget);
  });

  testWidgets('PiP hides controls and renders alerts in a small window', (tester) async {
    tester.view.physicalSize = const Size(320, 180);
    tester.view.devicePixelRatio = 1;
    addTearDown(() { tester.view.resetPhysicalSize(); tester.view.resetDevicePixelRatio(); });
    final state = createMockUIState(alertText1: 'TAKE CONTROL', alertSize: 3, alertStatus: 2);
    await tester.pumpWidget(MaterialApp(home: AugmentedRoadView(uiState: state, pip: true)));
    expect(find.byType(CompactHud), findsOneWidget);
    expect(find.text('連線資訊'), findsNothing);
    expect(find.text('TAKE CONTROL'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });
}
