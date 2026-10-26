// Selected PiP / window-brightness functionality from opview-rivian-support.
// No APK installer, remote commands, or extra Android permissions.
import 'package:flutter/foundation.dart';
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
/// 重新隱藏狀態列 / 導航列（main.dart 啟動時設定的 immersiveSticky，
/// 被系統手勢或對話框叫出後有時不會自動收回）
Future<void> reapplyImmersive() async {
  try { await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky); }
  on PlatformException { /* best-effort */ }
  on MissingPluginException { /* best-effort */ }
}
Future<bool> enterPip() async {
  try {
    final entered = await _channel.invokeMethod<bool>('enterPip') ?? false;
    if (!entered) pipSupported.value = false;
    return entered;
  } on PlatformException { pipSupported.value = false; return false; }
  on MissingPluginException { pipSupported.value = false; return false; }
}
