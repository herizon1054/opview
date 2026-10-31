// 盲點偵測（BSM）邊緣光暈
// 對應 dplcc tici augmented_road_view.py 的 dp side indicators：
//   tici：畫面左右邊緣畫一整條實心黃色條（寬 = UI_BORDER_SIZE）
//     盲點 only      → 常亮
//     盲點 + 同側方向燈 → 快閃（每 0.25 秒切換）
//     方向燈 only    → 綠色慢閃
// opview 差異（刻意）：
//   - 改成從螢幕邊緣向內淡化的光暈，上下兩端也淡出，不是一整條實心條
//   - 方向燈 only 不畫邊緣光暈，改由儀表卡片旁的紅色箭頭表示
import 'package:flutter/material.dart';

/// 盲點光暈顏色：琥珀黃（tici 為純黃 255,255,0，略降飽和配合 opview 色系）
const blindspotAmber = Color(0xFFFFC83D);

class BlindspotGlow extends StatefulWidget {
  final bool left;
  /// 同側方向燈也亮 → 快閃（tici: DP_INDICATOR_BLINK_RATE_FAST，0.25 秒切換）
  final bool fastBlink;
  /// 光暈向內延伸的寬度 (dp)
  final double width;
  const BlindspotGlow({super.key, required this.left, this.fastBlink = false, this.width = 72});

  @override
  State<BlindspotGlow> createState() => _BlindspotGlowState();
}

class _BlindspotGlowState extends State<BlindspotGlow> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 500));

  @override
  void initState() {
    super.initState();
    if (widget.fastBlink) _ctrl.repeat();
  }

  @override
  void didUpdateWidget(BlindspotGlow old) {
    super.didUpdateWidget(old);
    if (widget.fastBlink && !_ctrl.isAnimating) {
      _ctrl.repeat();
    } else if (!widget.fastBlink && _ctrl.isAnimating) {
      _ctrl.stop();
      _ctrl.value = 0;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final edge = widget.left ? Alignment.centerLeft : Alignment.centerRight;
    final inner = widget.left ? Alignment.centerRight : Alignment.centerLeft;
    final glow = SizedBox(width: widget.width, child: ShaderMask(
      // 上下兩端淡出，避免出現一整條硬邊
      shaderCallback: (r) => const LinearGradient(
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [Colors.transparent, Colors.white, Colors.white, Colors.transparent],
        stops: [0, .22, .78, 1],
      ).createShader(r),
      blendMode: BlendMode.dstIn,
      child: DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(
        begin: edge, end: inner,
        // 邊緣最亮、向內快速淡化
        colors: [
          blindspotAmber.withAlpha(0xB0),
          blindspotAmber.withAlpha(0x48),
          blindspotAmber.withAlpha(0x00),
        ],
        stops: const [0, .35, 1],
      ))),
    ));
    return RepaintBoundary(child: AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) => Opacity(
        opacity: !widget.fastBlink || _ctrl.value < .5 ? 1.0 : 0.0, child: child),
      child: glow,
    ));
  }
}
