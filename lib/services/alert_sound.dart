// 起步提醒聲音（前車起步 / 綠燈起步）：靜音（預設）/ Google 語音 / 嗶嗶聲
//   Google 語音：手機 Google 文字轉語音（台灣中文預設聲音）；沒有中文語音資料或引擎失敗時改播嗶嗶聲
//   嗶嗶聲：播放 App 內建的 assets/sounds/beep.wav，失敗時改用程式產生的短音
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
  AlertSoundMode.voice => 'Google 語音',
  AlertSoundMode.beep => '嗶嗶聲',
};

/// 嗶嗶聲的音檔（Flutter asset）
const beepSoundAsset = 'assets/sounds/beep.wav';

String stopGoSpeech(StopGoKind k) => switch (k) {
  StopGoKind.greenLight => '綠燈了，請注意起步',
  StopGoKind.leadDepart => '前車已起步',
};

/// 最近一次播放的結果（顯示設定的試聽按鈕下方顯示；也寫入 log）
final lastAlertSoundStatus = ValueNotifier<String?>(null);

Future<void> playStopGoSound(StopGoKind kind, AlertSoundMode mode) async {
  if (mode == AlertSoundMode.mute) return;
  String status;
  try {
    final r = await _channel.invokeMethod<Object?>('alertSound', {
      'mode': mode == AlertSoundMode.voice ? 'voice' : 'beep',
      'text': stopGoSpeech(kind),
      if (mode == AlertSoundMode.beep) 'asset': beepSoundAsset,
    });
    status = r is String ? r : '已送出';
  } on PlatformException catch (e) {
    status = '播放失敗：${e.message}';
  } on MissingPluginException {
    return; // 測試 / 非 Android
  }
  debugPrint('[opview] 提醒聲音（${alertSoundLabel(mode)}「${stopGoSpeech(kind)}」）：$status');
  lastAlertSoundStatus.value = status;
}
