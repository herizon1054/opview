import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opview/services/parking/parking_api.dart';
import 'package:opview/services/parking/parking_model.dart';
import 'package:opview/services/parking/parking_local.dart';
import 'package:opview/services/parking/parking_quota.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> fails(Future<dynamic> action, String contains) async {
  try {
    await action;
  } catch (e) {
    check(e.toString().contains(contains), 'Wrong error: $e');
    return;
  }
  throw StateError('Expected error containing $contains');
}

class Fixture {
  final values = <String, String>{};
  final requests = <http.Request>[];
  DateTime now = DateTime.utc(2026, 10, 31, 4);
  Future<http.Response> Function(http.Request)? handler;
  bool failCacheWrite = false;
  late ParkingRequestGate gate = newGate();
  late ParkingApi api = newApi();
  void advance([int seconds = 41]) {
    now = now.add(Duration(seconds: seconds));
  }

  ParkingRequestGate newGate() => ParkingRequestGate(
    read: () async => values['gate'],
    write: (s) async {
      values['gate'] = s;
    },
    clock: () => now,
  );
  http.Response response(Object data, [int status = 200]) => http.Response(
    jsonEncode(data),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
  Map<String, dynamic> staticRow(String id, bool on, {double lat = 25}) => {
    on ? 'ParkingSegmentID' : 'CarParkID': id,
    'City': 'Taipei',
    on ? 'ParkingSegmentName' : 'CarParkName': {'Zh_tw': on ? '路邊測試' : '路外測試'},
    on ? 'ParkingSegmentPosition' : 'CarParkPosition': {
      'PositionLat': lat,
      'PositionLon': 121,
    },
    'Address': '地址',
    'Description': '路段',
  };
  Map<String, dynamic> liveRow(String id, bool on) => {
    on ? 'ParkingSegmentID' : 'CarParkID': id,
    'Availabilities': [
      {'SpaceType': 1, 'AvailableSpaces': on ? 7 : 3, 'NumberOfSpaces': 10},
    ],
    'AvailableSpaces': 99,
    'ServiceStatus': 1,
    'DataCollectTime': now.toIso8601String(),
  };
  Future<http.Response> normal(http.Request r) async {
    if (r.url.host == 'data.ntpc.gov.tw') {
      final live = r.url.path.contains('e09b35a5');
      return http.Response(
        live
            ? 'ID,AVAILABLECAR\r\n010001,8\r\n'
            : 'ID,NAME,ADDRESS,TW97X,TW97Y,TOTALCAR\r\n010001,測試地方停車場,測試地址,250000,2765777,20\r\n',
        200,
        headers: {'content-type': 'text/csv; charset=utf-8'},
      );
    }
    if (r.url.host == 'hispark.hccg.gov.tw') {
      return response([
        {
          'PARKNO': '004',
          'PARKINGNAME': '新竹測試場',
          'ADDRESS': '測試路',
          'LONGITUDE': '121',
          'LATITUDE': '25',
          'TOTALQUANTITY': 100,
          'FREEQUANTITY': 12,
          'UPDATETIME': now.toIso8601String(),
        },
      ]);
    }
    if (r.method == 'POST')
      return response({'access_token': 'token', 'expires_in': 3600});
    final on = r.url.path.contains('/OnStreet/');
    final live = r.url.path.contains('Availability/');
    return response({
      'Items': [
        live
            ? liveRow('same', on)
            : staticRow('same', on, lat: on ? 25.001 : 25),
      ],
      'Count': 1,
    });
  }

  ParkingApi newApi() => ParkingApi(
    gate: gate,
    readCache: (k) async => values[k],
    writeCache: (k, v) async {
      if (failCacheWrite) throw StateError('cache write failed');
      values[k] = v;
    },
    readSecret: (k) async => values[k],
    writeSecret: (k, v) async {
      values[k] = v;
    },
    clock: () => now,
    sleep: (d) async {
      now = now.add(d);
    },
    clientFactory: () => MockClient((r) async {
      requests.add(r);
      return (handler ?? normal)(r);
    }),
  );
  Future<ParkingStaticCache> download({
    String id = 'id',
    String secret = 'secret',
    String city = 'Taipei',
  }) => api.downloadStatic(city: city, id: id, secret: secret);
  Future<ParkingResult> query({
    String id = 'id',
    String secret = 'secret',
    String city = 'Taipei',
    int radius = 1000,
  }) => api.nearby(
    city: city,
    id: id,
    secret: secret,
    lat: 25,
    lon: 121,
    radius: radius,
  );
}

final parkingCoreCases = <String, Future<void> Function()>{
  'missing credentials block static and live without HTTP': () async {
    final f = Fixture();
    await fails(f.download(id: '', secret: ''), '必須');
    await fails(f.query(id: '', secret: ''), '必須');
    check(f.requests.isEmpty, 'no anonymous or token request');
    check(
      !f.values.containsKey('parking_static_success_at_v6'),
      'no daily slot consumed',
    );
  },
  'member uses basic endpoints with bearer and gzip': () async {
    final f = Fixture();
    await f.download();
    f.advance();
    final result = await f.query();
    final data = f.requests.where((r) => r.method == 'GET').toList();
    check(data.length == 4, 'two static + two live');
    check(
      data.every((r) => r.headers['Authorization'] == 'Bearer token'),
      'bearer required',
    );
    check(
      data.every((r) => r.url.path.startsWith('/api/basic/')),
      'no advanced endpoint',
    );
    check(
      data.every((r) => r.headers['Accept-Encoding'] == 'gzip'),
      'gzip requested',
    );
    check(result.lots.length == 2, 'two types');
  },
  'matching uses category and city; distances sorted': () async {
    final f = Fixture();
    await f.download();
    f.advance();
    final r = await f.query();
    check(
      r.lots[0].availability?.cars == 3 && r.lots[1].availability?.cars == 7,
      'same id must not collide',
    );
    check(!r.lots[0].onStreet && r.lots[1].onStreet, 'near before far');
    check(r.lots[0].key != r.lots[1].key, 'namespaced keys');
  },
  'static update ignores manual click cooldown without extending it': () async {
    final f = Fixture();
    await f.gate.beginClick();
    f.advance(25);
    check(await f.gate.remaining() == 5, 'reproduce screenshot');
    final cache = await f.download(city: 'Kaohsiung');
    check(cache.lots.isNotEmpty, 'static update must complete');
    check(await f.gate.remaining() == 5, 'static must not reset cooldown');
  },
  'static update does not block first vacancy query': () async {
    final f = Fixture();
    await f.download();
    check(await f.gate.remaining() == 0, 'no manual cooldown from startup');
    final result = await f.query();
    check(result.lots.isNotEmpty, 'query immediately after static update');
    check(await f.gate.remaining() == 30, 'live query still has cooldown');
  },
  'diagnostics sample all supported endpoints without modifying caches':
      () async {
        final f = Fixture();
        final r = await f.api.testCities(id: 'id', secret: 'secret');
        check(!r.values.contains('尚未測試'), 'all supported probes completed');
        check(r.values.any((s) => s == '未列入支援'), 'unsupported distinct');
        check(
          r.values.every((s) => !s.startsWith('失敗')),
          'mock endpoints pass',
        );
        check(
          !f.values.keys.any((k) => k.startsWith('parking_static')),
          'no cache/success writes',
        );
        check(await f.gate.remaining() == 0, 'no manual click cooldown');
        for (final req in f.requests.where(
          (r) => r.method == 'GET' && r.url.host == 'tdx.transportdata.tw',
        )) {
          check(req.url.queryParameters[r'$top'] == '1', 'sample only');
        }
      },
  'diagnostics default completes beyond ten minutes': () async {
    final f = Fixture();
    final started = f.now;
    final r = await f.api.testCities(id: 'id', secret: 'secret');
    check(
      f.now.difference(started) > const Duration(minutes: 10),
      'cross old deadline',
    );
    check(
      !r.values.contains('尚未測試') && !r.values.contains('測試中'),
      'all jobs completed',
    );
    check(
      f.requests.where((r) => r.method == 'GET').length == 57,
      'all 57 endpoints',
    );
    check(!f.api.busy, 'operation released');
  },
  'diagnostics stop on forbidden rather than hit every city': () async {
    final f = Fixture();
    f.handler = (r) async =>
        r.method == 'POST' ? f.normal(r) : f.response({}, 403);
    final r = await f.api.testCities(id: 'id', secret: 'secret');
    check(f.requests.length == 2, 'auth plus first forbidden request only');
    check(r.values.any((s) => s.contains('IP鎖定')), 'show refusal');
    check(r.values.contains('尚未測試'), 'others untested');
  },
  '10km includes a distant lot excluded by 1200m': () async {
    final f = Fixture();
    f.handler = (r) async {
      if (r.method == 'GET' && r.url.path.contains('/CarPark/')) {
        return f.response({
          'Items': [f.staticRow('same', false, lat: 25.045)],
          'Count': 1,
        });
      }
      return f.normal(r);
    };
    await f.download();
    final near = await f.query(radius: 1200);
    check(near.lots.every((e) => e.onStreet), 'distant offstreet excluded');
    f.advance(61);
    final far = await f.query(radius: 10000);
    check(far.lots.any((e) => !e.onStreet), '5km offstreet included');
  },
  'diagnostics cancellation does not continue later endpoints': () async {
    final f = Fixture();
    f.handler = (r) async {
      final response = await f.normal(r);
      if (r.method == 'GET') f.api.cancel();
      return response;
    };
    final rows = await f.api.testCities(id: 'id', secret: 'secret');
    check(f.requests.length == 2, 'no subsequent request');
    check(rows.values.any((v) => v.contains('已停止')), 'cancelled active row');
    check(rows.values.contains('尚未測試'), 'others untested');
    check(!f.api.busy, 'released');
  },
  '30 seconds blocks double clicks without HTTP': () async {
    final f = Fixture();
    await f.download();
    f.advance();
    await f.query();
    final n = f.requests.length;
    await fails(f.query(), '等待');
    check(f.requests.length == n, 'no extra requests');
    check(await f.gate.remaining() == 30, 'countdown');
    f.advance(29);
    check(await f.gate.remaining() == 1, 'countdown after29');
    f.advance(1);
    check(await f.gate.remaining() == 0, 'cooldown complete');
  },
  'token reused in memory and after API recreation': () async {
    final f = Fixture();
    await f.download(id: 'id', secret: 'secret');
    f.advance();
    await f.query(id: 'id', secret: 'secret');
    f.advance(61);
    f.api = f.newApi();
    await f.query(id: 'id', secret: 'secret');
    check(
      f.requests.where((r) => r.method == 'POST').length == 1,
      'one token across operations',
    );
    check(
      f.requests
          .where((r) => r.method == 'GET')
          .every((r) => r.headers['Authorization'] == 'Bearer token'),
      'bearer',
    );
  },
  'expiry and credential changes each require one fresh token': () async {
    final f = Fixture();
    await f.download(id: 'id', secret: 'secret');
    f.advance(3601);
    await f.query(id: 'id', secret: 'secret');
    f.advance(61);
    await f.query(id: 'other', secret: 'different');
    check(
      f.requests.where((r) => r.method == 'POST').length == 3,
      'expiry and changed credentials',
    );
  },
  'partial key rejected; no calls': () async {
    final f = Fixture();
    await fails(f.download(id: 'id', secret: ''), '必須');
    check(f.requests.isEmpty, 'no request');
  },
  'no static cache means no live lookup or silent static download': () async {
    final f = Fixture();
    await fails(f.query(), '尚無');
    check(f.requests.isEmpty, 'no HTTP');
  },
  'static pagination follows Count; invalid coordinates excluded': () async {
    final f = Fixture();
    f.handler = (r) async {
      if (r.method == 'POST') return f.normal(r);
      final on = r.url.path.contains('/OnStreet/');
      if (on) return f.response({'Items': [], 'Count': 0});
      final skip = r.url.queryParameters[r'$skip'];
      return f.response({
        'Count': 3,
        'Items': skip == '0'
            ? [f.staticRow('a', false), f.staticRow('bad', false, lat: 100)]
            : [f.staticRow('b', false)],
      });
    };
    final cache = await f.download();
    check(
      f.requests.length == 4 && cache.lots.length == 2,
      'paged count and coordinates',
    );
    check(
      f.requests[2].url.queryParameters[r'$skip'] == '2',
      'actual page length',
    );
  },
  'failed static refresh retains last complete cache': () async {
    final f = Fixture();
    await f.download();
    final raw = f.values['parking_static_v3_Taipei'];
    f.advance(7 * 86400);
    f.handler = (r) => r.url.path.contains('/OnStreet/')
        ? Future.value(f.response({}, 500))
        : f.normal(r);
    await fails(f.download(), '500');
    check(raw == f.values['parking_static_v3_Taipei'], 'atomic cache');
  },
  '5/minute rolling gate persists and is shared with static requests':
      () async {
        final f = Fixture();
        for (var i = 0; i < 5; i++)
          check(await f.gate.reserveData() == 0, 'slot $i');
        check(await f.newGate().reserveData() > 0, 'restart gate');
        f.advance(61);
        check(await f.newGate().reserveData() == 0, 'window reset');
      },
  'there is no daily40 or monthly2.5 cap': () async {
    final f = Fixture();
    for (var i = 0; i < 120; i++) {
      check(await f.gate.reserveData() == 0, 'unwanted cap');
      f.advance(61);
    }
  },
  '429 obeys Retry-After without auto retry': () async {
    final f = Fixture();
    await f.download();
    f.advance(61);
    f.handler = (r) async =>
        http.Response('{}', 429, headers: {'retry-after': '90'});
    final r = await f.query();
    check(r.warning?.contains('受限') == true, 'warn');
    check(await f.gate.remaining() == 90, 'Retry-After');
    check(f.requests.length <= 5, 'at most two live attempts, no retry');
  },
  'one endpoint failure keeps the other result': () async {
    final f = Fixture();
    await f.download();
    f.advance(61);
    f.handler = (r) => r.url.path.contains('/OnStreet/')
        ? Future.value(f.response({}, 503))
        : f.normal(r);
    final r = await f.query();
    check(
      r.lots.first.availability?.cars == 3 && r.lots.last.availability == null,
      'partial response',
    );
    check(r.warning != null, 'partial warning');
  },
  'two live requests start concurrently': () async {
    final f = Fixture();
    await f.download();
    f.advance(61);
    final both = Completer<void>();
    var started = 0;
    f.handler = (r) async {
      started++;
      if (started == 2) both.complete();
      await both.future;
      return f.normal(r);
    };
    await f.query().timeout(const Duration(seconds: 2));
    check(started == 2, 'concurrent GET');
  },
  'cancel aborts results and no automatic rerun': () async {
    final f = Fixture();
    await f.download();
    f.advance(61);
    final finish = Completer<void>(), started = Completer<void>();
    f.handler = (r) async {
      if (!started.isCompleted) started.complete();
      await finish.future;
      return f.normal(r);
    };
    final result = f.query();
    await started.future;
    f.api.cancel();
    finish.complete();
    await fails(result, '取消');
    check(f.requests.length <= 5, 'no retry');
  },
  'New Taipei local offstreet complements TDX roadside': () async {
    final f = Fixture();
    await f.download(city: 'NewTaipei');
    f.advance();
    final r = await f.query(city: 'NewTaipei');
    check(f.requests.length == 5, 'token + two static + two live');
    check(
      r.lots.any((e) => e.onStreet) && r.lots.any((e) => e.isLocal),
      'both types',
    );
    check(
      r.lots.firstWhere((e) => e.isLocal).availability?.cars == 8,
      'local vacancy',
    );
  },
  'stale or unknown source does not become a fresh vacancy': () async {
    final now = DateTime.utc(2026, 10, 31);
    final a = ParkingAvailability.parse({
      'AvailableSpaces': 9,
      'DataCollectTime': now
          .subtract(const Duration(minutes: 6))
          .toIso8601String(),
    });
    check(a.label(now) == '資料過期', 'stale');
    check(
      ParkingAvailability.parse({'AvailableSpaces': 9}).label(now) == '時間不明',
      'missing time',
    );
  },
  'token without expires_in is rejected, never assumes24hours': () async {
    final f = Fixture();
    f.handler = (r) async => f.response({'access_token': 'x'});
    await fails(f.download(id: 'id', secret: 'secret'), '有效期限');
    check(f.requests.length == 1, 'no data GET');
  },
  'daily update survives restart and changing city or credentials': () async {
    final f = Fixture();
    await f.download();
    f.advance(61);
    f.api = f.newApi();
    final n = f.requests.length;
    await fails(f.download(), '未滿 7 天');
    await fails(
      f.download(city: 'Taoyuan', id: 'other', secret: 'new'),
      '未滿 7 天',
    );
    check(f.requests.length == n, 'no second batch or token');
  },
  'static update waits seven full days across restart': () async {
    final f = Fixture();
    await f.download();
    f.advance(7 * 86400 - 1);
    f.api = f.newApi();
    check(!await f.api.staticUpdateDue('Taipei'), 'not yet seven days');
    await fails(f.download(), '未滿 7 天');
    f.advance(1);
    check(await f.api.staticUpdateDue('Taipei'), 'exact seven-day boundary');
    await f.download();
    check(!await f.api.staticUpdateDue('Taipei'), 'new interval begins');
  },
  'failed static attempt can retry the same day after restart': () async {
    final f = Fixture();
    f.handler = (r) async => f.response({}, 500);
    await fails(f.download(), '500');
    f.advance(61);
    f.api = f.newApi();
    check(await f.api.staticUpdateDue('Taipei'), 'failure is not success');
    check(await f.api.cached('Taipei') == null, 'no incomplete cache');
    f.handler = null;
    await f.download();
    check(!await f.api.staticUpdateDue('Taipei'), 'retry success counted');
  },
  'cancelled static attempt can retry the same day': () async {
    final f = Fixture();
    final started = Completer<void>(), finish = Completer<void>();
    f.handler = (r) async {
      started.complete();
      await finish.future;
      return f.normal(r);
    };
    final result = f.download();
    await started.future;
    f.api.cancel();
    finish.complete();
    await fails(result, '取消');
    f.advance(61);
    check(await f.api.staticUpdateDue('Taipei'), 'cancel does not count');
    f.handler = null;
    await f.download();
    check(!await f.api.staticUpdateDue('Taipei'), 'retry success counted');
  },
  'clock rollback and corrupt daily record do not trigger downloads': () async {
    final f = Fixture();
    f.values['parking_static_success_at_v6'] = '2026-11-01T00:00:00Z';
    await fails(f.download(), '未滿 7 天');
    f.values['parking_static_success_at_v6'] = 'broken';
    await fails(f.download(), '紀錄異常');
    check(f.requests.isEmpty, 'fail closed');
  },
  'same-day cache from previous version avoids download': () async {
    final f = Fixture();
    await f.download();
    f.values.remove('parking_static_success_at_v6');
    f.advance(61);
    await fails(f.download(), '未滿 7 天');
    check(f.requests.length == 3, 'reuse existing cache');
  },
  'cache write failure does not count as a successful daily update': () async {
    final f = Fixture();
    await f.download();
    final old = f.values['parking_static_v3_Taipei'];
    f.advance(7 * 86400);
    f.failCacheWrite = true;
    await fails(f.download(), 'cache write failed');
    check(f.values['parking_static_v3_Taipei'] == old, 'old cache retained');
    check(await f.api.staticUpdateDue('Taipei'), 'write failure is retryable');
    f.advance(61);
    f.failCacheWrite = false;
    await f.download();
    check(!await f.api.staticUpdateDue('Taipei'), 'successful commit counts');
  },
  'old failed-attempt ledger does not prevent retry after upgrade': () async {
    final f = Fixture();
    f.values['parking_static_attempt_day_v4'] = '2026-10-31';
    await f.download();
    check(!await f.api.staticUpdateDue('Taipei'), 'new success recorded');
  },
  '1000 and 1200 meter searches filter different candidates': () async {
    final f = Fixture();
    f.handler = (r) async {
      if (r.method == 'POST' || r.url.path.contains('Availability/'))
        return f.normal(r);
      final on = r.url.path.contains('/OnStreet/');
      return f.response({
        'Items': [f.staticRow('same', on, lat: on ? 25.010 : 25)],
        'Count': 1,
      });
    };
    await f.download();
    f.advance(61);
    check(
      (await f.query(radius: 1000)).lots.length == 1,
      '1000m excludes distant segment',
    );
    f.advance(61);
    check(
      (await f.query(radius: 1200)).lots.length == 2,
      '1200m includes segment',
    );
  },
  'R5 successful date migrates without immediate redownload': () async {
    final f = Fixture();
    f.values['parking_static_success_day_v5'] = '2026-10-31';
    check(!await f.api.staticUpdateDue('Taipei'), 'old success respected');
    f.advance(8 * 86400);
    check(await f.api.staticUpdateDue('Taipei'), 'old date eventually expires');
  },
  '403 shows IP or permission failure and does not count as success': () async {
    final f = Fixture();
    f.handler = (r) async => f.response({}, 403);
    await fails(f.download(), '查詢失敗／IP鎖定');
    check(await f.api.staticUpdateDue('Taipei'), '403 remains retryable');
    f.advance(61);
    f.handler = null;
    await f.download();
    f.advance(61);
    f.handler = (r) async => f.response({}, 403);
    final result = await f.query();
    check(result.warning?.contains('查詢失敗／IP鎖定') == true, 'live warning');
    check(
      result.lots.every((lot) => lot.availability == null),
      'no false vacancies',
    );
  },
  '401 is authentication failure rather than IP lock': () async {
    final f = Fixture();
    f.handler = (r) async => f.response({}, 401);
    await fails(f.download(), '認證失敗');
    check(f.requests.length == 1, 'no automatic retry');
  },
  'local requests never receive TDX credentials': () async {
    final f = Fixture();
    await f.download(city: 'NewTaipei');
    f.advance(61);
    await f.query(city: 'NewTaipei');
    final requests = f.requests.where(
      (r) => r.url.host != 'tdx.transportdata.tw',
    );
    check(requests.length == 2, 'one static and one live local request');
    check(
      requests.every(
        (r) => !r.headers.containsKey('Authorization') && r.body.isEmpty,
      ),
      'no secret leak',
    );
  },
  'local 200 HTML rejection retains TDX roadside result': () async {
    final f = Fixture();
    await f.download(city: 'NewTaipei');
    f.advance(61);
    f.handler = (r) async => r.url.host == 'data.ntpc.gov.tw'
        ? http.Response('<html>Request Rejected</html>', 200)
        : f.normal(r);
    final result = await f.query(city: 'NewTaipei');
    check(result.warning?.contains('IP鎖定') == true, 'WAF rejection displayed');
    check(
      result.lots.firstWhere((e) => e.onStreet).availability?.cars == 7,
      'TDX retained',
    );
    check(
      result.lots.firstWhere((e) => e.isLocal).availability == null,
      'failed local not zero',
    );
  },
  'TDX authentication failure does not suppress local vacancies': () async {
    final f = Fixture();
    await f.download(city: 'NewTaipei');
    f.advance(3601);
    f.handler = (r) async =>
        r.method == 'POST' ? f.response({}, 401) : f.normal(r);
    final result = await f.query(city: 'NewTaipei');
    check(result.warning?.contains('認證失敗') == true, 'auth warning');
    check(
      result.lots.firstWhere((e) => e.isLocal).availability?.cars == 8,
      'independent local success',
    );
  },
  'Hsinchu live lookup does not refresh an unnecessary TDX token': () async {
    final f = Fixture();
    await f.download(city: 'Hsinchu');
    f.advance(3601);
    final before = f.requests.where((r) => r.method == 'POST').length;
    final result = await f.query(city: 'Hsinchu');
    check(
      f.requests.where((r) => r.method == 'POST').length == before,
      'no token for local-only live',
    );
    check(
      result.lots.firstWhere((e) => e.isLocal).availability?.cars == 12,
      'Hsinchu count',
    );
  },
  'NTPC negative counts stay unknown and missing times are explicit': () async {
    final now = DateTime.utc(2026, 10, 31);
    final values = localParkingAvailability(
      'NewTaipei',
      'ID,AVAILABLECAR\n001,-9\n002,0\n003,15\n',
      now,
    );
    check(values['local:ntpc:001']!.label(now) == '無空位資料', 'negative sentinel');
    check(values['local:ntpc:002']!.label(now) == '回報 0 位*', 'known zero');
    check(
      values['local:ntpc:003']!.sourceTime == null &&
          !values['local:ntpc:003']!.fresh(now),
      'do not forge timestamp',
    );
    check(
      values['local:ntpc:003']!.label(now.add(const Duration(minutes: 6))) ==
          '資料過期',
      'retrieval expiry',
    );
  },
  'Hsinchu timezone and stale timestamps are respected': () async {
    final row = {
      'PARKNO': '004',
      'FREEQUANTITY': 12,
      'TOTALQUANTITY': 20,
      'UPDATETIME': '2026-10-31T12:00:00',
    };
    final a = localParkingAvailability(
      'Hsinchu',
      jsonEncode([row]),
      DateTime.utc(2026, 10, 31, 4),
    )['local:hccg:004']!;
    check(
      a.sourceTime == DateTime.utc(2026, 10, 31, 4),
      'Taiwan +08 timestamp',
    );
    check(a.label(DateTime.utc(2026, 10, 31, 4, 6)) == '資料過期', 'source stale');
  },
  'local CSV handles commas and newlines without destroying IDs': () async {
    final lots = localParkingLots(
      'NewTaipei',
      '\uFEFFID,NAME,ADDRESS,TW97X,TW97Y,TOTALCAR\r\n010001,"場,一","路\r\n段",250000,2765777,20\r\n',
    );
    check(
      lots.single.id == 'local:ntpc:010001' && lots.single.name == '場,一',
      'leading zero and quotes',
    );
    check(lots.single.address == '路\n段', 'embedded newline');
    check(
      ParkingLot.fromJson(lots.single.toJson()).sourceLabel == '新北市政府',
      'source persists',
    );
  },
  'local duplicate merging requires matching name and nearby position':
      () async {
        final a = ParkingLot('tdx1', 'Hsinchu', '測試停車場', '', 25, 121);
        final b = ParkingLot('tdx2', 'Hsinchu', '另一個停車場', '', 25, 121);
        final c = ParkingLot(
          'local:hccg:1',
          'Hsinchu',
          '測試停車場',
          '',
          25.0001,
          121,
        );
        final result = mergeLocalParking([a, b], [c]);
        check(
          result.length == 2 && !result.contains(a) && result.contains(b),
          'conservative dedupe',
        );
      },
  'local static download failure preserves complete old cache': () async {
    final f = Fixture();
    await f.download(city: 'NewTaipei');
    final old = f.values['parking_static_v3_NewTaipei'];
    f.advance(7 * 86400);
    f.handler = (r) async =>
        r.url.host == 'data.ntpc.gov.tw' ? f.response({}, 503) : f.normal(r);
    await fails(f.download(city: 'NewTaipei'), '503');
    check(
      f.values['parking_static_v3_NewTaipei'] == old,
      'atomic complete cache',
    );
    check(
      await f.api.staticUpdateDue('NewTaipei'),
      'failure remains retryable',
    );
  },
  'TWD97 coordinates match independent PROJ reference': () async {
    final p = twd97ToWgs84(296882, 2767068)!;
    check(
      (p.$1 - 25.010925151488685).abs() < 0.000001 &&
          (p.$2 - 121.46449194269124).abs() < 0.000001,
      'EPSG3826 conversion',
    );
    check(twd97ToWgs84(315148.7, 25.22236) == null, 'mixed units rejected');
    check(twd97ToWgs84(0, 0) == null, 'missing coordinates rejected');
  },
  'identical local IDs collapse and conflicting IDs are excluded': () async {
    const header = 'ID,NAME,ADDRESS,TW97X,TW97Y,TOTALCAR\n';
    final lots = localParkingLots(
      'NewTaipei',
      header +
          '001,場一,路一,250000,2765777,10\n001,場一,不同地址文字,250000,2765777,10\n' +
          '002,場二,路二,250000,2765777,10\n002,別場,路三,250000,2765777,10\n',
    );
    check(
      lots.length == 1 && lots.single.id == 'local:ntpc:001',
      'no ambiguous ID joins',
    );
    final counts = localParkingAvailability(
      'NewTaipei',
      'ID,AVAILABLECAR\n001,3\n001,3\n002,8\n002,9\n',
      DateTime.now(),
    );
    check(
      counts.length == 1 && counts['local:ntpc:001']!.cars == 3,
      'conflicting counts omitted',
    );
  },
  'TDX-only old city cache is upgraded once then kept seven days': () async {
    final f = Fixture();
    await f.download(city: 'NewTaipei');
    final j = jsonDecode(f.values['parking_static_v3_NewTaipei']!) as Map;
    j.remove('localSchema');
    f.values['parking_static_v3_NewTaipei'] = jsonEncode(j);
    check(
      await f.api.staticUpdateDue('NewTaipei'),
      'needs local schema migration',
    );
    f.advance(61);
    await f.download(city: 'NewTaipei');
    check(!await f.api.staticUpdateDue('NewTaipei'), 'new cache is reusable');
    f.advance(7 * 86400);
    check(await f.api.staticUpdateDue('NewTaipei'), 'seven days expires');
  },
  'cancelled local download cannot overwrite old cache or count success':
      () async {
        final f = Fixture();
        final started = Completer<void>(), finish = Completer<void>();
        f.handler = (r) async {
          if (r.url.host == 'data.ntpc.gov.tw') {
            started.complete();
            await finish.future;
          }
          return f.normal(r);
        };
        final result = f.download(city: 'NewTaipei');
        await started.future;
        f.api.cancel();
        finish.complete();
        await fails(result, '取消');
        check(
          f.values['parking_static_v3_NewTaipei'] == null,
          'no partial cache',
        );
        check(f.values['parking_static_success_at_v6'] == null, 'not success');
      },
};
