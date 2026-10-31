import 'dart:convert';
import 'dart:math' as math;

import 'package:csv/csv.dart';

import 'parking_model.dart';

/// Official public feeds only. Never pass TDX credentials to these hosts.
const localParkingCities = {'NewTaipei', 'Hsinchu'};
const ntpcStaticUrl =
    'https://data.ntpc.gov.tw/api/datasets/B1464EF0-9C7C-4A6F-ABF7-6BDF32847E68/csv/file';
const ntpcLiveUrl =
    'https://data.ntpc.gov.tw/api/datasets/e09b35a5-a738-48cc-b0f5-570b67ad9c78/csv/file';
const hsinchuParkingUrl = 'https://hispark.hccg.gov.tw/OpenData/GetParkInfo';

String localParkingUrl(String city, {required bool live}) => switch (city) {
  'NewTaipei' => live ? ntpcLiveUrl : ntpcStaticUrl,
  'Hsinchu' => hsinchuParkingUrl,
  _ => throw ArgumentError('Unsupported local parking city'),
};

List<Map<String, dynamic>> _rows(String city, String body, bool live) {
  if (city == 'Hsinchu') {
    final value = jsonDecode(body);
    if (value is! List || value.isEmpty || value.any((e) => e is! Map)) {
      throw const FormatException('新竹市停車資料格式異常或空白');
    }
    final rows = value.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    if (rows.any(
      (e) =>
          !e.containsKey('PARKNO') ||
          !e.containsKey(live ? 'FREEQUANTITY' : 'LONGITUDE'),
    )) {
      throw const FormatException('新竹市停車資料缺少必要欄位');
    }
    return rows;
  }
  final table = const CsvToListConverter(
    shouldParseNumbers: false,
    allowInvalid: false,
    eol: '\n',
  ).convert(body.replaceFirst('\uFEFF', '').replaceAll('\r\n', '\n'));
  if (table.length < 2) throw const FormatException('新北市停車資料格式異常或空白');
  final headers = table.first
      .map((e) => e.toString().trim().toUpperCase())
      .toList();
  final required = live
      ? ['ID', 'AVAILABLECAR']
      : ['ID', 'NAME', 'TW97X', 'TW97Y', 'TOTALCAR'];
  if (!required.every(headers.contains))
    throw const FormatException('新北市停車資料缺少必要欄位');
  return table
      .skip(1)
      .where((r) => r.any((e) => e.toString().trim().isNotEmpty))
      .map((r) {
        if (r.length != headers.length)
          throw const FormatException('新北市 CSV 列不完整');
        return <String, dynamic>{
          for (var i = 0; i < headers.length; i++) headers[i]: r[i],
        };
      })
      .toList();
}

int? _integer(Object? x) {
  final n = x is num ? x : num.tryParse(x?.toString().trim() ?? '');
  return parkingInt(n);
}

double? _double(Object? x) {
  final n = double.tryParse(x?.toString().trim() ?? '');
  return n != null && n.isFinite ? n : null;
}

/// Inverse Transverse Mercator, TWD97 / TM2 zone 121 (GRS80, EPSG:3826).
/// Reject mixed units/invalid coordinates rather than silently relocating a lot.
(double, double)? twd97ToWgs84(double x, double y) {
  if (!x.isFinite ||
      !y.isFinite ||
      x < 100000 ||
      x > 400000 ||
      y < 2400000 ||
      y > 2900000)
    return null;
  const a = 6378137.0, f = 1 / 298.257222101, k = 0.9999;
  const e2 = f * (2 - f), ep2 = e2 / (1 - e2);
  final mu =
      (y / k) / (a * (1 - e2 / 4 - 3 * e2 * e2 / 64 - 5 * e2 * e2 * e2 / 256));
  final e1 = (1 - math.sqrt(1 - e2)) / (1 + math.sqrt(1 - e2));
  final phi =
      mu +
      (3 * e1 / 2 - 27 * math.pow(e1, 3) / 32) * math.sin(2 * mu) +
      (21 * e1 * e1 / 16 - 55 * math.pow(e1, 4) / 32) * math.sin(4 * mu) +
      151 * math.pow(e1, 3) / 96 * math.sin(6 * mu) +
      1097 * math.pow(e1, 4) / 512 * math.sin(8 * mu);
  final sin = math.sin(phi), cos = math.cos(phi), tan = math.tan(phi);
  final n = a / math.sqrt(1 - e2 * sin * sin);
  final r = a * (1 - e2) / math.pow(1 - e2 * sin * sin, 1.5);
  final t = tan * tan, c = ep2 * cos * cos, d = (x - 250000) / (n * k);
  final lat =
      phi -
      n *
          tan /
          r *
          (d * d / 2 -
              (5 + 3 * t + 10 * c - 4 * c * c - 9 * ep2) * math.pow(d, 4) / 24 +
              (61 + 90 * t + 298 * c + 45 * t * t - 252 * ep2 - 3 * c * c) *
                  math.pow(d, 6) /
                  720);
  final lon =
      121 * math.pi / 180 +
      (d -
              (1 + 2 * t + c) * math.pow(d, 3) / 6 +
              (5 - 2 * c + 28 * t - 3 * c * c + 8 * ep2 + 24 * t * t) *
                  math.pow(d, 5) /
                  120) /
          cos;
  return (lat * 180 / math.pi, lon * 180 / math.pi);
}

// Published feeds can repeat IDs. Collapse identical identity fields; omit
// conflicting IDs entirely, never attach another lot's vacancy count.
List<Map<String, dynamic>> _uniqueRows(
  List<Map<String, dynamic>> rows,
  String idField,
  List<String> fields,
) {
  final unique = <String, Map<String, dynamic>>{};
  final conflicts = <String>{};
  for (final row in rows) {
    final id = row[idField]?.toString().trim() ?? '';
    if (id.isEmpty) throw const FormatException('地方停車場編號缺漏');
    final previous = unique[id];
    if (previous != null &&
        fields.any(
          (key) =>
              previous[key]?.toString().trim() != row[key]?.toString().trim(),
        )) {
      conflicts.add(id);
    }
    unique.putIfAbsent(id, () => row);
  }
  return unique.entries
      .where((e) => !conflicts.contains(e.key))
      .map((e) => e.value)
      .toList();
}

List<ParkingLot> localParkingLots(String city, String body) {
  final rows = _uniqueRows(
    _rows(city, body, false),
    city == 'NewTaipei' ? 'ID' : 'PARKNO',
    city == 'NewTaipei'
        ? ['NAME', 'TW97X', 'TW97Y']
        : ['PARKINGNAME', 'LONGITUDE', 'LATITUDE'],
  );
  final result = <ParkingLot>[];
  final seen = <String>{};
  for (final row in rows) {
    final ntpc = city == 'NewTaipei';
    final id = row[ntpc ? 'ID' : 'PARKNO']?.toString().trim() ?? '';
    if (id.isEmpty || !seen.add(id))
      throw const FormatException('地方停車場編號缺漏或重複');
    if ((_integer(row[ntpc ? 'TOTALCAR' : 'TOTALQUANTITY']) ?? 0) <= 0)
      continue;
    final x = _double(row[ntpc ? 'TW97X' : 'LONGITUDE']);
    final y = _double(row[ntpc ? 'TW97Y' : 'LATITUDE']);
    if (x == null || y == null) continue;
    final p = ntpc ? twd97ToWgs84(x, y) : (y, x);
    if (p == null || p.$1 < 21.5 || p.$1 > 26.5 || p.$2 < 119 || p.$2 > 123)
      continue;
    final name = row[ntpc ? 'NAME' : 'PARKINGNAME']?.toString().trim() ?? '';
    if (name.isEmpty) continue;
    result.add(
      ParkingLot(
        'local:${ntpc ? 'ntpc' : 'hccg'}:$id',
        city,
        name,
        row['ADDRESS']?.toString() ?? '',
        p.$1,
        p.$2,
      ),
    );
  }
  if (result.isEmpty) throw const FormatException('地方停車資料無有效汽車場地，保留舊快取');
  return result;
}

DateTime? _taiwanTime(Object? value) {
  var s = value?.toString().trim() ?? '';
  if (s.isEmpty) return null;
  if (!RegExp(r'(Z|[+-]\d\d:\d\d)$').hasMatch(s)) s += '+08:00';
  return DateTime.tryParse(s)?.toUtc();
}

Map<String, ParkingAvailability> localParkingAvailability(
  String city,
  String body,
  DateTime fetchedAt,
) {
  final result = <String, ParkingAvailability>{};
  final rows = _uniqueRows(
    _rows(city, body, true),
    city == 'NewTaipei' ? 'ID' : 'PARKNO',
    city == 'NewTaipei'
        ? ['AVAILABLECAR']
        : ['FREEQUANTITY', 'TOTALQUANTITY', 'UPDATETIME'],
  );
  for (final row in rows) {
    final ntpc = city == 'NewTaipei';
    final id = row[ntpc ? 'ID' : 'PARKNO']?.toString().trim() ?? '';
    final key = 'local:${ntpc ? 'ntpc' : 'hccg'}:$id';
    if (id.isEmpty || result.containsKey(key))
      throw const FormatException('地方空位編號缺漏或重複');
    final n = _integer(row[ntpc ? 'AVAILABLECAR' : 'FREEQUANTITY']);
    final total = ntpc ? null : _integer(row['TOTALQUANTITY']);
    final cars =
        n != null && n >= 0 && (total == null || total < 0 || n <= total)
        ? n
        : null;
    result[key] = ParkingAvailability(
      cars,
      null,
      null,
      ntpc ? null : _taiwanTime(row['UPDATETIME']),
      receivedAt: fetchedAt,
      reportWithoutTime: ntpc,
    );
  }
  return result;
}

/// Keep TDX-only lots; replace exact-name nearby duplicates with local stable IDs.
List<ParkingLot> mergeLocalParking(
  List<ParkingLot> base,
  List<ParkingLot> local,
) {
  String normalized(String s) =>
      s.replaceAll(RegExp(r'\s+'), '').replaceAll('台', '臺');
  return [
    ...base.where(
      (a) =>
          a.onStreet ||
          !local.any(
            (b) =>
                a.city == b.city &&
                normalized(a.name) == normalized(b.name) &&
                parkingDistance(a.lat, a.lon, b.lat, b.lon) < 80,
          ),
    ),
    ...local,
  ];
}
