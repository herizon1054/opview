// LINE 通知 → opview 直向畫面下方第三層（顯示 30 秒）
//
// Android：OpviewNotificationListener（NotificationListenerService）讀 LINE（jp.naver.line.android）的通知，
// 經 EventChannel 'org.dragonpilot.opview/line' 傳到這裡。需要使用者在系統「通知存取權」授權 opview。
// 訊息只放在記憶體，30 秒後移除；不寫 log（log 只記「收到幾則」）。

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _events = EventChannel('org.dragonpilot.opview/line');
const _system = MethodChannel('org.dragonpilot.opview/system');

class LineMessage {
  final String sender; // 寄件者；群組時為「群組 · 寄件者」
  final String text;
  final DateTime at;   // opview 收到的時間（到期計算用）
  const LineMessage(this.sender, this.text, this.at);
}

class LineNotifications extends ChangeNotifier {
  LineNotifications._();
  static final LineNotifications instance = LineNotifications._();

  static const showFor = Duration(seconds: 30);
  static const _maxKept = 6;

  final List<LineMessage> _messages = []; // 新的在前
  StreamSubscription<dynamic>? _sub;
  Timer? _expireTimer;
  bool _enabled = false;
  DateTime Function() now = DateTime.now; // 測試可替換

  bool get enabled => _enabled;
  /// 尚未過期的訊息（新的在前）
  List<LineMessage> get messages => List.unmodifiable(_messages);

  /// 開啟 / 關閉接收（顯示設定「顯示 LINE 通知」）
  void setEnabled(bool on) {
    if (on == _enabled) return;
    _enabled = on;
    if (on) {
      try {
        _sub = _events.receiveBroadcastStream().listen(_onEvent,
            onError: (Object e) => debugPrint('[opview] LINE 通知接收錯誤：$e'));
      } on MissingPluginException {
        // 非 Android（測試）
      }
    } else {
      _sub?.cancel();
      _sub = null;
      _clear();
    }
  }

  void _onEvent(dynamic e) {
    if (e is! Map) return;
    final title = (e['title'] as String? ?? '').trim();
    final text = (e['text'] as String? ?? '').trim();
    final conv = (e['conversation'] as String?)?.trim();
    final sender = conv != null && conv.isNotEmpty && conv != title ? '$conv · $title' : title;
    add(sender, text);
  }

  @visibleForTesting
  void add(String sender, String text) {
    if (text.isEmpty) return;
    final t = now();
    // LINE 會為同一則訊息更新通知（例如已讀、合併）：2 秒內同寄件者同內容視為同一則
    if (_messages.isNotEmpty) {
      final last = _messages.first;
      if (last.sender == sender && last.text == text && t.difference(last.at).inSeconds < 2) return;
    }
    _messages.insert(0, LineMessage(sender, text, t));
    if (_messages.length > _maxKept) _messages.removeRange(_maxKept, _messages.length);
    debugPrint('[opview] LINE 通知 +1（顯示中 ${_messages.length} 則）'); // 不記錄內容
    _scheduleExpire();
    notifyListeners();
  }

  void _scheduleExpire() {
    _expireTimer?.cancel();
    if (_messages.isEmpty) return;
    final oldest = _messages.last.at;
    var wait = oldest.add(showFor).difference(now());
    if (wait.isNegative) wait = Duration.zero;
    _expireTimer = Timer(wait + const Duration(milliseconds: 50), expire);
  }

  @visibleForTesting
  void expire() {
    final cutoff = now().subtract(showFor);
    final before = _messages.length;
    _messages.removeWhere((m) => !m.at.isAfter(cutoff));
    if (_messages.length != before) notifyListeners();
    _scheduleExpire();
  }

  @visibleForTesting
  void clear() => _clear();

  void _clear() {
    _expireTimer?.cancel();
    if (_messages.isEmpty) return;
    _messages.clear();
    notifyListeners();
  }
}

/// 是否已授權「通知存取權」
Future<bool> hasNotificationAccess() async {
  try { return await _system.invokeMethod<bool>('notificationAccess') ?? false; }
  on PlatformException { return false; }
  on MissingPluginException { return false; }
}

/// 開啟系統「通知存取權」設定頁
Future<bool> openNotificationAccessSettings() async {
  try { return await _system.invokeMethod<bool>('openNotificationAccess') ?? false; }
  on PlatformException { return false; }
  on MissingPluginException { return false; }
}
