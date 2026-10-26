// Phone-rendered dashboard inspired by CommaView's public Live View layout.
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../ui_state.dart';

const dashboardTeal = Color(0xFF61E3D4);

class DashboardHud extends StatelessWidget {
  final UIState state;
  final bool stale;
  const DashboardHud({super.key, required this.state, this.stale = false});

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
    final width = math.min(box.maxWidth * .60, box.maxHeight * 1.20);
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
              Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.directions_car_outlined, color: color, size: h * .18),
                Text(!stale && state.leadDistance != null ? '${state.leadDistance!.round()} m' : '—',
                    style: TextStyle(fontSize: h * .12, fontWeight: FontWeight.w600)),
                Text(!stale && state.leadHeadway != null ? '${state.leadHeadway!.toStringAsFixed(1)} s' : '—',
                    style: TextStyle(fontSize: h * .10, color: Colors.white60)),
              ])),
            ]);
          }),
        )),
    ]));
  });

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
