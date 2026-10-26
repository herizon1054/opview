// TDX 路況事件跑馬燈（畫面上方）
// 資料來源：dplcc tdx service 的 events（格式同 tici hud_renderer：「目前: a / b」）
// tici 版事件是貼在畫面下方 Performance 列上；opview 改放上方。
// 文字放得下就置中靜止，放不下才循環捲動。

import 'package:flutter/material.dart';
import 'dashboard_hud.dart' show tdxSlowColor;

class TdxMarquee extends StatefulWidget {
  final String text;
  final double fontSize;
  /// 捲動速度 (dp/s)
  final double speed;
  const TdxMarquee({super.key, required this.text, this.fontSize = 14, this.speed = 60});

  @override
  State<TdxMarquee> createState() => _TdxMarqueeState();
}

class _TdxMarqueeState extends State<TdxMarquee> with SingleTickerProviderStateMixin {
  static const _gap = 64.0;            // 循環時兩段文字之間的間隔
  static const _icon = 17.0;
  late final AnimationController _ctrl = AnimationController(vsync: this);
  double _textWidth = 0;
  double _available = 0;

  // 文字用 white70（同儀表板次要文字），不用純白
  TextStyle get _style => TextStyle(fontSize: widget.fontSize, color: Colors.white70,
      fontWeight: FontWeight.w500, height: 1.2);

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
  Widget build(BuildContext context) {
    return Container(
      height: widget.fontSize * 2.1,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      // 底色 / 邊框沿用儀表板面板（0xDC0D171C + 低透明度 teal 邊框）
      decoration: BoxDecoration(
        color: const Color(0xDC0D171C),
        borderRadius: BorderRadius.circular(widget.fontSize * 1.05),
        border: Border.all(color: const Color(0x335DE3D4)),
      ),
      child: Row(children: [
        Icon(Icons.warning_amber_rounded, color: tdxSlowColor.withAlpha(210), size: _icon),
        const SizedBox(width: 8),
        Expanded(child: LayoutBuilder(builder: (context, box) {
          final painter = TextPainter(
            text: TextSpan(text: widget.text, style: _style),
            textDirection: TextDirection.ltr, maxLines: 1,
            textScaler: MediaQuery.textScalerOf(context),
          )..layout();
          final textWidth = painter.width;
          painter.dispose();
          // 動畫控制不能在 build 中途改，排到這一幀之後
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _sync(textWidth, box.maxWidth);
          });
          final line = Text(widget.text, maxLines: 1, softWrap: false, style: _style);
          if (textWidth <= box.maxWidth) return Center(child: line);
          return ClipRect(child: AnimatedBuilder(
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
          ));
        })),
      ]),
    );
  }
}
