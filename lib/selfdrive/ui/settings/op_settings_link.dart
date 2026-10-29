// 開啟 comma 上的 OP 設定網頁（dragonpilot dashy serverd，http://<comma IP>:5088）
//
// serverd 在 dp0111pre 是 always_run：offroad 也能開，可用來打開「啟用 opview」等設定。
// 只允許 offroad 或 P 檔開啟；opview 未連線時用 serverd 的 /api/init（isOffroad）確認，連不到顯示「未連線」。
// sunnypilot 分支（沒有 :5088）改開 https://www.sunnylink.ai/（sp 的設定在 sunnylink 雲端）。
// IP 來源：目前連線 / mDNS 找到 / 快取的 comma IP；都沒有時讓使用者手動輸入（記住供下次使用）。

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:opview/services/viewer_system.dart' as system;
import 'package:opview/selfdrive/ui/ui_state.dart';

const opSettingsPort = 5088;
const _manualHostKey = 'op_settings_manual_host';

/// 裝置設定（comma 設定網頁）只允許 offroad 或 P 檔時開啟。app.dart 啟動時設定。
UIState? opSettingsGuardState;

const opSettingsNotConnected = '未連線：找不到 comma，無法確認是否 offroad／P 檔。\n'
    '請確認手機與 comma 在同一個網路後再試。';

/// opview 是否有即時資料（WebRTC 連線中且 3 秒內有更新）
bool hasLiveData(UIState? s) {
  final last = s?.lastModelAt;
  return s != null && s.isConnected && last != null &&
      DateTime.now().difference(last) <= const Duration(seconds: 3);
}

/// 判斷能不能開裝置設定；允許回傳 null，否則回傳要顯示的原因。
///   [s]            opview 的即時資料（WebRTC 連線中才有檔位）
///   [commaOffroad] comma serverd `/api/init` 的 isOffroad；null = 連不到 comma（未連線）
/// 規則：
///   1. opview 連線中且資料 3 秒內有更新：offroad（deviceState.started == false）或 P 檔才允許
///   2. 其他情況看 serverd：offroad 允許；onroad 但 opview 沒連上 → 無法確認檔位，不允許；
///      連不到 comma → 顯示「未連線」
String? decideOpSettings(UIState? s, bool? commaOffroad) {
  if (s != null && hasLiveData(s)) {
    if (!s.started || s.inPark) return null;
    return '行駛中無法開啟裝置設定。\n請停車排入 P 檔，或熄火（offroad）後再開啟。'
        '（目前檔位：${s.gearLetter ?? s.gearShifter}）';
  }
  if (commaOffroad == null) return opSettingsNotConnected;
  if (commaOffroad) return null;
  return 'comma 目前為 onroad，但 opview 未連線，無法確認檔位。\n'
      '請先在 opview 連線後於 P 檔開啟，或熄火（offroad）後再開啟。';
}

/// comma 上跑的分支
enum CommaBranch {
  /// dragonpilot 系（dp0111pre、dplcc…）：有 dashy serverd（:5088，always_run）
  dp,
  /// sunnypilot 系：沒有 :5088，設定在雲端 sunnylink
  sp,
  /// 連不到 comma（逾時 / 網路不通）
  unknown,
}

const sunnylinkUrl = 'https://www.sunnylink.ai/';

/// 判斷分支並取得 offroad 狀態（offroad 只有 dp 拿得到）。
///   1. GET :5088/api/init 回 JSON 且有 dp_dev_dashy → dp（isOffroad 一併取得）
///   2. :5088 連線被拒（主機在、但沒有 dashy）→ sp；
///      webrtcd 有開時再用 GET :5001/schema?services=selfdriveStateSP 確認（sp 專屬 cereal service）
///   3. 逾時 / 其他錯誤 → unknown（未連線）
Future<({CommaBranch branch, bool? offroad})> probeComma(String host, {http.Client? client}) async {
  final get = client?.get ?? http.get;
  try {
    final r = await get(Uri(scheme: 'http', host: host, port: opSettingsPort, path: '/api/init'))
        .timeout(const Duration(seconds: 3));
    if (r.statusCode == 200) {
      final j = jsonDecode(r.body);
      if (j is Map && j.containsKey('dp_dev_dashy')) {
        final off = j['isOffroad'];
        return (branch: CommaBranch.dp, offroad: off is bool ? off : null);
      }
    }
    return (branch: CommaBranch.unknown, offroad: null);
  } catch (e) {
    if (!_isConnectionRefused(e)) return (branch: CommaBranch.unknown, offroad: null);
  }
  // 主機在線但沒有 dashy → sunnypilot。webrtcd 有開時順便確認（失敗不影響判斷）
  try {
    final r = await get(Uri(scheme: 'http', host: host, port: 5001, path: '/schema',
        queryParameters: {'services': 'selfdriveStateSP'})).timeout(const Duration(seconds: 2));
    debugPrint('[opview] comma probe: :5001/schema selfdriveStateSP → ${r.statusCode}');
  } catch (_) {}
  return (branch: CommaBranch.sp, offroad: null);
}

bool _isConnectionRefused(Object e) {
  final t = e.toString();
  return t.contains('Connection refused') || t.contains('errno = 111');
}

Future<String?> _askHost(BuildContext context, String? initial) {
  final ctrl = TextEditingController(text: initial ?? '');
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('comma IP'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(hintText: '例如 192.168.43.100', helperText: '尚未找到 comma，請輸入 IP'),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('開啟')),
      ],
    ),
  );
}

/// 上次手動輸入的 comma IP（找不到 comma 時的備用）
Future<String?> loadManualCommaHost() async {
  try {
    final v = (await SharedPreferences.getInstance()).getString(_manualHostKey);
    return (v == null || v.isEmpty) ? null : v;
  } catch (_) {
    return null;
  }
}

/// 讓使用者輸入 comma IP 並記住；取消回傳 null
Future<String?> askCommaHost(BuildContext context, String? initial) async {
  final v = await _askHost(context, initial);
  if (v == null || v.isEmpty) return null;
  try { await (await SharedPreferences.getInstance()).setString(_manualHostKey, v); } catch (_) {}
  return v;
}

/// [host]：目前已知的 comma IP（可為 null）。[forceAsk]：一律讓使用者確認 / 修改 IP。
Future<void> openOpSettings(BuildContext context, String? host, {bool forceAsk = false}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  SharedPreferences? prefs;
  try { prefs = await SharedPreferences.getInstance(); } catch (_) {}
  var target = host ?? prefs?.getString(_manualHostKey);
  if (target == null || target.isEmpty || forceAsk) {
    if (!context.mounted) return;
    target = await _askHost(context, target);
    if (target == null || target.isEmpty) return;
    await prefs?.setString(_manualHostKey, target);
  }

  // 判斷分支（dp：comma 本機設定網頁；sp：sunnylink 雲端）＋ offroad／P 檔檢查
  final s = opSettingsGuardState;
  final live = hasLiveData(s);
  final probe = await probeComma(target);
  debugPrint('[opview] comma branch: ${probe.branch.name} (host $target, offroad ${probe.offroad})');
  final String? blocked;
  final String url;
  switch (probe.branch) {
    case CommaBranch.dp:
      blocked = decideOpSettings(s, live ? null : probe.offroad);
      url = Uri(scheme: 'http', host: target, port: opSettingsPort).toString();
    case CommaBranch.sp:
      // sunnypilot 沒有本機 offroad 查詢介面；opview 有即時資料時照樣擋行駛中，
      // 沒有即時資料時放行（sunnylink 是雲端網頁，comma 有回應代表已連上同一網路）
      blocked = live ? decideOpSettings(s, null) : null;
      url = sunnylinkUrl;
    case CommaBranch.unknown:
      blocked = opSettingsNotConnected;
      url = '';
  }
  final msg = blocked;
  if (msg != null) {
    debugPrint('[opview] OP settings blocked: branch=${probe.branch.name} connected=$live '
        'started=${s?.started} gear=${s?.gearShifter} offroad=${probe.offroad} host=$target');
    if (!context.mounted) return;
    await showDialog<void>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('裝置設定'),
      content: Text(msg),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('確定'))],
    ));
    return;
  }

  debugPrint('[opview] open OP settings $url');
  final ok = await system.openUrl(url);
  if (!ok) messenger?.showSnackBar(SnackBar(content: Text('無法開啟瀏覽器：$url')));
}
