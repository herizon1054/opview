// 路況卡（TDX）：表格式（2026-11-13，A 版）——直向、橫向同一個元件、同一種樣式。
//
//   ┌────────────────────────────────────────┐
//   │ 前方車速  25 km/h                [壅塞] │  ← 標題列：數字依壅塞分級上色，右邊分級色塊
//   ├────────────────────────────────────────┤
//   │ 事件   施工 外側車道封閉          3.0 km │  ← 直向才有（橫向在上方警示列）；過長捲動
//   │ 回堵   3.5 km  均速 28           1.5 km │  ← 國道；車速驟降時這一行換成黃底
//   │        （驟降  降至 25 km/h　回堵 3.5 km）│     （直向才換；橫向的驟降在上方警示列）
//   │ 車道   [92][85][38] 內→外        1.8 km │  ← 國道；色塊依國道壅塞分級
//   └────────────────────────────────────────┘
// 每行固定三欄：左標籤（固定寬）｜內容｜右距離（靠右對齊），沒資料的那一行不顯示。
// 檔名沿用 freeway_info.dart（2026-11-12 新增的檔案），避免覆蓋解壓後留下沒用到的舊檔。

import 'package:flutter/material.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/tdx/tdx_traffic_core.dart' show tdxCongestionOf;
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

/// 右欄距離：950 m 以下以 50 m 為單位，以上 0.1 km
String tdxCardDist(double d) => d < 950 ? '${(d / 50).round() * 50} m' : '${(d / 1000).toStringAsFixed(1)} km';

const _dropFill = Color(0xF0F2B731);
const _dropInk = Color(0xFF1A1300);

class TdxRouteCard extends StatelessWidget {
  final UIState state;
  /// 大小倍率：直向 1.3（同 PortraitPanel.fontZoom），橫向 1.0
  final double scale;
  /// 直向：TDX 事件與車速驟降顯示在卡片裡；橫向在上方警示列
  final bool portrait;
  const TdxRouteCard({super.key, required this.state, this.scale = 1, this.portrait = false});

  // 版面尺寸（× scale），heightFor 與 build 共用，直向面板依此預留高度
  static const _padV = 8.0, _padH = 12.0, _headH = 34.0, _divH = 9.0, _rowH = 26.0;
  static const _labelW = 34.0, _distW = 58.0;

  /// 直向卡片裡要不要顯示 TDX 事件那一行
  static bool _hasEvent(UIState s, bool portrait) => portrait && s.tdxEventRows.isNotEmpty;

  static int _rows(UIState s, bool portrait) => freewayInfoRows(s) + (_hasEvent(s, portrait) ? 1 : 0);

  /// 有沒有東西可顯示（TDX 前方車速、國道資訊，或直向的 TDX 事件）
  static bool visible(UIState s, {bool portrait = false}) =>
      s.tdxNextSpeedDisplay != null || _rows(s, portrait) > 0;

  static double heightFor(UIState s, double scale, {bool portrait = false}) {
    final rows = _rows(s, portrait);
    // + 2：面板邊框（上下各 1）
    return scale * (2 * _padV + _headH + (rows > 0 ? _divH + rows * _rowH : 0)) + 2;
  }

  @override
  Widget build(BuildContext context) {
    final s = scale;
    final speed = state.tdxNextSpeedDisplay;
    final c = tdxCongestionColor(state.tdxCongestion);
    final label = tdxCongestionLabel(state.tdxCongestion);
    final muted = TextStyle(fontSize: 12 * s, color: Colors.white54, height: 1.1);
    final body = TextStyle(fontSize: 14 * s, color: Colors.white.withAlpha(220), height: 1.1);
    final distStyle = TextStyle(fontSize: 13 * s, color: Colors.white60, height: 1.1,
        fontFeatures: const [FontFeature.tabularFigures()]);

    // 一行：標籤｜內容｜距離
    // [fit]：內容太寬時縮小（跑馬燈要自己捲動，不縮）
    Widget row(String key, Widget content, String dist, {bool hi = false, bool fit = true}) {
      final r = SizedBox(height: _rowH * s, child: Row(children: [
        SizedBox(width: _labelW * s, child: Text(key, style: hi
            ? muted.copyWith(color: _dropInk, fontWeight: FontWeight.w800) : muted)),
        Expanded(child: Align(alignment: Alignment.centerLeft, child: fit
            ? FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: content) : content)),
        SizedBox(width: _distW * s, child: Text(dist, textAlign: TextAlign.right, maxLines: 1,
            style: hi ? distStyle.copyWith(color: _dropInk, fontWeight: FontWeight.w800) : distStyle)),
      ]));
      if (!hi) return r;
      // 黃底往左右各多 6 dp（在卡片內距裡），文字欄位和其他行對齊不變
      return Stack(clipBehavior: Clip.none, children: [
        Positioned(left: -6 * s, right: -6 * s, top: 0, bottom: 0, child: DecoratedBox(
          decoration: BoxDecoration(color: _dropFill, borderRadius: BorderRadius.circular(6 * s)))),
        r,
      ]);
    }

    // 標題列：前方車速 25 km/h ……［壅塞］
    final head = SizedBox(height: _headH * s, child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      Text('前方車速', style: muted),
      SizedBox(width: 8 * s),
      Text(speed == null ? '—' : '$speed', style: TextStyle(fontSize: 26 * s, fontWeight: FontWeight.w700,
          color: speed == null ? Colors.white54 : c, height: 1)),
      SizedBox(width: 4 * s),
      Text(state.isMetric ? 'km/h' : 'mph', style: muted),
      const Spacer(),
      if (speed != null && label.isNotEmpty)
        Container(
          padding: EdgeInsets.symmetric(horizontal: 7 * s, vertical: 2 * s),
          decoration: BoxDecoration(color: c.withAlpha(46), borderRadius: BorderRadius.circular(6 * s)),
          child: Text(label, style: muted.copyWith(color: c, fontWeight: FontWeight.w700))),
    ]));

    final rows = <Widget>[];
    // 事件（直向）
    if (_hasEvent(state, portrait)) {
      final ev = state.tdxEventRows;
      final text = ev.map((e) => e.what).join(' / ');
      rows.add(row('事件', TdxMarquee(text: text, fontSize: 14 * s, maxWidth: double.infinity,
          bare: true, showIcon: false), ev.first.dist, fit: false));
    }
    // 回堵 / 車速驟降
    final q = state.tdxQueueInfo;
    if (q != null) {
      final unit = state.isMetric ? 'km/h' : 'mph';
      final len = '${tdxCardDist(q.len)}${q.open ? '+' : ''}';
      final where = q.d < 50 ? '回堵中' : tdxCardDist(q.d);
      if (portrait && state.tdxDropText.isNotEmpty) {
        rows.add(row('驟降', Text('降至 ${q.min} $unit　回堵 $len',
            style: body.copyWith(color: _dropInk, fontWeight: FontWeight.w800)), where, hi: true));
      } else {
        rows.add(row('回堵', Row(mainAxisSize: MainAxisSize.min, children: [
          Text(len, style: body.copyWith(color: tdxCongestedColor, fontWeight: FontWeight.w700)),
          SizedBox(width: 8 * s),
          Text('均速 ${q.avg}', style: muted),
        ]), where));
      }
    }
    // 車道車速：色塊（內 → 外）
    final lanes = state.tdxLanes;
    if (lanes != null) {
      final kmh = state.isMetric;
      rows.add(row('車道', Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < lanes.speeds.length; i++) ...[
          if (i > 0) SizedBox(width: 3 * s),
          Container(
            width: 34 * s, height: 18 * s, alignment: Alignment.center,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(4 * s),
              // 顏色依國道壅塞分級（km/h）
              color: tdxCongestionColor(tdxCongestionOf('Freeway',
                  kmh ? lanes.speeds[i] : (lanes.speeds[i] / kmToMile).round()))),
            child: Text('${lanes.speeds[i]}', style: TextStyle(fontSize: 12 * s, height: 1,
                fontWeight: FontWeight.w800, color: const Color(0xFF0B1114)))),
        ],
        SizedBox(width: 5 * s),
        Text('內→外', style: muted.copyWith(fontSize: 10 * s)),
      ]), tdxCardDist(lanes.d)));
    }

    return Container(
      height: heightFor(state, s, portrait: portrait),
      padding: EdgeInsets.symmetric(horizontal: _padH * s, vertical: _padV * s),
      decoration: opviewPanel(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        head,
        if (rows.isNotEmpty) ...[
          SizedBox(height: _divH * s, child: Center(child: Container(height: 1, color: const Color(0x245DE3D4)))),
          ...rows,
        ],
      ]),
    );
  }
}
