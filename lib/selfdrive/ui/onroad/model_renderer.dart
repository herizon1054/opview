// model renderer — path, lane lines, road edges, lead indicators
// ported from openpilot selfdrive/ui/onroad/model_renderer.py
//
// CustomPainter that projects 3D model data to 2D screen space
// using the calibrated car-space transform matrix.
// no 3D engine — just matrix math and canvas paths.

import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/common/transformations.dart';

// -- constants (model_renderer.py:14-16) --

const clipMargin = 500.0;
const minDrawDistance = 10.0;
const maxDrawDistance = 100.0;

// path gradient colors (model_renderer.py:18-28)
const throttleColors = [
  Color.fromARGB(102, 13, 248, 122),
  Color.fromARGB(89, 114, 255, 92),
  Color.fromARGB(0, 114, 255, 92),
];
const noThrottleColors = [
  Color.fromARGB(102, 242, 242, 242),
  Color.fromARGB(89, 242, 242, 242),
  Color.fromARGB(0, 242, 242, 242),
];

// lead indicator colors (model_renderer.py:308-309)
const _leadGlowColor = Color.fromARGB(255, 218, 202, 37);
const _leadChevronBase = Color.fromARGB(255, 201, 34, 49);

// 鎖定框標籤：本車比前車快超過此值（km/h）時底色改為系統紅色
const _leadClosingWarnKph = 20.0;
// 系統紅色：同 alert_renderer 的 critical 警示底色（openpilot 0xC92231）
const _leadClosingBg = Color(0xF1C92231);

// 彩虹模式（儀表介面路徑）：對照參考影片逐格取樣（66–74 秒，10 fps）校正：
// - 色相隨「實際距離」線性變化（不是畫面高度）：近端大片同色、往遠處色帶越來越密；
//   影片前車約 46 m，路徑近端 → 前車約 140°（紅 → 黃 → 綠），擬合約每公尺 3.4°
// - 同一點色相每秒遞減約 50°（約 7 秒一輪，近端紅 → 紫 → 藍 → 綠 → 黃 → 紅）
// - 純色（HSL 飽和 1、亮度 .5），透明度遠近一致約 50%（不往遠處淡出）
const _rainbowDegPerMeter = 3.4;
const _rainbowDegPerSec = 50.0;
const _rainbowAlpha = .5;
const _rainbowMaxStops = 24;

// 前車鎖定框：以車身尺寸投影到畫面（距離越近框越大），超過原本上限（85 × 縮放）時改為「近距離樣式」
const _leadHalfWidthM = 0.9; // 一般小客車寬約 1.8 m
const _leadHeightM = 1.5;
const _leadBoxMaxW = 85.0; // 原本鎖定框寬度上限（遠距離樣式不變）
const _leadNearMaxFrac = .7; // 近距離框最寬為畫面寬的 70%

// -- data classes --

class LeadVehicle {
  List<Offset> glow;
  List<Offset> chevron;
  int fillAlpha;

  LeadVehicle() : glow = [], chevron = [], fillAlpha = 0;
}

// -- the painter --

class ModelRendererPainter extends CustomPainter {
  final UIState state;
  final List<List<double>> carSpaceTransform;
  final Rect contentRect;
  final int _version;

  ModelRendererPainter({
    required this.state,
    required this.carSpaceTransform,
    required this.contentRect,
  }) : _version = state.version;

  // working data — rebuilt each paint
  late Rect _clipRegion;
  late double _pathOffsetZ;

  // reusable working lists — cleared and refilled each call to avoid allocations
  final _leftScreen = <Offset>[];
  final _rightScreen = <Offset>[];
  final _expColors = <Color>[];
  final _expStops = <double>[];

  @override
  void paint(Canvas canvas, Size size) {
    if (state.pathX.isEmpty) return;
    if (state.rpyCalib.isEmpty) return;
    if (_isZeroTransform()) return;

    _clipRegion = contentRect.inflate(clipMargin);
    _pathOffsetZ = state.calibHeight.isNotEmpty ? state.calibHeight[0] : heightInit;

    // max draw distance from path end
    final pathX = state.pathX;
    var maxDist = pathX.last.clamp(minDrawDistance, maxDrawDistance);
    final maxIdx = _getPathLengthIdx(state.laneLineX[0], maxDist);

    // project lane lines
    final laneLinePolys = List.generate(4, (i) => _mapLineToPolygon(
      state.laneLineX[i], state.laneLineY[i], state.laneLineZ[i],
      0.025 * state.laneLineProbs[i].clamp(0.0, 1.0), 0.0, maxIdx, maxDist,
    ));

    // project road edges
    final roadEdgePolys = List.generate(2, (i) => _mapLineToPolygon(
      state.roadEdgeX[i], state.roadEdgeY[i], state.roadEdgeZ[i],
      0.025, 0.0, maxIdx, maxDist,
    ));

    // project path (shorten for lead vehicle)
    if (state.leadDistance != null) {
      final leadD = state.leadDistance! * 2.0;
      maxDist = (leadD - min(leadD * 0.35, 10.0)).clamp(0.0, maxDist);
    }
    final pathMaxIdx = _getPathLengthIdx(pathX, maxDist);
    final pathPoly = _mapLineToPolygon(
      pathX, state.pathY, state.pathZ,
      0.9, _pathOffsetZ, pathMaxIdx, maxDist, allowInvert: false,
    );

    // draw everything
    _drawLaneLines(canvas, laneLinePolys);
    _drawRoadEdges(canvas, roadEdgePolys);
    _drawPath(canvas, pathPoly, maxDist);
    _drawLeadIndicators(canvas, pathX);
  }

  // -- drawing --

  /// draw lane lines: white, alpha from probability
  void _drawLaneLines(Canvas canvas, List<List<Offset>> laneLines) {
    for (int i = 0; i < 4; i++) {
      if (laneLines[i].isEmpty) continue;
      final alpha = (state.laneLineProbs[i].clamp(0.0, 0.7) * 255).round();
      _drawPolygon(canvas, laneLines[i], Color.fromARGB(alpha, 255, 255, 255));
    }
  }

  /// draw road edges: red, alpha from 1-std
  void _drawRoadEdges(Canvas canvas, List<List<Offset>> roadEdges) {
    for (int i = 0; i < 2; i++) {
      if (roadEdges[i].isEmpty) continue;
      final alpha = ((1.0 - state.roadEdgeStds[i]).clamp(0.0, 1.0) * 255).round();
      _drawPolygon(canvas, roadEdges[i], Color.fromARGB(alpha, 255, 0, 0));
    }
  }

  /// draw path: gradient from bottom to top
  void _drawPath(Canvas canvas, List<Offset> pathPoly, double maxDist) {
    if (pathPoly.isEmpty) return;

    if (state.modernOverlay) {
      if (state.rainbowPath) {
        _drawRainbowPath(canvas, pathPoly, maxDist);
      } else {
        _drawGradientPolygon(canvas, pathPoly, const [
          Color(0x882CD4C3), Color(0x552CD4C3), Color(0x102CD4C3),
        ], [0.0, 0.6, 1.0]);
      }
      final outline = Path()..addPolygon(pathPoly, true);
      canvas.drawPath(outline, Paint()..color = const Color(0xAA61E3D4)
        ..style = PaintingStyle.stroke..strokeWidth = 2);
      return;
    }
    if (state.experimentalMode) {
      _drawExperimentalPath(canvas, pathPoly);
      return;
    }

    final blend = state.throttleBlend.clamp(0.0, 1.0);
    final colors = [
      for (int i = 0; i < throttleColors.length; i++)
        Color.lerp(noThrottleColors[i], throttleColors[i], blend)!,
    ];
    _drawGradientPolygon(canvas, pathPoly, colors, [0.0, 0.5, 1.0]);
  }

  /// 彩虹模式：沿路徑排列的彩虹色帶（色相依路徑點的實際距離），隨時間流動。
  /// 每次 modelV2 更新重畫（約 20 Hz），以牆鐘決定相位，不需要另外的動畫計時器。
  void _drawRainbowPath(Canvas canvas, List<Offset> pathPoly, double maxDist) {
    if (pathPoly.length < 3) return;
    final t = DateTime.now().millisecondsSinceEpoch / 1000.0;
    final phase = (t * _rainbowDegPerSec) % 360.0;
    Color colorAt(double d) => HSLColor.fromAHSL(
        _rainbowAlpha, (d * _rainbowDegPerMeter - phase) % 360.0, 1.0, .5).toColor();

    // 漸層範圍 = 多邊形上下界（同 _drawGradientPolygon）
    var minY = double.infinity, maxY = double.negativeInfinity;
    for (final p in pathPoly) {
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }
    final h = maxY - minY;
    if (h < 1) return;

    // 路徑中心線各點投影到畫面，以畫面 y 當漸層位置、距離決定色相（只取由下往上單調的點）
    final pathX = state.pathX, pathY = state.pathY, pathZ = state.pathZ;
    final n = min(pathX.length, min(pathY.length, pathZ.length));
    final dist = <double>[], pos = <double>[];
    var lastPos = -1.0;
    for (var i = 0; i < n; i++) {
      final x = pathX[i];
      if (x < 0) continue;
      final over = x > maxDist;
      final d = over ? maxDist : x;
      double y = pathY[i], z = pathZ[i];
      if (over && i > 0 && x != pathX[i - 1]) {
        final k = ((maxDist - pathX[i - 1]) / (x - pathX[i - 1])).clamp(0.0, 1.0).toDouble();
        y = pathY[i - 1] + k * (y - pathY[i - 1]);
        z = pathZ[i - 1] + k * (z - pathZ[i - 1]);
      }
      final sy = _projectY(d, y, z + _pathOffsetZ);
      if (sy != null) {
        final f = ((maxY - sy) / h).clamp(0.0, 1.0).toDouble();
        if (f > lastPos + .002) {
          dist.add(d);
          pos.add(f);
          lastPos = f;
        }
      }
      if (over) break;
    }
    if (dist.isEmpty) {
      _drawPolygon(canvas, pathPoly, colorAt(0));
      return;
    }

    // 點太多時抽樣（保留最後一點），並補齊 0 / 1 兩端
    final colors = <Color>[], stops = <double>[];
    final step = max(1, (dist.length / _rainbowMaxStops).ceil());
    if (pos.first > 0) {
      colors.add(colorAt(dist.first));
      stops.add(0.0);
    }
    for (var i = 0; i < dist.length; i += step) {
      colors.add(colorAt(dist[i]));
      stops.add(pos[i]);
    }
    if (stops.last < pos.last) {
      colors.add(colorAt(dist.last));
      stops.add(pos.last);
    }
    if (stops.last < 1) {
      colors.add(colorAt(dist.last));
      stops.add(1.0);
    }
    if (colors.length < 2) {
      _drawPolygon(canvas, pathPoly, colors.first);
      return;
    }
    _drawGradientPolygon(canvas, pathPoly, colors, stops);
  }

  /// 3D 點投影到畫面的 y（w 太小回傳 null）
  double? _projectY(double x, double y, double z) {
    final t = carSpaceTransform;
    final w = t[2][0] * x + t[2][1] * y + t[2][2] * z;
    if (w.abs() < 1e-6) return null;
    return (t[1][0] * x + t[1][1] * y + t[1][2] * z) / w;
  }

  /// experimental mode: HSL acceleration gradient
  void _drawExperimentalPath(Canvas canvas, List<Offset> pathPoly) {
    if (pathPoly.length < 2) return;

    final maxLen = min(pathPoly.length ~/ 2, state.accelerationX.length);
    if (maxLen < 2) {
      _drawPolygon(canvas, pathPoly, const Color.fromARGB(30, 255, 255, 255));
      return;
    }

    _expColors.clear();
    _expStops.clear();

    for (int i = 0; i < maxLen; i++) {
      final trackY = pathPoly[i].dy;
      if (trackY < contentRect.top || trackY > contentRect.bottom) continue;

      final linGradPoint = 1.0 - (trackY - contentRect.top) / contentRect.height;
      final pathHue = (60 + state.accelerationX[i] * 35).clamp(0.0, 120.0);
      final saturation = (state.accelerationX[i].abs() * 1.5).clamp(0.0, 1.0);
      final lightness = _lerp(0.95, 0.62, saturation);
      final alpha = _lerp(0.4, 0.0, ((linGradPoint - 0.375) / 0.375).clamp(0.0, 1.0));

      _expColors.add(_hslaToColor(pathHue, saturation, lightness, alpha));
      _expStops.add(linGradPoint);
    }

    if (_expColors.length > 1) {
      _drawGradientPolygon(canvas, pathPoly, _expColors, _expStops);
    } else {
      _drawPolygon(canvas, pathPoly, const Color.fromARGB(30, 255, 255, 255));
    }
  }

  /// draw lead vehicle indicators
  void _drawLeadIndicators(Canvas canvas, List<double> pathX) {
    final leads = [state.leadOne, state.leadTwo];
    double? oneD, oneY; // leadOne 位置（leadTwo 與它重疊時不畫箭頭）
    for (var li = 0; li < leads.length; li++) {
      final lead = leads[li];
      if (lead == null || !leadPresent(lead)) continue;

      final dRel = (lead['dRel'] as num?)?.toDouble();
      final vRel = (lead['vRel'] as num?)?.toDouble() ?? 0;
      final yRel = (lead['yRel'] as num?)?.toDouble();
      if (dRel == null || yRel == null || !dRel.isFinite ||
          !yRel.isFinite || !vRel.isFinite || dRel <= 0) {
        continue;
      }
      if (state.lastRadarAt != null &&
          DateTime.now().difference(state.lastRadarAt!).inMilliseconds > 2000) {
        continue;
      }
      final idx = _getPathLengthIdx(pathX, dRel);

      final z = (idx < state.pathZ.length) ? state.pathZ[idx] : 0.0;
      final point = _mapToScreen(dRel, -yRel, z + _pathOffsetZ);
      if (point == null) continue;

      if (state.modernOverlay) {
        if (li == 0) {
          // leadOne：鎖定框（含十字線）+ 下方距離 / 速度標籤
          // 前車速度：radarState LeadData.vLead（m/s，絕對速度）；沒有時以 vEgo + vRel 推算
          final vLeadRaw = (lead['vLead'] as num?)?.toDouble();
          final vLead = (vLeadRaw != null && vLeadRaw.isFinite) ? vLeadRaw : state.vEgo + vRel;
          // 車身在畫面上的範圍：左右各 0.9 m、高 1.5 m（地面 → 車頂），用來決定近距離時的框大小
          Rect? body;
          final groundZ = z + _pathOffsetZ;
          final l = _mapToScreen(dRel, -yRel - _leadHalfWidthM, groundZ);
          final r = _mapToScreen(dRel, -yRel + _leadHalfWidthM, groundZ);
          final top = _mapToScreen(dRel, -yRel, groundZ - _leadHeightM);
          if (l != null && r != null && top != null && top.dy < point.dy) {
            body = Rect.fromLTRB(min(l.dx, r.dx), top.dy, max(l.dx, r.dx), point.dy);
          }
          _drawLeadBox(canvas, point, dRel, vLead, body);
          oneD = dRel;
          oneY = yRel;
        } else {
          // leadTwo：目標下方紅色箭頭（與 leadOne 幾乎同一位置時不畫，避免疊在鎖定框上）
          if (oneD != null && (dRel - oneD).abs() < 3 && (yRel - oneY!).abs() < 1.5) continue;
          _drawLeadTwoArrow(canvas, point, dRel);
        }
        continue;
      }
      final lv = _buildLeadVehicle(dRel, vRel, point);
      _drawLeadTriangles(canvas, lv);
    }
  }

  // A projected radar marker, not an image-detection bounding box.
  //
  // 遠距離（車身投影寬度 ≤ 85 × 縮放）：四角括號 + 十字線，標籤在框下方；框寬改為跟著車身投影變大。
  // 近距離（車身投影更寬）：框住整台車的方框（細邊框 + 半透明底），標籤移到框內約車牌高度；
  //   框寬上限為畫面寬 70%，超出畫面的部分裁掉。
  void _drawLeadBox(Canvas canvas, Offset point, double distance, double vLead, [Rect? body]) {
    // 依短邊縮放：橫向 = 高（與原本相同），直向 = 寬，兩種方向外觀一致
    final scale = (min(contentRect.width, contentRect.height) / 600).clamp(0.6, 2.0);
    final unit = state.isMetric ? 'km' : 'mph';
    final conv = state.isMetric ? msToKph : msToMph;
    final speed = vLead.isFinite ? (max(0.0, vLead) * conv).round().toString() : '—';
    final label = '${distance.round()} m · $speed $unit';
    final closing = vLead.isFinite && state.vEgo.isFinite &&
        (state.vEgo - vLead) * msToKph > _leadClosingWarnKph;

    if (body != null && body.width > _leadBoxMaxW * scale && body.height > 0) {
      _drawLeadBoxNear(canvas, body, label, closing, scale);
      return;
    }

    // 括號框寬度：取「原本依距離的寬度」與「車身投影寬度」較大者，上限 85 × 縮放；
    // 接近上限時框的底部逐漸貼齊前車底部，切換成近距離方框時不會跳動
    final maxW = _leadBoxMaxW * scale;
    final legacyW = (1500 / distance).clamp(28.0, _leadBoxMaxW) * scale;
    final width = body == null ? legacyW : max(legacyW, min(body.width, maxW));
    final t = ((width / maxW - .6) / .4).clamp(0.0, 1.0);
    final rect = Rect.fromLTWH(point.dx - width / 2, point.dy - width * .3 * (1 - t) - width * .7,
        width, width * .7);
    final paint = Paint()..color = const Color(0xFF61E3D4)
      ..style = PaintingStyle.stroke..strokeWidth = 2 * scale;
    final arm = width * .23;
    for (final corner in [rect.topLeft, rect.topRight, rect.bottomLeft, rect.bottomRight]) {
      final dx = corner.dx == rect.left ? arm : -arm;
      final dy = corner.dy == rect.top ? arm : -arm;
      canvas.drawPath(Path()..moveTo(corner.dx + dx, corner.dy)
        ..lineTo(corner.dx, corner.dy)..lineTo(corner.dx, corner.dy + dy), paint);
    }
    // 框內十字線（中心留小缺口，不遮住前車）
    final cross = Paint()..color = paint.color.withAlpha(200)
      ..style = PaintingStyle.stroke..strokeWidth = 1.2 * scale;
    final c = rect.center;
    final gapC = width * .07;
    canvas.drawLine(Offset(rect.left + width * .18, c.dy), Offset(c.dx - gapC, c.dy), cross);
    canvas.drawLine(Offset(c.dx + gapC, c.dy), Offset(rect.right - width * .18, c.dy), cross);
    canvas.drawLine(Offset(c.dx, rect.top + rect.height * .14), Offset(c.dx, c.dy - gapC), cross);
    canvas.drawLine(Offset(c.dx, c.dy + gapC), Offset(c.dx, rect.bottom - rect.height * .14), cross);
    // 鎖定框下方：距離（固定公尺）· 前車速度（km 或 mph，不顯示 /h）。車距時間仍在右側儀表卡片。
    // 本車比前車快超過 20 km/h：底色改為系統紅色（與 critical 警示同色 0xC92231）。
    // 一律放框下方；只有超出畫面底部時往上收，避免被切掉
    _drawLeadLabel(canvas, label, closing, scale, centerX: point.dx, top: rect.bottom + 8 * scale);
  }

  /// 近距離鎖定框：框住整台車，細邊框 + 半透明底 + 四角加粗；標籤在框內約車牌高度
  void _drawLeadBoxNear(Canvas canvas, Rect body, String label, bool closing, double scale) {
    var rect = body;
    final maxW = contentRect.width * _leadNearMaxFrac;
    if (rect.width > maxW) {
      // 以底部中心為基準等比縮小（框仍貼著前車底部）
      final k = maxW / rect.width;
      rect = Rect.fromLTRB(rect.center.dx - maxW / 2, rect.bottom - rect.height * k,
          rect.center.dx + maxW / 2, rect.bottom);
    }
    rect = rect.intersect(contentRect.deflate(2));
    if (rect.width <= 0 || rect.height <= 0) return;
    const c = Color(0xFF61E3D4);
    canvas.drawRect(rect, Paint()..color = const Color(0x2261E3D4));
    canvas.drawRect(rect, Paint()..color = c.withAlpha(220)
      ..style = PaintingStyle.stroke..strokeWidth = 1.6 * scale);
    // 四角加粗短邊，與遠距離的括號樣式呼應
    final arm = min(rect.width, rect.height) * .12;
    final corner = Paint()..color = c..style = PaintingStyle.stroke
      ..strokeWidth = 3.2 * scale..strokeCap = StrokeCap.square;
    for (final p in [rect.topLeft, rect.topRight, rect.bottomLeft, rect.bottomRight]) {
      final dx = p.dx == rect.left ? arm : -arm;
      final dy = p.dy == rect.top ? arm : -arm;
      canvas.drawPath(Path()..moveTo(p.dx + dx, p.dy)..lineTo(p.dx, p.dy)..lineTo(p.dx, p.dy + dy), corner);
    }
    // 標籤字級隨框放大（最多 1.6 倍），放在框內 70% 高度（約車牌位置）
    final grow = (rect.width / (_leadBoxMaxW * scale)).clamp(1.0, 1.6);
    _drawLeadLabel(canvas, label, closing, scale * grow,
        centerX: rect.center.dx, top: rect.top + rect.height * .70);
  }

  /// 鎖定框標籤（距離 · 前車速度）；超出畫面時往內收
  void _drawLeadLabel(Canvas canvas, String label, bool closing, double scale,
      {required double centerX, required double top}) {
    final text = TextPainter(text: TextSpan(text: label,
      style: TextStyle(color: Colors.white, fontSize: 12 * scale, fontWeight: FontWeight.w600)),
      textDirection: TextDirection.ltr)..layout();
    final oy = min(top, contentRect.bottom - text.height - 4 * scale);
    final minX = contentRect.left + 10 * scale;
    final maxX = max(minX, contentRect.right - text.width - 10 * scale);
    final ox = min(max(centerX - text.width / 2, minX), maxX);
    final origin = Offset(ox, oy);
    canvas.drawRRect(RRect.fromRectAndRadius(
      Rect.fromLTWH(origin.dx - 7 * scale, origin.dy - 4 * scale,
        text.width + 14 * scale, text.height + 8 * scale), Radius.circular(10 * scale)),
      Paint()..color = closing ? _leadClosingBg : const Color(0xDD10191D));
    text.paint(canvas, origin);
    text.dispose();
  }

  /// leadTwo：目標點（車輛底部）下方的紅色向上箭頭，大小依距離縮放（同鎖定框的縮放規則）
  void _drawLeadTwoArrow(Canvas canvas, Offset point, double distance) {
    final scale = (min(contentRect.width, contentRect.height) / 600).clamp(0.6, 2.0);
    final w = (900 / distance).clamp(16.0, 38.0) * scale;
    final h = w * .8;
    // 一律放目標下方；超出畫面底部時往上收
    final top = min(point.dy + 4 * scale, contentRect.bottom - h - 4 * scale);
    final path = Path()
      ..moveTo(point.dx, top)                                // 尖端朝上指向目標
      ..lineTo(point.dx + w / 2, top + h * .55)
      ..lineTo(point.dx + w * .2, top + h * .55)
      ..lineTo(point.dx + w * .2, top + h)
      ..lineTo(point.dx - w * .2, top + h)
      ..lineTo(point.dx - w * .2, top + h * .55)
      ..lineTo(point.dx - w / 2, top + h * .55)
      ..close();
    canvas.drawPath(path, Paint()..color = const Color(0xFFE5393B));
    canvas.drawPath(path, Paint()..color = const Color(0xCC10191D)
      ..style = PaintingStyle.stroke..strokeWidth = 1.5 * scale);
  }

  // -- projection --

  /// project a single 3D point to screen space
  Offset? _mapToScreen(double x, double y, double z) {
    final pt = matvec3(carSpaceTransform, [x, y, z]);
    if (pt[2].abs() < 1e-6) return null;

    final sx = pt[0] / pt[2];
    final sy = pt[1] / pt[2];
    if (!_clipRegion.contains(Offset(sx, sy))) return null;

    return Offset(sx, sy);
  }

  /// convert 3D line (xyz lists) to 2D polygon (left side + right side reversed)
  /// core projection: offset left/right, project, clip, concatenate
  List<Offset> _mapLineToPolygon(
    List<double> xList, List<double> yList, List<double> zList,
    double yOff, double zOff, int maxIdx, double maxDistance, {
    bool allowInvert = true,
  }) {
    final n = min(xList.length, min(yList.length, zList.length));
    if (n == 0) return [];

    _leftScreen.clear();
    _rightScreen.clear();

    final end = min(maxIdx + 1, n);
    for (int i = 0; i < end; i++) {
      if (xList[i] < 0) continue;
      _projectPair(xList[i], yList[i], zList[i], yOff, zOff, _leftScreen, _rightScreen);
    }

    // interpolate endpoint for smooth ending
    if (maxIdx > 0 && maxIdx < n - 1) {
      final x0 = xList[maxIdx], x1 = xList[maxIdx + 1];
      if (x1 != x0) {
        final t = (maxDistance - x0) / (x1 - x0);
        _projectPair(
          maxDistance,
          yList[maxIdx] + t * (yList[maxIdx + 1] - yList[maxIdx]),
          zList[maxIdx] + t * (zList[maxIdx + 1] - zList[maxIdx]),
          yOff, zOff, _leftScreen, _rightScreen,
        );
      }
    }

    if (_leftScreen.isEmpty) return [];

    // handle Y-inversion on hills: keep only monotonically decreasing Y
    if (!allowInvert && _leftScreen.length > 1) {
      final kept = <int>[0];
      var minY = _leftScreen[0].dy;
      for (int i = 1; i < _leftScreen.length; i++) {
        if (_leftScreen[i].dy <= minY) {
          minY = _leftScreen[i].dy;
          kept.add(i);
        }
      }
      if (kept.isEmpty) return [];
      final filteredLeft = kept.map((i) => _leftScreen[i]).toList();
      final filteredRight = kept.map((i) => _rightScreen[i]).toList();
      return [...filteredLeft, ...filteredRight.reversed];
    }

    return [..._leftScreen, ..._rightScreen.reversed];
  }

  // project a point with left/right offset, append to output lists if in clip region
  // matvec3 inlined to avoid allocating List<double> per call (~462 calls/frame)
  void _projectPair(double x, double y, double z,
      double yOff, double zOff, List<Offset> leftOut, List<Offset> rightOut) {
    final t = carSpaceTransform;
    final ly = y - yOff, ry = y + yOff, oz = z + zOff;

    // left point: t @ [x, ly, oz]
    final lw = t[2][0] * x + t[2][1] * ly + t[2][2] * oz;
    if (lw.abs() < 1e-6) return;
    final lsx = (t[0][0] * x + t[0][1] * ly + t[0][2] * oz) / lw;
    final lsy = (t[1][0] * x + t[1][1] * ly + t[1][2] * oz) / lw;

    // right point: t @ [x, ry, oz]
    final rw = t[2][0] * x + t[2][1] * ry + t[2][2] * oz;
    if (rw.abs() < 1e-6) return;
    final rsx = (t[0][0] * x + t[0][1] * ry + t[0][2] * oz) / rw;
    final rsy = (t[1][0] * x + t[1][1] * ry + t[1][2] * oz) / rw;

    if (!_clipRegion.contains(Offset(lsx, lsy))) return;
    if (!_clipRegion.contains(Offset(rsx, rsy))) return;

    leftOut.add(Offset(lsx, lsy));
    rightOut.add(Offset(rsx, rsy));
  }

  // -- lead vehicle geometry (model_renderer.py:234-256) --

  LeadVehicle _buildLeadVehicle(double dRel, double vRel, Offset point) {
    final lv = LeadVehicle();

    // fill alpha: closer = more opaque, closing speed increases it
    const speedBuff = 10.0, leadBuff = 40.0;
    var fillAlpha = 0.0;
    if (dRel < leadBuff) {
      fillAlpha = 255 * (1.0 - dRel / leadBuff);
      if (vRel < 0) fillAlpha += 255 * (-vRel / speedBuff);
      fillAlpha = fillAlpha.clamp(0.0, 255.0);
    }
    lv.fillAlpha = fillAlpha.round();

    // size: bigger when closer, scaled to match stock 1080p reference
    final scale = min(contentRect.width, contentRect.height) / 1080.0; // 依短邊（直向一致）
    final sz = ((25 * 30) / (dRel / 3 + 30)).clamp(15.0, 30.0) * 2.35 * scale;
    final x = point.dx.clamp(0.0, contentRect.width - sz / 2);
    final y = min(point.dy, contentRect.height - sz * 0.6);

    final gxo = sz / 5, gyo = sz / 10;

    lv.glow = [
      Offset(x + sz * 1.35 + gxo, y + sz + gyo),
      Offset(x, y - gyo),
      Offset(x - sz * 1.35 - gxo, y + sz + gyo),
    ];
    lv.chevron = [
      Offset(x + sz * 1.25, y + sz),
      Offset(x, y),
      Offset(x - sz * 1.25, y + sz),
    ];

    return lv;
  }

  // -- canvas helpers --

  /// draw a filled polygon with solid color
  void _drawPolygon(Canvas canvas, List<Offset> points, Color color) {
    if (points.length < 3) return;
    final path = ui.Path()..addPolygon(points, true);
    canvas.drawPath(path, Paint()..color = color);
  }

  /// draw polygon with vertical gradient
  void _drawGradientPolygon(Canvas canvas, List<Offset> points, List<Color> colors, List<double> stops) {
    if (points.length < 3) return;

    final path = ui.Path()..addPolygon(points, true);

    // find bounding box for gradient
    var minY = double.infinity, maxY = double.negativeInfinity;
    for (final p in points) {
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }

    final shader = ui.Gradient.linear(
      Offset(0, maxY),  // bottom (gradient start = 0.0)
      Offset(0, minY),  // top (gradient end = 1.0)
      colors,
      stops,
    );

    canvas.drawPath(path, Paint()..shader = shader);
  }

  /// draw lead glow + chevron triangles
  void _drawLeadTriangles(Canvas canvas, LeadVehicle lv) {
    if (lv.glow.length < 3 || lv.chevron.length < 3) return;

    // glow: yellow
    final glowPath = ui.Path()..addPolygon(lv.glow, true);
    canvas.drawPath(glowPath, Paint()..color = _leadGlowColor);

    // chevron: red with distance-based alpha
    final chevronPath = ui.Path()..addPolygon(lv.chevron, true);
    canvas.drawPath(chevronPath, Paint()..color = _leadChevronBase.withAlpha(lv.fillAlpha));
  }

  // -- utility --

  /// find the index where posX <= distance
  int _getPathLengthIdx(List<double> posX, double distance) {
    if (posX.isEmpty) return 0;
    int idx = 0;
    for (int i = 0; i < posX.length; i++) {
      if (posX[i] <= distance) idx = i;
    }
    return idx;
  }

  /// check if transform is all zeros (not yet calibrated)
  bool _isZeroTransform() {
    for (final row in carSpaceTransform) {
      for (final v in row) {
        if (v != 0.0) return false;
      }
    }
    return true;
  }

  /// HSL+alpha to Color (model_renderer.py:412-420)
  /// h in degrees (0-360), s/l in 0-1, a in 0-1
  Color _hslaToColor(double h, double s, double l, double a) {
    return HSLColor.fromAHSL(a, h, s, l).toColor();
  }

  double _lerp(double a, double b, double t) => a + (b - a) * t;

  @override
  bool shouldRepaint(ModelRendererPainter oldDelegate) =>
    oldDelegate._version != _version || !identical(oldDelegate.carSpaceTransform, carSpaceTransform);
}
