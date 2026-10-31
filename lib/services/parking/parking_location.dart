import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';

import 'parking_catalog.dart';

Future<Position> parkingPosition() async {
  if (!await Geolocator.isLocationServiceEnabled()) throw StateError('請開啟手機定位');
  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied)
    permission = await Geolocator.requestPermission();
  if (permission == LocationPermission.denied ||
      permission == LocationPermission.deniedForever) {
    throw StateError('請在手機設定允許位置權限');
  }
  final p = await Geolocator.getCurrentPosition(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.high,
      timeLimit: Duration(seconds: 12),
    ),
  );
  final age = DateTime.now().difference(p.timestamp).inSeconds;
  if (age > 30 ||
      age < -5 ||
      !p.latitude.isFinite ||
      !p.longitude.isFinite ||
      p.latitude.abs() > 90 ||
      p.longitude.abs() > 180 ||
      !p.accuracy.isFinite ||
      p.accuracy < 0 ||
      p.accuracy > 150) {
    throw StateError('定位過舊或誤差超過 150 公尺，請稍後重試');
  }
  return p;
}

Future<String> parkingCity(Position p, String override) async {
  if (parkingCities.containsKey(override)) return override;
  // OS geocoding, not a TDX request. No guessed city when unavailable.
  try {
    final places = await placemarkFromCoordinates(
      p.latitude,
      p.longitude,
    ).timeout(const Duration(seconds: 10));
    for (final place in places) {
      final area = (place.administrativeArea ?? '').replaceAll('台', '臺').trim();
      for (final e in parkingCities.entries) {
        if (area == e.value ||
            area.toLowerCase().replaceAll(' ', '') == e.key.toLowerCase() ||
            area.toLowerCase().replaceAll(' city', '').replaceAll(' ', '') ==
                e.key.toLowerCase())
          return e.key;
      }
    }
  } catch (_) {
    /* User can explicitly select a city; no location guess. */
  }
  throw StateError('無法自動辨識縣市，請在停車設定選擇縣市');
}
