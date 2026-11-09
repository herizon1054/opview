// TDX 前方路況（手機內建）純計算部分。預期值與 comma 端 tdx_traffic.py 用同一組資料算出的結果對照：
//   locate A along 221.08、heading 180 → C、path A(-221.08, 884.32) B(884.32, 3095.12)、
//   25.02 的事件 1989.72 m、不在路段上同路正前方 497.43 m。
// 唯一刻意的差異：路徑從車子的投影點開始（25.005 的事件 Python 版找不到，這裡是 331.62 m）。
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/services/tdx/tdx_traffic_core.dart';

Map<String, dynamic> _shapesJson() => {
  'UpdateTime': '2026-11-09T10:00:00+08:00',
  'SectionShapes': [
    {'SectionID': 'A', 'Geometry': 'LINESTRING(121.5 25.0, 121.5 25.01)'},
    {'SectionID': 'B', 'Geometry': 'LINESTRING(121.5 25.01, 121.5 25.03)'},
    {'SectionID': 'C', 'Geometry': 'LINESTRING(121.5001 25.03, 121.5001 25.0)'}, // 對向
  ],
};

Map<String, dynamic> _sectJson() => {
  'Sections': [
    {'SectionID': 'A', 'SectionName': '甲交流道-乙交流道', 'RoadName': '國道1號'},
    {'SectionID': 'B', 'SectionName': '乙交流道-丙交流道', 'RoadName': '國道1號'},
    {'SectionID': 'C', 'SectionName': '丙交流道-甲交流道', 'RoadName': '國道1號'},
  ],
};

Map<String, dynamic> _event(String id, double lat, {int type = 2, String dir = '北向', String title = '內側車道封閉'}) => {
  'EventID': id, 'EventType': type, 'EventTitle': title,
  'Positions': 'POINT(121.5 $lat)',
  'Location': {'FreeExpressHighway': {'Road': '國道1號', 'Direction': dir}},
  'Impact': {'Description': '請減速'},
  'EffectiveTime': '2026-11-09T09:00:00+08:00',
  'ExpireTime': '2026-11-09T12:00:00+08:00',
};

void main() {
  final now = DateTime.parse('2026-11-09T10:00:00+08:00').millisecondsSinceEpoch / 1000.0;
  final sections = TdxSections(tdxShrinkShapes(_shapesJson()), tdxShrinkSections(_sectJson()));
  final (x, y) = tdxXY(25.002, 121.5);

  test('shrink + locate + path follow the direction of travel', () {
    expect(sections.length, 3);
    final hit = sections.locate(x, y, 0)!;
    expect(hit.$1, 'A');
    expect(hit.$2, closeTo(221.08, 0.01));
    expect(sections.locate(x, y, 180)!.$1, 'C'); // 對向車道 10 m 外
    expect(sections.locate(x, y, 90), isNull); // 航向不符

    final (secs, line) = sections.path('A', hit.$2);
    expect(secs.map((s) => s.sid), ['A', 'B']);
    expect(secs[0].d1, closeTo(884.32, 0.01));
    expect(secs[1].d1, closeTo(3095.12, 0.01));
    expect(line.first.$3, 0.0); // 從車子的位置開始
    final (ex, ey) = tdxXY(25.02, 121.5);
    expect(tdxOnPath(line, ex, ey, tdxEventPathM), closeTo(1989.72, 0.01));
    final (cx, cy) = tdxXY(25.005, 121.5);
    expect(tdxOnPath(line, cx, cy, tdxEventPathM), closeTo(331.62, 0.01));
  });

  test('live speeds drop stale readings', () {
    final sp = tdxLiveSpeeds({
      'LiveTraffics': [
        {'SectionID': 'A', 'TravelSpeed': 90, 'DataCollectTime': '2026-11-09T09:59:00+08:00'},
        {'SectionID': 'B', 'TravelSpeed': 35, 'DataCollectTime': '2026-11-09T09:58:00+08:00'},
        {'SectionID': 'C', 'TravelSpeed': 80, 'DataCollectTime': '2026-11-09T09:00:00+08:00'}, // 過期
        {'SectionID': 'D', 'TravelSpeed': -99},
      ],
    }, now);
    expect(sp, {'A': 90, 'B': 35});
  });

  test('events: parse, direction, expiry', () {
    final ev = tdxLiveEvents({
      'LiveEvents': [
        _event('e1', 25.02),
        {..._event('old', 25.02), 'ExpireTime': '2026-11-09T09:30:00+08:00'},
      ],
    }, now);
    expect(ev.length, 1);
    expect(ev.single.kind, '施工');
    expect(ev.single.dir, 0.0);
    expect(ev.single.roads, ['國道1號']);
    expect(ev.single.text, '請減速');
  });

  test('report: slowest section ahead, events on our path only, current/ahead rotation', () {
    final events = tdxLiveEvents({
      'LiveEvents': [
        _event('ahead', 25.02),
        _event('opposite', 25.02, dir: '南向'),
        _event('here', 25.005, type: 1, title: '小客車事故'),
      ],
    }, now);
    final hit = sections.locate(x, y, 0)!;
    Map<String, dynamic> rep(bool currentFirst) => tdxReport(
      auth: 'Freeway', sections: sections, sid: hit.$1, along: hit.$2, x: x, y: y, hd: 0, road: '',
      speeds: {'A': 90, 'B': 35}, events: events, showCurrentFirst: currentFirst);

    final r = rep(true);
    expect(r['auth'], 'Freeway');
    expect(r['road'], '甲交流道-乙交流道');
    expect(r['speed'], 90);
    expect(r['nextSpeed'], 35);
    expect(r['congestion'], 'congested'); // 國道 < 40
    expect(r['events'], [{'description': '事故 350公尺 小客車事故', 'isCurrentSection': true}]);
    expect(rep(false)['events'], [{'description': '施工 2.0公里 內側車道封閉', 'isCurrentSection': false}]);
  });

  test('report off the sections: event straight ahead on our road', () {
    final (ox, oy) = tdxXY(25.0, 121.6);
    final events = tdxLiveEvents({
      'LiveEvents': [
        {
          'EventID': 'c1', 'EventType': 5, 'EventTitle': '道路管制', 'Positions': 'POINT(121.6 25.0045)',
          'Location': {'CityRoad': {'Roadways': [{'Road': '中山北路'}]}},
        },
      ],
    }, now);
    Map<String, dynamic> rep(String road) => tdxReport(
      auth: null, sections: null, sid: null, along: 0, x: ox, y: oy, hd: 0, road: road,
      speeds: null, events: events, showCurrentFirst: false);
    final r = rep('中山北路二段');
    expect(r['nextSpeed'], -1);
    expect(r['congestion'], 'unknown');
    expect(r['events'], [{'description': '管制 500公尺 道路管制', 'isCurrentSection': false}]);
    expect(rep('民生東路')['events'], isEmpty);
  });

  test('congestion thresholds per road kind', () {
    expect(tdxCongestionOf('Freeway', 85), 'smooth');
    expect(tdxCongestionOf('Freeway', 60), 'slow');
    expect(tdxCongestionOf('Highway', 45), 'slow');
    expect(tdxCongestionOf('City', 32), 'smooth');
    expect(tdxCongestionOf('City', 10), 'congested');
    expect(tdxCongestionOf('Freeway', -1), 'unknown');
  });
}
