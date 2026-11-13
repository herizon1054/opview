// UI state — the single source of truth
// ported from openpilot selfdrive/ui/ui_state.py
//
// one ChangeNotifier, fed by telemetry parser.
// data-driven refresh: notifyListeners on modelV2 arrival.

import 'package:opview/services/stop_go_alerts.dart';
import 'package:opview/services/proximity_alert.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:opview/services/tdx/tdx_traffic_core.dart' show tdxDistText, tdxDropAheadM, tdxDropDeltaKph;

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
  bool hideHudCard = false; // 儀表介面不顯示儀表卡片（顯示設定「顯示儀表卡片」）
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
  /// modelV2.leadsV3[0] 在 t=0 的純視覺前車（近距離警示用）；comma 端沒送 leadsV3 時為 null
  double? visionLeadX, visionLeadY, visionLeadProb;
  bool visionLeadSeen = false; // 曾收到 leadsV3
  bool _leadsV3Warned = false;
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
  // 國道擴充（2026-11-12）：回堵、各車道車速（tdxReport 的 queue / lanes）
  ({double d, double len, int avg, int min, bool open})? _tdxQueue;
  ({double d, List<int> speeds})? _tdxLanes;

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

  /// 路況卡（表格式，2026-11-13）用：每個事件拆成 (內容, 距離)。core 的描述格式是「種類 距離 內容」
  /// （例：「施工 3.0公里 外側車道封閉」）；不符合格式的整段當內容、距離空白。
  static final _evRe = RegExp(r'^(\S+) (\d+(?:\.\d+)?)(公尺|公里)(?: (.*))?$');
  List<({String what, String dist})> get tdxEventRows {
    if (!_tdxAlive || !isConnected) return const [];
    return [
      for (final e in _tdxEvents)
        if (_evRe.firstMatch(e.description) case final m?)
          (what: [m.group(1)!, if ((m.group(4) ?? '').isNotEmpty) m.group(4)!].join(' '),
           dist: '${m.group(2)} ${m.group(3) == '公里' ? 'km' : 'm'}')
        else
          (what: e.description, dist: ''),
    ];
  }

  /// 路況卡用的回堵數字（車速為目前單位），沒有為 null
  ({double d, double len, bool open, int avg, int min})? get tdxQueueInfo {
    final q = _tdxAlive ? _tdxQueue : null;
    if (q == null) return null;
    int u(int kph) => isMetric ? kph : (kph * kmToMile).round();
    return (d: q.d, len: q.len, open: q.open, avg: u(q.avg), min: u(q.min));
  }

  /// 近距離警示觸發中（低信心目標在 2–3 m 內）：事件列顯示「碰撞注意」，優先於 TDX 事件。
  /// 斷線時不顯示。空字串 = 沒有。
  String get collisionText {
    if (!isConnected) return '';
    final t = ProximityAlert.instance.active;
    if (t == null) return '';
    return '碰撞注意  前方 ${(t.dRel < 0 ? 0 : t.dRel).toStringAsFixed(1)} m';
  }

  /// 事件位置要顯示的文字與樣式：碰撞注意（紅）> 國道車速驟降（黃）> TDX 事件
  ({String text, bool collision, bool warn}) get eventBanner => eventBannerFor(portrait: false);

  /// 儀表介面（直向、橫向）：TDX 事件、車速驟降都在路況卡裡（2026-11-13），道路畫面上方的警示列只剩碰撞注意。
  /// 原版介面沒有路況卡：碰撞注意 > 車速驟降 > TDX 事件都在警示列。[portrait] 保留給呼叫端，目前兩個方向相同。
  ({String text, bool collision, bool warn}) eventBannerFor({required bool portrait}) {
    final c = collisionText;
    if (c.isNotEmpty) return (text: c, collision: true, warn: false);
    if (modernOverlay) return (text: '', collision: false, warn: false);
    final d = tdxDropText;
    if (d.isNotEmpty) return (text: d, collision: false, warn: true);
    return (text: isConnected ? tdxEventText : '', collision: false, warn: false);
  }

  String _spd(int kph) => '${isMetric ? kph : (kph * kmToMile).round()}';

  /// 國道回堵：「回堵 1.2公里起 3.5公里｜均速 25」/「回堵中 還有 3.5公里以上｜均速 25」，沒有為空字串
  String get tdxQueueText {
    final q = _tdxAlive ? _tdxQueue : null;
    if (q == null) return '';
    final len = '${tdxDistText(q.len)}${q.open ? '以上' : ''}';
    final avg = '均速 ${_spd(q.avg)}';
    return q.d < 50 ? '回堵中 還有 $len｜$avg' : '回堵 ${tdxDistText(q.d)}起 $len｜$avg';
  }

  /// 前方偵測器各車道車速（目前單位，依 LaneID 由內而外），沒有為 null
  ({double d, List<int> speeds})? get tdxLanes {
    final l = _tdxAlive ? _tdxLanes : null;
    if (l == null) return null;
    return (d: l.d, speeds: [for (final v in l.speeds) isMetric ? v : (v * kmToMile).round()]);
  }

  /// 國道車速驟降：回堵起點在前方 2 公里內，且本車比回堵最慢路段快 40 km/h 以上。沒有為空字串。
  String get tdxDropText {
    final q = _tdxAlive && isConnected ? _tdxQueue : null;
    if (q == null || q.d > tdxDropAheadM) return '';
    if (vEgo * 3.6 - q.min < tdxDropDeltaKph) return '';
    // 格式（2026-11-13）：「車速驟降 前方1.5公里 降至25km」
    final unit = isMetric ? 'km' : 'mph';
    return q.d < 50 ? '車速驟降 已進入回堵 降至${_spd(q.min)}$unit'
        : '車速驟降 前方${tdxDistText(q.d)} 降至${_spd(q.min)}$unit';
  }

  /// 車速驟降開始時發出一次（app.dart 播單聲嗶）；同一段回堵 tdxDropBeepCooldown 內不重複
  static const tdxDropBeepCooldown = Duration(minutes: 3);
  final _tdxDropEvents = StreamController<String>.broadcast();
  Stream<String> get tdxDropEvents => _tdxDropEvents.stream;
  bool _tdxDropOn = false;
  DateTime? _tdxDropBeepAt;

  void _checkTdxDrop(DateTime now) {
    final t = tdxDropText;
    final on = t.isNotEmpty;
    if (on && !_tdxDropOn &&
        (_tdxDropBeepAt == null || now.difference(_tdxDropBeepAt!) >= tdxDropBeepCooldown)) {
      _tdxDropBeepAt = now;
      debugPrint('[tdx] $t（本車 ${(vEgo * 3.6).round()} km/h）');
      _tdxDropEvents.add(t);
    }
    _tdxDropOn = on;
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
    final q = data['queue'];
    _tdxQueue = q is Map && q['d'] is num && q['len'] is num && q['avg'] is num && q['min'] is num
        ? (d: (q['d'] as num).toDouble(), len: (q['len'] as num).toDouble(), avg: (q['avg'] as num).toInt(),
           min: (q['min'] as num).toInt(), open: q['open'] == true)
        : null;
    final l = data['lanes'];
    _tdxLanes = l is Map && l['d'] is num && l['speeds'] is List && (l['speeds'] as List).isNotEmpty
        ? (d: (l['d'] as num).toDouble(), speeds: [for (final v in l['speeds'] as List) if (v is num) v.toInt()])
        : null;
    _checkTdxDrop(lastTdxAt!);
    // no notify — picked up on next modelV2（未連線時畫面本來就不顯示 TDX）
  }

  /// 斷線時清掉，避免重連後顯示上次的路況（對應 tici 熄火時 _reset_tdx）
  void resetTdx() {
    lastTdxAt = null;
    _tdxNextSpeedRaw = -1;
    tdxCongestion = 'unknown';
    _tdxEvents.clear();
    _tdxQueue = null;
    _tdxLanes = null;
    _tdxDropOn = false;
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

    // 純視覺前車（modelV2.leadsV3[0]，t=0）：comma 端精簡 modelV2 有帶 leadsV3 才有
    final leads = data['leadsV3'];
    final l0 = leads is List && leads.isNotEmpty && leads.first is Map ? leads.first as Map : null;
    double? first(Object? v) => v is List && v.isNotEmpty && v.first is num ? (v.first as num).toDouble() : null;
    visionLeadX = l0 == null ? null : first(l0['x']);
    visionLeadY = l0 == null ? null : first(l0['y']);
    visionLeadProb = l0 == null ? null : (l0['prob'] as num?)?.toDouble();
    if (l0 != null) visionLeadSeen = true;
    if (l0 == null && !visionLeadSeen && !_leadsV3Warned && ProximityAlert.instance.enabled) {
      _leadsV3Warned = true;
      debugPrint('[opview] 近距離警示：comma 端 modelV2 沒有 leadsV3（webrtcd 未更新），警示不會觸發');
    }

    StopGoAlerts.instance.update(this); // 前車起步 / 綠燈起步 / 停等計時（20 Hz）
    ProximityAlert.instance.update(ProximityInput(
      vEgo: vEgo, leadX: visionLeadX, leadY: visionLeadY, leadProb: visionLeadProb,
      pathX: pathX, pathY: pathY,
    ));
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
