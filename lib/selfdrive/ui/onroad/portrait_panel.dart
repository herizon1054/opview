// 直向 opview 的下方資訊區（方案 B）：影像在上方完整顯示，這裡放在影像與操作列之間。
//
//   ┌ 徽章（ENGAGED / EXPERIMENTAL）……………… opview ┐
//   │ ◀ 儀表卡片：MAX ｜ 車速 ｜ 前車距離 / 車頭時距 ▶  │  ← 兩側為方向燈箭頭
//   │ TDX 列：前方車速（依壅塞分級上色）＋ 路況分級     │  ← 有 TDX 資料才顯示
//   │ TDX 事件（施工、事故…，過長自動捲動）            │  ← 有事件才顯示
//   └ 警示（alert）顯示區：small / mid 在底部，full 蓋滿本區 ┘
//
// 原版介面（modernOverlay = false）：原版 HUD 仍疊在影像上，本區只放 TDX 事件與警示。

import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../ui_state.dart';
import 'alert_renderer.dart';
import 'dashboard_hud.dart';
import 'tdx_marquee.dart';

class PortraitPanel extends StatelessWidget {
  final UIState state;
  final bool stale;
  const PortraitPanel({super.key, required this.state, this.stale = false});

  static const double pad = 16, gap = 12;
  static const double badgeH = 26, tdxRowH = 56, eventH = 34;
  // 儀表區尺寸（v8 起，讓出空間給下方 TDX / 警示區），以 390 寬螢幕為例：
  //   卡片寬 = 原本 90%；卡片高 = 原本 150 × 0.624 ≈ 94
  //   儀表區（上邊距 + 徽章列 + 間距 + 卡片）：14 + 26 + 12 + 120 = 172 → 10 + 26 + 8 + 94 ≈ 138（再減 20%）
  static const double topPad = 10, cardGap = 8;
  static const double cardWidthScale = .9, cardHeightScale = .624;
  static const double cardMaxH = 150 * cardHeightScale, cardMinH = 72;

  static String congestionLabel(String c) => switch (c) {
    'smooth' => '順暢',
    'slow' => '車多',
    'congested' => '壅塞',
    _ => '',
  };

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
    final w = box.maxWidth;
    final modern = state.modernOverlay;
    final (status, color) = dashboardStatus(state, stale);
    final tdxSpeed = modern && !stale ? state.tdxNextSpeedDisplay : null;
    final event = state.isConnected ? state.tdxEventText : '';

    // 卡片高度：寬度的 0.42 × 0.624（上限約 94），再依剩餘高度縮（短螢幕不溢出）
    final fixed = topPad + (modern ? badgeH + cardGap : 0)
        + (tdxSpeed != null ? tdxRowH + gap : 0)
        + (event.isNotEmpty ? eventH + gap : 0) + 8;
    final cardH = math.max(0.0, math.min(math.min(cardMaxH, (w - 2 * pad) * .42 * cardHeightScale),
        box.maxHeight - fixed - (modern ? cardGap : 0)));
    final showCard = modern && cardH >= cardMinH;

    final column = Padding(
      padding: const EdgeInsets.fromLTRB(pad, topPad, pad, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        if (modern) SizedBox(height: badgeH, child: Row(children: [
          dashboardBadge(status, color),
          if (state.experimentalMode && !stale) ...[
            const SizedBox(width: 8), dashboardBadge('EXPERIMENTAL', Colors.amberAccent),
          ],
          const Spacer(),
          const Text('opview', style: TextStyle(fontSize: 13, color: Colors.white60,
              fontWeight: FontWeight.w700)),
        ])),
        if (showCard) ...[
          const SizedBox(height: cardGap),
          SizedBox(height: cardH, child: _cardWithBlinkers(cardH, w - 2 * pad)),
        ],
        if (tdxSpeed != null) ...[
          const SizedBox(height: gap),
          _tdxRow(tdxSpeed),
        ],
        if (event.isNotEmpty) ...[
          const SizedBox(height: gap),
          SizedBox(height: eventH, child: Align(alignment: Alignment.centerLeft,
            child: TdxMarquee(text: event, maxWidth: w - 2 * pad))),
        ],
      ]),
    );

    return IgnorePointer(child: ClipRect(child: Stack(fit: StackFit.expand, children: [
      // 內容高度已依可用空間計算；萬一系統字型過大，裁掉而不是丟 overflow
      SingleChildScrollView(physics: const NeverScrollableScrollPhysics(), child: column),
      // 警示：small / mid 貼本區底部，寬度依本區寬（不再依短邊縮到很小）；full 蓋滿本區
      AlertRenderer(uiState: state, scale: w / 1080, compact: modern),
    ])));
  });

  /// 儀表卡片置中、寬度為原本的 90%；兩側固定留方向燈欄位（不亮時空白，卡片不會跳動），
  /// 與橫向 DashboardHud 相同位置邏輯。卡片縮窄後多出的寬度給方向燈箭頭（上限 卡片高 × 0.42）。
  Widget _cardWithBlinkers(double cardH, double rowW) {
    final baseSlot = math.min(cardH * .42, rowW * .12);
    final cardW = (rowW - 2 * baseSlot) * cardWidthScale;
    final slot = math.min(cardH * .42, (rowW - cardW) / 2);
    Widget side(bool left) => SizedBox(width: slot, child: Center(child:
        !stale && (left ? state.leftBlinker : state.rightBlinker)
            ? BlinkerArrow(left: left, size: slot) : null));
    return Row(mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      side(true),
      SizedBox(width: cardW, child: DashboardCard(state: state, stale: stale, tdxInRightColumn: false)),
      side(false),
    ]);
  }

  Widget _tdxRow(int speed) {
    final c = tdxCongestionColor(state.tdxCongestion);
    final label = congestionLabel(state.tdxCongestion);
    return Container(
      height: tdxRowH,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(color: const Color(0xFF0D151B), borderRadius: BorderRadius.circular(16)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        const Text('前方車速', style: TextStyle(fontSize: 12, color: Colors.white60)),
        const SizedBox(width: 14),
        Text('$speed', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: c, height: 1)),
        const SizedBox(width: 6),
        Text(state.isMetric ? 'km/h' : 'mph', style: const TextStyle(fontSize: 12, color: Colors.white60)),
        const Spacer(),
        if (label.isNotEmpty)
          Text('TDX $label', style: TextStyle(fontSize: 12, color: c, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}
