// TDX 前方路況：純計算部分（不依賴 Flutter，可單元測試、可在 Isolate 執行）
//
// 移植自 comma 端 tdx_traffic.py（2026-10-18 版），差異：
//   - VD（車道偵測器）：2026-11-12 起恢復（國道各車道車速），但 Live VD 只抓前方幾支偵測器
//     （OData \$filter），不像 comma 端每分鐘下載全國道。
//   - 新增回堵長度與車速驟降判斷（tdxQueueAhead），comma 端沒有。
//   - 縣市判斷改用手機 OS 反向地理編碼（tdx_traffic_service.dart），不下載縣市界線圖資。
//   - 輸出直接轉成 opview UIState.applyTdx() 吃的格式（nextSpeed / congestion / events），
//     與原本 comma 端 tdxd 發布的 custom.Tdx 欄位相同，畫面元件不用改。
//   - 前方車速 = 前方 3 公里內最慢路段（tdxd 是「約 3 公里處那一段」；tdx_traffic.py 的 slow
//     判斷另有門檻，這裡改為一律顯示最慢值，壅塞分級依道路種類各自的門檻）。
//
// 「前方」沿 TDX 路段線形（線形方向即行車方向）追蹤：腳下路段（ON_SECTION_M 內、航向差 HEADING_DEG 內），
// 接著找起點落在本段終點 CHAIN_M 內、方向相近的下一段，最多 PATH_M。事件落在這條路徑上（且 TDX 有標方向時
// 方向相同）才算；不在任何路段上時（沒有即時資料的縣市道路），事件須在目前道路名稱上且在正前方。

import 'dart:math' as math;

const tdxOnSectionM = 30.0;
const tdxHeadingDeg = 45.0;
const tdxChainM = 120.0;
const tdxChainDeg = 60.0;
const tdxEndHeadingM = 50.0;
const tdxPathM = 5000.0; // 路徑往前追多遠
const tdxAheadM = 3000.0; // 往前多遠內的東西才報（國道）
// 與 tdx_traffic.py 不同（刻意差異，2026-11-11）：前方車速往前看的距離依道路種類。
// 市區路口多、常轉彎，3 公里外的路段多半不是要去的地方；省道介於中間。事件仍用 tdxAheadM。
const tdxSpeedAheadM = {'Freeway': 3000.0, 'Highway': 2000.0, 'City': 800.0};
const tdxEventPathM = 60.0;
const tdxStraightM = 1500.0, tdxStraightLatM = 40.0; // 不在路段上：同一條路正前方的事件
const tdxGrid = 500.0; // m，空間索引格
// 國道路段串接跨缺口（2026-11-12，用真實 TDX 國道資料驗證）：TDX 的國道線形常有缺口或重疊——
// 平面 120–250 m（交流道處）、汐止五股高架最多 2.5 km（五股轉接道）、重疊時下一段起點在本段終點後方 ~150 m。
// 原本只接 120 m 內的路段 → 465 段中 41 段接不下去，且高架在缺口處會接到平面（反之亦然，例：泰山轉接道）。
// 改為國道先找「同一條路（RoadName 相同）」：tdxBridgeNearM 內不限方位（處理重疊），
// tdxBridgeNearM–tdxBridgeFarM 要在行車方向正前方 tdxBridgeDeg 內（跨缺口），且該段終點要在本段終點前方；
// 找不到才照原規則接 120 m 內的其他路（高架在汐止端 / 楊梅端結束併回平面）。跨缺口時距離加上缺口長度。
// 2026-11-13（早上尖峰真實資料）：另有「線形畫過頭」——下一段起點落在本段線上、終點前 300–900 m
// （國8 台南端到新吉 306 m、汐五高架 中壢轉接二到校前路 912 m），原規則接不到或跳過一段。
// → 起點落在本段最後 tdxOverlapM 內、橫向 tdxBridgeLatM 內的同路段也算，位置為負（重疊），取最前面的那段。
const tdxBridgeNearM = 300.0;
const tdxBridgeFarM = 3000.0;
const tdxBridgeDeg = 20.0;
const tdxOverlapM = 2000.0;
const tdxBridgeLatM = 40.0;

// TDX 各資料的涵蓋範圍（swagger 列舉，2026-10-18）
const tdxLiveCities = {
  'YilanCounty', 'ChanghuaCounty', 'YunlinCounty', 'PingtungCounty', 'Keelung', 'Taipei', 'Kaohsiung',
  'Taichung', 'Tainan', 'Taoyuan',
};
const tdxEventCities = {
  'Taipei', 'NewTaipei', 'Taoyuan', 'Taichung', 'Tainan', 'Kaohsiung', 'Keelung', 'MiaoliCounty',
  'ChiayiCounty', 'PingtungCounty', 'YilanCounty', 'KinmenCounty',
};
const tdxEventKind = {1: '事故', 2: '施工', 3: '壅塞', 4: '特殊事件', 5: '管制', 6: '災變'};
const _dirZh = {
  '北向': 0.0, '東北向': 45.0, '東向': 90.0, '東南向': 135.0, '南向': 180.0, '西南向': 225.0, '西向': 270.0,
  '西北向': 315.0,
};

/// 壅塞分級門檻 (smooth 以上, slow 以上)，km/h；其餘為 congested。
/// 國道沿用 tdxd（80 / 40），省道、市區依 tdx_traffic.py SLOW_KPH 另訂。
const tdxCongestionKph = {'Freeway': (80, 40), 'Highway': (50, 30), 'City': (30, 15)};

final double _kx = 111320.0 * math.cos(23.7 * math.pi / 180); // 度 -> 公尺，台灣範圍內夠準
const double _ky = 110540.0;

(double, double) tdxXY(double lat, double lon) => (lon * _kx, lat * _ky);

double tdxAngDiff(double a, double b) => ((a - b + 180.0) % 360.0 - 180.0).abs();

double tdxHeadingOf(double dx, double dy) => (math.atan2(dx, dy) * 180.0 / math.pi) % 360.0;

final _num = RegExp(r'(-?\d+(?:\.\d+)?)\s+(-?\d+(?:\.\d+)?)');

/// POINT / LINESTRING 的 [(lon, lat), ...]，依原順序
List<(double, double)> tdxWktPoints(String? s) => _num
    .allMatches(s ?? '')
    .map((m) => (double.parse(m.group(1)!), double.parse(m.group(2)!)))
    .toList();

/// 相鄰點至少相距 step（與 pts 同單位），保留最後一點
List<(double, double)> tdxThin(List<(double, double)> pts, double step) {
  if (pts.length < 3) return pts;
  final out = [pts.first];
  for (final p in pts.sublist(1, pts.length - 1)) {
    final last = out.last;
    if (math.sqrt(math.pow(p.$1 - last.$1, 2) + math.pow(p.$2 - last.$2, 2)) >= step) out.add(p);
  }
  out.add(pts.last);
  return out;
}

/// ISO 時間 → epoch 秒；無法解析回傳 null
double? tdxParseTime(Object? s) {
  if (s is! String) return null;
  final t = DateTime.tryParse(s);
  return t == null ? null : t.millisecondsSinceEpoch / 1000.0;
}

/// TDX 把清單包在帶更新時間的物件裡；清單就是裡面唯一的 list
List tdxItems(Object? j) {
  if (j is List) return j;
  if (j is Map) {
    for (final v in j.values) {
      if (v is List) return v;
    }
  }
  return const [];
}

double _round(double v, int digits) {
  final f = math.pow(10, digits).toDouble();
  return (v * f).round() / f;
}

// ------------------------------------------------------------------ 靜態資料縮減（下載後、存快取前）
/// SectionShape → {SectionID: [[lat, lon], ...]}
Map<String, List<List<double>>> tdxShrinkShapes(Object? j) {
  final out = <String, List<List<double>>>{};
  for (final s in tdxItems(j)) {
    if (s is! Map) continue;
    final id = s['SectionID'], geom = s['Geometry'];
    if (id is! String || id.isEmpty || geom is! String || geom.isEmpty) continue;
    out[id] = [
      for (final (lo, la) in tdxThin(tdxWktPoints(geom), 0.0001)) [_round(la, 6), _round(lo, 6)],
    ];
  }
  return out;
}

/// Section → {SectionID: {name, road}}
Map<String, Map<String, String>> tdxShrinkSections(Object? j) {
  final out = <String, Map<String, String>>{};
  for (final s in tdxItems(j)) {
    if (s is! Map) continue;
    final id = s['SectionID'];
    if (id is! String || id.isEmpty) continue;
    final road = s['RoadName'] is String ? s['RoadName'] as String : '';
    final name = s['SectionName'] is String && (s['SectionName'] as String).isNotEmpty
        ? s['SectionName'] as String : road;
    out[id] = {'name': name, 'road': road};
  }
  return out;
}

// ------------------------------------------------------------------ 路段幾何
typedef TdxPathSection = ({String sid, double d0, double d1}); // 距我們到該段起點、終點的公尺數
typedef TdxPathPoint = (double x, double y, double d); // 路徑點與距我們的公尺數

int _gkey(int i, int j) => i * 1048576 + j; // 台灣範圍 j 約 4400~5600，不會溢位到下一列

/// 單一管轄單位的所有路段：線形轉成本地公尺，建網格索引，用來找自己在哪一段與接下來是哪一段
class TdxSections {
  final pts = <String, List<(double, double)>>{};
  final cum = <String, List<double>>{};
  final Map<String, ({String name, String road})> names;
  final _grid = <int, Set<(String, int)>>{};
  final _starts = <int, List<String>>{};

  /// shapes: {SectionID: [[lat, lon], ...]}；names: {SectionID: {name, road}}（可為 null）
  TdxSections(Map shapes, Map? rawNames) : names = _names(rawNames) {
    shapes.forEach((sid, ll) {
      if (sid is! String || ll is! List) return;
      final p = <(double, double)>[];
      for (final q in ll) {
        if (q is List && q.length >= 2 && q[0] is num && q[1] is num) {
          p.add(tdxXY((q[0] as num).toDouble(), (q[1] as num).toDouble()));
        }
      }
      if (p.length < 2) return;
      final c = <double>[0.0];
      for (var k = 1; k < p.length; k++) {
        c.add(c.last + _hypot(p[k].$1 - p[k - 1].$1, p[k].$2 - p[k - 1].$2));
      }
      pts[sid] = p;
      cum[sid] = c;
      for (var i = 0; i < p.length - 1; i++) {
        for (final cell in _cells(p[i], p[i + 1])) {
          _grid.putIfAbsent(cell, () => <(String, int)>{}).add((sid, i));
        }
      }
      _starts.putIfAbsent(_gkey(_fl(p.first.$1), _fl(p.first.$2)), () => []).add(sid);
    });
  }

  static Map<String, ({String name, String road})> _names(Map? raw) {
    final out = <String, ({String name, String road})>{};
    raw?.forEach((k, v) {
      if (k is String && v is Map) {
        out[k] = (name: v['name'] is String ? v['name'] as String : '',
                  road: v['road'] is String ? v['road'] as String : '');
      }
    });
    return out;
  }

  int get length => pts.length;
  String nameOf(String sid) => names[sid]?.name ?? '';
  String roadOf(String sid) => names[sid]?.road ?? '';

  static int _fl(double v) => (v / tdxGrid).floor();

  static Iterable<int> _cells((double, double) a, (double, double) b) sync* {
    final x0 = math.min(a.$1, b.$1), x1 = math.max(a.$1, b.$1);
    final y0 = math.min(a.$2, b.$2), y1 = math.max(a.$2, b.$2);
    for (var i = _fl(x0); i <= _fl(x1); i++) {
      for (var j = _fl(y0); j <= _fl(y1); j++) {
        yield _gkey(i, j);
      }
    }
  }

  Set<(String, int)> _near(double x, double y) {
    final i = _fl(x), j = _fl(y);
    final out = <(String, int)>{};
    for (var di = -1; di <= 1; di++) {
      for (var dj = -1; dj <= 1; dj++) {
        final g = _grid[_gkey(i + di, j + dj)];
        if (g != null) out.addAll(g);
      }
    }
    return out;
  }

  /// (到線段距離, 在路段上的累積公尺, 線段航向)
  (double, double, double) _segHit(String sid, int i, double x, double y) {
    final (ax, ay) = pts[sid]![i];
    final (bx, by) = pts[sid]![i + 1];
    final dx = bx - ax, dy = by - ay;
    final ll = dx * dx + dy * dy;
    final t = ll == 0 ? 0.0 : (((x - ax) * dx + (y - ay) * dy) / ll).clamp(0.0, 1.0).toDouble();
    final px = ax + t * dx, py = ay + t * dy;
    return (_hypot(x - px, y - py), cum[sid]![i] + t * math.sqrt(ll), tdxHeadingOf(dx, dy));
  }

  /// 腳下且同向的路段：(SectionID, 在該段上的公尺數)，找不到回傳 null
  (String, double)? locate(double x, double y, double hd) {
    (double, String, double)? best;
    for (final (sid, i) in _near(x, y)) {
      final (d, s, h) = _segHit(sid, i, x, y);
      if (d <= tdxOnSectionM && tdxAngDiff(h, hd) <= tdxHeadingDeg && (best == null || d < best.$1)) {
        best = (d, sid, s);
      }
    }
    return best == null ? null : (best.$2, best.$3);
  }

  /// 路段頭 / 尾 END_HEADING_M 的方向：交流道處最前或最後一小段可能指向任何方向
  double _endHeading(String sid, bool start) {
    final p = pts[sid]!, c = cum[sid]!;
    (double, double) a, b;
    if (start) {
      var k = p.length - 1;
      for (var i = 1; i < p.length; i++) {
        if (c[i] >= tdxEndHeadingM) { k = i; break; }
      }
      a = p.first;
      b = p[k];
    } else {
      var k = 0;
      for (var i = p.length - 2; i >= 0; i--) {
        if (c.last - c[i] >= tdxEndHeadingM) { k = i; break; }
      }
      a = p[k];
      b = p.last;
    }
    return tdxHeadingOf(b.$1 - a.$1, b.$2 - a.$2);
  }

  /// 下一段與缺口長度（正 = 缺口、負 = 重疊；|值| ≤ tdxChainM 視為 0）。[bridge]：國道跨缺口規則（見 tdxBridgeNearM）。
  (String, double)? _next(String sid, Set<String> seen, {bool sameRoad = false, bool bridge = false}) {
    final (ex, ey) = pts[sid]!.last;
    final he = _endHeading(sid, false);
    final i = _fl(ex), j = _fl(ey);
    final road = roadOf(sid);
    if (bridge && road.isNotEmpty) {
      final ux = math.sin(he * math.pi / 180), uy = math.cos(he * math.pi / 180);
      final p = pts[sid]!, c = cum[sid]!;
      final len = c.last;
      final r = (tdxBridgeFarM / tdxGrid).ceil();
      (String, double)? near; // (下一段, 起點相對本段終點的位置：負 = 重疊、正 = 缺口)
      for (var di = -r; di <= r; di++) {
        for (var dj = -r; dj <= r; dj++) {
          for (final s2 in _starts[_gkey(i + di, j + dj)] ?? const <String>[]) {
            if (seen.contains(s2) || roadOf(s2) != road) continue;
            if (tdxAngDiff(_endHeading(s2, true), he) > tdxChainDeg) continue;
            final (sx, sy) = pts[s2]!.first;
            final (qx, qy) = pts[s2]!.last;
            if ((qx - ex) * ux + (qy - ey) * uy <= 0) continue; // 終點要在前方（不接回後面的路段）
            double? at;
            // ① 起點落在本段最後 tdxOverlapM 的線上（線形畫過頭）
            for (var k = p.length - 2; k >= 0 && c[k + 1] >= len - tdxOverlapM; k--) {
              final (d, a, _) = _segHit(sid, k, sx, sy);
              if (d <= tdxBridgeLatM && a >= len - tdxOverlapM) { at = a - len; break; }
            }
            if (at == null) {
              // ② 終點附近（不限方位）或正前方的缺口
              final g = _hypot(sx - ex, sy - ey);
              if (g > tdxBridgeFarM) continue;
              if (g > tdxBridgeNearM && tdxAngDiff(tdxHeadingOf(sx - ex, sy - ey), he) > tdxBridgeDeg) continue;
              at = (sx - ex) * ux + (sy - ey) * uy < 0 ? -g : g;
            }
            if (near == null || at < near.$2) near = (s2, at);
          }
        }
      }
      if (near != null) return (near.$1, near.$2.abs() > tdxChainM ? near.$2 : 0.0);
    }
    ((int, double), String)? best;
    for (var di = -1; di <= 1; di++) {
      for (var dj = -1; dj <= 1; dj++) {
        for (final s2 in _starts[_gkey(i + di, j + dj)] ?? const <String>[]) {
          if (seen.contains(s2)) continue;
          final (sx, sy) = pts[s2]!.first;
          if (_hypot(sx - ex, sy - ey) > tdxChainM) continue;
          final turn = tdxAngDiff(_endHeading(s2, true), he);
          if (turn > tdxChainDeg) continue;
          // 市區：只沿同一條路往前接（路口直行可能接到別條路，車速差很多）
          if (sameRoad && road.isNotEmpty && roadOf(s2) != road) continue;
          // 同一條路優先，其次最直
          final key = (roadOf(s2) != road ? 1 : 0, turn);
          if (best == null || key.$1 < best.$1.$1 || (key.$1 == best.$1.$1 && key.$2 < best.$1.$2)) {
            best = (key, s2);
          }
        }
      }
    }
    return best == null ? null : (best.$2, 0.0);
  }

  /// 從 sid 的 along 公尺處往前：[(路段, 到起點距離, 到終點距離)] 與路徑折線 [(x, y, 距離)]
  /// [sameRoad]：只沿同一條路（RoadName 相同）往下接，市區用。[bridge]：國道跨缺口（見 tdxBridgeNearM）。
  (List<TdxPathSection>, List<TdxPathPoint>) path(String sid, double along,
      {bool sameRoad = false, bool bridge = false}) {
    final secs = <TdxPathSection>[];
    final line = <TdxPathPoint>[];
    final c = cum[sid]!, p = pts[sid]!;
    secs.add((sid: sid, d0: -along, d1: c.last - along));
    // 與 tdx_traffic.py 不同：路徑從車子在路段上的投影點開始，而不是下一個線形點。
    // 原寫法在線形點稀疏（直路段兩點可能相距上公里）時，車子與下一點之間的事件會落在路徑外。
    for (var k = 0; k < p.length; k++) {
      if (c[k] < along) continue;
      if (k > 0 && c[k] > along && c[k] > c[k - 1]) {
        final t = (along - c[k - 1]) / (c[k] - c[k - 1]);
        line.add((p[k - 1].$1 + t * (p[k].$1 - p[k - 1].$1), p[k - 1].$2 + t * (p[k].$2 - p[k - 1].$2), 0.0));
      }
      for (var m = k; m < p.length; m++) {
        line.add((p[m].$1, p[m].$2, c[m] - along));
      }
      break;
    }
    var off = c.last - along;
    final seen = {sid};
    var cur = sid;
    while (off < tdxPathM) {
      final hop = _next(cur, seen, sameRoad: sameRoad, bridge: bridge);
      if (hop == null) break;
      final (nxt, gap) = hop;
      off += gap; // 跨缺口：距離加上缺口長度；重疊：扣掉（下一段的 d0 會小於上一段的 d1）
      seen.add(nxt);
      final cn = cum[nxt]!, pn = pts[nxt]!;
      secs.add((sid: nxt, d0: off, d1: off + cn.last));
      for (var k = 0; k < pn.length; k++) {
        line.add((pn[k].$1, pn[k].$2, off + cn[k]));
      }
      off += cn.last;
      cur = nxt;
    }
    return (secs, line);
  }
}

double _hypot(double a, double b) => math.sqrt(a * a + b * b);

/// 路徑上最接近 (x, y) 的點距我們幾公尺；離路徑超過 maxD 回傳 null
double? tdxOnPath(List<TdxPathPoint> line, double x, double y, double maxD) {
  (double, double)? best;
  for (var k = 0; k + 1 < line.length; k++) {
    final (ax, ay, sa) = line[k];
    final (bx, by, sb) = line[k + 1];
    final dx = bx - ax, dy = by - ay;
    final ll = dx * dx + dy * dy;
    final t = ll == 0 ? 0.0 : (((x - ax) * dx + (y - ay) * dy) / ll).clamp(0.0, 1.0).toDouble();
    final d = _hypot(x - ax - t * dx, y - ay - t * dy);
    if (d <= maxD && (best == null || d < best.$1)) best = (d, sa + t * (sb - sa));
  }
  return best?.$2;
}

// ------------------------------------------------------------------ 即時資料解析
const tdxLiveMaxAge = 15 * 60.0; // s：依資料自身收集時間，超過就丟掉

/// Live（路段旅行速率）→ {SectionID: km/h}
Map<String, int> tdxLiveSpeeds(Object? j, double nowWall) {
  final out = <String, int>{};
  for (final s in tdxItems(j)) {
    if (s is! Map) continue;
    final t = tdxParseTime(s['DataCollectTime']);
    if (t != null && nowWall - t > tdxLiveMaxAge) continue;
    final sp = s['TravelSpeed'], id = s['SectionID'];
    if (id is String && sp is num && sp.isFinite && sp > 0) out[id] = sp.toInt();
  }
  return out;
}

class TdxEvent {
  final double lat, lon;
  final String kind, title, text;
  final double? dir; // TDX 標示的行車方向（度），未標示為 null
  final List<String> roads;
  final String id;
  const TdxEvent({required this.lat, required this.lon, required this.kind, required this.title,
    required this.text, required this.dir, required this.roads, required this.id});
}

List<String> _eventRoads(Map loc) {
  final roads = <String>[];
  void add(Object? r) { if (r is String && r.isNotEmpty) roads.add(r); }
  final fe = loc['FreeExpressHighway'];
  if (fe is Map) add(fe['Road']);
  final cr = loc['CityRoad'];
  if (cr is Map && cr['Roadways'] is List) {
    for (final rw in cr['Roadways'] as List) { if (rw is Map) add(rw['Road']); }
  }
  final it = loc['Intersection'];
  if (it is Map && it['Roads'] is List) {
    for (final r in it['Roads'] as List) {
      if (r is Map) {
        add(r['Road']);
      } else {
        add(r);
      }
    }
  }
  final ad = loc['Address'];
  if (ad is Map) add(ad['Road']);
  return roads;
}

/// LiveEvent（v1 RoadEvent）→ 目前有效的事件
List<TdxEvent> tdxLiveEvents(Object? j, double nowWall) {
  final out = <TdxEvent>[];
  for (final e in tdxItems(j)) {
    if (e is! Map) continue;
    final exp = tdxParseTime(e['ExpireTime']), eff = tdxParseTime(e['EffectiveTime']);
    if ((exp != null && exp < nowWall) || (eff != null && eff > nowWall)) continue;
    final pts = tdxWktPoints(e['Positions'] is String ? e['Positions'] as String : null);
    if (pts.isEmpty) continue;
    final loc = e['Location'] is Map ? e['Location'] as Map : const {};
    final fe = loc['FreeExpressHighway'];
    final dirn = fe is Map && fe['Direction'] is String ? fe['Direction'] as String : '';
    final imp = e['Impact'] is Map ? e['Impact'] as Map : const {};
    final text = (imp['Description'] is String ? imp['Description'] as String : '').trim();
    final type = e['EventType'];
    out.add(TdxEvent(
      lat: pts.first.$2, lon: pts.first.$1,
      kind: tdxEventKind[type is num ? type.toInt() : int.tryParse('$type')] ?? '狀況',
      title: (e['EventTitle'] is String ? e['EventTitle'] as String : '').trim(),
      text: text.length <= 16 ? text : '',
      dir: _dirZh[dirn],
      roads: _eventRoads(loc),
      id: e['EventID']?.toString() ?? '${pts.first.$1},${pts.first.$2},$type',
    ));
  }
  return out;
}

// ------------------------------------------------------------------ 組成畫面資料
String tdxDistText(double d) =>
    d < 950 ? '${(d / 50).round() * 50}公尺' : '${(d / 1000).toStringAsFixed(1)}公里';

String tdxCongestionOf(String? auth, int kph) {
  if (kph <= 0) return 'unknown';
  final (smooth, slow) = tdxCongestionKph[auth] ?? tdxCongestionKph['Freeway']!;
  return kph >= smooth ? 'smooth' : kph >= slow ? 'slow' : 'congested';
}

/// 產生 UIState.applyTdx() 用的資料（欄位同 custom.Tdx：nextSpeed / congestion / events）。
///
/// auth：'Freeway' / 'Highway' / 'City:Taipei'…，不在任何路段上為 null。
/// speeds：該 auth 仍新鮮的即時車速（沒有為 null）。events：所有仍新鮮的事件（已去重）。
/// road：手機地理編碼取得的目前道路名（只用在不在路段上時）。
/// showCurrentFirst：每 10 秒在「目前 / 前方」之間輪替（同 tdxd）。
Map<String, dynamic> tdxReport({
  required String? auth,
  required TdxSections? sections,
  required String? sid,
  required double along,
  required double x,
  required double y,
  required double hd,
  required String road,
  required Map<String, int>? speeds,
  required List<TdxEvent> events,
  required bool showCurrentFirst,
  TdxVdIndex? vds,
  Map<String, List<TdxLane>>? vdLive,
}) {
  final kind = auth?.split(':').first;
  List<TdxPathPoint>? line;
  var curEnd = 300.0; // 不在路段上時，300 m 內的事件算「目前」
  int? cur;
  String roadName = '';
  final ahead = <({int v, String sid, double d})>[];
  TdxQueue? queue;
  List<(String, double)> vdAhead = const [];
  if (auth != null && sections != null && sid != null && sections.pts.containsKey(sid)) {
    final (secs, l) = sections.path(sid, along, sameRoad: kind == 'City', bridge: kind == 'Freeway');
    line = l;
    curEnd = secs.first.d1;
    roadName = sections.nameOf(sid);
    if (kind == 'Freeway' && vds != null) vdAhead = vds.ahead(l, x, y, hd);
    if (speeds != null) {
      if (kind == 'Freeway') queue = tdxQueueAhead(secs, speeds);
      cur = speeds[sid];
      for (final s in secs.skip(1)) {
        if (s.d0 > (tdxSpeedAheadM[kind] ?? tdxAheadM)) break;
        final v = speeds[s.sid];
        if (v != null) ahead.add((v: v, sid: s.sid, d: s.d0));
      }
    }
  }

  // 事件：在路徑上（或不在路段上時，同一條路的正前方）
  final cand = <(double, TdxEvent)>[];
  for (final e in events) {
    final (ex, ey) = tdxXY(e.lat, e.lon);
    if ((ex - x).abs() > tdxPathM || (ey - y).abs() > tdxPathM) continue;
    if (e.dir != null && tdxAngDiff(e.dir!, hd) > 90.0) continue;
    double? d;
    if (line != null && line.isNotEmpty) {
      d = tdxOnPath(line, ex, ey, tdxEventPathM);
    } else if (road.isNotEmpty && e.roads.any((r) => road.contains(r) || r.contains(road))) {
      final dx = ex - x, dy = ey - y, h = hd * math.pi / 180.0;
      final al = dx * math.sin(h) + dy * math.cos(h), lat = dx * math.cos(h) - dy * math.sin(h);
      if (al > 0 && al <= tdxStraightM && lat.abs() <= tdxStraightLatM) d = al;
    }
    if (d != null && d >= 0 && d <= tdxAheadM) cand.add((d, e));
  }
  cand.sort((a, b) => a.$1.compareTo(b.$1));
  final picked = cand.take(3).toList();
  String desc((double, TdxEvent) c) {
    final e = c.$2;
    final what = e.title.isNotEmpty ? e.title : e.text;
    final s = '${e.kind} ${tdxDistText(c.$1)}${what.isEmpty ? '' : ' $what'}';
    return s.length > 48 ? s.substring(0, 48) : s;
  }
  final current = [for (final c in picked) if (c.$1 <= curEnd) desc(c)];
  final aheadEv = [for (final c in picked) if (c.$1 > curEnd) desc(c)];
  final useCurrent = showCurrentFirst ? current.isNotEmpty : aheadEv.isEmpty;
  final sel = useCurrent ? current : aheadEv;
  final isCurrent = useCurrent;

  // 前方車速 = 目前路段與前方（國道 3 km / 省道 2 km / 市區 800 m）內最慢的路段。
  // 與 tdx_traffic.py / 前版不同：目前路段也算進來。原本只看「下一段以後」，目前路段 30 km/h、
  // 下一段（可能已接到別條路）87 km/h 時會顯示 87。nextSid / nextD 記錄來源供 log 核對。
  if (cur != null && sid != null) ahead.insert(0, (v: cur, sid: sid, d: 0.0));
  final slowest = ahead.isEmpty ? null : ahead.reduce((a, b) => b.v < a.v ? b : a);
  final next = slowest?.v ?? -1;
  return {
    'auth': kind,
    'road': roadName,
    'sid': sid,
    'speed': cur ?? -1,
    'nextSpeed': next,
    'nextSid': slowest?.sid,
    'nextD': slowest?.d ?? 0.0,
    'nextName': slowest != null && sections != null ? sections.nameOf(slowest.sid) : roadName,
    'congestion': tdxCongestionOf(kind, next),
    'events': [for (final s in sel) {'description': s, 'isCurrentSection': isCurrent}],
    // 國道擴充（2026-11-12）
    'queue': queue == null ? null
        : {'d': queue.d, 'len': queue.len, 'avg': queue.avg, 'min': queue.min, 'open': queue.open},
    'vdAhead': [for (final v in vdAhead) v.$1],
    'lanes': _lanesAhead(vdAhead, vdLive),
  };
}

/// 前方第一支有即時資料的偵測器（tdxVdMinM–tdxVdMaxM）→ {'d', 'vd', 'speeds', 'ids', 'types'}
Map<String, dynamic>? _lanesAhead(List<(String, double)> vdAhead, Map<String, List<TdxLane>>? live) {
  if (live == null) return null;
  for (final (id, d) in vdAhead) {
    if (d < tdxVdMinM || d > tdxVdMaxM) continue;
    final lanes = live[id];
    if (lanes == null || lanes.isEmpty) continue;
    return {
      'd': d, 'vd': id,
      'speeds': [for (final l in lanes) l.speed],
      'ids': [for (final l in lanes) l.id],
      'types': [for (final l in lanes) l.type],
    };
  }
  return null;
}

// ------------------------------------------------------------------ 國道擴充（2026-11-12）
// ① 回堵：沿前方路段，連續低於 tdxQueueKph 的路段長度加總。
//    起點要在前方 tdxQueueStartM 內；資料中斷（沒有即時車速）或車速回到門檻以上就結束；
//    到路徑盡頭（約 5 公里）仍在回堵 → open（「以上」）。
// ② 車速驟降（UIState 用本車車速判斷）：回堵起點在 tdxDropAheadM 內，且本車比回堵最慢路段快 tdxDropDeltaKph 以上。
// ③ 車道車速：前方第一支同向 VD（tdxVdMinM–tdxVdMaxM，距路徑 tdxVdPathM 內）的各車道車速，
//    依 LaneID 排序（交通部即時路況標準：由內側往外側編號；未實車確認，log 會記原始 LaneID / LaneType）。
const tdxQueueKph = 40; // 同國道壅塞分級的 congested（tdxCongestionKph['Freeway'].$2）
const tdxQueueStartM = 3000.0;
const tdxDropAheadM = 2000.0;
const tdxDropDeltaKph = 40;
const tdxVdPathM = 40.0; // 同 tdx_traffic.py VD_PATH_M
const tdxVdMinM = 150.0; // 同 VD_MIN_M：太近的偵測器就是腳下
const tdxVdMaxM = 3000.0;
const tdxVdCandidates = 8; // Live VD 只抓前方這幾支
const _compass = {'N': 0.0, 'NE': 45.0, 'E': 90.0, 'SE': 135.0, 'S': 180.0, 'SW': 225.0, 'W': 270.0, 'NW': 315.0};

typedef TdxQueue = ({double d, double len, int avg, int min, bool open});

TdxQueue? tdxQueueAhead(List<TdxPathSection> secs, Map<String, int> speeds) {
  var i = 0;
  for (; i < secs.length; i++) {
    final v = speeds[secs[i].sid];
    if (math.max(0.0, secs[i].d0) > tdxQueueStartM) return null;
    if (v != null && v < tdxQueueKph) break;
  }
  if (i >= secs.length) return null;
  final start = math.max(0.0, secs[i].d0);
  var len = 0.0, wsum = 0.0, minV = 999;
  var open = true;
  var reach = start; // 已算過的最遠處（國道線形重疊時，下一段 d0 < 上一段 d1，不重複算）
  for (var k = i; k < secs.length; k++) {
    final v = speeds[secs[k].sid];
    if (v == null || v >= tdxQueueKph) { open = false; break; }
    final l = secs[k].d1 - math.max(reach, secs[k].d0);
    if (secs[k].d1 > reach) reach = secs[k].d1;
    if (l <= 0) continue;
    len += l;
    wsum += v * l;
    minV = math.min(minV, v);
  }
  if (len <= 0) return null;
  return (d: start, len: len, avg: (wsum / len).round(), min: minV, open: open);
}

/// VD 靜態資料 → {VDID: [lat, lon, 方向（度，可為 null）]}
Map<String, List<double?>> tdxShrinkVds(Object? j) {
  final out = <String, List<double?>>{};
  for (final v in tdxItems(j)) {
    if (v is! Map) continue;
    final id = v['VDID'], la = v['PositionLat'], lo = v['PositionLon'];
    if (id is! String || id.isEmpty || la is! num || lo is! num) continue;
    final links = v['DetectionLinks'];
    final first = links is List && links.isNotEmpty && links.first is Map ? links.first as Map : const {};
    out[id] = [_round(la.toDouble(), 6), _round(lo.toDouble(), 6), _compass[first['Bearing']]];
  }
  return out;
}

typedef TdxLane = ({int id, int type, int speed});

/// Live VD → {VDID: [各車道，依 LaneID 排序]}；Status ≠ 0、過期、車速 ≤ 0 的不要
Map<String, List<TdxLane>> tdxLiveVds(Object? j, double nowWall) {
  final out = <String, List<TdxLane>>{};
  for (final v in tdxItems(j)) {
    if (v is! Map || v['VDID'] is! String) continue;
    if (v['Status'] != 0) continue;
    final t = tdxParseTime(v['DataCollectTime']);
    if (t != null && nowWall - t > tdxLiveMaxAge) continue;
    final lanes = <TdxLane>[];
    final flows = v['LinkFlows'];
    for (final lf in flows is List ? flows : const []) {
      final ls = lf is Map ? lf['Lanes'] : null;
      for (final ln in ls is List ? ls : const []) {
        if (ln is! Map) continue;
        final sp = ln['Speed'];
        if (sp is! num || !sp.isFinite || sp <= 0) continue;
        final id = ln['LaneID'], ty = ln['LaneType'];
        lanes.add((id: id is num ? id.toInt() : 0, type: ty is num ? ty.toInt() : 0, speed: sp.round()));
      }
    }
    if (lanes.isEmpty) continue;
    lanes.sort((a, b) => a.id.compareTo(b.id));
    out[v['VDID'] as String] = lanes;
  }
  return out;
}

/// 國道 VD 位置索引
class TdxVdIndex {
  final List<({String id, double x, double y, double? bearing})> _all = [];
  TdxVdIndex(Map raw) {
    raw.forEach((k, v) {
      if (k is! String || v is! List || v.length < 2 || v[0] is! num || v[1] is! num) return;
      final (x, y) = tdxXY((v[0] as num).toDouble(), (v[1] as num).toDouble());
      _all.add((id: k, x: x, y: y, bearing: v.length > 2 && v[2] is num ? (v[2] as num).toDouble() : null));
    });
  }
  int get length => _all.length;

  /// 路徑上同向、在前方的偵測器 [(VDID, 距離)]，由近到遠最多 tdxVdCandidates 支（含 tdxVdMinM 內的，
  /// 讓下一輪 Live 抓到時已經在前方）
  List<(String, double)> ahead(List<TdxPathPoint> line, double x, double y, double hd) {
    if (line.length < 2) return const [];
    final out = <(String, double)>[];
    for (final v in _all) {
      if ((v.x - x).abs() > tdxPathM + 200 || (v.y - y).abs() > tdxPathM + 200) continue;
      if (v.bearing != null && tdxAngDiff(v.bearing!, hd) > 90.0) continue;
      final d = tdxOnPath(line, v.x, v.y, tdxVdPathM);
      if (d != null && d > 0) out.add((v.id, d));
    }
    out.sort((a, b) => a.$2.compareTo(b.$2));
    return out.length > tdxVdCandidates ? out.sublist(0, tdxVdCandidates) : out;
  }
}
