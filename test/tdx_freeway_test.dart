// TDX 國道擴充（2026-11-12）：回堵長度、車速驟降、前方偵測器各車道車速
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/services/tdx/tdx_traffic_core.dart';
import 'package:opview/services/viewer_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'golden/mock_ui_state.dart';

// 一條往北的國道：A（1 km）→ B（2 km）→ C（2 km）→ D（2 km）
Map<String, dynamic> _shapes() => {'SectionShapes': [
  {'SectionID': 'A', 'Geometry': 'LINESTRING(121.5 25.0, 121.5 25.009)'},
  {'SectionID': 'B', 'Geometry': 'LINESTRING(121.5 25.009, 121.5 25.027)'},
  {'SectionID': 'C', 'Geometry': 'LINESTRING(121.5 25.027, 121.5 25.045)'},
  {'SectionID': 'D', 'Geometry': 'LINESTRING(121.5 25.045, 121.5 25.063)'},
]};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final now = DateTime.parse('2026-11-12T10:00:00+08:00').millisecondsSinceEpoch / 1000.0;
  final secs = TdxSections(tdxShrinkShapes(_shapes()), null);
  final (x, y) = tdxXY(25.0, 121.5);
  final hit = secs.locate(x, y, 0)!;

  group('queue', () {
    final path = secs.path(hit.$1, hit.$2).$1;
    test('contiguous slow sections ahead, start within 3 km', () {
      final q = tdxQueueAhead(path, {'A': 90, 'B': 30, 'C': 20, 'D': 70})!;
      expect(q.d, closeTo(path[1].d0, .01)); // 約 1 km
      expect(q.len, closeTo(path[3].d0 - path[1].d0, .01)); // B + C 約 4 km
      expect(q.min, 20);
      expect(q.avg, 25);
      expect(q.open, isFalse);
    });
    test('already in the queue, reaches the end of the path → open', () {
      final q = tdxQueueAhead(path, {'A': 25, 'B': 30, 'C': 20, 'D': 10})!;
      expect(q.d, 0);
      expect(q.open, isTrue);
    });
    test('no data breaks the queue; start beyond 3 km is ignored; 40 km/h is not a queue', () {
      expect(tdxQueueAhead(path, {'A': 90, 'B': 30, 'D': 10})!.open, isFalse);
      expect(tdxQueueAhead(path, {'A': 90, 'B': 90, 'C': 90, 'D': 10}), isNull); // D 約 5 km 外
      expect(tdxQueueAhead(path, {'A': 40, 'B': 40}), isNull);
    });
  });

  group('VD', () {
    final vds = TdxVdIndex(tdxShrinkVds({'VDs': [
      {'VDID': 'near', 'PositionLat': 25.001, 'PositionLon': 121.5, 'DetectionLinks': [{'Bearing': 'N'}]}, // 約 110 m
      {'VDID': 'n1', 'PositionLat': 25.016, 'PositionLon': 121.5, 'DetectionLinks': [{'Bearing': 'N'}]}, // 約 1.8 km
      {'VDID': 's1', 'PositionLat': 25.010, 'PositionLon': 121.5001, 'DetectionLinks': [{'Bearing': 'S'}]}, // 對向
      {'VDID': 'far', 'PositionLat': 25.040, 'PositionLon': 121.5, 'DetectionLinks': [{'Bearing': 'N'}]}, // 4.4 km
      {'VDID': 'off', 'PositionLat': 25.010, 'PositionLon': 121.51}, // 1 km 外的別條路
    ]}));
    final live = tdxLiveVds({'VDLives': [
      {'VDID': 'near', 'Status': 0, 'DataCollectTime': '2026-11-12T09:59:00+08:00',
        'LinkFlows': [{'Lanes': [{'LaneID': 0, 'LaneType': 1, 'Speed': 95}]}]},
      {'VDID': 'n1', 'Status': 0, 'DataCollectTime': '2026-11-12T09:59:00+08:00',
        'LinkFlows': [{'Lanes': [
          {'LaneID': 2, 'LaneType': 1, 'Speed': 38},
          {'LaneID': 0, 'LaneType': 1, 'Speed': 92.4},
          {'LaneID': 1, 'LaneType': 1, 'Speed': 85},
          {'LaneID': 3, 'LaneType': 1, 'Speed': 0}, // 沒資料
        ]}]},
      {'VDID': 'far', 'Status': 1, 'LinkFlows': [{'Lanes': [{'LaneID': 0, 'Speed': 50}]}]}, // 故障
      {'VDID': 'old', 'Status': 0, 'DataCollectTime': '2026-11-12T09:00:00+08:00',
        'LinkFlows': [{'Lanes': [{'LaneID': 0, 'Speed': 50}]}]},
    ]}, now);

    test('shrink + live parse', () {
      expect(vds.length, 5);
      expect(live.keys, unorderedEquals(['near', 'n1']));
      expect(live['n1']!.map((l) => l.speed), [92, 85, 38]); // 依 LaneID 排序、去掉 0
    });

    test('ahead: same direction, on our path, nearest first', () {
      final line = secs.path(hit.$1, hit.$2).$2;
      final a = vds.ahead(line, x, y, 0);
      expect(a.map((e) => e.$1), ['near', 'n1', 'far']);
    });

    test('report: first VD 150 m–3 km with live data; queue only on Freeway', () {
      Map<String, dynamic> rep(String auth) => tdxReport(
        auth: auth, sections: secs, sid: hit.$1, along: hit.$2, x: x, y: y, hd: 0, road: '',
        speeds: {'A': 90, 'B': 30}, events: const [], showCurrentFirst: true, vds: vds, vdLive: live);
      final r = rep('Freeway');
      expect(r['vdAhead'], ['near', 'n1', 'far']);
      expect(r['lanes']['vd'], 'n1'); // near 在 150 m 內
      expect(r['lanes']['speeds'], [92, 85, 38]);
      expect((r['lanes']['d'] as double), closeTo(1769, 5));
      expect(r['queue']['min'], 30);
      final h = rep('Highway');
      expect(h['queue'], isNull);
      expect(h['lanes'], isNull);
    });
  });

  // 國道跨缺口（2026-11-12）：TDX 國道線形有缺口 / 重疊，同一條路優先、可跨 3 公里內的缺口
  group('bridge', () {
    TdxSections mk(List<(String, double, double, String)> rows) => TdxSections(
      tdxShrinkShapes({'S': [for (final (k, a, b, _) in rows)
        {'SectionID': k, 'Geometry': 'LINESTRING(121.5 $a, 121.5 $b)'}]}),
      {for (final (k, _, _, r) in rows) k: {'name': k, 'road': r}});

    test('same road across a ~1 km gap beats another road 55 m away; gap counted in distance', () {
      final g = mk([('A', 25.0, 25.009, 'R'), ('B', 25.018, 25.027, 'R'), ('E', 25.0095, 25.02, 'X')]);
      final pb = g.path('A', 0, bridge: true).$1;
      expect(pb.map((e) => e.sid), ['A', 'B']);
      expect(pb[1].d0, closeTo((25.018 - 25.0) * 110540, 1));
      expect(g.path('A', 0).$1.map((e) => e.sid), ['A', 'E']); // 非國道（不跨缺口）照原規則
    });
    test('overlap: next section starts ~150 m behind our end', () {
      final g = mk([('A', 25.0, 25.009, 'R'), ('C', 25.0077, 25.02, 'R')]);
      expect(g.path('A', 0, bridge: true).$1.map((e) => e.sid), ['A', 'C']);
      expect(g.path('A', 0).$1.map((e) => e.sid), ['A']);
    });
    // 2026-11-13：線形畫過頭（國8 台南端到新吉 306 m、汐五高架 912 m）
    test('overshoot: next section starts ~885 m before our end on our own line', () {
      final g = mk([('A', 25.0, 25.009, 'R'), ('C', 25.001, 25.02, 'R')]);
      final p = g.path('A', 0, bridge: true).$1;
      expect(p.map((e) => e.sid), ['A', 'C']);
      expect(p[1].d0, closeTo(0.001 * 110540, 1)); // 重疊：d0 < 上一段 d1
      final q = tdxQueueAhead(p, {'A': 90, 'C': 30})!;
      expect(q.d, closeTo(0.001 * 110540, 1));
      expect(q.len, closeTo(p[1].d1 - p[1].d0, 1)); // 重疊部分不重複算
    });
    test('gap over 3 km is not bridged', () {
      final g = mk([('A', 25.0, 25.009, 'R'), ('F', 25.04, 25.05, 'R')]);
      expect(g.path('A', 0, bridge: true).$1.map((e) => e.sid), ['A']);
    });
  });

  group('UIState', () {
    Map<String, dynamic> data({double qd = 1500, int min = 25}) => {
      'nextSpeed': min, 'congestion': 'congested', 'events': [{'description': '施工 3.0公里 外側車道封閉',
        'isCurrentSection': false}],
      'queue': {'d': qd, 'len': 3500.0, 'avg': 28, 'min': min, 'open': false},
      'lanes': {'d': 1800.0, 'speeds': [92, 85, 38]},
    };

    test('queue / lanes text, drop banner priority and one beep per 3 minutes', () async {
      final s = createMockUIState(vEgo: 90 / 3.6);
      final beeps = <String>[];
      final sub = s.tdxDropEvents.listen(beeps.add);
      s.applyTdx(data());
      expect(s.tdxQueueText, '回堵 1.5公里起 3.5公里｜均速 28');
      expect(s.tdxLanes!.speeds, [92, 85, 38]);
      expect(s.eventBanner, (text: '車速驟降  前方 1.5公里 降到 25 km/h', collision: false, warn: true));
      s.applyTdx(data(qd: 1200));
      await Future<void>.delayed(Duration.zero);
      expect(beeps.length, 1); // 持續中不重複

      // 本車已慢下來（只快 30）→ 不算驟降，恢復顯示 TDX 事件
      s.vEgo = 55 / 3.6;
      s.applyTdx(data(qd: 900));
      expect(s.tdxDropText, '');
      expect(s.eventBanner.text, '前方: 施工 3.0公里 外側車道封閉');
      // 再次加速：3 分鐘內不再嗶
      s.vEgo = 90 / 3.6;
      s.applyTdx(data(qd: 800));
      await Future<void>.delayed(Duration.zero);
      expect(s.tdxDropText, isNotEmpty);
      expect(beeps.length, 1);

      // 回堵起點超過 2 公里不算驟降
      s.applyTdx(data(qd: 2500));
      expect(s.tdxDropText, '');
      // 已在回堵中
      s.applyTdx({...data(qd: 0), 'queue': {'d': 0.0, 'len': 6000.0, 'avg': 20, 'min': 15, 'open': true}});
      expect(s.tdxQueueText, '回堵中 還有 6.0公里以上｜均速 20');
      s.resetTdx();
      expect(s.tdxQueueText, '');
      expect(s.tdxLanes, isNull);
      await sub.cancel();
      s.dispose();
    });

    test('drop beep setting persists (default on)', () async {
      final v = ViewerSettings();
      await v.load();
      expect(v.tdxDropBeep, isTrue);
      v.setTdxDropBeep(false);
      final p = await SharedPreferences.getInstance();
      expect(p.getBool('viewer_tdx_drop_beep'), isFalse);
      v.dispose();
    });
  });

  for (final (name, size) in [('landscape', const Size(844, 385)), ('portrait', const Size(390, 844))]) {
    testWidgets('freeway info + drop banner ($name)', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(() { tester.view.resetPhysicalSize(); tester.view.resetDevicePixelRatio(); });
      final settings = ViewerSettings();
      final state = createMockUIState(vEgo: 95 / 3.6)
        ..modernOverlay = true
        ..applyTdx({
          'nextSpeed': 25, 'congestion': 'congested', 'events': const [],
          'queue': {'d': 1500.0, 'len': 3500.0, 'avg': 28, 'min': 25, 'open': false},
          'lanes': {'d': 1800.0, 'speeds': [92, 85, 38]},
        });
      await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(),
          home: AugmentedRoadView(uiState: state, settings: settings)));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('車速驟降'), findsWidgets);
      expect(find.textContaining('回堵 1.5公里起 3.5公里'), findsWidgets);
      expect(find.text('92'), findsWidgets);
      expect(find.text('38'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      settings.dispose();
      state.dispose();
    });
  }
}
