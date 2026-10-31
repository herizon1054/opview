import 'package:flutter_test/flutter_test.dart';
import 'package:opview/services/parking/parking_quota.dart';

void main() {
  test('corrupt cooldown storage fails closed', () async {
    final gate = ParkingRequestGate(
      read: () async => '{bad',
      write: (_) async {},
    );
    await expectLater(gate.beginClick(), throwsA(isA<ParkingGateError>()));
  });
}
