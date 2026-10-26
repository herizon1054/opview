// Phone-rendered dashboard inspired by CommaView's public Live View layout.
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../ui_state.dart';

const dashboardTeal = Color(0xFF61E3D4);

/// TDX 壅塞分級顏色。分級與 tici 相同（smooth / slow / congested），
/// 色值改用 opview 儀表盤色系：順暢 = 主色青綠，車多 / 壅塞用低飽和琥珀 / 珊瑚，
/// 避免 tici 的高飽和純黃、純紅在深色儀表卡片上太跳。
const tdxSmoothColor = dashboardTeal;              // tici: (128, 216, 166)
const tdxSlowColor = Color(0xFFE2C275);            // tici: (255, 204, 0)
const tdxCongestedColor = Color(0xFFE88A80);       // tici: (255, 100, 100)
Color tdxCongestionColor(String congestion) => switch (congestion) {
  'smooth' => tdxSmoothColor,
  'slow' => tdxSlowColor,
  'congested' => tdxCongestedColor,
  _ => Colors.white70,
};

class DashboardHud extends StatelessWidget {
  final UIState state;
  final bool stale;
  const DashboardHud({super.key, required this.state, this.stale = false});

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
    // 整體縮小 10%（原 .60 / 1.20）；卡片內字級、圖示皆依卡片高度等比，一起縮
    final width = math.min(box.maxWidth * .54, box.maxHeight * 1.08);
    final status = stale ? '資料中斷' : switch (state.status) {
      UIStatus.engaged => 'ENGAGED',
      UIStatus.override_ => 'OVERRIDE',
      UIStatus.disengaged => 'DISENGAGED',
    };
    final color = stale ? Colors.orangeAccent : state.status == UIStatus.engaged
        ? dashboardTeal : Colors.white70;
    return IgnorePointer(child: Stack(children: [
      const Positioned(top: 16, left: 18, child: Text('opview',
        style: TextStyle(fontSize: 20, color: Colors.white70, fontWeight: FontWeight.w700))),
      Positioned(left: 14, bottom: 18, child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min,
        children: [
          if (state.experimentalMode && !stale)
            _badge('EXPERIMENTAL', Colors.amberAccent),
          const SizedBox(height: 6), _badge(status, color),
        ],
      )),
      Positioned(bottom: 14, left: (box.maxWidth - width) / 2, width: width,
        height: width * .31,
        child: DecoratedBox(decoration: BoxDecoration(
          color: const Color(0xDC0D171C), borderRadius: BorderRadius.circular(28),
          border: Border.all(color: const Color(0x335DE3D4))),
          child: LayoutBuilder(builder: (context, constraints) {
            final h = constraints.maxHeight;
            return Row(children: [
              Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text('MAX', style: TextStyle(color: color, fontSize: h * .10,
                    fontWeight: FontWeight.w700, letterSpacing: 2)),
                Text(!stale && state.isCruiseSet ? '${state.setSpeed.round()}' : '—',
                    style: TextStyle(fontSize: h * .26, fontWeight: FontWeight.w700)),
              ])),
              Expanded(flex: 3, child: CustomPaint(
                painter: _GaugePainter(stale ? 0 : state.displaySpeed,
                  state.isMetric ? 160 : 100, color),
                child: Center(child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                  Text(stale ? '—' : '${state.displaySpeed.round()}',
                    style: TextStyle(fontSize: h * .42, fontWeight: FontWeight.w700, height: 1)),
                  Text(state.isMetric ? 'km/h' : 'mph',
                    style: TextStyle(fontSize: h * .10, color: Colors.white70)),
                  SizedBox(height: h * .09),
                  Text(stale ? 'TELEMETRY STALE' : 'LIVE TELEMETRY',
                    style: TextStyle(fontSize: h * .065, color: color, letterSpacing: 1.3)),
                  SizedBox(height: h * .07),
                ])),
              )),
              Expanded(child: _rightColumn(h, color)),
            ]);
          }),
        )),
    ]));
  });

  // 右欄：有 TDX 前方車速時，小車圖示改成「前方車速」文字、下方顯示車速（依壅塞分級上色）；
  // 前車距離 / 車頭時距縮成一行保留在最下面。沒有 TDX 資料時維持原本的小車 + 距離。
  Widget _rightColumn(double h, Color color) {
    final tdxSpeed = stale ? null : state.tdxNextSpeedDisplay;
    final dist = !stale ? state.leadDistance : null;
    final headway = !stale ? state.leadHeadway : null;
    if (tdxSpeed == null) {
      return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.directions_car_outlined, color: color, size: h * .18),
        Text(dist != null ? '${dist.round()} m' : '—',
            style: TextStyle(fontSize: h * .12, fontWeight: FontWeight.w600)),
        Text(headway != null ? '${headway.toStringAsFixed(1)} s' : '—',
            style: TextStyle(fontSize: h * .10, color: Colors.white60)),
      ]);
    }
    final tdxColor = tdxCongestionColor(state.tdxCongestion);
    final lead = dist == null ? null
        : headway == null ? '${dist.round()} m' : '${dist.round()} m · ${headway.toStringAsFixed(1)} s';
    return FittedBox(fit: BoxFit.scaleDown, child: Column(
      mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
      // 標籤與 MAX 同層級（淡白），只有數字帶分級色
      Text('前方車速', style: TextStyle(fontSize: h * .10, color: Colors.white70,
          fontWeight: FontWeight.w600, letterSpacing: 1, height: 1.2)),
      Text('$tdxSpeed', style: TextStyle(fontSize: h * .22, color: tdxColor,
          fontWeight: FontWeight.w700, height: 1.05)),
      Text(state.isMetric ? 'km/h' : 'mph',
          style: TextStyle(fontSize: h * .08, color: Colors.white70, height: 1.2)),
      if (lead != null) ...[
        SizedBox(height: h * .03),
        Text(lead, style: TextStyle(fontSize: h * .08, color: Colors.white60, height: 1.2)),
      ],
    ]));
  }

  Widget _badge(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
    decoration: BoxDecoration(color: const Color(0xDB10191D),
      borderRadius: BorderRadius.circular(20), border: Border.all(color: color.withAlpha(100))),
    child: Text(text, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700)),
  );
}

class _GaugePainter extends CustomPainter {
  final double speed, maximum;
  final Color color;
  _GaugePainter(this.speed, this.maximum, this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final radius = math.min(size.width / 2 - 6, size.height * .76);
    if (radius <= 0) return;
    final center = Offset(size.width / 2, size.height * .82);
    final rect = Rect.fromCircle(center: center, radius: radius);
    final pen = Paint()..style = PaintingStyle.stroke..strokeWidth = 4..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, math.pi, math.pi, false, pen..color = const Color(0xFF35484D));
    final fraction = speed.isFinite ? (speed / maximum).clamp(0.0, 1.0) : 0.0;
    canvas.drawArc(rect, math.pi, math.pi * fraction, false, pen..color = color);
    pen..strokeWidth = 1.5..color = Colors.white38;
    for (var i = 0; i <= 10; i++) {
      final a = math.pi + i * math.pi / 10;
      final outer = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(center + outer * (radius - 7), center + outer * (radius - 13), pen);
    }
  }
  @override
  bool shouldRepaint(_GaugePainter old) => old.speed != speed || old.maximum != maximum || old.color != color;
}
