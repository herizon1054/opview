// UI state — the single source of truth
// ported from openpilot selfdrive/ui/ui_state.py
//
// one ChangeNotifier, fed by telemetry parser.
// data-driven refresh: notifyListeners on modelV2 arrival.

import 'package:opview/services/stop_go_alerts.dart';
import 'package:flutter/foundation.dart';

// -- constants --

const uiBorderSize = 30;
const setSpeedNA = 255;
const kmToMile = 0.621371;
const msToKph = 3.6;
const msToMph = 2.23694;

// -- radarState LeadData --
// 有沒有前車：dragonpilot（dplcc / dp0111pre，舊 cereal）欄位叫 status，
// sunnypilot / openpilot 新版 cereal 改名為 present（同一個欄位編號 @11）。兩個都認。
bool leadPresent(Map<String, dynamic>? lead) =>
    lead != null && (lead['status'] == true || lead['present'] == true);

/// leadTwo 是否和 leadOne 是不同目標（opview 只在不同時畫紅色箭頭；與 model_renderer 的判斷相同）。
/// openpilot 的 leadTwo 不是「第二台車」，而是模型「2 秒後的前車」預測（modelV2.leadsV3[1]）
/// 配對到的目標，大多數時間就是 leadOne 那台車；只有切入、變換車道、前車離開等情況才會不同。
bool leadTwoSeparate(Map<String, dynamic>? one, Map<String, dynamic>? two) {
  if (!leadPresent(two)) return false;
  if (!leadPresent(one)) return true;
  final d1 = (one!['dRel'] as num?)?.toDouble(), y1 = (one['yRel'] as num?)?.toDouble();
  final d2 = (two!['dRel'] as num?)?.toDouble(), y2 = (two['yRel'] as num?)?.toDouble();
  if (d1 == null || y1 == null || d2 == null || y2 == null) return true;
  return (d2 - d1).abs() >= 3 || (y2 - y1).abs() >= 1.5;
}

// -- engagement status (matches ui_state.py UIStatus) --

enum UIStatus { disengaged, engaged, override_ }

// -- state --

class UIState extends ChangeNotifier {
  // engagement
  UIStatus status = UIStatus.disengaged;
  bool started = false;

  // Phone-only presentation state. Never sent back to comma.
  bool modernOverlay = true;
  bool rainbowPath = false; // 彩虹模式（顯示設定；只影響儀表介面的路徑）
  DateTime? lastModelAt;
  DateTime? lastRadarAt;
  /// 最新一筆資料比「最順時」多晚到（ms，由 ConnectionManager 依 logMonoTime 計算）。
  /// 超過 [dataLagLimitMs] 時畫面上的速度、路徑已是好幾秒前的狀態，改顯示「資料延遲」。
  int dataLagMs = 0;
  static const dataLagLimitMs = 1500;
  bool get dataLagging => isConnected && dataLagMs > dataLagLimitMs;
  double? get leadDistance {
    if (!leadPresent(leadOne)) return null;
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
  // carState.standstill / gasPressed（停等計時、前車 / 綠燈起步偵測）
  bool standstill = false;
  bool gasPressed = false;
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

  // tdx — TDX 即時路況，由 opview 手機端自己抓（lib/services/tdx/tdx_traffic_service.dart，1Hz 呼叫 applyTdx）。
  // 已不再讀 comma 的 tdx service；資料欄位沿用 custom.Tdx（nextSpeed / congestion / events）。
  // 超過 10 秒沒更新（手機定位中斷、服務停止）視為過期不顯示。
  static const tdxAliveTimeout = Duration(seconds: 10);
  DateTime? lastTdxAt;
  int _tdxNextSpeedRaw = -1;      // km/h，-1 = 無資料
  String tdxCongestion = 'unknown'; // unknown / smooth / slow / congested
  final List<({String description, bool isCurrentSection})> _tdxEvents = [];

  // 手機端顯示開關（顯示設定的 TDX 開關）；關閉時服務也會停止抓取
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
    // no notify — picked up on next modelV2（未連線時畫面本來就不顯示 TDX）
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
    standstill = data['standstill'] == true;
    gasPressed = data['gasPressed'] == true;
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

    StopGoAlerts.instance.update(this); // 前車起步 / 綠燈起步 / 停等計時（20 Hz）
    _notify();  // data-driven: render on modelV2 arrival
  }

  void applyLiveCalibration(Map<String, dynamic> data) {
    _fillDoubles(rpyCalib, data['rpyCalib']);
    _fillDoubles(wideFromDeviceEuler, data['wideFromDeviceEuler']);
    calStatus = data['calStatus'] as String? ?? '';
    _fillDoubles(calibHeight, data['height']);
    // no notify — picked up on next modelV2
  }

  // log：每 60 秒記錄一次前車資料統計，確認 leadOne / leadTwo 有沒有資料、leadTwo 多常和 leadOne 不同
  int _leadMsgs = 0, _leadOneCount = 0, _leadTwoCount = 0, _leadTwoSeparateCount = 0;
  String _leadField = '-';
  DateTime? _leadStatsSince;

  void applyRadarState(Map<String, dynamic> data) {
    final now = DateTime.now();
    lastRadarAt = now;
    leadOne = data['leadOne'] as Map<String, dynamic>?;
    leadTwo = data['leadTwo'] as Map<String, dynamic>?;
    _leadStatsSince ??= now;
    _leadMsgs++;
    if (leadPresent(leadOne)) _leadOneCount++;
    if (leadPresent(leadTwo)) _leadTwoCount++;
    if (leadTwoSeparate(leadOne, leadTwo)) _leadTwoSeparateCount++;
    if (_leadField == '-' && leadOne != null) {
      _leadField = leadOne!.containsKey('present') ? 'present'
          : leadOne!.containsKey('status') ? 'status' : '無（看不出有沒有前車）';
    }
    if (now.difference(_leadStatsSince!).inSeconds >= 60) {
      debugPrint('[opview] 前車資料（60 秒）：radarState $_leadMsgs 筆，有 leadOne $_leadOneCount、'
          '有 leadTwo $_leadTwoCount（其中與 leadOne 不同、會畫紅色箭頭 $_leadTwoSeparateCount），欄位 $_leadField');
      _leadMsgs = _leadOneCount = _leadTwoCount = _leadTwoSeparateCount = 0;
      _leadStatsSince = now;
    }
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
