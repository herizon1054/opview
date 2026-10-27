// opview 持久化 log（可分享）
//
// - 攔截所有 debugPrint（連線狀態列、mDNS、網段掃描、WebRTC 等都經由 debugPrint 輸出）
//   以及 Flutter / 平台未捕捉例外，加上時間戳寫入 App 私有目錄的 opview.log
// - 單檔超過 1 MB 輪替成 opview.log.1（最多保留約 2 MB）
// - 分享：合併兩個檔 → Android 存到「下載/opview/」並開啟系統分享選單（LINE、Messenger、Email…）
//   Android 9 以下沒有 MediaStore Downloads，改分享最後 100 KB 文字
//
// 只記錄連線與資料統計，不記錄定位等個資。

import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('org.dragonpilot.opview/log');
const _maxFileBytes = 1024 * 1024;

class AppLog {
  AppLog._();
  static final AppLog instance = AppLog._();

  File? _file;
  final List<String> _pending = []; // init 完成前先暫存
  int _writesSinceCheck = 0;
  DebugPrintCallback? _origDebugPrint;

  /// 在 main() 最前面呼叫：攔截 debugPrint 與未捕捉例外
  void install() {
    if (_origDebugPrint != null) return;
    _origDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      _origDebugPrint!(message, wrapWidth: wrapWidth);
      if (message != null) add(message);
    };
    final prevFlutterError = FlutterError.onError;
    FlutterError.onError = (details) {
      add('[error] ${details.exceptionAsString()}\n${details.stack ?? ''}');
      prevFlutterError?.call(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      add('[error] uncaught: $error\n$stack');
      return false; // 交回預設處理
    };
  }

  /// 取得 App 私有目錄、寫入啟動資訊
  Future<void> init() async {
    try {
      final dir = await _channel.invokeMethod<String>('dir');
      if (dir == null) return;
      _file = File('$dir/opview.log');
      final info = await _channel.invokeMapMethod<String, dynamic>('info') ?? const {};
      _writeRaw('\n========== opview start ${_ts()} ==========');
      _writeRaw('app ${info['version'] ?? '?'} (${info['build'] ?? '?'}) · '
          '${info['manufacturer'] ?? '?'} ${info['model'] ?? '?'} · Android ${info['release'] ?? '?'} (SDK ${info['sdk'] ?? '?'})');
      for (final l in _pending) {
        _writeRaw(l);
      }
      _pending.clear();
    } on MissingPluginException {
      // 非 Android（測試 / iOS）：只保留 debugPrint
    } on PlatformException {
      // best-effort
    }
  }

  String _ts() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final ms = n.millisecond.toString().padLeft(3, '0');
    return '${n.year}-${two(n.month)}-${two(n.day)} ${two(n.hour)}:${two(n.minute)}:${two(n.second)}.$ms';
  }

  void add(String message) {
    final line = '${_ts()} $message';
    if (_file == null) {
      if (_pending.length < 500) _pending.add(line);
      return;
    }
    _writeRaw(line);
  }

  void _writeRaw(String line) {
    final f = _file;
    if (f == null) return;
    try {
      f.writeAsStringSync('$line\n', mode: FileMode.append, flush: false);
      if (++_writesSinceCheck >= 50) {
        _writesSinceCheck = 0;
        if (f.existsSync() && f.lengthSync() > _maxFileBytes) {
          final old = File('${f.path}.1');
          if (old.existsSync()) old.deleteSync();
          f.renameSync(old.path);
        }
      }
    } catch (_) {
      // 磁碟滿 / 權限：放棄這行，不影響 App
    }
  }

  /// 合併 opview.log.1 + opview.log 成分享用檔案，回傳路徑
  Future<String?> export() async {
    final f = _file;
    if (f == null) return null;
    final out = File('${f.parent.path}/opview-log-${_stamp()}.txt');
    final sink = out.openWrite();
    for (final p in ['${f.path}.1', f.path]) {
      final src = File(p);
      if (await src.exists()) await sink.addStream(src.openRead());
    }
    await sink.close();
    // 清掉舊的匯出檔，只留這一份
    for (final e in f.parent.listSync()) {
      if (e is File && e.path != out.path && e.path.contains('opview-log-')) {
        try { e.deleteSync(); } catch (_) {}
      }
    }
    return out.path;
  }

  String _stamp() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}${two(n.month)}${two(n.day)}-${two(n.hour)}${two(n.minute)}${two(n.second)}';
  }

  /// 匯出並開啟系統分享；回傳給使用者看的結果文字
  Future<String> share() async {
    add('[opview] log shared');
    final path = await export();
    if (path == null) return '此平台不支援 log 檔';
    try {
      final r = await _channel.invokeMethod<String>('share', path) ?? 'error';
      if (r.startsWith('ok:')) return '已存到 ${r.substring(3)}，並開啟分享';
      if (r == 'text') return '已用文字分享（Android 9 以下只含最後 100 KB）';
      return '分享失敗：$r';
    } on PlatformException catch (e) {
      return '分享失敗：${e.message}';
    } on MissingPluginException {
      return '此平台不支援分享';
    }
  }

  /// 清除 log 檔
  Future<void> clear() async {
    final f = _file;
    if (f == null) return;
    for (final p in [f.path, '${f.path}.1']) {
      final x = File(p);
      if (await x.exists()) await x.delete();
    }
    add('[opview] log cleared');
  }
}
