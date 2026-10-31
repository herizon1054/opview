import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'parking_catalog.dart';
import 'parking_model.dart';
import 'parking_quota.dart';

class ParkingApiError implements Exception {
  final String message;
  final int? status;
  ParkingApiError(this.message, [this.status]);
  @override
  String toString() => message;
}

class ParkingStaticCache {
  final DateTime downloadedAt;
  final List<ParkingLot> lots;
  ParkingStaticCache(this.downloadedAt, this.lots);
}

class ParkingResult {
  final List<ParkingLot> lots;
  final String? warning;
  final DateTime fetchedAt;
  ParkingResult(this.lots, this.warning, this.fetchedAt);
}

/// Only basic endpoints. One live GET per supported kind, no advanced NearBy.
class ParkingApi {
  final ParkingRequestGate gate;
  final Future<String?> Function(String) readCache, readSecret;
  final Future<void> Function(String, String) writeCache, writeSecret;
  final http.Client Function() clientFactory;
  final DateTime Function() clock;
  final Future<void> Function(Duration) sleep;
  http.Client? _client;
  int _generation = 0;
  bool _busy = false;
  Future<String>? _tokenFlight;
  Map<String, dynamic>? _token;
  ParkingApi({
    required this.gate,
    required this.readCache,
    required this.writeCache,
    required this.readSecret,
    required this.writeSecret,
    http.Client Function()? clientFactory,
    DateTime Function()? clock,
    Future<void> Function(Duration)? sleep,
  }) : clientFactory = clientFactory ?? http.Client.new,
       clock = clock ?? DateTime.now,
       sleep = sleep ?? Future<void>.delayed;
  bool get busy => _busy;
  void cancel() {
    _generation++;
    _client?.close();
  }

  void _check(int gen) {
    if (gen != _generation) throw ParkingApiError('查詢已取消');
  }

  Future<T> _operation<T>(Future<T> Function(int) body) async {
    if (_busy) throw ParkingApiError('已有查詢或下載進行中');
    _busy = true;
    final gen = _generation;
    _client = clientFactory();
    try {
      return await body(gen);
    } finally {
      _client?.close();
      _client = null;
      _busy = false;
    }
  }

  void _credentials(String id, String secret) {
    if (id.trim().isEmpty || secret.trim().isEmpty)
      throw ParkingApiError('必須填入 Client ID 與 Client Secret 才能使用停車查詢');
  }

  Future<ParkingStaticCache?> cached(String city) async {
    final raw = await readCache('parking_static_v3_$city');
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map;
      if (j['v'] != 3 || j['city'] != city || j['complete'] != true)
        return null;
      final lots = (j['lots'] as List)
          .map((x) => ParkingLot.fromJson(Map<String, dynamic>.from(x as Map)))
          .toList();
      if (lots.any((x) => x.city != city)) return null;
      return ParkingStaticCache(DateTime.parse(j['at'] as String), lots);
    } catch (_) {
      return null;
    }
  }

  Future<String> _authorization(String id, String secret, int gen) async {
    _credentials(id, secret);
    final fingerprint = sha256
        .convert(utf8.encode('$id\u0000$secret'))
        .toString();
    Future<String> load() async {
      if (_token == null) {
        final raw = await readSecret('parking_token_v3');
        try {
          if (raw != null)
            _token = Map<String, dynamic>.from(jsonDecode(raw) as Map);
        } catch (_) {
          _token = null;
        }
      }
      _check(gen);
      final expiry = DateTime.tryParse(_token?['expires']?.toString() ?? '');
      if (_token?['fingerprint'] == fingerprint &&
          expiry != null &&
          clock().isBefore(expiry) &&
          _token?['value'] is String) {
        return _token!['value'] as String;
      }
      final request = http.Request(
        'POST',
        Uri.https(
          'tdx.transportdata.tw',
          '/auth/realms/TDXConnect/protocol/openid-connect/token',
        ),
      );
      request.bodyFields = {
        'grant_type': 'client_credentials',
        'client_id': id,
        'client_secret': secret,
      };
      final response = await _send(request, gen);
      final j = jsonDecode(response.body) as Map;
      final seconds = j['expires_in'];
      if (j['access_token'] is! String ||
          seconds is! num ||
          !seconds.isFinite ||
          seconds <= 0) {
        throw ParkingApiError('TDX Token 缺少有效期限，請稍後再試');
      }
      final lifetime = seconds.toInt();
      _token = {
        'fingerprint': fingerprint,
        'value': j['access_token'],
        'expires': clock()
            .add(
              Duration(
                seconds: math.max(0, lifetime - math.min(60, lifetime ~/ 10)),
              ),
            )
            .toUtc()
            .toIso8601String(),
      };
      await writeSecret('parking_token_v3', jsonEncode(_token));
      _check(gen);
      return j['access_token'] as String;
    }

    if (_tokenFlight != null) return _tokenFlight!;
    final future = load();
    _tokenFlight = future;
    try {
      return await future;
    } finally {
      _tokenFlight = null;
    }
  }

  Future<http.Response> _send(http.Request request, int gen) async {
    _check(gen);
    request.followRedirects = false;
    request.headers['Accept'] = 'application/json';
    request.headers['Accept-Encoding'] =
        'gzip'; // Native IOClient automatically decompresses.
    final response = await _client!
        .send(request)
        .timeout(const Duration(seconds: 15));
    _check(gen);
    if (response.statusCode == 429) {
      await response.stream.listen((_) {}).cancel();
      final seconds = int.tryParse(response.headers['retry-after'] ?? '');
      await gate.blockFor(
        Duration(seconds: seconds != null && seconds > 0 ? seconds : 60),
      );
      throw ParkingApiError('TDX 頻率或額度受限，請稍後手動查詢；未自動重試', 429);
    }
    if (response.statusCode != 200) {
      await response.stream.listen((_) {}).cancel();
      if (response.statusCode == 401) {
        _token = null;
        await writeSecret('parking_token_v3', '{}');
      }
      throw ParkingApiError(switch (response.statusCode) {
        401 => 'TDX 認證失敗，請檢查 Client ID 與 Client Secret',
        403 => '查詢失敗／IP鎖定：請確認 IP 或帳戶權限（403 不一定代表 IP 已鎖定）',
        400 => 'TDX 不接受此查詢條件',
        _ => 'TDX 暫時無法使用（${response.statusCode}）',
      }, response.statusCode);
    }
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 15),
    )) {
      _check(gen);
      if (bytes.length + chunk.length > 8 * 1024 * 1024)
        throw ParkingApiError('單筆資料過大，已停止下載');
      bytes.addAll(chunk);
    }
    return http.Response.bytes(bytes, 200, headers: response.headers);
  }

  Future<dynamic> _get(
    String path,
    Map<String, String> query,
    String token,
    int gen, {
    bool waitForSlot = false,
    void Function(String)? progress,
  }) async {
    while (true) {
      _check(gen);
      final delay = await gate.reserveData();
      if (delay == 0) break;
      if (!waitForSlot)
        throw ParkingGateError('本機每分鐘 5 筆節流，請等待 ${(delay / 1000).ceil()} 秒再查詢');
      progress?.call('靜態下載節流等待 ${(delay / 1000).ceil()} 秒…');
      // Short waits allow cancellation promptly, no background request retries.
      await sleep(Duration(milliseconds: math.min(delay, 1000)));
    }
    _check(gen);
    final r = http.Request(
      'GET',
      Uri.https('tdx.transportdata.tw', path, query),
    );
    if (token.isNotEmpty) r.headers['Authorization'] = 'Bearer $token';
    return jsonDecode(utf8.decode((await _send(r, gen)).bodyBytes));
  }

  static const staticRefreshInterval = Duration(days: 7);

  Future<bool> staticUpdateDue(String city) async {
    final raw = await readSecret('parking_static_success_at_v6');
    DateTime? last;
    if (raw != null) {
      last = DateTime.tryParse(raw);
      if (last == null) throw ParkingApiError('位置更新紀錄異常，已停止自動下載');
    } else {
      // R5 only stored a Taiwan date. Use its end to avoid updating early.
      final old = await readSecret('parking_static_success_day_v5');
      if (old != null) {
        if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(old)) {
          throw ParkingApiError('位置更新紀錄異常，已停止自動下載');
        }
        last = DateTime.parse('${old}T00:00:00Z')
            .add(const Duration(hours: 16));
      }
    }
    if (last != null && clock().difference(last) < staticRefreshInterval)
      return false;
    final cache = await cached(city);
    return cache == null ||
        clock().difference(cache.downloadedAt) >= staticRefreshInterval;
  }

  /// Count only successful commits; wait seven full days between updates.
  Future<ParkingStaticCache> downloadStatic({
    required String city,
    required String id,
    required String secret,
    void Function(String)? progress,
  }) => _operation((gen) async {
    _credentials(id, secret);
    if (!parkingCities.containsKey(city)) throw ParkingApiError('請選擇有效縣市');
    if (!await staticUpdateDue(city)) {
      throw ParkingApiError('位置資料距上次成功更新未滿 7 天');
    }
    _check(gen);
    await gate.beginClick();
    _check(gen);
    final token = await _authorization(id.trim(), secret.trim(), gen);
    final lots = <String, ParkingLot>{};
    for (final on in [false, true]) {
      if (!(on ? onStaticCities : offStaticCities).contains(city)) continue;
      final idField = on ? 'ParkingSegmentID' : 'CarParkID';
      final kind = on ? 'OnStreet/ParkingSegment' : 'OffStreet/CarPark';
      final select = on
          ? 'ParkingSegmentID,City,ParkingSegmentName,ParkingSegmentPosition,Description'
          : 'CarParkID,City,CarParkName,CarParkPosition,Address,IsMotorcycle';
      var skip = 0;
      final seenIds = <String>{};
      while (true) {
        progress?.call('下載${on ? '路邊' : '路外'}靜態資料：已讀 $skip 筆');
        final data = await _get(
          '/api/basic/v1/Parking/$kind/City/$city',
          {
            r'$format': 'JSON',
            r'$select': select,
            r'$orderby': idField,
            r'$top': '500',
            r'$skip': '$skip',
            r'$count': 'true',
          },
          token,
          gen,
          waitForSlot: true,
          progress: progress,
        );
        if (data is! Map || data['Items'] is! List)
          throw ParkingApiError('TDX 靜態資料格式異常，舊快取保留');
        final items = data['Items'] as List;
        if (items.isEmpty) {
          if (data['Count'] is int && skip < (data['Count'] as int))
            throw ParkingApiError('靜態資料分頁不完整，舊快取保留');
          break;
        }
        for (final row in items) {
          if (row is! Map<String, dynamic> ||
              row[idField] is! String ||
              !seenIds.add(row[idField] as String)) {
            throw ParkingApiError('靜態分頁重複或資料異常，舊快取保留');
          }
          final lot = ParkingLot.parse({...row, 'City': city}, onStreet: on);
          if (lot != null) lots[lot.key] = lot;
        }
        skip += items.length;
        if (data['Count'] is int && skip >= (data['Count'] as int)) break;
        // If no reliable Count, request until an empty page rather than assume page size.
        if (skip > 100000) throw ParkingApiError('靜態資料筆數異常，舊快取保留');
      }
    }
    _check(gen);
    final at = clock();
    await writeCache(
      'parking_static_v3_$city',
      jsonEncode({
        'v': 3,
        'city': city,
        'complete': true,
        'at': at.toUtc().toIso8601String(),
        'lots': lots.values.map((e) => e.toJson()).toList(),
      }),
    );
    // Count only after the complete cache has been committed successfully.
    await writeSecret(
      'parking_static_success_at_v6',
      at.toUtc().toIso8601String(),
    );
    return ParkingStaticCache(at, lots.values.toList());
  });

  Future<ParkingResult> nearby({
    required String city,
    required String id,
    required String secret,
    required double lat,
    required double lon,
    required int radius,
  }) => _operation((gen) async {
    _credentials(id, secret);
    final cache = await cached(city);
    if (cache == null)
      throw ParkingApiError('尚無${parkingCities[city] ?? city}位置資料，請查看自動更新狀態');
    await gate.beginClick();
    final sorted =
        cache.lots
            .where((e) => parkingDistance(lat, lon, e.lat, e.lon) <= radius)
            .toList()
          ..sort(
            (a, b) => parkingDistance(
              lat,
              lon,
              a.lat,
              a.lon,
            ).compareTo(parkingDistance(lat, lon, b.lat, b.lon)),
          );
    final candidates = <ParkingLot>[
      ...sorted.where((e) => !e.onStreet).take(20),
      ...sorted.where((e) => e.onStreet).take(20),
    ];
    if (candidates.isEmpty)
      return ParkingResult([], '目前範圍沒有已快取的停車場或路段', clock());
    final needed = [false, true]
        .where(
          (on) =>
              (on ? onLiveCities : offLiveCities).contains(city) &&
              candidates.any((e) => e.onStreet == on),
        )
        .toList();
    if (needed.isEmpty)
      return ParkingResult(candidates, '此縣市的這類場地尚無 TDX 動態空位資料', clock());
    final token = await _authorization(id.trim(), secret.trim(), gen);
    Future<String?> loadKind(bool on) async {
      final group = candidates.where((e) => e.onStreet == on).toList();
      if (group.isEmpty) return null;
      if (!(on ? onLiveCities : offLiveCities).contains(city))
        return '${on ? '路邊' : '路外'}空位未提供';
      final idField = on ? 'ParkingSegmentID' : 'CarParkID';
      final filter = group
          .map((e) => "$idField eq '${e.id.replaceAll("'", "''")}'")
          .join(' or ');
      try {
        final kind = on
            ? 'OnStreet/ParkingSegmentAvailability'
            : 'OffStreet/ParkingAvailability';
        final data = await _get(
          '/api/basic/v1/Parking/$kind/City/$city',
          {
            r'$filter': filter,
            r'$select':
                '$idField,Availabilities,AvailableSpaces,ServiceStatus,DataCollectTime',
            r'$top': '100',
            r'$format': 'JSON',
          },
          token,
          gen,
        );
        if (data is! Map || data['Items'] is! List)
          throw ParkingApiError('TDX 空位資料格式異常');
        final byId = {for (final lot in group) lot.id: lot};
        for (final row
            in (data['Items'] as List).whereType<Map<String, dynamic>>()) {
          byId[row[idField]]?.availability = ParkingAvailability.parse(row);
        }
        return null;
      } catch (e) {
        if (e is ParkingApiError || e is ParkingGateError) return e.toString();
        return '${on ? '路邊' : '路外'}更新失敗，請檢查網路';
      }
    }

    // In normal single-city operation, at most two live GETs, concurrently.
    final warnings = await Future.wait([loadKind(false), loadKind(true)]);
    _check(gen);
    candidates.sort(
      (a, b) => parkingDistance(
        lat,
        lon,
        a.lat,
        a.lon,
      ).compareTo(parkingDistance(lat, lon, b.lat, b.lon)),
    );
    final notes = warnings.whereType<String>().toSet().toList();
    if (clock().difference(cache.downloadedAt).inDays >= 7)
      notes.add('位置資料超過 7 天，請確認自動更新狀態');
    return ParkingResult(
      candidates,
      notes.isEmpty ? null : notes.join('；'),
      clock(),
    );
  });
}
