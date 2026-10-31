import 'package:flutter_test/flutter_test.dart';
import 'package:opview/services/parking/parking_model.dart';

void main() {
  final now = DateTime.utc(2026, 10, 30, 12);
  Map<String, dynamic> data({
    Object? available = 3,
    Object? total = 10,
    int type = 1,
    int status = 1,
    DateTime? time,
  }) => {
    'AvailableSpaces': 99,
    'ServiceStatus': status,
    'DataCollectTime': (time ?? now).toIso8601String(),
    'Availabilities': [
      {
        'SpaceType': type,
        'AvailableSpaces': available,
        'NumberOfSpaces': total,
      },
    ],
  };
  test('speed uses km/h with finite radius and API cap', () {
    expect([0, 20, 40, 70, 120].map((v) => parkingRadius(v.toDouble())), [
      300,
      500,
      700,
      1000,
      1000,
    ]);
    expect(parkingRadius(-20), 300);
    expect(parkingRadius(double.nan), 300);
  });
  test('distance is metres and symmetric', () {
    expect(parkingDistance(25, 121, 25, 121), 0);
    expect(parkingDistance(25, 121, 25.001, 121), closeTo(111.195, .02));
    expect(parkingDistance(25.001, 121, 25, 121), closeTo(111.195, .02));
  });
  test('motorcycles and unknown totals never become car counts', () {
    expect(ParkingAvailability.parse(data(type: 2)).cars, isNull);
    expect(ParkingAvailability.parse(data(type: 2)).label(now), '未分類 99 位');
    expect(ParkingAvailability.parse(data(available: -1)).cars, isNull);
    expect(ParkingAvailability.parse(data(available: 1.5)).cars, isNull);
    expect(ParkingAvailability.parse(data(available: 11)).cars, isNull);
    expect(ParkingAvailability.parse(data()).label(now), '汽車 3 位');
    expect(ParkingAvailability.parse(data(available: 0)).label(now), '汽車已滿');
  });
  test('closed, stale, future and missing timestamp hide counts', () {
    expect(ParkingAvailability.parse(data(status: 2)).label(now), '非營業中');
    expect(
      ParkingAvailability.parse(
        data(time: now.subtract(const Duration(minutes: 6))),
      ).label(now),
      '資料過期',
    );
    expect(
      ParkingAvailability.parse(data(time: now.add(const Duration(minutes: 2))))
          .label(now),
      '資料過期',
    );
    expect(
      ParkingAvailability.parse(data()..remove('DataCollectTime')).label(now),
      '時間不明',
    );
  });
  test('duplicate car types are not double counted', () {
    final d = data();
    (d['Availabilities'] as List).add({'SpaceType': 1, 'AvailableSpaces': 5});
    expect(ParkingAvailability.parse(d).cars, isNull);
  });
  test('invalid coordinates and motorcycle lots are excluded', () {
    final d = <String, dynamic>{
      'CarParkID': 'a',
      'City': 'Taipei',
      'CarParkName': {'Zh_tw': '測試'},
      'CarParkPosition': {'PositionLat': 25, 'PositionLon': 121},
    };
    expect(ParkingLot.parse(d)?.name, '測試');
    expect(ParkingLot.parse({...d, 'IsMotorcycle': 1}), isNull);
    expect(
      ParkingLot.parse({
        ...d,
        'CarParkPosition': {'PositionLat': 100, 'PositionLon': 121},
      }),
      isNull,
    );
    expect(ParkingLot.parse({...d, 'City': ''}), isNull);
  });
}
