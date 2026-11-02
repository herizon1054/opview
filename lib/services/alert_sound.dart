// 起步提醒聲音（前車起步 / 綠燈起步）：靜音（預設）/ Google 女聲 / 嗶嗶聲
// 直向、橫向都會播放（畫面提示也是直向、橫向都有）。
// Android：MainActivity 的 "alertSound"
//   voice → TextToSpeech（優先使用 Google 文字轉語音引擎，台灣中文），音訊用途為導航語音，會壓低音樂音量
//   beep  → ToneGenerator 雙短音

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'stop_go_alerts.dart';

enum AlertSoundMode { mute, voice, beep }

const _channel = MethodChannel('org.dragonpilot.opview/system');

String alertSoundLabel(AlertSoundMode m) => switch (m) {
  AlertSoundMode.mute => '靜音',
  AlertSoundMode.voice => 'Google 女聲',
  AlertSoundMode.beep => '嗶嗶聲',
};

String stopGoSpeech(StopGoKind k) => switch (k) {
  StopGoKind.greenLight => '綠燈了，請注意起步',
  StopGoKind.leadDepart => '前車已起步',
};

Future<void> playStopGoSound(StopGoKind kind, AlertSoundMode mode) async {
  if (mode == AlertSoundMode.mute) return;
  try {
    await _channel.invokeMethod('alertSound', {
      'mode': mode == AlertSoundMode.voice ? 'voice' : 'beep',
      'text': stopGoSpeech(kind),
    });
  } on PlatformException catch (e) {
    debugPrint('[opview] 提醒聲音播放失敗：${e.message}');
  } on MissingPluginException {
    // 測試 / 非 Android
  }
}
