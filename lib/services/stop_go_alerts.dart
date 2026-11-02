// 前車起步偵測 / 綠燈起步偵測 / 車輛停等計時
//
// 移植自 openpilot-spmaster-dev（sunnypilot）：
//   sunnypilot/selfdrive/controls/lib/e2e_alerts_helper.py   （偵測邏輯：門檻、狀態機）
//   selfdrive/ui/sunnypilot/onroad/circular_alerts.py        （畫面：顯示 3 秒、停等計時）
//
// 與 sunnypilot 的刻意差異：
//   - sunnypilot 在 comma 的縱向規劃器裡計算，結果經 longitudinalPlanSP.e2eAlerts 給 UI；
//     dp / 其他分支沒有這個訊息，所以 opview 在手機端用同樣的輸入與門檻重算：
//       modelV2.position.x、radarState.leadOne、carState（standstill / vEgo / gasPressed）、
//       selfdriveState.enabled（取代 carControl.enabled）。
//   - sunnypilot 以 modelV2 幀數（DT_MDL = 0.05 s）累計時間；opview 改用手機單調時鐘的實際間隔
//     （每次最多算 0.2 s），手機合併 / 丟棄舊訊息時計時仍正確。超過 2 秒沒有資料（斷線）就整個重置。
//   - leadOne 是否存在：sunnypilot 用 leadOne.present，cereal 標準欄位為 leadOne.status，這裡用 status。
//
// 只在 openpilot 未啟用、停車中時運作（與 sunnypilot 相同：allowed = 靜止 && 沒踩油門 && 未啟用 && 2 秒內沒移動）。
// 提醒僅供參考，起步前仍須駕駛自行確認路況。

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';

enum StopGoKind { greenLight, leadDepart }

class StopGoAlerts extends ChangeNotifier {
  StopGoAlerts({Stopwatch? clock}) : _clock = clock ?? (Stopwatch()..start());
  static final StopGoAlerts instance = StopGoAlerts();

  // e2e_alerts_helper.py
  static const greenLightXThreshold = 30.0;    // 模型路徑最遠點 > 30 m 視為前方淨空（燈號轉綠）
  static const leadDepartDistThreshold = 1.0;  // 前車距離比停等時最近距離多 1 m
  static const triggerTimerThreshold = 0.3;    // 條件持續 0.3 s 才提醒
  static const closeLeadDist = 8.0;            // 前車在 8 m 內才算「停在前車後面」
  static const leadArmTime = 1.0;              // 停穩 1 s 後才開始偵測前車起步
  static const recentMovingTime = 2.0;         // 2 s 內移動過不算停等
  // circular_alerts.py
  static const displayFor = Duration(seconds: 3);
  static const _resetGap = 2.0;                // 超過 2 s 沒資料：重置

  static const _inactive = 0, _armed = 1, _consumed = 2;

  final Stopwatch _clock;
  double get _now => _clock.elapsedMicroseconds / 1e6;

  bool greenLightEnabled = false;
  bool leadDepartEnabled = false;
  bool standstillTimerEnabled = false;

  /// 設定變更（顯示設定）
  void configure({required bool greenLight, required bool leadDepart, required bool standstillTimer}) {
    final changed = greenLight != greenLightEnabled || leadDepart != leadDepartEnabled ||
        standstillTimer != standstillTimerEnabled;
    greenLightEnabled = greenLight;
    leadDepartEnabled = leadDepart;
    standstillTimerEnabled = standstillTimer;
    if (changed) notifyListeners();
  }

  /// 每次提醒觸發一次（聲音用；直向、橫向都會收到）
  final StreamController<StopGoKind> _events = StreamController<StopGoKind>.broadcast();
  Stream<StopGoKind> get events => _events.stream;

  // 畫面狀態
  StopGoKind? _shownKind;
  double _shownUntil = -1;
  double? _standstillSince;
  bool _standstill = false;

  /// 目前要顯示的起步提醒（3 秒內），沒有則 null
  StopGoKind? get activeAlert => _now < _shownUntil ? _shownKind : null;
  /// 停等計時（秒）；不在停等或功能關閉時 null
  double? get standstillSeconds =>
      standstillTimerEnabled && _standstill && _standstillSince != null ? _now - _standstillSince! : null;

  // 偵測狀態
  double? _lastUpdate;
  double? _lastMovingAt;
  int _glState = _inactive, _ldState = _inactive;
  double _glTimer = 0, _ldTimer = 0, _ldArmTimer = 0;
  double _lastLeadDistance = -1;
  bool _allowed = false, _lastAllowed = false;
  bool _ldConfirmedLead = false, _ldArmed = false;

  @visibleForTesting
  bool get allowed => _allowed;

  void reset() {
    _lastUpdate = null;
    _lastMovingAt = null;
    _glState = _ldState = _inactive;
    _glTimer = _ldTimer = _ldArmTimer = 0;
    _lastLeadDistance = -1;
    _allowed = _lastAllowed = false;
    _ldConfirmedLead = _ldArmed = false;
    _standstillSince = null;
    _standstill = false;
    _shownUntil = -1;
  }

  /// modelV2 到達時呼叫（UIState.applyModelV2）。[nowSec] 只給測試用。
  void update(UIState s, {double? nowSec}) {
    final now = nowSec ?? _now;
    final last = _lastUpdate;
    if (last != null && now - last > _resetGap) reset();
    final dt = _lastUpdate == null ? 0.05 : (now - _lastUpdate!).clamp(0.0, 0.2);
    _lastUpdate = now;

    final standstill = s.standstill;
    final moving = !standstill && s.vEgo > 0.1;
    if (moving) _lastMovingAt = now;
    // python: last_moving_frame == -1（開機後從沒移動過）也算 recent_moving → 不允許
    final recentMoving = _lastMovingAt == null || now - _lastMovingAt! < recentMovingTime;
    _allowed = !moving && !s.gasPressed && !s.enabled && !recentMoving;

    // 停等計時（circular_alerts.py：car_state.standstill）
    _standstill = standstill;
    if (standstill) {
      _standstillSince ??= now;
    } else {
      _standstillSince = null;
    }

    final lead = s.leadOne;
    final hasLead = lead?['status'] == true;
    final dRel = (lead?['dRel'] as num?)?.toDouble() ?? double.infinity;
    final modelX = s.pathX;
    final farX = modelX.isEmpty ? 0.0 : modelX.last;

    // 綠燈起步
    var glTrigger = false;
    if (_glState == _armed) {
      _glTimer = farX > greenLightXThreshold ? _glTimer + dt : 0;
      if (_glTimer > triggerTimerThreshold) glTrigger = true;
    } else {
      _glTimer = 0;
    }

    // 前車起步
    final closeLead = hasLead && dRel < closeLeadDist;
    if (_allowed && !_lastAllowed && closeLead) {
      _ldConfirmedLead = true;
    } else if (!_allowed) {
      _ldConfirmedLead = false;
    }
    if (_allowed && _ldConfirmedLead && closeLead) {
      _ldArmTimer += dt;
      if (_ldArmTimer >= leadArmTime) _ldArmed = true;
    } else {
      _ldArmTimer = 0;
      _ldArmed = false;
    }

    var ldTrigger = false;
    if (_ldState == _armed) {
      if (_lastLeadDistance == -1 || dRel < _lastLeadDistance) _lastLeadDistance = dRel;
      if (_lastLeadDistance != -1 && dRel - _lastLeadDistance > leadDepartDistThreshold) {
        _ldTimer += dt;
      } else {
        _ldTimer = 0;
      }
      if (_ldTimer > triggerTimerThreshold) ldTrigger = true;
    } else {
      _lastLeadDistance = -1;
      _ldTimer = 0;
    }
    _lastAllowed = _allowed;

    final gl = _stateMachine(_glState, greenLightEnabled, _allowed && !hasLead, glTrigger);
    _glState = gl.$1;
    final ld = _stateMachine(_ldState, leadDepartEnabled, _allowed && _ldArmed, ldTrigger);
    _ldState = ld.$1;

    // circular_alerts.py：綠燈優先
    final fired = gl.$2 ? StopGoKind.greenLight : ld.$2 ? StopGoKind.leadDepart : null;
    if (fired != null) {
      _shownKind = fired;
      _shownUntil = now + displayFor.inMicroseconds / 1e6;
      debugPrint('[opview] ${fired == StopGoKind.greenLight ? '綠燈起步' : '前車起步'}提醒');
      _events.add(fired);
      notifyListeners();
    }
  }

  static (int, bool) _stateMachine(int state, bool enabled, bool allowed, bool triggered) {
    if (state != _inactive) {
      if (!allowed || !enabled) {
        state = _inactive;
      } else if (state == _armed && triggered) {
        state = _consumed;
      }
    } else if (allowed && enabled) {
      state = _armed;
    }
    return (state, triggered);
  }
}

/// m:ss（circular_alerts.py：f"{minute:01d}:{second:02d}"）
String formatStandstill(double seconds) {
  final s = seconds.floor();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}
