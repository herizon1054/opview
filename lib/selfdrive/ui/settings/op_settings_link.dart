// 開啟 comma 上的 OP 設定網頁（dragonpilot dashy serverd，http://<comma IP>:5088）
//
// serverd 在 dp0111pre 是 always_run：offroad 也能開，可用來打開「啟用 opview」等設定。
// IP 來源：目前連線 / mDNS 找到 / 快取的 comma IP；都沒有時讓使用者手動輸入（記住供下次使用）。

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:opview/services/viewer_system.dart' as system;

const opSettingsPort = 5088;
const _manualHostKey = 'op_settings_manual_host';

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
  final url = 'http://$target:$opSettingsPort';
  debugPrint('[opview] open OP settings $url');
  final ok = await system.openUrl(url);
  if (!ok) messenger?.showSnackBar(SnackBar(content: Text('無法開啟瀏覽器：$url')));
}
