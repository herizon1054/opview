import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ParkingConfig extends ChangeNotifier {
  static final instance = ParkingConfig();
  static const _storage = FlutterSecureStorage();
  bool enabled = true;
  String city = 'auto';
  int radius = 10000;
  String clientId = '', clientSecret = '';
  bool get hasCredentials =>
      clientId.trim().isNotEmpty && clientSecret.trim().isNotEmpty;
  Future<void>? _loading;
  Future<void> load() => _loading ??= _load().catchError((Object error) {
    _loading = null;
    throw error;
  });
  Future<void> _load() async {
    final raw = await _storage.read(key: 'opview_parking_config_v1');
    if (raw == null) return;
    final data = jsonDecode(raw) as Map;
    enabled = data['enabled'] == true;
    clientId = data['id'] as String? ?? '';
    clientSecret = data['secret'] as String? ?? '';
    city = data['city'] as String? ?? 'auto';
    radius =
        data['radiusTestV1'] == true &&
            const [1000, 1200, 10000].contains(data['radius'])
        ? data['radius'] as int
        : 10000;
    notifyListeners();
  }

  Future<void> save(
    bool on,
    String id,
    String secret, {
    String selectedCity = 'auto',
    int selectedRadius = 10000,
  }) async {
    if (on && (id.trim().isEmpty || secret.trim().isEmpty)) {
      throw StateError('啟用停車功能必須填入 Client ID 與 Client Secret');
    }
    if (!const [1000, 1200, 10000].contains(selectedRadius)) {
      throw ArgumentError('搜尋範圍僅支援 1000、1200 或 10000 公尺');
    }
    await _storage.write(
      key: 'opview_parking_config_v1',
      value: jsonEncode({
        'enabled': on,
        'id': id.trim(),
        'secret': secret.trim(),
        'city': selectedCity,
        'radius': selectedRadius,
        'radiusTestV1': true,
      }),
    );
    enabled = on;
    clientId = id.trim();
    clientSecret = secret.trim();
    city = selectedCity;
    radius = selectedRadius;
    notifyListeners();
  }
}
