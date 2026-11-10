// 實驗模式開關（opview 側欄 / 直向操作列第一顆按鈕）
//
// opview 本身只接收 webrtcd 的資料，沒有寫入 comma 參數的管道，所以需要 comma 端提供端點
// （與車型選擇同一個服務：dp dashy serverd / sp opviewd，port 5088）：
//
//   POST /api/experimental_mode   body {"enabled": true | false}
//     200 {"experimental_mode": true | false}            寫入後的實際值（comma 端可能拒絕開啟）
//     403 / 409 {"error": "<原因>"}                       例如車輛不支援 openpilot 縱向控制、尚未確認實驗模式說明
//     404                                                comma 端尚未加入此端點（分支未更新）
//
// comma 端應比照 openpilot 設定頁 / onroad 按鈕的條件：只有 openpilot 縱向控制可用時才允許開啟，
// 並寫入 ExperimentalMode；尚未在 comma 設定頁確認過實驗模式說明（ExperimentalModeConfirmed）時拒絕開啟，
// 不代替使用者確認（見 COMMA_EXPERIMENTAL_ENDPOINT_zh-TW.md）。
// 實際是否開啟以 selfdriveState.experimentalMode 為準（UIState.experimentalMode），按鈕依它顯示。

import 'dart:convert';
import 'package:http/http.dart' as http;

import 'comma_models_api.dart' show CommaApiException, commaSettingsPort;

/// 送出開關；回傳 comma 寫入後的值（回應沒有帶值時回傳 [enabled]）
Future<bool> setCommaExperimentalMode(String host, bool enabled, {http.Client? client}) async {
  final post = client?.post ?? http.post;
  final r = await post(Uri(scheme: 'http', host: host, port: commaSettingsPort, path: '/api/experimental_mode'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'enabled': enabled}))
      .timeout(const Duration(seconds: 5));
  Object? body;
  try {
    body = jsonDecode(utf8.decode(r.bodyBytes));
  } catch (_) {
    body = null;
  }
  if (r.statusCode == 404) {
    throw CommaApiException('comma 端沒有實驗模式設定（請更新 comma 分支）');
  }
  if (r.statusCode != 200) {
    final err = body is Map && body['error'] is String ? body['error'] as String : '';
    throw CommaApiException(err.isNotEmpty ? err : '切換失敗（${r.statusCode}）');
  }
  final v = body is Map ? body['experimental_mode'] : null;
  return v is bool ? v : enabled;
}
