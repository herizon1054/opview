// 直向 opview 的下方資訊區（方案 B）：影像在上方完整顯示，這裡放在影像與操作列之間。
//
//   ┌ 徽章（ENGAGED / EXPERIMENTAL）……………… opview ┐
//   │ ◀ 儀表卡片：MAX ｜ 車速 ｜ 前車距離 / 車頭時距 ▶  │  ← 兩側為方向燈箭頭
//   │ TDX 列：前方車速（依壅塞分級上色）＋ 路況分級     │  ← 有 TDX 資料才顯示
//   │ TDX 事件（施工、事故…，過長自動捲動）            │  ← 有事件才顯示
//   └ （comma 事件 / alert 改顯示在道路畫面底部，見 AugmentedRoadView）┘
//
// 原版介面（modernOverlay = false）：原版 HUD 仍疊在影像上，本區只放 TDX 事件與警示。

import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../ui_state.dart';
import 'dashboard_hud.dart';
import 'tdx_marquee.dart';

class PortraitPanel extends StatelessWidget {
  final UIState state;
  final bool stale;
  const PortraitPanel({super.key, required this.state, this.stale = false});

  // v20：TDX 字級 ×1.3
  static const double fontZoom = 1.3;

  static const double pad = 16, gap = 12;
  static const double badgeH = 26, tdxRowH = 56 * fontZoom, eventH = 34 * fontZoom;
  // 儀表卡片尺寸，以 390 寬螢幕為例：
  //   v8：寬 = 原本 90%（245）；高 = 原本 150 × 0.624 ≈ 94；上邊距 10、徽章與卡片間距 8
  //   （v13 曾放大 20%，v14 依需求改回）
  //   v20：高度 ×1.2（94 → 約 113），寬度不變（仍依 0.624 的高度計算方向燈欄位與卡片寬）
  static const double topPad = 10, cardGap = 8;
  static const double cardWidthScale = .9, cardHeightScale = .624;
  static const double cardHeightZoom = 1.2;
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
    final cardH = math.max(0.0, math.min(math.min(cardMaxH, (w - 2 * pad) * .42 * cardHeightScale) * cardHeightZoom,
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
            child: TdxMarquee(text: event, maxWidth: w - 2 * pad, fontSize: 17.25 * fontZoom))),
        ],
      ]),
    );

    return IgnorePointer(child: ClipRect(child: Stack(fit: StackFit.expand, children: [
      // 內容高度已依可用空間計算；萬一系統字型過大，裁掉而不是丟 overflow
      SingleChildScrollView(physics: const NeverScrollableScrollPhysics(), child: column),
    ])));
  });

  /// 儀表卡片置中、寬度為原本的 90%；兩側固定留方向燈欄位（不亮時空白，卡片不會跳動），
  /// 與橫向 DashboardHud 相同位置邏輯。卡片縮窄後多出的寬度給方向燈箭頭（上限 卡片高 × 0.42）。
  Widget _cardWithBlinkers(double cardH, double rowW) {
    // 卡片寬度用放大前的高度計算（v20：高度提高、寬度不變）
    final baseSlot = math.min(cardH / cardHeightZoom * .42, rowW * .12);
    final cardW = math.min(rowW, (rowW - 2 * baseSlot) * cardWidthScale);
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
        const Text('前方車速', style: TextStyle(fontSize: 12 * fontZoom, color: Colors.white60)),
        const SizedBox(width: 14),
        Text('$speed', style: TextStyle(fontSize: 26 * fontZoom, fontWeight: FontWeight.w700, color: c, height: 1)),
        const SizedBox(width: 6),
        Text(state.isMetric ? 'km/h' : 'mph', style: const TextStyle(fontSize: 12 * fontZoom, color: Colors.white60)),
        const Spacer(),
        if (label.isNotEmpty)
          Text('TDX $label', style: TextStyle(fontSize: 12 * fontZoom, color: c, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}
