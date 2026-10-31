// Selected PiP / window-brightness functionality from opview-rivian-support.
// No APK installer, remote commands, or extra Android permissions.
import 'package:flutter/foundation.dart';
import 'dart:ui' show Brightness, Color;
import 'package:flutter/services.dart';

const _channel = MethodChannel('org.dragonpilot.opview/system');
final pipMode = ValueNotifier<bool>(false);
final pipSupported = ValueNotifier<bool>(false);
final brightnessSupported = ValueNotifier<bool>(false);

void listenForPip() {
  _channel.setMethodCallHandler((call) async {
    if (call.method == 'pipChanged') pipMode.value = call.arguments == true;
  });
}
void stopListeningForPip() {
  _channel.setMethodCallHandler(null);
  pipMode.value = false;
}
Future<void> setAppBrightness(double? value) async {
  try {
    await _channel.invokeMethod('setBrightness', value ?? -1.0);
    brightnessSupported.value = true;
  } on PlatformException { brightnessSupported.value = false; }
  on MissingPluginException { brightnessSupported.value = false; }
}
Future<void> setPipEnabled(bool enabled) async {
  try {
    pipSupported.value = await _channel.invokeMethod<bool>('setPipEnabled', enabled) ?? false;
  } on PlatformException { pipSupported.value = false; }
  on MissingPluginException { pipSupported.value = false; }
}
Future<bool> isInPip() async {
  try { return await _channel.invokeMethod<bool>('isInPip') ?? false; }
  on PlatformException { return false; }
  on MissingPluginException { return false; }
}
// 狀態列（電量、訊號、時間）：主畫面與直向 opview 畫面顯示；橫向 / 全螢幕 / 子母畫面隱藏。
// 導航列一律隱藏。由 app.dart 的 _SystemUiSync 依目前畫面呼叫 setStatusBarVisible()。
bool _statusBarWanted = false;
bool? _statusBarApplied;

Future<void> setStatusBarVisible(bool show) async {
  _statusBarWanted = show;
  if (_statusBarApplied == show) return;
  await _applySystemUi();
}

Future<void> _applySystemUi() async {
  final show = _statusBarWanted;
  try {
    if (show) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: const [SystemUiOverlay.top]);
      // 黑底白字，和 opview 深色背景一致
      SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
        statusBarColor: Color(0xFF000000),
        statusBarIconBrightness: Brightness.light, // Android：白色圖示
        statusBarBrightness: Brightness.dark,      // iOS
      ));
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    _statusBarApplied = show;
  } on PlatformException { /* best-effort */ }
  on MissingPluginException { /* best-effort */ }
}

/// 重新套用目前的系統列設定（被系統手勢或對話框叫出後有時不會自動收回）
Future<void> reapplyImmersive() => _applySystemUi();
/// 以系統瀏覽器開啟網址（OP 設定網頁）
Future<bool> openUrl(String url) async {
  try { return await _channel.invokeMethod<bool>('openUrl', url) ?? false; }
  on PlatformException { return false; }
  on MissingPluginException { return false; }
}
Future<bool> enterPip() async {
  try {
    final entered = await _channel.invokeMethod<bool>('enterPip') ?? false;
    if (!entered) pipSupported.value = false;
    return entered;
  } on PlatformException { pipSupported.value = false; return false; }
  on MissingPluginException { pipSupported.value = false; return false; }
}

/// 點「全螢幕」時鎖定橫向；退出全螢幕 / 離開 opview 畫面時恢復（直向 + 兩個橫向，同 main.dart）
Future<void> setLandscapeOnly(bool on) async {
  try {
    await SystemChrome.setPreferredOrientations(on
        ? const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
        : const [DeviceOrientation.portraitUp, DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  } on PlatformException { /* best-effort */ }
  on MissingPluginException { /* best-effort */ }
}
