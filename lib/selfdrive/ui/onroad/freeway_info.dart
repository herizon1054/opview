// 路況卡（2026-11-12 版面統一）：TDX 前方車速 + 國道回堵 + 前方偵測器各車道車速，合成一張卡。
//   直向：PortraitPanel 儀表卡片下方（取代原本的 TDX 列與兩列國道資訊）
//   橫向：道路畫面左上角、opview 標題下方（取代儀表卡片右欄的前方車速、上方國道膠囊、「無卡片」時的前方車速膠囊）
// 兩個方向內容、樣式相同，只有大小（scale）不同。非國道只有第一行。
// 直向（portrait，2026-11-13）：TDX 事件、車速驟降都收進這張卡，道路畫面上方的警示列只剩碰撞注意：
//   前方車速 → TDX 事件（過長捲動）→ ── → 車速驟降（黃底，取代回堵那一行）或回堵 → 車道車速
// 橫向：事件、車速驟降仍在上方警示列，卡片只有前方車速＋回堵＋車道。
// 檔名沿用 freeway_info.dart（前一版新增的檔案），避免覆蓋解壓後留下沒用到的舊檔。

import 'package:flutter/material.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/tdx/tdx_traffic_core.dart' show tdxDistText, tdxCongestionOf;
import 'dashboard_hud.dart' show tdxCongestionColor, tdxCongestedColor, opviewPanel, tdxCongestionLabel;
import 'tdx_marquee.dart';

/// 國道資訊有幾行（回堵、車道車速各一行）
int freewayInfoRows(UIState s) => (s.tdxQueueText.isNotEmpty ? 1 : 0) + (s.tdxLanes != null ? 1 : 0);

/// ThrottledHud 用：內容有變才重畫
String freewayInfoKey(UIState s) {
  final l = s.tdxLanes;
  return '${s.tdxNextSpeedDisplay}|${s.tdxCongestion}|${s.tdxQueueText}|${s.tdxDropText}|${s.tdxEventText}|'
      '${l == null ? '' : '${(l.d / 50).round()}:${l.speeds.join(',')}'}';
}

class TdxRouteCard extends StatelessWidget {
  final UIState state;
  /// 大小倍率：直向 1.3（同 PortraitPanel.fontZoom），橫向 1.0
  final double scale;
  /// 直向：TDX 事件與車速驟降顯示在卡片裡；橫向在上方警示列
  final bool portrait;
  const TdxRouteCard({super.key, required this.state, this.scale = 1, this.portrait = false});

  // 版面尺寸（× scale），heightFor 與 build 共用，直向面板依此預留高度
  static const _padV = 8.0, _padH = 14.0, _headH = 34.0, _divH = 9.0, _rowH = 22.0, _eventH = 24.0;

  /// 直向卡片裡要不要顯示 TDX 事件那一行
  static bool _hasEvent(UIState s, bool portrait) => portrait && s.isConnected && s.tdxEventText.isNotEmpty;

  /// 有沒有東西可顯示（TDX 前方車速、國道資訊，或直向的 TDX 事件）
  static bool visible(UIState s, {bool portrait = false}) =>
      s.tdxNextSpeedDisplay != null || freewayInfoRows(s) > 0 || _hasEvent(s, portrait);

  static double heightFor(UIState s, double scale, {bool portrait = false}) {
    final rows = freewayInfoRows(s);
    final ev = _hasEvent(s, portrait) ? _eventH : 0.0;
    // + 2：面板邊框（上下各 1）
    return scale * (2 * _padV + _headH + ev + (rows > 0 ? _divH + rows * _rowH : 0)) + 2;
  }

  @override
  Widget build(BuildContext context) {
    final s = scale;
    final speed = state.tdxNextSpeedDisplay;
    final c = tdxCongestionColor(state.tdxCongestion);
    final label = tdxCongestionLabel(state.tdxCongestion);
    final muted = TextStyle(fontSize: 12 * s, color: Colors.white60, height: 1.1);
    final rowStyle = TextStyle(fontSize: 14 * s, color: Colors.white60, height: 1.1);
    final queue = state.tdxQueueText;
    final lanes = state.tdxLanes;

    Widget line(Widget child) => SizedBox(height: _rowH * s,
        child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: child));

    final head = SizedBox(height: _headH * s, child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      Text('前方車速', style: muted),
      SizedBox(width: 10 * s),
      Text(speed == null ? '—' : '$speed', style: TextStyle(fontSize: 26 * s, fontWeight: FontWeight.w700,
          color: speed == null ? Colors.white60 : c, height: 1)),
      SizedBox(width: 5 * s),
      Text(state.isMetric ? 'km/h' : 'mph', style: muted),
      const Spacer(),
      if (speed != null && label.isNotEmpty)
        Text('TDX $label', style: muted.copyWith(color: c, fontWeight: FontWeight.w600)),
    ]));

    final rows = <Widget>[];
    final drop = portrait ? state.tdxDropText : '';
    if (drop.isNotEmpty) {
      // 車速驟降：取代回堵那一行（驟降一定有回堵，行數不變）
      rows.add(SizedBox(height: _rowH * s, child: Container(
        padding: EdgeInsets.symmetric(horizontal: 6 * s),
        decoration: BoxDecoration(color: const Color(0xF0F2B731), borderRadius: BorderRadius.circular(6 * s)),
        child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Row(
          mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.trending_down_rounded, size: 15 * s, color: const Color(0xFF1A1300)),
            SizedBox(width: 4 * s),
            Text(drop, style: rowStyle.copyWith(color: const Color(0xFF1A1300), fontWeight: FontWeight.w800)),
          ])),
      )));
    } else if (queue.isNotEmpty) {
      final parts = queue.split('｜');
      rows.add(line(Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.traffic_rounded, size: 15 * s, color: tdxCongestedColor),
        SizedBox(width: 4 * s),
        Text(parts.first, style: rowStyle.copyWith(color: tdxCongestedColor, fontWeight: FontWeight.w700)),
        if (parts.length > 1) ...[SizedBox(width: 10 * s), Text(parts.sublist(1).join('｜'), style: rowStyle)],
      ])));
    }
    if (lanes != null) {
      final kmh = state.isMetric;
      rows.add(line(Row(mainAxisSize: MainAxisSize.min, children: [
        Text('車道 ${tdxDistText(lanes.d)}', style: rowStyle),
        SizedBox(width: 10 * s),
        Text('內', style: rowStyle),
        SizedBox(width: 5 * s),
        for (var i = 0; i < lanes.speeds.length; i++) ...[
          if (i > 0) Text('｜', style: rowStyle),
          // 顏色依國道壅塞分級（km/h）
          Text('${lanes.speeds[i]}', style: rowStyle.copyWith(fontWeight: FontWeight.w700,
              color: tdxCongestionColor(tdxCongestionOf('Freeway',
                  kmh ? lanes.speeds[i] : (lanes.speeds[i] / kmToMile).round())))),
        ],
        SizedBox(width: 5 * s),
        Text('外', style: rowStyle),
      ])));
    }

    final event = _hasEvent(state, portrait)
        ? SizedBox(height: _eventH * s, child: TdxMarquee(text: state.tdxEventText, fontSize: 14 * s,
            maxWidth: double.infinity, bare: true))
        : null;

    return Container(
      height: heightFor(state, s, portrait: portrait),
      padding: EdgeInsets.symmetric(horizontal: _padH * s, vertical: _padV * s),
      decoration: opviewPanel(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        head,
        if (event != null) event,
        if (rows.isNotEmpty) ...[
          SizedBox(height: _divH * s, child: Center(child: Container(height: 1, color: const Color(0x265DE3D4)))),
          ...rows,
        ],
      ]),
    );
  }
}
