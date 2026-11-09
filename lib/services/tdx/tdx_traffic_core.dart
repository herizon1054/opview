// TDX 前方路況：純計算部分（不依賴 Flutter，可單元測試、可在 Isolate 執行）
//
// 移植自 comma 端 tdx_traffic.py（2026-10-18 版），差異：
//   - 不抓 VD（車道偵測器）：opview 沒有車道車速的顯示位置，省一次 API 與大量靜態資料。
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
const tdxAheadM = 3000.0; // 往前多遠內的東西才報
const tdxEventPathM = 60.0;
const tdxStraightM = 1500.0, tdxStraightLatM = 40.0; // 不在路段上：同一條路正前方的事件
const tdxGrid = 500.0; // m，空間索引格

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

  String? _next(String sid, Set<String> seen) {
    final (ex, ey) = pts[sid]!.last;
    final he = _endHeading(sid, false);
    final i = _fl(ex), j = _fl(ey);
    final road = roadOf(sid);
    ((int, double), String)? best;
    for (var di = -1; di <= 1; di++) {
      for (var dj = -1; dj <= 1; dj++) {
        for (final s2 in _starts[_gkey(i + di, j + dj)] ?? const <String>[]) {
          if (seen.contains(s2)) continue;
          final (sx, sy) = pts[s2]!.first;
          if (_hypot(sx - ex, sy - ey) > tdxChainM) continue;
          final turn = tdxAngDiff(_endHeading(s2, true), he);
          if (turn > tdxChainDeg) continue;
          // 同一條路優先，其次最直
          final key = (roadOf(s2) != road ? 1 : 0, turn);
          if (best == null || key.$1 < best.$1.$1 || (key.$1 == best.$1.$1 && key.$2 < best.$1.$2)) {
            best = (key, s2);
          }
        }
      }
    }
    return best?.$2;
  }

  /// 從 sid 的 along 公尺處往前：[(路段, 到起點距離, 到終點距離)] 與路徑折線 [(x, y, 距離)]
  (List<TdxPathSection>, List<TdxPathPoint>) path(String sid, double along) {
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
      final nxt = _next(cur, seen);
      if (nxt == null) break;
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
}) {
  final kind = auth?.split(':').first;
  List<TdxPathPoint>? line;
  var curEnd = 300.0; // 不在路段上時，300 m 內的事件算「目前」
  int? cur;
  String roadName = '';
  final ahead = <int>[];
  if (auth != null && sections != null && sid != null && sections.pts.containsKey(sid)) {
    final (secs, l) = sections.path(sid, along);
    line = l;
    curEnd = secs.first.d1;
    roadName = sections.nameOf(sid);
    if (speeds != null) {
      cur = speeds[sid];
      for (final s in secs.skip(1)) {
        if (s.d0 > tdxAheadM) break;
        final v = speeds[s.sid];
        if (v != null) ahead.add(v);
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

  final next = ahead.isNotEmpty ? ahead.reduce(math.min) : (cur ?? -1);
  return {
    'auth': kind,
    'road': roadName,
    'speed': cur ?? -1,
    'nextSpeed': next,
    'congestion': tdxCongestionOf(kind, next),
    'events': [for (final s in sel) {'description': s, 'isCurrentSection': isCurrent}],
  };
}
