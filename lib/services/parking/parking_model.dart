import 'dart:math' as math;

int parkingRadius(double speedKph) =>
    (300 + (speedKph.isFinite ? speedKph.clamp(0, 200) : 0) * 10)
        .clamp(300, 1000)
        .round();

double parkingDistance(double lat1, double lon1, double lat2, double lon2) {
  const r = math.pi / 180;
  final a =
      math.pow(math.sin((lat2 - lat1) * r / 2), 2) +
      math.cos(lat1 * r) *
          math.cos(lat2 * r) *
          math.pow(math.sin((lon2 - lon1) * r / 2), 2);
  return 6371000 * 2 * math.asin(math.sqrt(a.clamp(0, 1)));
}

int? parkingInt(Object? value) {
  if (value is! num || !value.isFinite || value != value.round()) return null;
  return value.toInt();
}

class ParkingLot {
  final String id, city, name, address;
  final double lat, lon;
  final bool onStreet;
  ParkingAvailability? availability;
  ParkingLot(
    this.id,
    this.city,
    this.name,
    this.address,
    this.lat,
    this.lon, {
    this.onStreet = false,
  });
  String get key => '$city/${onStreet ? 'on' : 'off'}/$id';

  Map<String, dynamic> toJson() => {
    'id': id,
    'city': city,
    'name': name,
    'address': address,
    'lat': lat,
    'lon': lon,
    'onStreet': onStreet,
  };
  factory ParkingLot.fromJson(Map<String, dynamic> data) {
    final lat = (data['lat'] as num).toDouble(),
        lon = (data['lon'] as num).toDouble();
    if (!lat.isFinite || !lon.isFinite || lat.abs() > 90 || lon.abs() > 180)
      throw const FormatException('position');
    return ParkingLot(
      data['id'] as String,
      data['city'] as String,
      data['name'] as String,
      data['address'] as String,
      lat,
      lon,
      onStreet: data['onStreet'] == true,
    );
  }
  static ParkingLot? parse(Map<String, dynamic> data, {bool onStreet = false}) {
    final p = data[onStreet ? 'ParkingSegmentPosition' : 'CarParkPosition'];
    if (p is! Map || data['IsMotorcycle'] == 1) return null;
    final lat = p['PositionLat'], lon = p['PositionLon'];
    if (lat is! num ||
        lon is! num ||
        !lat.isFinite ||
        !lon.isFinite ||
        lat.abs() > 90 ||
        lon.abs() > 180 ||
        (lat == 0 && lon == 0))
      return null;
    final id = data[onStreet ? 'ParkingSegmentID' : 'CarParkID'],
        city = data['City'];
    if (id is! String || id.isEmpty || city is! String || city.isEmpty)
      return null;
    final n = data[onStreet ? 'ParkingSegmentName' : 'CarParkName'];
    return ParkingLot(
      id,
      city,
      n is Map ? (n['Zh_tw'] ?? n['En'] ?? id).toString() : id,
      data[onStreet ? 'Description' : 'Address']?.toString() ?? '',
      lat.toDouble(),
      lon.toDouble(),
      onStreet: onStreet,
    );
  }
}

class ParkingAvailability {
  final int? cars, unclassified, serviceStatus;
  final DateTime? sourceTime;
  ParkingAvailability(
    this.cars,
    this.unclassified,
    this.serviceStatus,
    this.sourceTime,
  );

  factory ParkingAvailability.parse(Map<String, dynamic> data) {
    final list = data['Availabilities'];
    int? cars;
    if (list is List) {
      final matches = list
          .whereType<Map>()
          .where((x) => x['SpaceType'] == 1)
          .toList();
      // Duplicate type entries may overlap: do not sum uncertain counts.
      if (matches.length == 1) {
        final n = parkingInt(matches.single['AvailableSpaces']);
        final total = parkingInt(matches.single['NumberOfSpaces']);
        if (n != null && n >= 0 && (total == null || total < 0 || n <= total))
          cars = n;
      }
    }
    final n = parkingInt(data['AvailableSpaces']);
    return ParkingAvailability(
      cars,
      n != null && n >= 0 ? n : null,
      parkingInt(data['ServiceStatus']),
      DateTime.tryParse(data['DataCollectTime']?.toString() ?? ''),
    );
  }

  bool fresh(DateTime now) =>
      sourceTime != null &&
      now.difference(sourceTime!).inSeconds >= -60 &&
      now.difference(sourceTime!).inSeconds <= 300;

  String label(DateTime now) {
    if (!fresh(now)) return sourceTime == null ? '時間不明' : '資料過期';
    if (serviceStatus != null && serviceStatus != 1) return '非營業中';
    if (cars != null) return cars == 0 ? '汽車已滿' : '汽車 $cars 位';
    // Total may include motorcycles, reserved or monthly rental spaces.
    if (unclassified != null) return '未分類 $unclassified 位';
    return '空位未知';
  }
}
