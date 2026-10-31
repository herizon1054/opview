// opview 持久化 log（可分享）
//
// - 攔截所有 debugPrint（連線狀態列、mDNS、網段掃描、WebRTC 等都經由 debugPrint 輸出）
//   以及 Flutter / 平台未捕捉例外，加上時間戳寫入 App 私有目錄的 opview.log
// - 單檔超過 1 MB 輪替成 opview.log.1（最多保留約 2 MB）
// - 只保留最近 3 天：啟動時、每 6 小時、匯出前刪掉 3 天前的行（依每行開頭的時間戳；
//   沒有時間戳的行，例如 codec / app / 例外堆疊，跟著前一個有時間戳的行一起保留或刪除）
//   「下載/opview/」裡分享過的舊檔也只留 3 天內的（MainActivity.shareLog）
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
const logRetention = Duration(days: 3);

final _lineTsRe = RegExp(r'^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})');
final _startTsRe = RegExp(r'opview start (\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})');

DateTime? _lineTime(String line) {
  final m = _lineTsRe.firstMatch(line) ?? _startTsRe.firstMatch(line);
  if (m == null) return null;
  int g(int i) => int.parse(m.group(i)!);
  return DateTime(g(1), g(2), g(3), g(4), g(5), g(6));
}

/// 刪掉 [cutoff] 之前的行；沒有時間戳的行跟著前一個有時間戳的行走
/// （檔案開頭沒有時間戳的行，跟著第一個有時間戳的行走）。回傳保留的行。
@visibleForTesting
List<String> pruneLogLines(List<String> lines, DateTime cutoff) {
  final out = <String>[];
  final leading = <String>[];
  bool? keep;
  for (final l in lines) {
    final t = _lineTime(l);
    if (t != null) {
      final k = !t.isBefore(cutoff);
      if (keep == null && k) out.addAll(leading);
      keep = k;
    } else if (keep == null) {
      leading.add(l);
      continue;
    }
    if (keep) out.add(l);
  }
  return out;
}

class AppLog {
  AppLog._();
  static final AppLog instance = AppLog._();

  File? _file;
  final List<String> _pending = []; // init 完成前先暫存
  int _writesSinceCheck = 0;
  DebugPrintCallback? _origDebugPrint;
  Timer? _pruneTimer;

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
      _pruneOld();
      _pruneTimer ??= Timer.periodic(const Duration(hours: 6), (_) => _pruneOld());
      final info = await _channel.invokeMapMethod<String, dynamic>('info') ?? const {};
      _writeRaw('\n========== opview start ${_ts()} ==========');
      _writeRaw('app ${info['version'] ?? '?'} (${info['build'] ?? '?'}) · '
          '${info['manufacturer'] ?? '?'} ${info['model'] ?? '?'} · Android ${info['release'] ?? '?'} (SDK ${info['sdk'] ?? '?'})');
      for (final l in _pending) {
        _writeRaw(l);
      }
      _pending.clear();
      // 上次程式怎麼結束的（閃退 / ANR / 被系統回收…），見 MainActivity.lastExitReport
      try {
        final exits = await _channel.invokeListMethod<String>('lastExit');
        for (final l in exits ?? const <String>[]) {
          _writeRaw(l);
        }
      } catch (e) {
        _writeRaw('prev exit 查詢失敗：$e');
      }
      // H.264 解碼器能力：c2.qti 若不支援 1928×1208，WebRTC 會退回軟體解碼（每幀約 120 ms）
      try {
        final codecs = await _channel.invokeListMethod<String>('codecs', {'width': 1928, 'height': 1208});
        for (final c in codecs ?? const <String>[]) {
          _writeRaw('codec $c');
        }
      } catch (e) {
        _writeRaw('codec 查詢失敗：$e');
      }
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

  /// 只保留最近 3 天（見檔頭說明）
  void _pruneOld() {
    final f = _file;
    if (f == null) return;
    final cutoff = DateTime.now().subtract(logRetention);
    for (final p in ['${f.path}.1', f.path]) {
      final x = File(p);
      try {
        if (!x.existsSync()) continue;
        if (x.lastModifiedSync().isBefore(cutoff)) { x.deleteSync(); continue; } // 整檔都是 3 天前
        final lines = x.readAsLinesSync();
        final kept = pruneLogLines(lines, cutoff);
        if (kept.length != lines.length) {
          x.writeAsStringSync(kept.isEmpty ? '' : '${kept.join('\n')}\n', flush: true);
        }
      } catch (_) {
        // best-effort
      }
    }
  }

  /// 合併 opview.log.1 + opview.log 成分享用檔案，回傳路徑
  Future<String?> export() async {
    final f = _file;
    if (f == null) return null;
    _pruneOld();
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
