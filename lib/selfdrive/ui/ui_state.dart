// UI state — the single source of truth
// ported from openpilot selfdrive/ui/ui_state.py
//
// one ChangeNotifier, fed by telemetry parser.
// data-driven refresh: notifyListeners on modelV2 arrival.

import 'package:flutter/foundation.dart';

// -- constants --

const uiBorderSize = 30;
const setSpeedNA = 255;
const kmToMile = 0.621371;
const msToKph = 3.6;
const msToMph = 2.23694;

// -- engagement status (matches ui_state.py UIStatus) --

enum UIStatus { disengaged, engaged, override_ }

// -- state --

class UIState extends ChangeNotifier {
  // engagement
  UIStatus status = UIStatus.disengaged;
  bool started = false;

  // Phone-only presentation state. Never sent back to comma.
  bool modernOverlay = true;
  DateTime? lastModelAt;
  DateTime? lastRadarAt;
  double? get leadDistance {
    if (leadOne?['status'] != true) return null;
    if (lastRadarAt != null && DateTime.now().difference(lastRadarAt!).inMilliseconds > 2000) return null;
    final value = leadOne?['dRel'];
    if (value is! num || !value.isFinite || value <= 0) return null;
    return value.toDouble();
  }
  // Time headway, NOT time to collision. Undefined at walking speed/stopped.
  double? get leadHeadway => leadDistance != null && vEgo.isFinite && vEgo > 1.0
      ? leadDistance! / vEgo : null;

  double? steeringAngleDeg;
  double? aEgo;
  bool leftBlinker = false, rightBlinker = false;
  bool leftBlindspot = false, rightBlindspot = false;

  // carState.gearShifter（car.capnp enum GearShifter：unknown / park / drive / neutral /
  // reverse / sport / low / brake / eco / manumatic）。pycapnp to_dict 給名稱字串。
  String gearShifter = 'unknown';
  static const _gearNames = ['unknown', 'park', 'drive', 'neutral', 'reverse',
    'sport', 'low', 'brake', 'eco', 'manumatic'];
  bool get inPark => gearShifter == 'park';
  /// 儀表板碼表中間改顯示的擋位字母；D / S / L 等行駛擋回傳 null（照常顯示車速）
  String? get gearLetter => switch (gearShifter) {
    'park' => 'P',
    'reverse' => 'R',
    'neutral' => 'N',
    _ => null,
  };

  // carState
  double vEgo = 0.0;
  double vEgoCluster = 0.0;
  double vCruiseCluster = 0.0;
  bool vEgoClusterSeen = false;

  // selfdriveState
  bool enabled = false;
  bool experimentalMode = false;
  String alertText1 = '';
  String alertText2 = '';
  int alertSize = 0;     // 0=none, 1=small, 2=mid, 3=full
  int alertStatus = 0;   // 0=normal, 1=userPrompt, 2=critical
  String openpilotState = '';

  // controlsState
  double vCruiseDEPRECATED = 0.0;

  // modelV2 — raw lists from cereal
  List<double> pathX = [];
  List<double> pathY = [];
  List<double> pathZ = [];
  List<List<double>> laneLineX = [[], [], [], []];
  List<List<double>> laneLineY = [[], [], [], []];
  List<List<double>> laneLineZ = [[], [], [], []];
  List<double> laneLineProbs = [0, 0, 0, 0];
  List<List<double>> roadEdgeX = [[], []];
  List<List<double>> roadEdgeY = [[], []];
  List<List<double>> roadEdgeZ = [[], []];
  List<double> roadEdgeStds = [0, 0];
  List<double> accelerationX = [];

  // liveCalibration
  List<double> rpyCalib = [];
  List<double> wideFromDeviceEuler = [];
  String calStatus = '';
  List<double> calibHeight = [];

  // radarState
  Map<String, dynamic>? leadOne;
  Map<String, dynamic>? leadTwo;

  // longitudinalPlan
  bool allowThrottle = true;

  // tdx — dplcc 高公局即時路況（custom.Tdx，tdxd 1Hz，只在 onroad 發布）
  // 存活判斷對齊 tici hud_renderer 的 sm.alive['tdx']：
  //   SubMaster alive = 距上次收到 < 10 / frequency 秒，services.py tdx = 1Hz → 10 秒
  static const tdxAliveTimeout = Duration(seconds: 10);
  DateTime? lastTdxAt;
  int _tdxNextSpeedRaw = -1;      // km/h，-1 = 無資料
  String tdxCongestion = 'unknown'; // unknown / smooth / slow / congested
  final List<({String description, bool isCurrentSection})> _tdxEvents = [];

  // 手機端顯示開關（側欄 TDX 按鈕），關閉時照樣接收，只是不顯示
  bool tdxEnabled = true;

  bool get _tdxAlive => tdxEnabled && lastTdxAt != null &&
      DateTime.now().difference(lastTdxAt!) < tdxAliveTimeout;

  /// 前方路段車速 (km/h)；與 tici 相同只在 0 < v <= 150 時有效，否則 null
  int? get tdxNextSpeedKph =>
      _tdxAlive && _tdxNextSpeedRaw > 0 && _tdxNextSpeedRaw <= 150 ? _tdxNextSpeedRaw : null;

  /// 前方車速（目前單位），無資料為 null
  int? get tdxNextSpeedDisplay {
    final v = tdxNextSpeedKph;
    if (v == null) return null;
    return isMetric ? v : (v * kmToMile).round();
  }

  /// 事件文字，格式與 tici 相同：「目前: a / b」或「前方: a / b」，無事件為空字串
  String get tdxEventText {
    if (!_tdxAlive || _tdxEvents.isEmpty) return '';
    final loc = _tdxEvents.first.isCurrentSection ? '目前' : '前方';
    return '$loc: ${_tdxEvents.map((e) => e.description).join(' / ')}';
  }

  void applyTdx(Map<String, dynamic> data) {
    lastTdxAt = DateTime.now();
    final speed = data['nextSpeed'];
    _tdxNextSpeedRaw = speed is num && speed.isFinite ? speed.toInt() : -1;
    final congestion = data['congestion'];
    // pycapnp to_dict() 把 enum 轉成名稱字串；保險起見也接受序號
    tdxCongestion = congestion is String ? congestion
        : congestion is int && congestion >= 0 && congestion < _tdxCongestionNames.length
            ? _tdxCongestionNames[congestion] : 'unknown';
    _tdxEvents.clear();
    final events = data['events'];
    if (events is List) {
      for (final e in events) {
        if (e is! Map) continue;
        final desc = e['description'];
        if (desc is! String || desc.isEmpty) continue;
        _tdxEvents.add((description: desc, isCurrentSection: e['isCurrentSection'] == true));
      }
    }
    // no notify — picked up on next modelV2
  }

  /// 斷線時清掉，避免重連後顯示上次的路況（對應 tici 熄火時 _reset_tdx）
  void resetTdx() {
    lastTdxAt = null;
    _tdxNextSpeedRaw = -1;
    tdxCongestion = 'unknown';
    _tdxEvents.clear();
  }

  static const _tdxCongestionNames = ['unknown', 'smooth', 'slow', 'congested'];

  // throttle blend — smooth fade between throttle/no-throttle path colors
  // first-order filter: tau=0.25s, updated at modelV2 rate (~20Hz)
  double throttleBlend = 1.0; // 1.0 = full throttle colors, 0.0 = no-throttle

  // deviceState / roadCameraState — for camera intrinsics lookup
  String deviceType = '';
  String sensor = '';

  // is_metric (default true, like stock)
  bool isMetric = true;

  // active camera: 'road' or 'wideRoad' (switches on experimental mode)
  String streamType = 'road';

  // connection state — drives "Connecting..." overlay + screen wake lock
  bool isConnected = false;

  // rolling status log shown on the connecting overlay (newest last)
  final List<String> connectionLog = [];
  static const _maxLogLines = 8;

  void addConnectionStatus(String msg) {
    connectionLog.add(msg);
    if (connectionLog.length > _maxLogLines) connectionLog.removeAt(0);
  }

  /// monotonic version counter — incremented on each notify.
  /// used by painters to detect state changes in shouldRepaint.
  int version = 0;

  /// notify listeners and bump version
  void _notify() {
    version++;
    notifyListeners();
  }

  /// force immediate notify (for connection state changes)
  void notifyNow() {
    _notify();
  }

  // -- apply methods: one per cereal service --

  void applyCarState(Map<String, dynamic> data) {
    steeringAngleDeg = _finite(data['steeringAngleDeg']);
    aEgo = _finite(data['aEgo']);
    leftBlinker = data['leftBlinker'] == true;
    rightBlinker = data['rightBlinker'] == true;
    leftBlindspot = data['leftBlindspot'] == true;
    rightBlindspot = data['rightBlindspot'] == true;
    final gear = data['gearShifter'];
    gearShifter = gear is String ? gear
        : gear is int && gear >= 0 && gear < _gearNames.length ? _gearNames[gear] : 'unknown';
    vEgo = (data['vEgo'] as num?)?.toDouble() ?? 0.0;
    vEgoCluster = (data['vEgoCluster'] as num?)?.toDouble() ?? 0.0;
    vCruiseCluster = (data['vCruiseCluster'] as num?)?.toDouble() ?? 0.0;
    if (!vEgoClusterSeen && vEgoCluster != 0.0) vEgoClusterSeen = true;
    // no notify — picked up on next modelV2
  }

  void applySelfdriveState(Map<String, dynamic> data) {
    enabled = data['enabled'] as bool? ?? false;
    experimentalMode = data['experimentalMode'] as bool? ?? false;
    alertText1 = data['alertText1'] as String? ?? '';
    alertText2 = data['alertText2'] as String? ?? '';
    alertSize = _alertSizeFromString(data['alertSize']);
    alertStatus = _alertStatusFromString(data['alertStatus']);
    openpilotState = data['state'] as String? ?? '';

    // update engagement status
    started = true;
    if (openpilotState == 'preEnabled' || openpilotState == 'overriding') {
      status = UIStatus.override_;
    } else {
      status = enabled ? UIStatus.engaged : UIStatus.disengaged;
    }
    // no notify — picked up on next modelV2
  }

  void applyControlsState(Map<String, dynamic> data) {
    vCruiseDEPRECATED = (data['vCruiseDEPRECATED'] as num?)?.toDouble() ?? 0.0;
    // no notify — picked up on next modelV2
  }

  void applyModelV2(Map<String, dynamic> data) {
    lastModelAt = DateTime.now();
    _fillDoubles(pathX, data['position']?['x']);
    _fillDoubles(pathY, data['position']?['y']);
    _fillDoubles(pathZ, data['position']?['z']);

    final lanes = data['laneLines'] as List? ?? [];
    for (int i = 0; i < 4 && i < lanes.length; i++) {
      _fillDoubles(laneLineX[i], lanes[i]['x']);
      _fillDoubles(laneLineY[i], lanes[i]['y']);
      _fillDoubles(laneLineZ[i], lanes[i]['z']);
    }
    _fillDoublesFixed(laneLineProbs, data['laneLineProbs'], 4);

    final edges = data['roadEdges'] as List? ?? [];
    for (int i = 0; i < 2 && i < edges.length; i++) {
      _fillDoubles(roadEdgeX[i], edges[i]['x']);
      _fillDoubles(roadEdgeY[i], edges[i]['y']);
      _fillDoubles(roadEdgeZ[i], edges[i]['z']);
    }
    _fillDoublesFixed(roadEdgeStds, data['roadEdgeStds'], 2);
    _fillDoubles(accelerationX, data['acceleration']?['x']);

    // smooth throttle blend: first-order filter (tau=0.25s at ~20Hz → k≈0.167)
    const k = 0.167; // dt / (tau + dt) = 0.05 / (0.25 + 0.05)
    final target = allowThrottle ? 1.0 : 0.0;
    throttleBlend = throttleBlend + k * (target - throttleBlend);

    _notify();  // data-driven: render on modelV2 arrival
  }

  void applyLiveCalibration(Map<String, dynamic> data) {
    _fillDoubles(rpyCalib, data['rpyCalib']);
    _fillDoubles(wideFromDeviceEuler, data['wideFromDeviceEuler']);
    calStatus = data['calStatus'] as String? ?? '';
    _fillDoubles(calibHeight, data['height']);
    // no notify — picked up on next modelV2
  }

  void applyRadarState(Map<String, dynamic> data) {
    lastRadarAt = DateTime.now();
    leadOne = data['leadOne'] as Map<String, dynamic>?;
    leadTwo = data['leadTwo'] as Map<String, dynamic>?;
    // no notify — picked up on next modelV2
  }

  void applyLongitudinalPlan(Map<String, dynamic> data) {
    allowThrottle = data['allowThrottle'] as bool? ?? true;
    // no notify — picked up on next modelV2
  }

  void applyDeviceState(Map<String, dynamic> data) {
    deviceType = data['deviceType'] as String? ?? '';
    started = data['started'] as bool? ?? started;
    // no notify — picked up on next modelV2
  }

  void applyRoadCameraState(Map<String, dynamic> data) {
    sensor = data['sensor'] as String? ?? '';
    // no notify — picked up on next modelV2
  }

  // -- derived values --

  /// display speed in current unit (km/h or mph)
  double get displaySpeed {
    final v = vEgoClusterSeen ? vEgoCluster : vEgo;
    final conv = isMetric ? msToKph : msToMph;
    final s = v * conv;
    return s > 0 ? s : 0;
  }

  /// raw cruise speed in kph (before unit conversion)
  double get _rawSetSpeed => vCruiseCluster != 0.0 ? vCruiseCluster : vCruiseDEPRECATED;

  /// is cruise actively set
  bool get isCruiseSet => _rawSetSpeed > 0 && _rawSetSpeed < setSpeedNA;

  /// cruise set speed in current unit
  double get setSpeed {
    final s = _rawSetSpeed;
    if (!isCruiseSet) return s;
    return isMetric ? s : s * kmToMile;
  }

  /// is cruise available (not -1)
  bool get isCruiseAvailable => _rawSetSpeed != -1;

  double? _finite(dynamic value) => value is num && value.isFinite ? value.toDouble() : null;

  // -- helpers --

  /// Clear [target] and refill from [source] — reuses the existing list.
  void _fillDoubles(List<double> target, dynamic source) {
    target.clear();
    if (source is List) {
      for (final e in source) {
        target.add((e as num?)?.toDouble() ?? 0.0);
      }
    }
  }

  /// Clear [target] and refill from [source], ensuring exactly [n] elements.
  void _fillDoublesFixed(List<double> target, dynamic source, int n) {
    target.clear();
    if (source is List) {
      for (int i = 0; i < n && i < source.length; i++) {
        target.add((source[i] as num?)?.toDouble() ?? 0.0);
      }
    }
    while (target.length < n) {
      target.add(0.0);
    }
  }

  int _alertSizeFromString(dynamic v) {
    if (v is int) return v;
    if (v is String) {
      switch (v) {
        case 'none': return 0;
        case 'small': return 1;
        case 'mid': return 2;
        case 'full': return 3;
      }
    }
    return 0;
  }

  int _alertStatusFromString(dynamic v) {
    if (v is int) return v;
    if (v is String) {
      switch (v) {
        case 'normal': return 0;
        case 'userPrompt': return 1;
        case 'critical': return 2;
      }
    }
    return 0;
  }

}
