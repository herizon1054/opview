// opview — openpilot onroad UI
// entry point: landscape, immersive, go

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app.dart';
import 'services/app_log.dart';
import 'services/webrtc_native_log.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // 持久化 log：攔截 debugPrint / 未捕捉例外，寫入 App 私有目錄（顯示設定 →「分享 log」）
  AppLog.instance.install();
  AppLog.instance.init();

  // libwebrtc 原生 warning / error（硬體解碼器退回軟體等）寫進 opview log；須早於任何 WebRTC 呼叫
  WebrtcNativeLog.install();

  // 直向 / 橫向都可：主畫面與 opview 畫面依方向切換排版（不含倒立直向）
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  // immersive fullscreen — no status bar, no nav bar
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  // keep screen on: handled via FLAG_KEEP_SCREEN_ON in MainActivity.kt

  runApp(const OpviewApp());
}
