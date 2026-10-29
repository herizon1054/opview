import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/home/home_page.dart';
import 'package:opview/services/comma_models_api.dart';
import 'package:opview/services/viewer_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('home page shows model section and four buttons on a landscape phone', (tester) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(() { tester.view.resetPhysicalSize(); tester.view.resetDevicePixelRatio(); });
    var entered = 0;
    final settings = ViewerSettings();
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: HomePage(
      settings: settings, hostGetter: () => null, onEnterOpview: () => entered++)));
    await tester.pump();
    expect(find.text('車型選擇'), findsOneWidget);
    expect(find.text('確認變更'), findsOneWidget); // 尚未讀到車型：按鈕停用
    expect(find.text('未連線'), findsOneWidget);  // 標題旁狀態
    expect(find.textContaining('目前車型'), findsOneWidget);
    for (final t in ['進入 opview', '顯示設定', '裝置設定', '離開程式']) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    expect(find.textContaining('尋找 comma'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('進入 opview'));
    expect(entered, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    settings.dispose();
  });

  test('parse model list from serverd /api/models', () {
    final m = parseModels({
      'model_list': {'Toyota': ['TOYOTA_RAV4_TSS2', 'TOYOTA_COROLLA_TSS2'], 'Honda': ['HONDA_CIVIC'], 'Empty': []},
      'selected_model': 'TOYOTA_COROLLA_TSS2',
    });
    expect(m.byBrand.keys.toList(), ['Honda', 'Toyota']); // 空品牌去掉、依名稱排序
    expect(m.byBrand['Toyota'], ['TOYOTA_COROLLA_TSS2', 'TOYOTA_RAV4_TSS2']);
    expect(m.brandOf('TOYOTA_COROLLA_TSS2'), 'Toyota');
    expect(parseModels({'model_list': {}, 'selected_model': ''}).selected, '');
  });

  test('auto-enter-opview and TDX toggles persist', () async {
    final a = ViewerSettings();
    await a.load();
    expect(a.autoEnterOpview, isFalse);
    a.setAutoEnterOpview(true);
    a.setTdx(false);
    final b = ViewerSettings();
    await b.load();
    expect(b.autoEnterOpview, isTrue);
    expect(b.tdx, isFalse);
    a.dispose();
    b.dispose();
  });
}
