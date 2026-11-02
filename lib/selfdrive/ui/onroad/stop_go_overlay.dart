// 前車起步 / 綠燈起步 / 停等計時 — 道路畫面右側中間的圓形提示（直向、橫向都顯示；直向依影像高度縮小）
// 版型移植自 sunnypilot selfdrive/ui/sunnypilot/onroad/circular_alerts.py：
//   黑色半透明圓 + 外框；起步提醒時外框白 / 綠交替閃爍（每秒前 40% 白），圖示在中間、文字在下方；
//   停等計時時外框固定白色，上方琥珀色「停等中」、下方白色 m:ss。
// 與 sunnypilot 的差異：
//   - 圖示改用程式繪製的台灣常見橫式三燈號誌（綠燈亮）與「前車＋向前箭頭」，不需要圖檔
//     （spmaster 的 green_light.png / lead_depart.png 是 git LFS 指標檔，不是實際圖片）。
//   - 文字改為中文；尺寸依畫面高度等比（sunnypilot 為固定 250 px 半徑）。
//   - 有 comma 警示（alertSize != 0）時不顯示（同 sunnypilot 的 _allow_e2e_alerts）。

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show FontFeature;
import 'package:flutter/material.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/stop_go_alerts.dart';

class StopGoOverlay extends StatefulWidget {
  final UIState state;
  final double screenH;
  const StopGoOverlay({super.key, required this.state, required this.screenH});
  @override
  State<StopGoOverlay> createState() => _StopGoOverlayState();
}

class _StopGoOverlayState extends State<StopGoOverlay> {
  Timer? _tick;
  int _frame = 0;

  @override
  void initState() {
    super.initState();
    // 閃爍與計時：每 100 ms 重畫（只有這個小區塊）
    _tick = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final a = StopGoAlerts.instance;
      if (!mounted) return;
      if (a.activeAlert != null || a.standstillSeconds != null || _frame != 0) {
        setState(() => _frame = a.activeAlert != null ? _frame + 1 : 0);
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = StopGoAlerts.instance;
    if (widget.state.alertSize != 0) return const SizedBox.shrink();
    final alert = a.activeAlert;
    final standstill = a.standstillSeconds;
    if (alert == null && standstill == null) return const SizedBox.shrink();

    final r = (widget.screenH * .19).clamp(52.0, 110.0); // 直向影像約 244 dp 高：下限 52
    // 每秒前 40% 白色、其餘綠色（circular_alerts.py：frame % fps < fps / 2.5）
    final pulseWhite = (_frame % 10) < 4;
    final ringColor = alert == null || pulseWhite ? const Color(0x4BFFFFFF) : const Color(0x4B00FF00);
    final textColor = alert == null || pulseWhite ? Colors.white : const Color(0xBE00FF00);

    final Widget content;
    if (alert != null) {
      content = Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(width: r * .95, height: r * .95, child: CustomPaint(
          painter: alert == StopGoKind.greenLight ? const GreenLightIconPainter() : const LeadDepartIconPainter())),
        SizedBox(height: r * .06),
        Text(alert == StopGoKind.greenLight ? '綠燈起步' : '前車起步',
          style: TextStyle(color: textColor, fontSize: r * .24, fontWeight: FontWeight.w800, height: 1.1)),
      ]);
    } else {
      content = Column(mainAxisSize: MainAxisSize.min, children: [
        Text('停等中', style: TextStyle(color: const Color(0xF0FFAF03), fontSize: r * .26,
            fontWeight: FontWeight.w800, height: 1.1)),
        SizedBox(height: r * .08),
        Text(formatStandstill(standstill!), style: TextStyle(color: Colors.white, fontSize: r * .46,
            fontWeight: FontWeight.w800, height: 1, fontFeatures: const [FontFeature.tabularFigures()])),
      ]);
    }
    return Align(
      alignment: const Alignment(.82, .08),
      child: IgnorePointer(child: Container(
        width: r * 2, height: r * 2,
        decoration: BoxDecoration(shape: BoxShape.circle, color: const Color(0xBE000000),
          border: Border.all(color: ringColor, width: math.max(3, r * .06))),
        alignment: Alignment.center,
        child: FittedBox(fit: BoxFit.scaleDown, child: Padding(
          padding: EdgeInsets.all(r * .18), child: content)),
      )),
    );
  }
}

/// 台灣常見的橫式三燈號誌（紅 / 黃 / 綠），綠燈亮
class GreenLightIconPainter extends CustomPainter {
  final bool dimmed;
  const GreenLightIconPainter({this.dimmed = false});
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final body = RRect.fromRectAndRadius(Rect.fromLTWH(w * .04, h * .30, w * .92, h * .40),
        Radius.circular(h * .12));
    canvas.drawRRect(body, Paint()..color = const Color(0xFF1E2427));
    canvas.drawRRect(body, Paint()..color = const Color(0xFF8A969C)..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1, w * .03));
    // 支架
    canvas.drawRect(Rect.fromLTWH(w * .46, h * .14, w * .08, h * .16), Paint()..color = const Color(0xFF8A969C));
    final rLamp = h * .13;
    final cy = h * .50;
    final lamps = [
      (w * .22, const Color(0xFF5A1E1E)),  // 紅（暗）
      (w * .50, const Color(0xFF5A4A16)),  // 黃（暗）
      (w * .78, dimmed ? const Color(0xFF1E5A2E) : const Color(0xFF2EE66B)), // 綠（亮）
    ];
    for (final (x, c) in lamps) {
      canvas.drawCircle(Offset(x, cy), rLamp, Paint()..color = c);
    }
    if (!dimmed) {
      canvas.drawCircle(Offset(w * .78, cy), rLamp * 1.7,
        Paint()..color = const Color(0x552EE66B)..maskFilter = MaskFilter.blur(BlurStyle.normal, rLamp * .6));
    }
  }
  @override
  bool shouldRepaint(GreenLightIconPainter old) => old.dimmed != dimmed;
}

/// 前車（車尾）＋ 向前的綠色箭頭
class LeadDepartIconPainter extends CustomPainter {
  const LeadDepartIconPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final stroke = math.max(1.5, w * .05);
    // 箭頭（向上 = 前車往前開）
    final arrow = Path()
      ..moveTo(w * .50, h * .02)
      ..lineTo(w * .72, h * .24)
      ..lineTo(w * .59, h * .24)
      ..lineTo(w * .59, h * .38)
      ..lineTo(w * .41, h * .38)
      ..lineTo(w * .41, h * .24)
      ..lineTo(w * .28, h * .24)
      ..close();
    canvas.drawPath(arrow, Paint()..color = const Color(0xFF2EE66B));
    // 車尾
    final roof = RRect.fromRectAndRadius(Rect.fromLTWH(w * .26, h * .46, w * .48, h * .18),
        Radius.circular(h * .06));
    final bodyR = RRect.fromRectAndRadius(Rect.fromLTWH(w * .14, h * .58, w * .72, h * .26),
        Radius.circular(h * .07));
    final fill = Paint()..color = const Color(0xFFDDE5E8);
    canvas.drawRRect(roof, fill);
    canvas.drawRRect(bodyR, fill);
    // 後擋玻璃
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(w * .31, h * .49, w * .38, h * .11),
        Radius.circular(h * .03)), Paint()..color = const Color(0xFF4A5A62));
    // 尾燈
    final tail = Paint()..color = const Color(0xFFE5393B);
    canvas.drawRect(Rect.fromLTWH(w * .18, h * .63, w * .12, h * .06), tail);
    canvas.drawRect(Rect.fromLTWH(w * .70, h * .63, w * .12, h * .06), tail);
    // 輪胎
    final tire = Paint()..color = const Color(0xFF2A3136);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(w * .18, h * .84, w * .14, h * .09),
        Radius.circular(stroke)), tire);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(w * .68, h * .84, w * .14, h * .09),
        Radius.circular(stroke)), tire);
  }
  @override
  bool shouldRepaint(LeadDepartIconPainter old) => false;
}

/// 顯示設定用的小圖示
Widget stopGoSettingIcon(StopGoKind? kind, {double size = 30}) => SizedBox(width: size, height: size,
  child: kind == null
      ? Icon(Icons.timer_outlined, size: size * .85, color: const Color(0xFFFFAF03))
      : CustomPaint(painter: kind == StopGoKind.greenLight
          ? const GreenLightIconPainter() : const LeadDepartIconPainter()));
