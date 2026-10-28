// 傳輸延遲記錄（log 用）
//
// ■ 資料延遲（data channel）
//   webrtcd 送出的每筆訊息帶 comma 的 logMonoTime（comma 開機起算的單調時鐘，ns）。
//   手機收到時記下手機的單調時鐘，兩者相減 = 「實際延遲 + 兩台時鐘的固定差」。
//   兩台時鐘沒有對時，所以算不出絕對延遲；改取最近 60 秒內最小的差值當基準（= 最順的那一筆），
//   每筆訊息比基準多出來的時間就是「額外延遲」（排隊、Wi-Fi 重傳、comma 端忙碌造成）。
//   單調時鐘的漂移在 60 秒內是微秒等級，可忽略。
//   另外記錄訊息到達的最大間隔（gap）：comma 端卡住或網路斷續時會變大。
//
// ■ 影像延遲（WebRTC inbound-rtp 統計，見 ConnectionManager）
//   jitter buffer 平均等待 + 平均解碼時間 + RTT/2 ≈ 手機端可量到的影像延遲（不含 comma 編碼與送出前的排隊）。

class LatencyTracker {
  static const window = Duration(seconds: 10);
  static const baselineWindows = 6; // 基準取最近 6 個視窗（60 秒）的最小值

  final Stopwatch _clock;
  final List<int> _deltasUs = [];        // 本視窗：手機時間 − comma 時間（µs）
  final List<int> _recentMinsUs = [];    // 前幾個視窗的最小差值
  int? _lastArrivalUs;
  int _maxGapUs = 0;

  LatencyTracker({Stopwatch? clock}) : _clock = clock ?? (Stopwatch()..start());

  int get nowUs => _clock.elapsedMicroseconds;

  void reset() {
    _deltasUs.clear();
    _recentMinsUs.clear();
    _lastArrivalUs = null;
    _maxGapUs = 0;
  }

  /// [commaMonoNs]：訊息的 logMonoTime；[arrivalUs]：手機收到時間（預設現在，測試可指定）
  void onMessage(int commaMonoNs, {int? arrivalUs}) {
    final t = arrivalUs ?? nowUs;
    _deltasUs.add(t - commaMonoNs ~/ 1000);
    final last = _lastArrivalUs;
    if (last != null && t - last > _maxGapUs) _maxGapUs = t - last;
    _lastArrivalUs = t;
  }

  /// 結束本視窗並回傳統計；本視窗沒有訊息回傳 null
  DataLatency? takeWindow() {
    if (_deltasUs.isEmpty) {
      _maxGapUs = 0;
      return null;
    }
    final curMin = _deltasUs.reduce((a, b) => a < b ? a : b);
    var baseline = curMin;
    for (final m in _recentMinsUs) {
      if (m < baseline) baseline = m;
    }
    final excess = _deltasUs.map((d) => d - baseline).toList()..sort();
    final sum = excess.fold<int>(0, (a, b) => a + b);
    final p95 = excess[((excess.length - 1) * .95).round()];
    final result = DataLatency(
      count: excess.length,
      avgMs: sum / excess.length / 1000,
      p95Ms: p95 / 1000,
      maxMs: excess.last / 1000,
      maxGapMs: _maxGapUs / 1000,
    );
    _recentMinsUs.add(curMin);
    if (_recentMinsUs.length > baselineWindows - 1) _recentMinsUs.removeAt(0);
    _deltasUs.clear();
    _maxGapUs = 0;
    return result;
  }
}

class DataLatency {
  final int count;
  final double avgMs, p95Ms, maxMs, maxGapMs;
  const DataLatency({required this.count, required this.avgMs, required this.p95Ms,
    required this.maxMs, required this.maxGapMs});

  @override
  String toString() => 'data +${avgMs.toStringAsFixed(0)}ms avg / +${p95Ms.toStringAsFixed(0)} p95'
      ' / +${maxMs.toStringAsFixed(0)} max (n=$count), gap max ${maxGapMs.toStringAsFixed(0)}ms';
}
