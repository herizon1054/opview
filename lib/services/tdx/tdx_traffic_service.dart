// TDX 前方路況：內建在 opview（手機自己定位、自己向 TDX 抓資料），不再讀 comma 的 tdx service。
//
// 只負責顯示：結果寫進 UIState.applyTdx()，畫面元件（前方車速、事件跑馬燈、直向 TDX 列）沿用原本的。
//
// 資料來源與額度
//   - 金鑰：與「附近停車場」共用停車設定裡的 TDX Client ID / Client Secret（ParkingConfig）。
//     沒填金鑰就不抓、不顯示。
//   - 頻率：與停車共用同一個本機節流 parkingGate（會員金鑰每分鐘 5 次）；停車查詢 / 下載進行中時路況暫停，
//     額度滿時這一輪直接略過，不排隊等待。
//   - 路上每 60 秒一輪、最多 2 次：所在道路的即時路段車速 + 即時事件（國道 / 省道 / 有即時資料的縣市；
//     不在任何路段上時只抓該縣市事件）。
//   - 路段線形與名稱（國道、省道，以及經過的縣市）存在 App 資料夾，7 天更新一次（手機網路流量考量，
//     comma 端是每天）；過期仍先用舊的，背景再更新。
//   - 有網路就抓，沒網路（或 TDX 連不到）就安靜略過，60 秒後再試。
//
// 定位：手機 GPS（geolocator 串流）。航向只在車速 > 3 m/s 時更新；縣市與道路名稱用手機反向地理編碼
// （每移動 150 m、最多每 15 秒一次）。
//
// 只在 opview 畫面且「TDX 路況顯示」開啟時執行（app.dart _syncTdx）。

import 'dart:async';
import 'dart:convert';
import 'dart:io' hide BytesBuilder;
import 'dart:math' as math;
import 'dart:typed_data' show BytesBuilder;

import 'package:flutter/foundation.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path_provider/path_provider.dart';

import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/services/parking/parking_catalog.dart' show parkingCities;
import 'package:opview/services/parking/parking_config.dart';
import 'package:opview/services/parking/parking_quota_store.dart' show parkingGate, parkingApi;
import 'package:opview/services/parking/parking_startup.dart';

import 'tdx_traffic_core.dart';

const _host = 'tdx.transportdata.tw';
const _ua = 'Mozilla/5.0 (Linux; Android) opview tdx_traffic'; // 沒有 UA 時 WAF 會回 HTML 拒絕頁
const _liveEvery = Duration(seconds: 60);
const _liveFresh = 180.0; // s：3 輪內的即時資料仍採用
const _staticMaxAge = Duration(days: 7);
const _gpsFresh = Duration(seconds: 5);
const _gpsMaxAccuracy = 30.0; // m
const _minHeadingSpeed = 3.0; // m/s；停著時 GPS 航向沒有意義
const _geoEveryM = 150.0;
const _geoMinGap = Duration(seconds: 15);
const _maxStaticBytes = 64 * 1024 * 1024;

class TdxTrafficService {
  static final instance = TdxTrafficService();

  /// 狀態文字（顯示設定的 TDX 開關副標題用）
  final status = ValueNotifier<String>('未啟用');

  UIState? _ui;
  bool _active = false;
  int _gen = 0;
  StreamSubscription<Position>? _gpsSub;
  Timer? _tick;
  bool _working = false;

  // 定位
  double? _lat, _lon, _hd;
  DateTime? _fixAt;
  (double, double)? _geoAt;
  DateTime? _geoTime;
  bool _geoBusy = false;
  String? _city;
  String _road = '';

  // 資料
  final _sections = <String, TdxSections>{}; // auth -> 路段
  final _staticAt = <String, DateTime>{}; // 快取名稱 -> 下載時間
  final _staticFailUntil = <String, DateTime>{};
  final _diskTried = <String>{}; // 已試過從磁碟載入的 auth（沒快取時不要每秒重讀）
  final _live = <String, (double, Map<String, int>)>{}; // auth -> (取得時間 epoch 秒, 車速)
  final _events = <String, (double, List<TdxEvent>)>{};
  DateTime _lastRound = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _failUntil = DateTime.fromMillisecondsSinceEpoch(0);
  bool? _online;
  bool _skipped = false; // 上一次 _callBytes 是因額度 / 停車查詢中而略過（不是失敗）
  String? _auth;

  // 連線
  http.Client? _client;
  String? _token, _tokenFor;
  DateTime _tokenUntil = DateTime.fromMillisecondsSinceEpoch(0);

  final _config = ParkingConfig.instance;

  void setActive(bool active, UIState ui) {
    _ui = ui;
    if (active == _active) return;
    _active = active;
    _gen++;
    if (active) {
      _start(_gen);
    } else {
      _stop();
    }
  }

  Future<void> _start(int gen) async {
    debugPrint('[tdx] 啟動（手機定位 + TDX，只供顯示）');
    try {
      await _config.load();
    } catch (_) {/* 讀不到停車設定 = 沒金鑰 */}
    if (gen != _gen) return;
    _failUntil = DateTime.fromMillisecondsSinceEpoch(0);
    _config.addListener(_configChanged);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    await _startGps(gen);
  }

  void _stop() {
    debugPrint('[tdx] 停止');
    _config.removeListener(_configChanged);
    _tick?.cancel();
    _tick = null;
    _gpsSub?.cancel();
    _gpsSub = null;
    _client?.close();
    _client = null;
    _fixAt = null;
    _ui?.resetTdx();
    status.value = '未啟用';
  }

  void _configChanged() {
    if (_tokenFor != _credKey) {
      _token = null;
      _failUntil = DateTime.fromMillisecondsSinceEpoch(0);
    }
  }

  String get _credKey => '${_config.clientId.trim()}\u0000${_config.clientSecret.trim()}';

  Future<void> _startGps(int gen) async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        status.value = '請開啟手機定位';
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (gen != _gen) return;
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        status.value = '未允許位置權限';
        return;
      }
      _gpsSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 0),
      ).listen(_onPosition, onError: (Object e) => debugPrint('[tdx] GPS 錯誤：$e'));
    } catch (e) {
      debugPrint('[tdx] GPS 無法啟動：$e');
      status.value = '無法使用手機定位';
    }
  }

  void _onPosition(Position p) {
    if (!p.latitude.isFinite || !p.longitude.isFinite || (p.latitude == 0 && p.longitude == 0)) return;
    if (!p.accuracy.isFinite || p.accuracy > _gpsMaxAccuracy) return;
    _lat = p.latitude;
    _lon = p.longitude;
    _fixAt = DateTime.now();
    if (p.speed.isFinite && p.speed > _minHeadingSpeed && p.heading.isFinite && p.heading >= 0) {
      _hd = p.heading % 360.0;
    }
  }

  bool get _fixFresh => _fixAt != null && DateTime.now().difference(_fixAt!) < _gpsFresh;

  // ------------------------------------------------------------------ 每秒
  void _onTick() {
    if (!_active) return;
    if (!_config.hasCredentials) {
      status.value = '請在停車設定填入 TDX 金鑰';
      return;
    }
    if (!_fixFresh) {
      if (_gpsSub != null) status.value = '等待手機定位';
      _maybeWork(); // 沒定位也先把國道 / 省道路段載入或更新
      return;
    }
    final (x, y) = tdxXY(_lat!, _lon!);
    _maybeGeocode(x, y);

    String? auth, sid;
    var along = 0.0;
    if (_hd != null) {
      for (final a in _auths()) {
        final s = _sections[a];
        final hit = s?.locate(x, y, _hd!);
        if (hit != null) {
          (auth, sid, along) = (a, hit.$1, hit.$2);
          break;
        }
      }
    }
    _auth = auth;

    final nowWall = DateTime.now().millisecondsSinceEpoch / 1000.0;
    final live = auth == null ? null : _live[auth];
    final seen = <String>{};
    final events = <TdxEvent>[
      for (final e in _events.values)
        if (nowWall - e.$1 < _liveFresh)
          for (final ev in e.$2)
            if (seen.add(ev.id)) ev,
    ];
    try {
      final rep = tdxReport(
        auth: auth, sections: auth == null ? null : _sections[auth], sid: sid, along: along,
        x: x, y: y, hd: _hd ?? 0.0, road: _road,
        speeds: live != null && nowWall - live.$1 < _liveFresh ? live.$2 : null,
        events: _hd == null ? const [] : events,
        showCurrentFirst: (DateTime.now().millisecondsSinceEpoch ~/ 10000) % 2 == 0,
      );
      _ui?.applyTdx(rep);
      final where = switch (rep['auth']) {
        'Freeway' => '國道', 'Highway' => '省道', 'City' => '市區道路', _ => '不在 TDX 路段上',
      };
      final road = rep['road'] as String? ?? '';
      status.value = _online == false
          ? '無網路，略過（$where）'
          : '$where${road.isEmpty ? '' : ' $road'}${live == null ? '' : '，車速 ${(nowWall - live.$1).round()} 秒前'}';
    } catch (e, st) {
      debugPrint('[tdx] report 例外：$e\n$st');
    }
    _maybeWork();
  }

  List<String> _auths() => [
    'Freeway', 'Highway',
    if (_city != null && tdxLiveCities.contains(_city)) 'City:$_city',
  ];

  // ------------------------------------------------------------------ 縣市 / 道路名稱（OS 地理編碼）
  void _maybeGeocode(double x, double y) {
    if (_geoBusy) return;
    final now = DateTime.now();
    if (_geoTime != null && now.difference(_geoTime!) < _geoMinGap) return;
    if (_geoAt != null && _city != null &&
        math.sqrt(math.pow(x - _geoAt!.$1, 2) + math.pow(y - _geoAt!.$2, 2)) < _geoEveryM) {
      return;
    }
    _geoBusy = true;
    _geoTime = now;
    final gen = _gen, lat = _lat!, lon = _lon!;
    () async {
      try {
        await setLocaleIdentifier('zh_TW');
        final places = await placemarkFromCoordinates(lat, lon).timeout(const Duration(seconds: 10));
        if (gen != _gen) return;
        String? city;
        var road = '';
        for (final p in places) {
          city ??= _cityCode(p.administrativeArea ?? '') ?? _cityCode(p.subAdministrativeArea ?? '');
          if (road.isEmpty) road = (p.thoroughfare ?? '').trim();
        }
        if (city != null) _city = city;
        _road = road;
        _geoAt = (x, y);
      } catch (_) {
        // 沒網路時 Android 地理編碼會失敗：沿用上次的縣市
      } finally {
        _geoBusy = false;
      }
    }();
  }

  static String? _cityCode(String area) {
    final a = area.replaceAll('台', '臺').trim();
    if (a.isEmpty) return null;
    final flat = a.toLowerCase().replaceAll(' city', '').replaceAll(' ', '');
    for (final e in parkingCities.entries) {
      if (a == e.value || flat == e.key.toLowerCase()) return e.key;
    }
    return null;
  }

  // ------------------------------------------------------------------ 網路 / 快取（同時只做一件事）
  void _maybeWork() {
    if (_working || !_active) return;
    _working = true;
    final gen = _gen;
    () async {
      try {
        await _work(gen);
      } catch (e) {
        debugPrint('[tdx] 背景工作例外：$e');
      } finally {
        _working = false;
      }
    }();
  }

  Future<void> _work(int gen) async {
    // 1) 磁碟快取載入（不用網路）
    for (final a in _auths()) {
      if (!_sections.containsKey(a) && _diskTried.add(a)) {
        await _loadFromDisk(a);
        if (gen != _gen) return;
      }
    }
    // 2) 即時資料：每 60 秒一輪
    final now = DateTime.now();
    if (_fixFresh && now.difference(_lastRound) >= _liveEvery) {
      _lastRound = now;
      await _round(gen);
      return;
    }
    // 3) 靜態資料過期 / 缺少：一次一筆
    for (final a in _auths()) {
      for (final spec in _staticSpecs(a)) {
        final at = _staticAt[spec.name];
        if (at != null && now.difference(at) < _staticMaxAge) continue;
        final fail = _staticFailUntil[spec.name];
        if (fail != null && now.isBefore(fail)) continue;
        // 名稱要等線形先有
        if (spec.isNames && !_sections.containsKey(a)) continue;
        await _fetchStatic(a, spec, gen);
        return;
      }
    }
  }

  Future<void> _round(int gen) async {
    final auth = _auth, city = _city;
    final wall = DateTime.now().millisecondsSinceEpoch / 1000.0;
    Future<void> events(String a) async {
      final b = await _callBytes(_eventPath(a));
      if (b == null || gen != _gen) return;
      try {
        _events[a] = (wall, await compute(_parseEvents, (b, wall)));
      } catch (e) {
        debugPrint('[tdx] 事件格式異常：$e');
      }
    }
    if (auth != null) {
      final b = await _callBytes(_livePath(auth));
      if (gen != _gen) return;
      if (b != null) {
        try {
          _live[auth] = (wall, await compute(_parseSpeeds, (b, wall)));
        } catch (e) {
          debugPrint('[tdx] 車速格式異常：$e');
        }
      }
      await events(auth);
    } else if (city != null && tdxEventCities.contains(city)) {
      await events('City:$city');
    }
  }

  static String _sub(String auth) => auth.startsWith('City:') ? 'City/${auth.substring(5)}' : auth;
  static String _livePath(String auth) => 'v2/Road/Traffic/Live/${_sub(auth)}';
  static String _eventPath(String auth) => 'v1/Traffic/RoadEvent/LiveEvent/${_sub(auth)}';

  static List<({String name, String path, bool isNames})> _staticSpecs(String auth) {
    final key = auth.startsWith('City:') ? auth.substring(5) : auth;
    final sub = _sub(auth);
    return [
      (name: 'shape_$key', path: 'v2/Road/Traffic/SectionShape/$sub', isNames: false),
      (name: 'sect_$key', path: 'v2/Road/Traffic/Section/$sub', isNames: true),
    ];
  }

  Future<File> _cacheFile(String name) async {
    final root = await getApplicationSupportDirectory();
    final dir = Directory('${root.path}/tdx_traffic');
    await dir.create(recursive: true);
    return File('${dir.path}/$name.json');
  }

  /// 讀快取 → (下載時間, 資料)
  Future<(DateTime, Object?)?> _readCache(String name) async {
    try {
      final f = await _cacheFile(name);
      if (!await f.exists()) return null;
      final (at, data) = await compute(_decodeCache, await f.readAsString());
      return (DateTime.fromMillisecondsSinceEpoch(at), data);
    } catch (e) {
      debugPrint('[tdx] 快取 $name 無法讀取：$e');
      return null;
    }
  }

  Future<void> _writeCache(String name, Object data, DateTime at) async {
    final f = await _cacheFile(name);
    final tmp = File('${f.path}.tmp');
    final text = await compute(_encodeCache, (at.millisecondsSinceEpoch, data));
    await tmp.writeAsString(text, flush: true);
    await tmp.rename(f.path);
  }

  Future<void> _loadFromDisk(String auth) async {
    final specs = _staticSpecs(auth);
    final shapes = await _readCache(specs[0].name);
    if (shapes == null || shapes.$2 is! Map) return; // 沒快取：交給 _work 下載
    final names = await _readCache(specs[1].name);
    _staticAt[specs[0].name] = shapes.$1;
    if (names != null) _staticAt[specs[1].name] = names.$1;
    await _build(auth, shapes.$2 as Map, names?.$2 is Map ? names!.$2 as Map : null);
  }

  Future<void> _build(String auth, Map shapes, Map? names) async {
    final s = await compute(_buildSections, (shapes, names));
    _sections[auth] = s;
    debugPrint('[tdx] $auth 路段 ${s.length} 筆');
  }

  Future<void> _fetchStatic(String auth, ({String name, String path, bool isNames}) spec, int gen) async {
    final bytes = await _callBytes(spec.path, big: true);
    if (gen != _gen) return;
    if (bytes == null) {
      if (!_skipped) _staticFailUntil[spec.name] = DateTime.now().add(const Duration(minutes: 5));
      return;
    }
    try {
      final shrunk = await compute(_shrinkStatic, (bytes, spec.isNames));
      if (shrunk.isEmpty) throw const FormatException('空的資料');
      final now = DateTime.now();
      await _writeCache(spec.name, shrunk, now);
      _staticAt[spec.name] = now;
      debugPrint('[tdx] 已更新 ${spec.name}（${bytes.length} bytes，${shrunk.length} 筆）');
      if (gen != _gen) return;
      if (spec.isNames) {
        final shapes = await _readCache(_staticSpecs(auth)[0].name);
        if (shapes != null && shapes.$2 is Map) await _build(auth, shapes.$2 as Map, shrunk);
      } else {
        final names = await _readCache(_staticSpecs(auth)[1].name);
        await _build(auth, shrunk, names?.$2 is Map ? names!.$2 as Map : null);
      }
    } catch (e) {
      debugPrint('[tdx] ${spec.name} 格式異常，保留舊資料：$e');
      _staticFailUntil[spec.name] = DateTime.now().add(const Duration(hours: 1));
    }
  }

  // ------------------------------------------------------------------ TDX 呼叫
  /// 一次 API 呼叫；離線、額度滿、停車查詢進行中都回傳 null（不重試，下一輪再說）
  Future<List<int>?> _callBytes(String path, {bool big = false}) async {
    _skipped = true;
    if (!_config.hasCredentials || DateTime.now().isBefore(_failUntil)) return null;
    if (parkingApi.busy || ParkingStartup.instance.busy) return null;
    try {
      if (await parkingGate.reserveData() != 0) return null; // 本機每分鐘 5 次滿了：略過
      _skipped = false;
      final token = await _getToken();
      final req = http.Request('GET', Uri.https(_host, '/api/basic/$path', {r'$format': 'JSON'}))
        ..followRedirects = false
        ..headers.addAll({
          'Authorization': 'Bearer $token', 'User-Agent': _ua,
          'Accept': 'application/json', 'Accept-Encoding': 'gzip',
        });
      final res = await _http().send(req).timeout(Duration(seconds: big ? 60 : 15));
      if (res.statusCode != 200) {
        await res.stream.listen((_) {}).cancel();
        if (res.statusCode == 429) {
          final s = int.tryParse(res.headers['retry-after'] ?? '');
          await parkingGate.blockFor(Duration(seconds: s != null && s > 0 ? s : 60));
        }
        if (res.statusCode == 401) _token = null;
        throw HttpException('HTTP ${res.statusCode}');
      }
      final bb = BytesBuilder(copy: false);
      await for (final chunk in res.stream.timeout(Duration(seconds: big ? 60 : 15))) {
        if (bb.length + chunk.length > _maxStaticBytes) throw const HttpException('資料過大');
        bb.add(chunk);
      }
      final bytes = bb.takeBytes();
      if (bytes.isNotEmpty && bytes.first == 0x3C) throw const HttpException('TDX 回應 HTML（拒絕存取）');
      if (_online != true) debugPrint('[tdx] 連上 TDX');
      _online = true;
      return bytes;
    } catch (e) {
      if (_online != false) debugPrint('[tdx] 離線或失敗（$e），60 秒後再試');
      _online = false;
      _failUntil = DateTime.now().add(const Duration(seconds: 60));
      return null;
    }
  }

  http.Client _http() => _client ??= IOClient(HttpClient()..autoUncompress = true);

  Future<String> _getToken() async {
    final key = _credKey;
    if (_token != null && _tokenFor == key && DateTime.now().isBefore(_tokenUntil)) return _token!;
    final req = http.Request('POST', Uri.https(_host, '/auth/realms/TDXConnect/protocol/openid-connect/token'))
      ..headers['User-Agent'] = _ua
      ..bodyFields = {
        'grant_type': 'client_credentials',
        'client_id': _config.clientId.trim(),
        'client_secret': _config.clientSecret.trim(),
      };
    final res = await http.Response.fromStream(await _http().send(req).timeout(const Duration(seconds: 15)));
    if (res.statusCode != 200) throw HttpException('Token HTTP ${res.statusCode}');
    final j = jsonDecode(res.body) as Map;
    final tok = j['access_token'], exp = j['expires_in'];
    if (tok is! String) throw const HttpException('Token 格式異常');
    final secs = exp is num && exp.isFinite && exp > 0 ? exp.toInt() : 3600;
    _token = tok;
    _tokenFor = key;
    _tokenUntil = DateTime.now().add(Duration(seconds: math.max(0, secs - 60)));
    return tok;
  }
}

// ------------------------------------------------------------------ 背景 isolate（compute）用的頂層函式
Object? _json(List<int> bytes) => jsonDecode(utf8.decode(bytes));
Map<String, int> _parseSpeeds((List<int>, double) m) => tdxLiveSpeeds(_json(m.$1), m.$2);
List<TdxEvent> _parseEvents((List<int>, double) m) => tdxLiveEvents(_json(m.$1), m.$2);
Map _shrinkStatic((List<int>, bool) m) => m.$2 ? tdxShrinkSections(_json(m.$1)) : tdxShrinkShapes(_json(m.$1));
TdxSections _buildSections((Map, Map?) m) => TdxSections(m.$1, m.$2);
(int, Object?) _decodeCache(String text) {
  final j = jsonDecode(text) as Map;
  return (j['at'] as int, j['data']);
}
String _encodeCache((int, Object) m) => jsonEncode({'at': m.$1, 'data': m.$2});
