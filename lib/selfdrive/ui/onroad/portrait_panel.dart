// 直向 opview 的下方資訊區（方案 B）：影像在上方完整顯示，這裡放在影像與操作列之間。
//
//   ┌ ◀ 儀表卡片：MAX ｜ 車速 ｜ 前車距離 / 車頭時距 ▶  ┐  ← 兩側為方向燈箭頭；v21 卡片變矮、字級不變
//   │   （v21 移除上方徽章列：ENGAGED / 資料中斷 / EXPERIMENTAL / opview）│
//   │ TDX 列：前方車速（依壅塞分級上色）＋ 路況分級     │  ← 有 TDX 資料才顯示
//   │ TDX 事件（施工、事故…，過長自動捲動）            │  ← 有事件才顯示（優先於 LINE）
//   │ LINE 通知（每則 30 秒）                          │  ← 有訊息才出現
//   │ 附近停車場與空位（按鈕與結果）                    │  ← 與 LINE 共用剩餘高度，任一方消失另一方補滿；
//   │                                                  │     沒查詢時縮成精簡版，查詢中 / 有結果時 LINE 只留兩行
//   └ （comma 事件 / alert 改顯示在道路畫面底部，見 AugmentedRoadView）┘
//
// 原版介面（modernOverlay = false）：原版 HUD 仍疊在影像上，本區只放 TDX 事件與警示。

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ui_state.dart';
import 'dashboard_hud.dart';
import 'tdx_marquee.dart';
import 'parking_panel.dart';
import 'package:opview/services/line_notifications.dart';
import 'package:opview/services/parking/parking_config.dart';

class PortraitPanel extends StatelessWidget {
  final UIState state;
  final bool stale;
  /// 顯示設定「顯示 LINE 通知」
  final bool lineEnabled;
  const PortraitPanel({
    super.key,
    required this.state,
    this.stale = false,
    this.lineEnabled = false,
  });

  // v20：TDX 與 LINE 字級 ×1.3
  static const double fontZoom = 1.3;
  static const double lineFont = 14 * fontZoom, lineHeight = 1.3, lineMsgGap = 6;
  // v21：LINE 區不再有標題列（「LINE · N 則」改為貼在上邊框的小標籤），上下內距 6
  static const double lineRowH = lineFont * lineHeight, linePadV = 6, lineChrome = 2 * linePadV + 2;
  // LINE 最小高度（兩行）：停車查詢使用中時 LINE 只留這麼多
  // 「LINE · N 則」標籤往上凸出 8 px：LINE 欄上方多留 lineTagSpace，標籤不會頂到上方的卡片 / TDX 列
  static const double lineTagSpace = 6;
  static const double lineMinH = lineTagSpace + lineChrome + 2 * lineRowH;
  static const lineGreen = Color(0xFF06C755);
  // 停車面板（完整版）最小高度；沒查詢時改用精簡版 ParkingPanel.idleHeight
  static const double parkingMinH = 100;

  static const double pad = 16, gap = 12;
  static const double badgeH = 26,
      tdxRowH = 56 * fontZoom,
      eventH = 34 * fontZoom;
  // 儀表卡片尺寸，以 390 寬螢幕為例：
  //   v8：寬 = 原本 90%（245）；高 = 原本 150 × 0.624 ≈ 94；上邊距 10、徽章與卡片間距 8
  //   （v13 曾放大 20%，v14 依需求改回）
  //   v20：高度 ×1.2（94 → 約 113），寬度不變（仍依 0.624 的高度計算方向燈欄位與卡片寬）
  // v21：影像與卡片間的留白 10 → 2（只留一條細縫，空間給下方 LINE / 停車）
  static const double topPad = 2, cardGap = 8;
  static const double cardWidthScale = .9, cardHeightScale = .624;
  static const double cardHeightZoom = 1.2;
  static const double cardMaxH = 150 * cardHeightScale, cardMinH = 72;
  // v21：卡片實際高度為內容高度的 80%（字級不變，只縮上下留白），約 113 → 90
  static const double cardBoxTrim = .8;

  /// 下方剩餘高度分給 LINE 與停車面板（各自上方間距 8 已算在內），回傳 (LINE 高, 停車高)；0 = 不顯示。
  ///   LINE 沒有訊息（或沒開）：停車面板全拿；開了 LINE 但停車查詢關閉 → 都不顯示
  ///   LINE 有訊息、停車關閉：LINE 全拿
  ///   LINE 有訊息、停車沒在用（沒查詢）：停車縮成精簡版 ParkingPanel.idleHeight，LINE 拿其餘；
  ///     LINE 連兩行都放不下時只顯示 LINE
  ///   LINE 有訊息、停車使用中（查詢中 / 有結果）：LINE 只留兩行，停車拿其餘（至少 parkingMinH）；
  ///     停車放不下時 LINE 讓出，只顯示停車
  static (double, double) splitRest(double rest, {required bool lineEnabled, required bool hasMessages,
      required bool parkingOn, required bool parkingActive}) {
    if (!hasMessages) {
      if (lineEnabled && !parkingOn) return (0, 0);
      return (0, rest >= parkingMinH ? rest : 0);
    }
    if (!parkingOn) return (rest >= lineMinH ? rest : 0, 0);
    if (parkingActive) {
      final parking = rest - lineMinH - 8;
      if (parking >= parkingMinH) return (lineMinH, parking);
      return (0, rest >= parkingMinH ? rest : 0);
    }
    final line = rest - ParkingPanel.idleHeight - 8;
    if (line >= lineMinH) return (line, ParkingPanel.idleHeight);
    return (rest >= lineMinH ? rest : 0, 0);
  }

  static String congestionLabel(String c) => switch (c) {
    'smooth' => '順暢',
    'slow' => '車多',
    'congested' => '壅塞',
    _ => '',
  };

  @override
  Widget build(BuildContext context) => lineEnabled
      // LINE 訊息出現 / 消失、停車查詢開關：重新分配下方空間（不等儀表節流）
      ? ListenableBuilder(
          listenable: Listenable.merge([LineNotifications.instance, ParkingConfig.instance, ParkingPanel.active]),
          builder: (context, _) => _layout(),
        )
      : _layout();

  Widget _layout() => LayoutBuilder(
    builder: (context, box) {
      final w = box.maxWidth;
      final modern = state.modernOverlay;
      final tdxSpeed = modern && !stale ? state.tdxNextSpeedDisplay : null;
      // 碰撞注意（近距離警示）優先於 TDX 事件，佔同一列
      final banner = state.eventBanner;
      final event = banner.text;

      // 卡片：內容高度（字級依此）＝ 寬度的 0.42 × 0.624 × 1.2（上限約 113），卡片實際高度 × cardBoxTrim；
      // 剩餘高度不夠時再一起縮（短螢幕不溢出）
      final fixed =
          topPad +
          (tdxSpeed != null ? tdxRowH + gap : 0) +
          (event.isNotEmpty ? eventH + gap : 0) +
          8 +
          // 開啟 LINE 時，卡片大小以「LINE 至少兩行」計算（不論當下有沒有訊息），卡片不會因訊息跳動
          (lineEnabled ? lineMinH + gap : 0);
      final cardH = math.max(
        0.0,
        math.min(
          math.min(cardMaxH, (w - 2 * pad) * .42 * cardHeightScale) * cardHeightZoom,
          (box.maxHeight - fixed) / cardBoxTrim,
        ),
      );
      // 「無卡片」：卡片與兩側方向燈不顯示，空間全部讓給下方 LINE / 停車
      final showCard = modern && !state.hideHudCard && cardH >= cardMinH;
      final cardBoxH = cardH * cardBoxTrim;

      final used =
          topPad +
          (showCard ? cardBoxH : 0) +
          (tdxSpeed != null ? gap + tdxRowH : 0) +
          (event.isNotEmpty ? gap + eventH : 0);
      // 下方剩餘高度：LINE 與停車共用（各自上方間距 8，底部留 8），分配規則見 splitRest
      final rest = math.max(0.0, box.maxHeight - used - 16);
      final (lineH, parkingH) = splitRest(rest,
          lineEnabled: lineEnabled,
          hasMessages: lineEnabled && LineNotifications.instance.messages.isNotEmpty,
          parkingOn: ParkingConfig.instance.enabled,
          parkingActive: ParkingPanel.active.value);
      final column = Padding(
        padding: const EdgeInsets.fromLTRB(pad, topPad, pad, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 上方徽章列（ENGAGED / 資料中斷 / EXPERIMENTAL / opview）已移除，空間給下方；
            // 連線狀態仍由卡片顏色與卡片內 LIVE TELEMETRY / TELEMETRY STALE 表示
            if (showCard)
              SizedBox(
                key: const ValueKey('card'),
                height: cardBoxH,
                child: _cardWithBlinkers(cardH, cardBoxH, w - 2 * pad),
              ),
            if (tdxSpeed != null) ...[
              const SizedBox(height: gap),
              _tdxRow(tdxSpeed),
            ],
            if (event.isNotEmpty) ...[
              const SizedBox(height: gap),
              SizedBox(
                height: eventH,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TdxMarquee(
                    text: event,
                    collision: banner.collision,
                    maxWidth: w - 2 * pad,
                    fontSize: 17.25 * fontZoom,
                  ),
                ),
              ),
            ],
            if (lineH > 0) ...[
              const SizedBox(height: 8),
              // LINE：純顯示，不攔截觸控
              SizedBox(
                key: const ValueKey('line'),
                height: lineH,
                child: Padding(padding: const EdgeInsets.only(top: lineTagSpace),
                  child: IgnorePointer(child: _lineBox(LineNotifications.instance.messages))),
              ),
            ],
            // 停車面板加 key：LINE 區出現 / 消失時保留查詢結果與倒數狀態
            if (parkingH > 0) ...[
              const SizedBox(height: 8),
              SizedBox(
                key: const ValueKey('parking'),
                height: parkingH,
                child: ParkingPanel(state: state, stale: stale),
              ),
            ],
          ],
        ),
      );

      return ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 內容高度已依可用空間計算；萬一系統字型過大，裁掉而不是丟 overflow
            SingleChildScrollView(
              physics: const NeverScrollableScrollPhysics(),
              child: column,
            ),
          ],
        ),
      );
    },
  );

  /// 儀表卡片置中、寬度為原本的 90%；兩側固定留方向燈欄位（不亮時空白，卡片不會跳動），
  /// 與橫向 DashboardHud 相同位置邏輯。卡片縮窄後多出的寬度給方向燈箭頭（上限 卡片高 × 0.42）。
  Widget _cardWithBlinkers(double cardH, double boxH, double rowW) {
    // 卡片寬度用放大前的高度計算（v20：高度提高、寬度不變）
    final baseSlot = math.min(cardH / cardHeightZoom * .42, rowW * .12);
    final cardW = math.min(rowW, (rowW - 2 * baseSlot) * cardWidthScale);
    // 方向燈箭頭大小維持原本（依內容高度），卡片變矮後仍放得下（0.42 × 113 ≈ 47 < 90）
    final slot = math.min(math.min(cardH * .42, boxH), (rowW - cardW) / 2);
    Widget side(bool left) => SizedBox(
      width: slot,
      child: Center(
        child: !stale && (left ? state.leftBlinker : state.rightBlinker)
            ? BlinkerArrow(left: left, size: slot)
            : null,
      ),
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        side(true),
        SizedBox(
          width: cardW,
          child: DashboardCard(
            state: state,
            stale: stale,
            tdxInRightColumn: false,
            contentHeight: cardH, // 字級依原本高度，卡片本身較矮
            expBadge: true, // 實驗模式：卡片左上角 EXP（取代已移除的徽章列）
          ),
        ),
        side(false),
      ],
    );
  }

  /// LINE 通知：新的在上，每則 30 秒後自動消失。
  /// 行數依剩餘高度自動決定：最新一則優先，能完整顯示就完整顯示，放不下才截斷（至少兩行）；
  /// 較舊的訊息用剩下的行數，連一行都放不下就不顯示。
  Widget _lineBox(List<LineMessage> msgs) {
    if (msgs.isEmpty) return const SizedBox.shrink();
    return Stack(clipBehavior: Clip.none, children: [
      Positioned.fill(child: Container(
        padding: const EdgeInsets.fromLTRB(14, linePadV, 14, linePadV),
        decoration: BoxDecoration(color: const Color(0xFF0D151B), borderRadius: BorderRadius.circular(16),
            border: Border.all(color: lineGreen.withAlpha(90))),
        child: LayoutBuilder(builder: (context, box) {
          final scaler = MediaQuery.textScalerOf(context);
          final lineH = scaler.scale(lineFont) * lineHeight;
          // 每行高度鎖定（含 emoji 的行不會被撐高），算出的行數與實際畫出來一致
          const strut = StrutStyle(fontSize: lineFont, height: lineHeight, forceStrutHeight: true);
          // 以像素計算剩餘空間：訊息間距只扣 lineMsgGap（原本每個間距算成一整行，
          // 3 則訊息會浪費 2 行、最後一則被提早截斷）；+0.5 px 容差避免浮點誤差少算一行
          var leftPx = box.maxHeight + .5;
          final children = <Widget>[];
          for (var i = 0; i < msgs.length; i++) {
            final gapPx = i == 0 ? 0.0 : lineMsgGap;
            final avail = ((leftPx - gapPx) / lineH).floor();
            if (avail <= 0) break;
            final span = _lineSpan(msgs[i]);
            final style = TextStyle(fontSize: lineFont, height: lineHeight,
                color: i == 0 ? Colors.white : Colors.white60);
            final tp = TextPainter(text: TextSpan(style: style, children: [span]), strutStyle: strut,
                textDirection: TextDirection.ltr, textScaler: scaler)..layout(maxWidth: box.maxWidth);
            final need = tp.computeLineMetrics().length;
            tp.dispose();
            // 最新一則優先，能完整顯示就完整顯示；其餘用剩下的行數
            final lines = math.min(need, avail);
            children.add(Padding(padding: EdgeInsets.only(top: gapPx),
              child: Text.rich(span, maxLines: lines, overflow: TextOverflow.ellipsis, style: style,
                  strutStyle: strut)));
            leftPx -= gapPx + lines * lineH;
          }
          return ClipRect(child: SingleChildScrollView(physics: const NeverScrollableScrollPhysics(),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children)));
        }),
      )),
      // 「LINE · N 則」小標籤貼在上邊框（落在上方 8 px 間距裡，不佔訊息行數）
      Positioned(right: 14, top: -8, child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(color: const Color(0xFF0D151B), borderRadius: BorderRadius.circular(6),
            border: Border.all(color: lineGreen.withAlpha(140))),
        child: Text(msgs.length > 1 ? 'LINE · ${msgs.length} 則' : 'LINE',
          style: const TextStyle(fontSize: 9 * fontZoom, color: lineGreen, fontWeight: FontWeight.w800,
              letterSpacing: .5, height: 1.25)),
      )),
    ]);
  }

  TextSpan _lineSpan(LineMessage m) => TextSpan(children: [
    if (m.sender.isNotEmpty)
      TextSpan(text: '${m.sender}：', style: const TextStyle(color: lineGreen, fontWeight: FontWeight.w700)),
    TextSpan(text: m.text),
  ]);

  Widget _tdxRow(int speed) {
    final c = tdxCongestionColor(state.tdxCongestion);
    final label = congestionLabel(state.tdxCongestion);
    return Container(
      height: tdxRowH,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF0D151B),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Text(
            '前方車速',
            style: TextStyle(fontSize: 12 * fontZoom, color: Colors.white60),
          ),
          const SizedBox(width: 14),
          Text(
            '$speed',
            style: TextStyle(
              fontSize: 26 * fontZoom,
              fontWeight: FontWeight.w700,
              color: c,
              height: 1,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            state.isMetric ? 'km/h' : 'mph',
            style: const TextStyle(
              fontSize: 12 * fontZoom,
              color: Colors.white60,
            ),
          ),
          const Spacer(),
          if (label.isNotEmpty)
            Text(
              'TDX $label',
              style: TextStyle(
                fontSize: 12 * fontZoom,
                color: c,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }
}
