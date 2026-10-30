// comma 車型選擇（dragonpilot dashy serverd，port 5088）
//
// 對照 dp0111pre dragonpilot/dashy/serverd.py：
//   GET  /api/models          → {"model_list": {品牌: [車型, …]}, "selected_model": "TOYOTA_COROLLA_TSS2" | ""}
//   POST /api/models/select   body {"selected_model": "<車型>" | "[AUTO]"}；"[AUTO]" 或空字串 = 清除（自動偵測）
// 寫入的是 comma 參數 dp_dev_model_selected；launch_chffrplus.sh 的 set_model_fingerprint 在開機啟動時讀取，
// 設定 FINGERPRINT / SKIP_FW_QUERY → **comma 重新開機後才生效**。
// serverd 是 always_run，offroad 也能用。

import 'dart:convert';
import 'package:http/http.dart' as http;

const commaSettingsPort = 5088;
const autoModel = '[AUTO]';

class CommaModels {
  final Map<String, List<String>> byBrand; // 品牌 → 車型（已排序）
  final String selected;                   // 空字串 = 自動偵測
  const CommaModels(this.byBrand, this.selected);

  /// 已選車型所屬品牌；找不到（或自動偵測）回傳 null
  String? brandOf(String model) {
    for (final e in byBrand.entries) {
      if (e.value.contains(model)) return e.key;
    }
    return null;
  }
}

class CommaApiException implements Exception {
  final String message;
  CommaApiException(this.message);
  @override
  String toString() => message;
}

CommaModels parseModels(Map<String, dynamic> json) {
  final raw = json['model_list'];
  final out = <String, List<String>>{};
  if (raw is Map) {
    raw.forEach((k, v) {
      if (v is List) {
        final models = v.map((e) => e.toString()).where((e) => e.isNotEmpty).toList()..sort();
        if (models.isNotEmpty) out[k.toString()] = models;
      }
    });
  }
  final sorted = Map.fromEntries(out.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
  return CommaModels(sorted, (json['selected_model'] ?? '').toString());
}

// 註：URL 一律用 Uri(host: …) 組，IPv6（含 link-local 的 %wlan0）會自動加中括號與編碼；
// 之前用字串 'http://$host:5088' 遇到 fe80::…%wlan0 會 FormatException。

/// 讀車型失敗的簡短原因（主畫面只顯示這一句，完整錯誤寫 log）
String shortCommaError(Object e) {
  final t = e.toString();
  if (e is CommaApiException) return t;
  if (t.contains('TimeoutException')) return 'comma 沒有回應';
  if (t.contains('Connection refused')) return 'comma 設定服務未啟動';
  if (t.contains('No route to host') || t.contains('Network is unreachable')) return '連不到 comma';
  if (t.contains('FormatException')) return 'comma 位址格式錯誤';
  return '連不到 comma';
}

Future<CommaModels> fetchCommaModels(String host) async {
  final r = await http
      .get(Uri(scheme: 'http', host: host, port: commaSettingsPort, path: '/api/models'))
      .timeout(const Duration(seconds: 5));
  if (r.statusCode != 200) throw CommaApiException('comma 回應 ${r.statusCode}');
  final body = jsonDecode(utf8.decode(r.bodyBytes));
  if (body is! Map<String, dynamic>) throw CommaApiException('車型清單格式不正確');
  return parseModels(body);
}

/// model：車型字串；null / [autoModel] = 自動偵測
Future<void> selectCommaModel(String host, String? model) async {
  final r = await http
      .post(Uri(scheme: 'http', host: host, port: commaSettingsPort, path: '/api/models/select'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'selected_model': model ?? autoModel}))
      .timeout(const Duration(seconds: 5));
  if (r.statusCode != 200) throw CommaApiException('儲存失敗（${r.statusCode}）');
}
