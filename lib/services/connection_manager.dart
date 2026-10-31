// connection manager — the orchestrator
// discover → connect → parse → apply to UIState
//
// one class ties it all together:
//   1. discover comma device via mDNS
//   2. connect WebRTC (video + data channel)
//   3. parse incoming telemetry via adapter
//   4. dispatch to UIState
//   5. reconnect on failure

import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/discovery.dart';
import 'package:opview/services/transport.dart';
import 'package:opview/services/latency_tracker.dart';
import 'package:opview/services/tdx_support.dart';
import 'package:opview/system/webrtc/webrtcd_api.dart' show hostSupportsOptionalServices;
import 'package:opview/services/adapter.dart';
import 'package:opview/services/impl/mdns_discovery.dart';
import 'package:opview/services/impl/subnet_scan_discovery.dart';
import 'package:opview/services/impl/webrtc_transport.dart';
import 'package:opview/services/impl/cereal_adapter.dart';
import 'package:opview/services/wake_lock_service.dart' as wake_lock;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

// retry config
const _retryDelay = Duration(seconds: 2);

// signaling（POST /stream）成功後，等 WebRTC 真正連通（ICE/DTLS）的上限
const _mediaConnectTimeout = Duration(seconds: 12);

// WebRTC 進入 disconnected 後的寬限時間（常會自行恢復），逾時才重連
const _disconnectGrace = Duration(seconds: 5);

// 影像卡住偵測（實測：封包照收、lost=0，但每秒只解出不到 1 幀、其餘被丟棄，畫面停在舊影像 / 綠畫面；
// 報告指出背景／前景重連後恢復；本版重建 PeerConnection 與 renderer）。每 5 秒取一次統計：
//   收到封包 ≥ 100（資料有在流）但解碼 < 5 fps → 記一次；連續 2 次（約 10 秒）就重建影像連線。
// 為避免無限重連，2 分鐘內最多自動重建 3 次。
const _statsInterval = Duration(seconds: 5);
const _stallMinPackets = 100;
const _stallMaxFps = 5.0;
const _stallWindows = 2;
const _stallMaxRecoveries = 3;
const _stallRecoveryWindow = Duration(minutes: 2);

// delay before re-discovery after all retries exhausted
const _rediscoverDelay = Duration(seconds: 15);

// SharedPreferences key for cached host
const _cachedHostKey = 'last_known_host';

// camera switching thresholds (augmented_road_view.py:29-30)
const wideCamMaxSpeed = 10.0;  // m/s — switch to wide below this
const roadCamMinSpeed = 15.0;  // m/s — switch to road above this

class ConnectionManager {
  final UIState _uiState;
  final Discovery _discovery;
  final Transport _transport;
  final TelemetryAdapter _adapter;

  dynamic get videoRenderer => _transport.videoRenderer;
  Listenable get rendererChanges => _transport.rendererChanges;
  bool _replaced = false;
  bool _switchingCamera = false;
  bool _statsBusy = false;

  ConnectionManager(
    this._uiState, {
    Discovery? discovery,
    Transport? transport,
    TelemetryAdapter? adapter,
  })  : // mDNS 為主；手機開熱點時 mDNS 常失效，3 秒後同時掃描本機各介面 /24 的 port 5001 作為備援
        _discovery = discovery ?? CompositeDiscovery([MdnsDiscovery(), SubnetScanDiscovery()]),
        _transport = transport ?? WebRTCTransport(),
        _adapter = adapter ?? CerealAdapter();

  String? _host;
  String? _lastKnownHost; // 最近一次找到 / 嘗試的 comma IP（OP 設定網頁用，連線失敗也保留）

  /// 目前或最近一次已知的 comma IP
  String? get lastKnownHost => _host ?? _lastKnownHost;

  // 主畫面只需要找到 comma（車型讀寫走 :5088），不建立 WebRTC；進入 opview 畫面才連 webrtcd。
  // 預設關閉，由 app 依目前畫面呼叫 setStreaming()。
  bool _streamingWanted = false;
  bool get streamingWanted => _streamingWanted;

  /// true = opview 畫面（建立 WebRTC 串流）；false = 主畫面（只搜尋 comma、記住 IP，斷開 WebRTC）
  void setStreaming(bool on) {
    if (_streamingWanted == on) return;
    _streamingWanted = on;
    debugPrint('[opview] streaming ${on ? 'on（opview 畫面，連線 webrtcd）' : 'off（主畫面只找 comma，不建立 WebRTC）'}');
    if (on) {
      if (_paused || _replaced) return;
      _retryCount = 0;
      if (_host != null) {
        _connect();
      } else {
        _host = _lastKnownHost;
        if (_host != null) _connect();
        _startDiscovery(); // IP 可能變了：同時重新搜尋
      }
    } else {
      final host = _host ?? _lastKnownHost;
      _teardown();
      _retryCount = 0;
      _host = host;
    }
  }

  /// 主畫面讀不到 comma 時呼叫：重新搜尋 comma（IP 可能變了），不建立 WebRTC
  void refreshHost() {
    if (_paused || _replaced || _uiState.isConnected || _connecting) return;
    _startDiscovery();
  }
  StreamSubscription? _deviceSub;
  StreamSubscription? _dataSub;
  StreamSubscription? _stateSub;
  Timer? _retryTimer;
  final _connectivity = Connectivity();
  StreamSubscription? _connectivitySub;
  bool _hadWifi = false;
  bool _connecting = false;
  bool _paused = false;
  bool _discovering = false;   // guard against duplicate _startDiscovery() (start() + connectivity race)
  bool _reconnecting = false;  // guard against re-entrant _scheduleReconnect
  int _connectEpoch = 0;       // invalidate stale in-flight connects
  int _retryCount = 0;
  static const _maxRetries = 3;
  String _streamType = 'road';

  // log：每 10 秒記錄各 service 收到的訊息數（判斷資料有沒有進來、tdx 有沒有在發）
  static final _typeRe = RegExp(r'"type":\s*"(\w+)"');
  // webrtcd 每筆訊息開頭為 {"type": "...", "logMonoTime": N, ...}（巢狀的 type 不會緊接 logMonoTime）
  // webrtcd 控制訊息：開頭即 {"type": "connectionReplaced" | "clockSync" | "disconnect"}
  static final _controlRe = RegExp(r'^\s*\{\s*"type"\s*:\s*"(connectionReplaced|clockSync|disconnect)"');
  static final _monoRe = RegExp(r'"type":\s*"\w+",\s*"logMonoTime":\s*(\d+)');
  final LatencyTracker _latency = LatencyTracker();
  // 合併處理：同一種 service 只留最新一筆，等事件佇列清空後一次套用（modelV2 最後套用，觸發重畫）。
  // 手機一時處理不完時（解碼 JSON + 畫面），舊訊息不會排隊一筆一筆慢慢畫，畫面永遠是最新狀態。
  static final _wholeMsgRe = RegExp(r'^\s*\{\s*"type":\s*"(\w+)",\s*"logMonoTime"');
  final Map<String, String> _pendingMsgs = {};
  bool _flushScheduled = false;
  int _pendingEpoch = 0;
  int _coalesced = 0;
  bool _lagLogged = false;
  VideoCounters? _prevVideoLog;
  final Map<String, int> _rxCounts = {};
  Timer? _statsTimer;
  Timer? _graceTimer;

  /// update status line shown on the connecting overlay
  void _setStatus(String msg) {
    final now = DateTime.now();
    final ts = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
    debugPrint('[opview] $msg');
    _uiState.addConnectionStatus('[$ts] $msg');
    if (!_uiState.isConnected) _uiState.notifyNow();
  }

  /// start discovery + auto-connect + network monitoring
  /// tries cached host first for fast reconnect, mDNS in parallel as fallback
  void start() async {
    if (_replaced || _paused) return;
    _listenConnectivity();
    _logNetwork();

    var cachedHost = await _loadCachedHost();
    // IPv6 link-local（fe80::…%wlan0）不能跨重開機沿用，也有部分 HTTP 用戶端不支援：不使用
    if (cachedHost != null && cachedHost.contains('%')) cachedHost = null;
    if (cachedHost != null) _lastKnownHost ??= cachedHost;
    final sameSubnet = cachedHost != null && await _isOnSameSubnet(cachedHost);
    if (_paused || _replaced) return;
    if (cachedHost != null && sameSubnet) {
      _setStatus('trying cached host $cachedHost');
      _host = cachedHost;
      _startDiscovery(); // mDNS in parallel as fallback
      _connect();
    } else {
      if (cachedHost != null) {
        _setStatus('cached host $cachedHost on different subnet, skipping');
      }
      _setStatus('searching for comma device…');
      _startDiscovery();
    }
  }

  /// monitor WiFi state — restart discovery when WiFi connects
  void _listenConnectivity() {
    _connectivitySub?.cancel();
    _connectivitySub = _connectivity.onConnectivityChanged.listen((result) {
      final hasWifi = result.contains(ConnectivityResult.wifi);
      debugPrint('[opview] connectivity: ${result.map((r) => r.name).join(',')}');
      if (hasWifi && !_hadWifi) {
        _setStatus('WiFi connected, searching…');
        _logNetwork();
        _hadWifi = true;
        if (_host == null && !_paused) {
          _startDiscovery();
        }
      } else if (!hasWifi && _hadWifi) {
        _hadWifi = false;
      }
    });
  }

  Future<void> _startDiscovery() async {
    if (_discovering || _paused || _replaced) return; // already searching — avoid duplicate mDNS sessions
    _discovering = true;
    _deviceSub?.cancel();
    _deviceSub = _discovery.devices.listen(_onDeviceFound);
    await _discovery.start();
  }

  void _stopDiscovery() {
    if (!_discovering) return;
    _discovering = false;
    _discovery.stop();
  }

  /// first device found → connect (or update host if cached attempt is still in-flight)
  void _onDeviceFound(DiscoveredDevice device) {
    if (_replaced || _paused || _uiState.isConnected) return; // already connected via cached host
    _host = device.host;
    _lastKnownHost = device.host;
    _setStatus('found ${device.displayName} at ${device.host}');
    _stopDiscovery();
    if (!_connecting) _connect();
  }

  Future<void> _connect() async {
    if (_connecting || _host == null || _paused || _replaced || !_streamingWanted) return;
    _connecting = true;
    _reconnecting = false;
    final epoch = ++_connectEpoch;

    // cancel stale listeners before attempting new connection
    _stateSub?.cancel();
    _stateSub = null;

    try {
      _setStatus('connecting to $_host (camera: $_streamType)');
      _listenData(); // receive connectionReplaced even while signaling is finishing
      await _transport.connect(_host!, camera: _streamType);
      if (epoch != _connectEpoch) return; // superseded by newer connect
      // signaling 成功不代表影像/資料通道通了：等 WebRTC 真正 connected 才算連線
      _setStatus('signaling ok, waiting for WebRTC media path…');
      final ok = await _waitMediaConnected(_mediaConnectTimeout);
      if (epoch != _connectEpoch) return;
      if (!ok) {
        _setStatus('WebRTC failed: no media path to $_host '
            '(state ${_transport.currentState.name}, ${_mediaConnectTimeout.inSeconds}s)');
        _scheduleReconnect();
        return;
      }
      _retryCount = 0;
      final tdx = hostSupportsOptionalServices(_host!);
      if (tdx != null && tdx != tdxSupport.value) {
        debugPrint('[opview] TDX: ${tdx ? '分支支援 tdx' : tdxUnsupportedText}');
      }
      tdxSupport.value = tdx;
      _listenState();
      _setConnected(true);
      _startStats();
      _stopDiscovery(); // connected — stop any parallel mDNS
      _saveCachedHost(_host!);
      _setStatus('connected');
    } catch (e) {
      if (epoch != _connectEpoch) return; // superseded, don't reconnect
      _setStatus('connection failed: $e');
      _scheduleReconnect();
    } finally {
      if (epoch == _connectEpoch) _connecting = false;
    }
  }

  Future<bool> _waitMediaConnected(Duration timeout) async {
    if (_transport.currentState == TransportState.connected) return true;
    if (_transport.currentState == TransportState.failed) return false;
    final done = Completer<bool>();
    final sub = _transport.stateStream.listen((s) {
      if (done.isCompleted) return;
      if (s == TransportState.connected) done.complete(true);
      if (s == TransportState.failed) done.complete(false);
    });
    try {
      // 訂閱前就已經變化的情況
      if (_transport.currentState == TransportState.connected) return true;
      return await done.future.timeout(timeout, onTimeout: () => false);
    } finally {
      await sub.cancel();
    }
  }

  /// 本機網路介面快照（熱點 / WiFi 網段判斷用）
  Future<void> _logNetwork() async {
    try {
      final ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
      final desc = ifaces.map((i) => '${i.name}=${i.addresses.map((a) => a.address).join('/')}').join(', ');
      debugPrint('[opview] net: ${desc.isEmpty ? '(none)' : desc}');
    } catch (e) {
      debugPrint('[opview] net: list failed $e');
    }
  }

  VideoCounters? _prevVideo;
  final Stopwatch _videoClock = Stopwatch()..start();
  int? _prevVideoUs;
  int _stallCount = 0;
  final List<DateTime> _stallRecoveries = [];

  void _startStats() {
    _statsTimer?.cancel();
    _rxCounts.clear();
    _prevVideo = null;
    _prevVideoLog = null;
    _latency.reset();
    _uiState.dataLagMs = 0;
    _lagLogged = false;
    _pendingMsgs.clear();
    _coalesced = 0;
    _stallCount = 0;
    var tick = 0;
    final epoch = _connectEpoch;
    _statsTimer = Timer.periodic(_statsInterval, (_) async {
      if (_statsBusy) return;
      _statsBusy = true;
      try {
        tick++;
        final logNow = tick.isEven; // log 維持每 10 秒一筆
        if (logNow) {
          final keys = _rxCounts.keys.toList()..sort();
          debugPrint('[opview] rx 10s: ${keys.isEmpty ? '(none)' : keys.map((k) => '$k=${_rxCounts[k]}').join(' ')}'
              '${_coalesced > 0 ? ' | 合併略過 $_coalesced 筆舊訊息（手機處理不及）' : ''}');
          _rxCounts.clear();
          _coalesced = 0;
        }
        final s = await _transport.statsSummary();
        if (epoch != _connectEpoch) return; // 期間已重連
        if (s != null && logNow) debugPrint('[opview] webrtc stats: $s');
        if (logNow) _logLatency(_transport.lastVideoCounters);
        _checkVideoStall(_transport.lastVideoCounters);
      } finally {
        _statsBusy = false;
      }
    });
  }

  /// 每 10 秒一筆傳輸延遲（說明見 latency_tracker.dart）：
  ///   latency 10s: data +平均/+p95/+最大（比 60 秒內最順的一筆多出的延遲）, gap 最大到達間隔 |
  ///   video jb 本視窗平均 jitter buffer 等待 + dec 平均解碼 + rtt/2 ≈ 手機端影像延遲
  void _logLatency(VideoCounters? v) {
    final data = _latency.takeWindow();
    String video = 'video (no stats)';
    final p = _prevVideoLog;
    if (v != null && p != null) {
      final dEmit = v.jitterEmitted - p.jitterEmitted;
      final dDec = v.framesDecoded - p.framesDecoded;
      final jb = dEmit > 0 ? (v.jitterDelaySec - p.jitterDelaySec) / dEmit * 1000 : null;
      final dec = dDec > 0 ? (v.decodeSec - p.decodeSec) / dDec * 1000 : null;
      final half = v.rttSec != null ? v.rttSec! * 500 : null;
      final total = (jb != null && dec != null) ? jb + dec + (half ?? 0) : null;
      String f(double? x) => x == null ? '?' : x.toStringAsFixed(0);
      video = 'video jb ${f(jb)}ms + dec ${f(dec)}ms + rtt/2 ${f(half)}ms ≈ ${f(total)}ms';
    }
    if (v != null) _prevVideoLog = v;
    // lag now：最新一筆比「整段連線最順的一筆」晚多少（上面 data +X 只跟最近 60 秒比，長時間積壓會被低估）
    debugPrint('[opview] latency 10s: ${data ?? 'data (none)'} | $video | lag now ${_latency.lastExcessMs}ms');
  }

  /// 影像卡住偵測：見檔案開頭 _stall* 常數說明
  void _checkVideoStall(VideoCounters? now) {
    final prev = _prevVideo;
    _prevVideo = now;
    final sampleUs = _videoClock.elapsedMicroseconds;
    final previousUs = _prevVideoUs;
    _prevVideoUs = sampleUs;
    if (now == null || prev == null || previousUs == null) return;
    final secs = (sampleUs - previousUs) / 1000000;
    if (secs <= 0) return;
    final dPkts = now.packets - prev.packets;
    final dDec = now.framesDecoded - prev.framesDecoded;
    if (dPkts < 0 || dDec < 0) {
      _stallCount = 0;
      return;
    }
    final fps = dDec / secs;
    if (dPkts < _stallMinPackets || fps >= _stallMaxFps) {
      _stallCount = 0;
      return;
    }
    _stallCount++;
    debugPrint('[opview] video stall? ${secs.toStringAsFixed(0)}s: pkts +$dPkts, decoded +$dDec '
        '(${fps.toStringAsFixed(1)} fps), received +${now.framesReceived - prev.framesReceived}, '
        'dropped +${now.framesDropped - prev.framesDropped} ($_stallCount/$_stallWindows)');
    if (_stallCount < _stallWindows) return;
    _stallCount = 0;

    final cutoff = DateTime.now().subtract(_stallRecoveryWindow);
    _stallRecoveries.removeWhere((t) => t.isBefore(cutoff));
    if (_stallRecoveries.length >= _stallMaxRecoveries) {
      debugPrint('[opview] video stalled, but already restarted $_stallMaxRecoveries times in '
          '${_stallRecoveryWindow.inMinutes} min — not restarting again');
      return;
    }
    _stallRecoveries.add(DateTime.now());
    _setStatus('video stalled (${fps.toStringAsFixed(1)} fps decoded) — restarting video stream');
    _teardown();
    _retryCount = 0;
    _connect();
  }

  void _stopStats() {
    _statsTimer?.cancel();
    _statsTimer = null;
  }

  /// listen to data channel → adapter → UIState
  void _listenData() {
    _dataSub?.cancel();
    _dataSub = _transport.dataStream.listen((chunk) {
      // 控制訊息（webrtcd 自己發的）只看開頭的 type 判斷，不做 jsonDecode；
      // 一般 cereal 訊息（modelV2 等，每秒約 100 筆）不再多解析一次，交給 adapter 處理。
      final control = _controlRe.firstMatch(chunk)?.group(1);
      if (control != null) {
        if (control == 'connectionReplaced') {
          _replaced = true;
          _stopDiscovery();
          _teardown();
          _setStatus('已由其他裝置接手，停止自動重連；返回前景不會搶回連線');
        }
        return; // clockSync / disconnect / connectionReplaced 都不是 cereal 資料
      }

      for (final m in _typeRe.allMatches(chunk)) {
        final t = m.group(1)!;
        _rxCounts[t] = (_rxCounts[t] ?? 0) + 1;
      }
      final arrival = _latency.nowUs;
      for (final m in _monoRe.allMatches(chunk)) {
        final mono = int.tryParse(m.group(1)!);
        if (mono != null) _latency.onMessage(mono, arrivalUs: arrival);
      }
      _uiState.dataLagMs = _latency.lastExcessMs;

      final type = _wholeMsgRe.firstMatch(chunk)?.group(1);
      if (type == null || chunk.contains('}{') || !chunk.trimRight().endsWith('}')) {
        // 不是單筆完整訊息（理論上不會發生）：照舊直接交給 adapter 拼接
        _flushPending();
        _adapter.apply(_uiState, chunk);
        _switchStreamIfNeeded();
        return;
      }
      if (_pendingMsgs.containsKey(type)) _coalesced++;
      _pendingMsgs[type] = chunk;
      if (!_flushScheduled) {
        _flushScheduled = true;
        _pendingEpoch = _connectEpoch;
        Timer.run(_flushPending);
      }
    });
  }

  void _flushPending() {
    _flushScheduled = false;
    if (_pendingMsgs.isEmpty) return;
    if (_pendingEpoch != _connectEpoch) {
      _pendingMsgs.clear(); // 期間已斷線 / 重連，丟掉舊連線的資料
      return;
    }
    final model = _pendingMsgs.remove('modelV2');
    for (final raw in _pendingMsgs.values) {
      _adapter.apply(_uiState, raw);
    }
    _pendingMsgs.clear();
    if (model != null) _adapter.apply(_uiState, model);
    _logLag();
    _switchStreamIfNeeded();
  }

  /// 資料延遲超過上限 / 恢復時各記一行（畫面同時改顯示「資料延遲」）
  void _logLag() {
    final lag = _uiState.dataLagMs;
    if (!_lagLogged && lag > UIState.dataLagLimitMs) {
      _lagLogged = true;
      debugPrint('[opview] data lag ${(lag / 1000).toStringAsFixed(1)}s — 資料晚到，畫面改顯示「資料延遲」');
    } else if (_lagLogged && lag < UIState.dataLagLimitMs ~/ 2) {
      _lagLogged = false;
      debugPrint('[opview] data lag recovered (${lag}ms)');
    }
  }

  /// switch camera based on experimental mode + speed hysteresis
  /// (augmented_road_view.py:122-136)
  Future<void> _switchStreamIfNeeded() async {
    if (_switchingCamera || !_uiState.isConnected || _replaced) return;
    String target;
    if (_uiState.experimentalMode) {
      final vEgo = _uiState.vEgo;
      if (vEgo < wideCamMaxSpeed) {
        target = 'wideRoad';
      } else if (vEgo > roadCamMinSpeed) {
        target = 'road';
      } else {
        // hysteresis zone — keep current
        return;
      }
    } else {
      target = 'road';
    }
    if (target == _streamType) return;

    _switchingCamera = true;
    final epoch = _connectEpoch;
    try {
      final sent = await _transport.sendControl('livestreamCameraSwitch', {'camera': target});
      if (epoch != _connectEpoch || _replaced) return;
      if (sent) {
        _streamType = target;
        _uiState.streamType = target;
        _prevVideo = null;
        _stallCount = 0;
        _uiState.notifyNow();
        _setStatus('camera switch → $target (same connection)');
      }
    } finally {
      _switchingCamera = false;
    }
  }

  /// listen for connection state → reconnect on failure
  void _listenState() {
    _stateSub?.cancel();
    _stateSub = _transport.stateStream.listen((state) {
      if (state == TransportState.failed) {
        _graceTimer?.cancel();
        _graceTimer = null;
        _setStatus('connection lost');
        _scheduleReconnect();
      } else if (state == TransportState.disconnected) {
        if (_graceTimer != null) return;
        _setStatus('WebRTC disconnected, waiting ${_disconnectGrace.inSeconds}s to recover…');
        _graceTimer = Timer(_disconnectGrace, () {
          _graceTimer = null;
          if (_transport.currentState != TransportState.connected) {
            _setStatus('connection lost (no recovery in ${_disconnectGrace.inSeconds}s)');
            _scheduleReconnect();
          }
        });
      } else if (state == TransportState.connected && _graceTimer != null) {
        _graceTimer!.cancel();
        _graceTimer = null;
        _setStatus('WebRTC recovered');
      }
    });
  }

  /// update connection state + toggle screen wake lock
  void _setConnected(bool connected) {
    if (_uiState.isConnected == connected) return;
    _uiState.isConnected = connected;
    if (!connected) _uiState.resetTdx();
    _uiState.notifyNow();
    wake_lock.setKeepScreenOn(connected);
  }

  /// cancel all timers and subscriptions (but keep _host and _deviceSub)
  void _teardown() {
    _connectEpoch++;  // invalidate any in-flight _transport.connect()
    _retryTimer?.cancel();
    _dataSub?.cancel();
    _stateSub?.cancel();
    _stateSub = null;
    _graceTimer?.cancel();
    _graceTimer = null;
    _stopStats();
    _adapter.reset();
    _connecting = false;
    _reconnecting = false;
    _setConnected(false);
    unawaited(_transport.close().catchError((Object e) {
      debugPrint('[opview] close failed: $e');
    })); // client serializes cleanup before the next connect
  }

  /// exponential backoff reconnect, fall back to re-discovery after max retries
  void _scheduleReconnect() {
    // prevent re-entrant calls (state listener + catch block firing together)
    if (_reconnecting || _paused || _replaced) return;
    _reconnecting = true;

    _retryTimer?.cancel();
    _dataSub?.cancel();
    _stateSub?.cancel();
    _stateSub = null;
    _graceTimer?.cancel();
    _graceTimer = null;
    _stopStats();
    _adapter.reset();
    unawaited(_transport.close().catchError((Object e) {
      debugPrint('[opview] close failed: $e');
    }));
    _setConnected(false);

    _retryCount++;

    if (_retryCount > _maxRetries) {
      // give up on this host, wait then re-discover
      _setStatus('$_maxRetries retries failed, re-discovering in ${_rediscoverDelay.inSeconds}s');
      _host = null;
      _retryCount = 0;
      _retryTimer = Timer(_rediscoverDelay, () {
        if (_paused) return;
        _reconnecting = false;
        _startDiscovery();
      });
      return;
    }

    _setStatus('retry $_retryCount/$_maxRetries in ${_retryDelay.inSeconds}s');
    _retryTimer = Timer(_retryDelay, () {
      _reconnecting = false;
      _connect();
    });
  }

  /// stop all activity — call when app goes to background
  void pause() {
    if (_paused) return;
    _paused = true;
    _setStatus('paused');
    _teardown();
  }

  /// tear down current connection and re-discover
  /// tries cached host first, mDNS in parallel (handles IP changes)
  void reconnect({bool automatic = false}) {
    _paused = false;
    if (automatic && _replaced) return;
    _replaced = false;
    _setStatus('reconnecting…');
    _teardown();
    _retryCount = 0;
    _host = null;
    start();
  }

  Future<String?> _loadCachedHost() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_cachedHostKey);
  }

  void _saveCachedHost(String host) async {
    if (host.contains('%')) return; // IPv6 link-local 不快取（見 start()）
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cachedHostKey, host);
  }

  /// check if a host IP is on the same /24 subnet as any local interface
  /// catches network switches (e.g. home wifi → hotspot, even within 192.168.x.x)
  Future<bool> _isOnSameSubnet(String host) async {
    try {
      final hostAddr = InternetAddress.tryParse(host);
      if (hostAddr == null) return true; // hostname, not IP — let it try

      final hostBytes = hostAddr.rawAddress;
      if (hostBytes.length != 4) return true; // IPv6 — skip check

      final interfaces = await NetworkInterface.list();
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.type != InternetAddressType.IPv4) continue;
          final localBytes = addr.rawAddress;
          // /24 match: same first three octets
          if (localBytes[0] == hostBytes[0] &&
              localBytes[1] == hostBytes[1] &&
              localBytes[2] == hostBytes[2]) {
            return true;
          }
        }
      }
      return false;
    } catch (e) {
      debugPrint('[opview] subnet check failed: $e');
      return true; // fail open — let it try
    }
  }

  Future<void> dispose() async {
    _retryTimer?.cancel();
    _connectivitySub?.cancel();
    _teardown();
    _deviceSub?.cancel();
    _discovery.dispose();
    await _transport.dispose();
  }
}
