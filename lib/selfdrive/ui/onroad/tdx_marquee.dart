// TDX 路況事件跑馬燈（畫面上方置中的小膠囊）
// 資料來源：dplcc tdx service 的 events（格式同 tici hud_renderer：「目前: a / b」）
// tici 版事件是貼在畫面下方 Performance 列上；opview 改放上方。
// 版型參考 CommaView 上方的狀態提示（例如 Changing Lanes）：小字、膠囊寬度貼合文字、置中。
// 文字放得下就整段靜止顯示；超過 maxWidth 才固定寬度、循環捲動。

import 'package:flutter/material.dart';
import 'dashboard_hud.dart' show tdxSlowColor;

class TdxMarquee extends StatefulWidget {
  final String text;
  final double fontSize;
  /// 膠囊最大寬度；超過才捲動
  final double maxWidth;
  /// 捲動速度 (dp/s)
  final double speed;
  const TdxMarquee({super.key, required this.text, this.fontSize = 17.25,  // 12.5 × 1.15 × 1.2
    this.maxWidth = 420, this.speed = 50});

  @override
  State<TdxMarquee> createState() => _TdxMarqueeState();
}

class _TdxMarqueeState extends State<TdxMarquee> with SingleTickerProviderStateMixin {
  static const _gap = 48.0;            // 循環時兩段文字之間的間隔
  static const _padH = 10.0;
  static const _iconGap = 6.0;
  late final AnimationController _ctrl = AnimationController(vsync: this);
  double _textWidth = 0;
  double _available = 0;

  double get _icon => widget.fontSize + 1.5;

  // 文字用 white70（同儀表板次要文字），不用純白
  TextStyle get _style => TextStyle(fontSize: widget.fontSize, color: Colors.white70,
      fontWeight: FontWeight.w500, height: 1.2, letterSpacing: .2);

  @override
  void didUpdateWidget(TdxMarquee old) {
    super.didUpdateWidget(old);
    // 事件內容換了（tdxd 每 10 秒在 目前/前方 之間輪替）就從頭捲
    if (old.text != widget.text) _textWidth = -1;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _sync(double textWidth, double available) {
    if (textWidth == _textWidth && available == _available) return;
    _textWidth = textWidth;
    _available = available;
    if (textWidth <= available) {
      _ctrl.stop();
      _ctrl.value = 0;
    } else {
      final ms = ((textWidth + _gap) / widget.speed * 1000).round();
      _ctrl.duration = Duration(milliseconds: ms);
      _ctrl.value = 0;
      _ctrl.repeat();
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, outer) {
    final maxPill = outer.maxWidth.isFinite
        ? (outer.maxWidth < widget.maxWidth ? outer.maxWidth : widget.maxWidth)
        : widget.maxWidth;
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: _style),
      textDirection: TextDirection.ltr, maxLines: 1,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final textWidth = painter.width;
    painter.dispose();
    final available = maxPill - 2 * _padH - _icon - _iconGap - 2; // 2 = 邊框
    final scrolling = textWidth > available;
    // 動畫控制不能在 build 中途改，排到這一幀之後
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sync(textWidth, available);
    });

    final line = Text(widget.text, maxLines: 1, softWrap: false, style: _style);
    final Widget body = !scrolling ? line : SizedBox(width: available, child: ClipRect(
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, child) => Transform.translate(
          offset: Offset(-_ctrl.value * (textWidth + _gap), 0), child: child),
        child: OverflowBox(
          alignment: Alignment.centerLeft,
          minWidth: 0, maxWidth: double.infinity,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            line, const SizedBox(width: _gap), line,
          ]),
        ),
      )));

    return Center(child: Container(
      height: widget.fontSize * 2.2,
      padding: const EdgeInsets.symmetric(horizontal: _padH),
      // 底色 / 邊框沿用儀表板面板（0xDC0D171C + 低透明度 teal 邊框）
      decoration: BoxDecoration(
        color: const Color(0xDC0D171C),
        borderRadius: BorderRadius.circular(widget.fontSize * 1.1),
        border: Border.all(color: const Color(0x335DE3D4)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.warning_amber_rounded, color: tdxSlowColor.withAlpha(210), size: _icon),
        const SizedBox(width: _iconGap),
        body,
      ]),
    ));
  });
}
