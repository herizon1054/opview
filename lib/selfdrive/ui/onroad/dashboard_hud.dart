// Phone-rendered dashboard inspired by CommaView's public Live View layout.
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../ui_state.dart';

const dashboardTeal = Color(0xFF61E3D4);

/// TDX 壅塞分級顏色。分級與 tici 相同（smooth / slow / congested），
/// 色值改用 opview 儀表盤色系：順暢 = 主色青綠，車多 / 壅塞用低飽和琥珀 / 珊瑚，
/// 避免 tici 的高飽和純黃、純紅在深色儀表卡片上太跳。
/// 方向燈箭頭顏色（紅，略降亮度以配合深色儀表卡片）
const blinkerRed = Color(0xFFF0524A);
/// 擋位字母顏色：P 紅（與方向燈箭頭同色）、R 綠（略降飽和配合深色卡片）、N 白
const parkRed = blinkerRed;
const reverseGreen = Color(0xFF6BD98A);
const neutralWhite = Colors.white;
Color gearColor(String letter) => switch (letter) {
  'P' => parkRed,
  'R' => reverseGreen,
  _ => neutralWhite,
};

// -- 儀表卡片尺寸：比例取自 CommaView 實拍畫面（1164×668 影格量測）--
//   卡片寬 = 畫面寬 41.2% 與 畫面高 71.9% 取小者；卡片高 = 寬 × 0.3375；
//   底邊距 = 畫面高 3.9%；水平置中。方向燈箭頭 ≈ 卡片高 0.34，距卡片外緣約 3% 卡片寬。
//   （opview 刻意差異：底邊距改 2%、箭頭放大一倍為 0.68，見下方常數）
const _cardWidthOfW = .412, _cardWidthOfH = .719;
const _cardAspect = .3375;
const _cardBottomOfH = .02;
// 直向：卡片放寬到畫面寬 66%（橫向比例在窄螢幕只剩約 160dp），兩側仍留方向燈空間
const _cardWidthOfWPortrait = .66;   // CommaView 為 3.9%，依需求改 2%

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
    // 卡片內字級、圖示皆依卡片高度等比
    final portrait = box.maxHeight > box.maxWidth;
    final width = portrait
        ? box.maxWidth * _cardWidthOfWPortrait
        : math.min(box.maxWidth * _cardWidthOfW, box.maxHeight * _cardWidthOfH);
    final cardH = width * _cardAspect;
    final bottom = box.maxHeight * _cardBottomOfH;
    final cardLeft = (box.maxWidth - width) / 2;
    final (status, color) = dashboardStatus(state, stale);
    return IgnorePointer(child: Stack(children: [
      const Positioned(top: 16, left: 18, child: Text('opview',
        style: TextStyle(fontSize: 20, color: Colors.white70, fontWeight: FontWeight.w700))),
      // 狀態徽章：橫向與卡片垂直置中對齊（同 CommaView），徽章高約 26dp；
      // 直向卡片佔大部分寬度，改放卡片上方左側，避免重疊
      if (portrait)
        Positioned(left: cardLeft, bottom: bottom + cardH + 8, child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _badge(status, color),
            if (state.experimentalMode && !stale) ...[
              const SizedBox(width: 6), _badge('EXPERIMENTAL', Colors.amberAccent),
            ],
          ],
        ))
      else
        Positioned(left: 14, bottom: bottom + math.max(0.0, (cardH - 26) / 2), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min,
          children: [
            if (state.experimentalMode && !stale)
              _badge('EXPERIMENTAL', Colors.amberAccent),
            const SizedBox(height: 6), _badge(status, color),
          ],
        )),
      Positioned(bottom: bottom, left: cardLeft, width: width,
        height: cardH,
        child: DashboardCard(state: state, stale: stale)),
      // 方向燈：儀表卡片左右兩側的箭頭，閃爍（carState.leftBlinker / rightBlinker）
      if (!stale && state.leftBlinker)
        _blinker(left: true, cardLeft: cardLeft, cardW: width, cardH: cardH, bottom: bottom, boxW: box.maxWidth),
      if (!stale && state.rightBlinker)
        _blinker(left: false, cardLeft: cardLeft, cardW: width, cardH: cardH, bottom: bottom, boxW: box.maxWidth),
    ]));
  });

  Widget _blinker({required bool left, required double cardLeft, required double cardW,
      required double cardH, required double bottom, required double boxW}) {
    final gap = cardW * .03;
    // CommaView 約 .34，依需求放大一倍；直向卡片較寬時縮到卡片外側剩餘空間內，不超出畫面
    final size = math.max(0.0, math.min(cardH * .68, (boxW - cardW) / 2 - gap - 2));
    return Positioned(
      bottom: bottom, height: cardH,
      left: left ? cardLeft - gap - size : cardLeft + cardW + gap,
      width: size,
      child: Center(child: BlinkerArrow(left: left, size: size)));
  }

  Widget _badge(String text, Color color) => dashboardBadge(text, color);
}

/// 狀態徽章文字與顏色（儀表介面與直向下方儀表區共用）
(String, Color) dashboardStatus(UIState state, bool stale) {
  final status = stale ? (state.dataLagging ? '資料延遲' : '資料中斷') : switch (state.status) {
    UIStatus.engaged => 'ENGAGED',
    UIStatus.override_ => 'OVERRIDE',
    UIStatus.disengaged => 'DISENGAGED',
  };
  final color = stale ? Colors.orangeAccent : state.status == UIStatus.engaged
      ? dashboardTeal : Colors.white70;
  return (status, color);
}

Widget dashboardBadge(String text, Color color) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
  decoration: BoxDecoration(color: const Color(0xDB10191D),
    borderRadius: BorderRadius.circular(20), border: Border.all(color: color.withAlpha(100))),
  child: Text(text, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700)),
);

/// 儀表卡片本體：MAX ｜ 車速儀表 ｜ 右欄（前車 或 TDX 前方車速）。字級依卡片高度等比。
/// [tdxInRightColumn] = false 時右欄固定顯示前車距離 / 車頭時距（直向版 TDX 另有獨立一列）。
class DashboardCard extends StatelessWidget {
  final UIState state;
  final bool stale;
  final bool tdxInRightColumn;
  const DashboardCard({super.key, required this.state, this.stale = false,
    this.tdxInRightColumn = true});

  @override
  Widget build(BuildContext context) {
    final (_, color) = dashboardStatus(state, stale);
    return LayoutBuilder(builder: (context, constraints) {
      final h = constraints.maxHeight;
      return DecoratedBox(decoration: BoxDecoration(
        color: const Color(0xDC0D171C), borderRadius: BorderRadius.circular(h * .17),
        border: Border.all(color: const Color(0x335DE3D4))),
        child: Row(children: [
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
              // P / R / N 檔：車速數字改成擋位大寫字母（P 紅、R 綠、N 白），
              // 單位隱藏（高度用透明佔位，版面不跳動）
              if (!stale && state.gearLetter != null) ...[
                Text(state.gearLetter!, style: TextStyle(fontSize: h * .42,
                  fontWeight: FontWeight.w800, height: 1, color: gearColor(state.gearLetter!))),
                Text(' ', style: TextStyle(fontSize: h * .10)),
              ] else ...[
                Text(stale ? '—' : '${state.displaySpeed.round()}',
                  style: TextStyle(fontSize: h * .42, fontWeight: FontWeight.w700, height: 1)),
                Text(state.isMetric ? 'km/h' : 'mph',
                  style: TextStyle(fontSize: h * .10, color: Colors.white70)),
              ],
              SizedBox(height: h * .09),
              Text(stale ? (state.dataLagging ? 'TELEMETRY DELAYED' : 'TELEMETRY STALE') : 'LIVE TELEMETRY',
                style: TextStyle(fontSize: h * .065, color: color, letterSpacing: 1.3)),
              SizedBox(height: h * .07),
            ])),
          )),
          Expanded(child: _rightColumn(h, color)),
        ]));
    });
  }

  // 右欄：有 TDX 前方車速時，小車圖示改成「前方車速」文字、下方顯示車速（依壅塞分級上色）；
  // 前車距離 / 車頭時距縮成一行保留在最下面。沒有 TDX 資料時維持原本的小車 + 距離。
  Widget _rightColumn(double h, Color color) {
    final tdxSpeed = stale || !tdxInRightColumn ? null : state.tdxNextSpeedDisplay;
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

/// 方向燈箭頭：亮 / 暗交替，週期約 0.8 秒（接近實車方向燈頻率）。
/// carState.leftBlinker / rightBlinker 在方向燈作動期間持續為 true，閃爍由這裡產生。
class BlinkerArrow extends StatefulWidget {
  final bool left;
  final double size;
  const BlinkerArrow({super.key, required this.left, required this.size});
  @override
  State<BlinkerArrow> createState() => _BlinkerArrowState();
}

class _BlinkerArrowState extends State<BlinkerArrow> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this, duration: const Duration(milliseconds: 800))..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(child: AnimatedBuilder(
    animation: _ctrl,
    // 前半週期亮、後半週期淡（不完全消失，維持位置感）
    builder: (context, child) => Opacity(opacity: _ctrl.value < .5 ? 1.0 : .18, child: child),
    child: Icon(widget.left ? Icons.keyboard_double_arrow_left_rounded
        : Icons.keyboard_double_arrow_right_rounded,
      color: blinkerRed, size: widget.size),
  ));
}
