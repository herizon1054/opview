// 近距離低信心目標警示（顯示設定「近距離警示」）
//
// 目的：行進中前方有車，但模型信心度未達 0.5（radard 不會把它當前車，openpilot 不會為它減速），
// 而且距離已經過近。
//
// 條件（全部成立）：
//   1. 本車車速 20–60 km/h（carState.vEgo，含兩端）
//   2. 純視覺目標機率 0.2 ≤ prob < 0.5：modelV2.leadsV3[0].prob。radard 的視覺前車要 prob > 0.5
//      才會出現；≥ 0.5 時 openpilot 已經在處理，不警示
//   3. 位於預測路線內：目標橫向位置 y 與模型路徑（modelV2.position）同距離處相差 ≤ 0.9 m
//   4. 車頭到目標 < 距離門檻：隨車速線性變化，20 km/h = 2 m、60 km/h = 3 m（每 10 km/h 加 0.25 m）。
//      車頭距離 = leadsV3 的 x − 1.52 m（RADAR_TO_CAMERA，同 radard 的 dRel、畫面鎖定框的距離）
// 穩定度（濾掉模型的假目標）：條件需連續 5 幀 modelV2（20 Hz 約 0.25 秒），且期間
//   - 橫向位置與第一幀相差 ≤ 0.6 m
//   - 每幀距離變化 ≤ 2 m
// 任一不符就從那一幀重新計數。觸發時畫面顯示箭頭並嗶一聲。
// 嗶過之後 30 秒內不再嗶（模型沒有目標編號，無法分辨是不是同一台；箭頭仍會顯示）。
// 超過 2 秒沒有 modelV2（斷線）整個重置。
//
// 依據（rlog 9 段，dplcc，2026-11-11）：模型失去前車時，leadsV3 的機率掉到 0.03–0.3，
// 位置在 4–10 m 之間左右亂跳（雷達同時沒有目標、駕駛沒有煞車），最長連續 0.25 秒落在路線內；
// 9 段中模型在距離門檻內、0.2–0.5 的幀都不在路線上（012：左側 4.5 m、機率 0.06–0.08），都不會觸發。尚無「真的低信心近距離車輛」的樣本，觸發率待實車確認。
//
// 需要 comma 端 webrtcd 的精簡 modelV2 帶 leadsV3（見 PROXIMITY_ALERT_zh-TW.md）；
// 沒有 leadsV3 時不會觸發。僅供參考，不會控制車輛。

import 'dart:async';
import 'package:flutter/foundation.dart';

/// 觸發中的目標（畫面箭頭用）
class ProximityTarget {
  final double x; // 相機到目標（m，模型座標）
  final double y; // 橫向（m，模型座標：右為正）
  final double dRel; // 車頭到目標（m）= x − 1.52
  final double prob;
  const ProximityTarget({required this.x, required this.y, required this.dRel, required this.prob});
}

/// 模型輸入（從 UIState 取出，方便測試）
class ProximityInput {
  final double vEgo; // m/s
  final double? leadX, leadY, leadProb; // leadsV3[0] 在 t=0
  final List<double> pathX, pathY; // modelV2.position
  const ProximityInput({required this.vEgo, this.leadX, this.leadY, this.leadProb,
    required this.pathX, required this.pathY});
}

const proximityMinKph = 20.0;
const proximityMaxKph = 60.0;
const proximityMinProb = 0.2;
const proximityMaxProb = 0.5;
const proximityDistAtMin = 2.0; // 20 km/h 時的距離門檻（m）
const proximityDistAtMax = 3.0; // 60 km/h 時的距離門檻（m）

/// 距離門檻（車頭到目標，m）：20 km/h 2 m → 60 km/h 3 m 線性
double proximityMaxDist(double kph) {
  final f = ((kph - proximityMinKph) / (proximityMaxKph - proximityMinKph)).clamp(0.0, 1.0).toDouble();
  return proximityDistAtMin + f * (proximityDistAtMax - proximityDistAtMin);
}
const radarToCamera = 1.52; // selfdrive/controls/radard.py：RADAR_TO_CAMERA
const proximityPathHalfWidth = 0.9;

/// 線性內插：xs 遞增；超出範圍用端點；資料不足回傳 null
double? interp(List<double> xs, List<double> ys, double x) {
  final n = xs.length < ys.length ? xs.length : ys.length;
  if (n == 0) return null;
  if (x <= xs[0]) return ys[0];
  for (var i = 1; i < n; i++) {
    if (x <= xs[i]) {
      final dx = xs[i] - xs[i - 1];
      if (dx <= 0) return ys[i];
      return ys[i - 1] + (x - xs[i - 1]) / dx * (ys[i] - ys[i - 1]);
    }
  }
  return ys[n - 1];
}

/// 單一幀判斷：符合條件回傳目標，否則 null
ProximityTarget? proximityCheck(ProximityInput m) {
  if (!m.vEgo.isFinite) return null;
  final kph = m.vEgo * 3.6;
  if (kph < proximityMinKph || kph > proximityMaxKph) return null;
  final x = m.leadX, y = m.leadY, p = m.leadProb;
  if (x == null || y == null || p == null || !x.isFinite || !y.isFinite || !p.isFinite) return null;
  if (p < proximityMinProb || p >= proximityMaxProb) return null;
  final d = x - radarToCamera;
  if (x <= 0 || d >= proximityMaxDist(kph)) return null;
  // 模型路徑同距離處 ±0.9 m
  final c = interp(m.pathX, m.pathY, x);
  if (c == null || (y - c).abs() > proximityPathHalfWidth) return null;
  return ProximityTarget(x: x, y: y, dRel: d, prob: p);
}

class ProximityAlert extends ChangeNotifier {
  ProximityAlert({Stopwatch? clock}) : _clock = clock ?? (Stopwatch()..start());
  static final ProximityAlert instance = ProximityAlert();

  static const holdFrames = 5; // 條件連續幾幀 modelV2 才觸發
  static const maxLatDrift = 0.6; // 持續期間橫向位置與第一幀最多差多少（m）
  static const maxStepD = 2.0; // 每幀距離最多變化多少（m）
  static const beepCooldown = 30.0; // 嗶過之後多久內不再嗶（秒）
  static const showAfter = 0.5; // 解除後箭頭再留多久
  static const _resetGap = 2.0;

  final Stopwatch _clock;
  double get _now => _clock.elapsedMicroseconds / 1e6;

  bool enabled = false;
  void configure({required bool enabled}) {
    if (enabled == this.enabled) return;
    this.enabled = enabled;
    _reset();
    notifyListeners();
  }

  /// 每次觸發一次（嗶一聲）
  final StreamController<ProximityTarget> _events = StreamController<ProximityTarget>.broadcast();
  Stream<ProximityTarget> get events => _events.stream;

  int _count = 0; // 條件連續成立的幀數
  ProximityTarget? _first, _prev; // 這段持續期間的第一幀 / 上一幀
  double? _beepAt; // 上次嗶的時間
  double _last = -1;
  ProximityTarget? _target;
  double _shownUntil = -1;

  /// 目前要顯示箭頭的目標（觸發中或剛解除 0.5 秒內）
  ProximityTarget? get active => activeAt(_now);
  ProximityTarget? activeAt(double now) => enabled && now < _shownUntil ? _target : null;

  void _reset() {
    _count = 0;
    _first = _prev = null;
    _beepAt = null;
    _target = null;
    _shownUntil = -1;
  }

  /// 每筆 modelV2 呼叫（約 20 Hz）
  /// [nowSec]：測試用的時間（秒）；平常用內部時鐘
  void update(ProximityInput m, {double? nowSec}) {
    if (!enabled) return;
    final now = nowSec ?? _now;
    if (_last >= 0 && now - _last > _resetGap) _reset();
    _last = now;
    final t = proximityCheck(m);
    if (t != null) {
      // 位置跳動（模型假目標的特徵）→ 從這一幀重新計時
      final f = _first, pv = _prev;
      if (f != null && pv != null &&
          ((t.y - f.y).abs() > maxLatDrift || (t.dRel - pv.dRel).abs() > maxStepD)) {
        _count = 0;
      }
      if (_count == 0) _first = t;
      _prev = t;
      _count++;
      if (_count >= holdFrames) {
        _target = t;
        _shownUntil = now + showAfter;
        if (_beepAt == null || now - _beepAt! >= beepCooldown) {
          _beepAt = now;
          debugPrint('[opview] 近距離警示：低信心目標 ${t.dRel.toStringAsFixed(1)} m、機率 ${t.prob.toStringAsFixed(2)}、'
              '橫向 ${t.y.toStringAsFixed(2)} m、本車 ${(m.vEgo * 3.6).round()} km/h');
          _events.add(t);
        }
      }
    } else {
      _count = 0;
      _first = _prev = null;
    }
  }
}
