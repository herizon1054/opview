import 'dart:async';
import 'dart:convert';

/// Only short-term throttling remains; no daily or monthly budget/cap.
class ParkingGateError implements Exception {
  final String message;
  ParkingGateError(this.message);
  @override
  String toString() => message;
}

class ParkingRequestGate {
  final Future<String?> Function() read;
  final Future<void> Function(String) write;
  final DateTime Function() clock;
  Future<void> _queue = Future<void>.value();
  Map<String, dynamic>? _state;
  ParkingRequestGate({
    required this.read,
    required this.write,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;
  Future<T> _serial<T>(Future<T> Function() action) {
    final f = _queue.then((_) => action());
    _queue = f.then<void>((_) {}, onError: (Object e, StackTrace s) {});
    return f;
  }

  Future<Map<String, dynamic>> _load() async {
    if (_state != null) return Map<String, dynamic>.from(_state!);
    final raw = await read();
    if (raw == null)
      return _state = {'requests': <int>[], 'clickUntil': 0, 'blockedUntil': 0};
    try {
      final s = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      if (s['requests'] is! List ||
          (s['requests'] as List).any((e) => e is! int) ||
          s['clickUntil'] is! int ||
          s['blockedUntil'] is! int)
        throw const FormatException();
      _state = s;
      return Map<String, dynamic>.from(s);
    } catch (_) {
      throw ParkingGateError('查詢冷卻紀錄無法讀取，請檢查手機儲存');
    }
  }

  Future<void> _save(Map<String, dynamic> s) async {
    await write(jsonEncode(s));
    _state = s;
  }

  int _remaining(int until) => ((until - clock().millisecondsSinceEpoch) / 1000)
      .ceil()
      .clamp(0, 2147483647);
  /// Milliseconds until [slots] requests fit in the rolling 5/minute window.
  /// Read-only: never reserves a slot.
  int _dataWait(Map<String, dynamic> s, int slots, int now) {
    if (slots <= 0) return 0;
    if (slots > 5) slots = 5;
    final times =
        (s['requests'] as List)
            .cast<int>()
            .where((t) => now - t < 60000)
            .toList()
          ..sort();
    final excess = times.length + slots - 5;
    if (excess <= 0) return 0;
    // The oldest `excess` requests must leave the window first.
    return (times[excess - 1] + 60001 - now).clamp(1, 86400000);
  }

  /// Seconds before a manual query may start. [dataSlots] also waits until
  /// that many live requests fit in the shared 5/minute window, so a query
  /// right after a large static download is not wasted on local throttling.
  Future<int> remaining({int dataSlots = 0}) => _serial(() async {
    final s = await _load(), now = clock().millisecondsSinceEpoch;
    final until = (s['clickUntil'] as int) > (s['blockedUntil'] as int)
        ? s['clickUntil'] as int
        : s['blockedUntil'] as int;
    final data = _dataWait(s, dataSlots, now);
    return _remaining(until > now + data ? until : now + data);
  });
  Future<void> beginClick() => _serial(() async {
    final s = await _load(), now = clock().millisecondsSinceEpoch;
    final until = (s['clickUntil'] as int) > (s['blockedUntil'] as int)
        ? s['clickUntil'] as int
        : s['blockedUntil'] as int;
    if (now < until) throw ParkingGateError('請等待 ${_remaining(until)} 秒再查詢');
    s['clickUntil'] = now + 30000;
    await _save(s);
  });

  /// Returns required delay without reserving if the rolling window is full.
  /// Static downloads and live requests share the same 5/minute local gate.
  Future<int> reserveData() => _serial(() async {
    final s = await _load(), now = clock().millisecondsSinceEpoch;
    if (now < (s['blockedUntil'] as int))
      return (s['blockedUntil'] as int) - now;
    final times =
        (s['requests'] as List)
            .cast<int>()
            .where((t) => now - t < 60000)
            .toList()
          ..sort();
    if (times.length >= 5)
      return (times.first + 60001 - now).clamp(1, 86400000);
    times.add(now);
    s['requests'] = times;
    await _save(s);
    return 0;
  });
  Future<void> blockFor(Duration duration) => _serial(() async {
    final s = await _load();
    final until = clock().add(duration).millisecondsSinceEpoch;
    if (until > (s['blockedUntil'] as int)) s['blockedUntil'] = until;
    await _save(s);
  });
}
