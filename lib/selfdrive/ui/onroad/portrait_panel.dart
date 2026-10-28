// 直向 opview 的下方資訊區（方案 B）：影像在上方完整顯示，這裡放在影像與操作列之間。
//
//   ┌ 徽章（ENGAGED / EXPERIMENTAL）……………… opview ┐
//   │ 儀表卡片：MAX ｜ 車速 ｜ 前車距離 / 車頭時距      │
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
  static const double cardMaxH = 150, cardMinH = 72;

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

    // 卡片高度：寬度的 0.42（上限 150），再依剩餘高度縮（短螢幕不溢出）
    final fixed = 14 + (modern ? badgeH + gap : 0)
        + (tdxSpeed != null ? tdxRowH + gap : 0)
        + (event.isNotEmpty ? eventH + gap : 0) + 8;
    final cardH = math.max(0.0, math.min(math.min(cardMaxH, (w - 2 * pad) * .42),
        box.maxHeight - fixed - (modern ? gap : 0)));
    final showCard = modern && cardH >= cardMinH;

    final column = Padding(
      padding: const EdgeInsets.fromLTRB(pad, 14, pad, 0),
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
          const SizedBox(height: gap),
          SizedBox(height: cardH, child: DashboardCard(state: state, stale: stale,
              tdxInRightColumn: false)),
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
