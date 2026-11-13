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
/// 壅塞分級文字（路況卡用）
String tdxCongestionLabel(String c) => switch (c) {
  'smooth' => '順暢', 'slow' => '車多', 'congested' => '壅塞', _ => '',
};

/// 所有資訊面板共用的外觀（2026-11-12 版面統一）：儀表卡片同色系的半透明深底、細青綠邊框、圓角 14。
/// 警示（碰撞注意 / 車速驟降）另有自己的底色。
const opviewPanelFill = Color(0xDC0D171C);
const opviewPanelBorder = Color(0x335DE3D4);
BoxDecoration opviewPanel({double radius = 14, Color border = opviewPanelBorder}) => BoxDecoration(
  color: opviewPanelFill, borderRadius: BorderRadius.circular(radius), border: Border.all(color: border));

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
      // 狀態徽章（2026-11-12 版面統一）：ENGAGED / EXPERIMENTAL 文字徽章拿掉，與直向一致——
      // 狀態看卡片顏色，實驗模式看道路畫面上的燒瓶圖示。只在資料中斷 / 延遲時顯示警告徽章。
      if (stale)
        Positioned(left: 14, bottom: bottom + math.max(0.0, (cardH - 26) / 2), child: _badge(status, color)),
      // 「無卡片」：不畫卡片，方向燈箭頭仍在原位置
      // TDX 前方車速改在左上角的路況卡（augmented_road_view），卡片右欄固定是前車
      if (!state.hideHudCard)
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

/// 儀表卡片本體：MAX ｜ 車速儀表 ｜ 右欄（前車距離 / 車頭時距）。字級依卡片高度等比。
/// 2026-11-12 版面統一：直向、橫向內容相同；TDX 前方車速一律在路況卡（TdxRouteCard），
/// 實驗模式一律看道路畫面上的燒瓶圖示（卡片角落的 EXP 拿掉）。
class DashboardCard extends StatelessWidget {
  final UIState state;
  final bool stale;
  /// 內容（字級、圖示）依此高度計算；卡片實際高度可以比它矮（直向：卡片變矮、字不變小）。
  /// null = 依卡片實際高度（橫向，原本行為）。
  final double? contentHeight;
  const DashboardCard({super.key, required this.state, this.stale = false, this.contentHeight});

  @override
  Widget build(BuildContext context) {
    final (_, color) = dashboardStatus(state, stale);
    return LayoutBuilder(builder: (context, constraints) {
      final boxH = constraints.maxHeight;
      final h = contentHeight ?? boxH;
      // 中間欄上下間距：原本 0.09h + 0.07h；卡片比內容高度矮時縮小間距，字級不變。
      // 文字高度：車速 0.42h（行高 1）＋ 單位 0.10h、TELEMETRY 0.065h × 實際行高
      // （沒指定行高時沿用主題，Material 3 bodyMedium 為 1.43；之前以 1 倍估算，直向卡片溢出約 1 px）
      final lineH = DefaultTextStyle.of(context).style.height ?? 1.25;
      final textH = .42 * h + (.10 + .065) * h * lineH;
      final gaps = math.min(.16 * h, math.max(0.0, boxH - textH - 1));
      return DecoratedBox(decoration: opviewPanel(radius: math.min(h * .17, boxH * .5)),
        child: Stack(children: [Positioned.fill(child: Row(children: [
          Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text('MAX', style: TextStyle(color: color, fontSize: h * .10,
                fontWeight: FontWeight.w700, letterSpacing: 2)),
            // 直向卡片高度提高、寬度不變時，三位數可能超出欄寬 → 等比縮小而不是換行
            FittedBox(fit: BoxFit.scaleDown, child: Text(!stale && state.isCruiseSet ? '${state.setSpeed.round()}' : '—',
                style: TextStyle(fontSize: h * .26, fontWeight: FontWeight.w700))),
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
              SizedBox(height: gaps * .5625),
              Text(stale ? (state.dataLagging ? 'TELEMETRY DELAYED' : 'TELEMETRY STALE') : 'LIVE TELEMETRY',
                style: TextStyle(fontSize: h * .065, color: color, letterSpacing: 1.3)),
              SizedBox(height: gaps * .4375),
            ])),
          )),
          Expanded(child: _rightColumn(h, color)),
        ])),
        ]));
    });
  }

  // 右欄：前車距離 / 車頭時距（直向、橫向相同；TDX 前方車速在路況卡）
  Widget _rightColumn(double h, Color color) {
    final dist = !stale ? state.leadDistance : null;
    final headway = !stale ? state.leadHeadway : null;
    return FittedBox(fit: BoxFit.scaleDown, child: Column(mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.directions_car_outlined, color: color, size: h * .18),
      Text(dist != null ? '${dist.round()} m' : '—',
          style: TextStyle(fontSize: h * .12, fontWeight: FontWeight.w600)),
      Text(headway != null ? '${headway.toStringAsFixed(1)} s' : '—',
          style: TextStyle(fontSize: h * .10, color: Colors.white60)),
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
