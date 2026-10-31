import 'package:flutter/foundation.dart';

import 'parking_catalog.dart';
import 'parking_config.dart';
import 'parking_location.dart';
import 'parking_quota_store.dart';

/// App-level owner: runs on launch/resume and after credentials are saved.
/// Never fetches vacancies, and never starts a periodic network timer.
class ParkingStartup extends ChangeNotifier {
  static final instance = ParkingStartup();
  final _config = ParkingConfig.instance;
  bool busy = false;
  bool _started = false, _foreground = true, _pending = false;
  int _generation = 0;
  String _status = '開啟 App 時檢查位置更新';
  String get status => _status;
  set status(String value) {
    _status = value;
    // Log status only: never credentials, tokens, or device coordinates.
    debugPrint('[parking] $value');
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _foreground = true;
    try {
      await _config.load();
      if (!_started) return;
      _config.addListener(_changed);
      await refresh();
    } catch (_) {
      status = '無法讀取停車設定';
      notifyListeners();
    }
  }

  void _changed() {
    _generation++;
    if (busy) {
      parkingApi.cancel();
      _pending = true;
    } else {
      refresh();
    }
  }

  void foreground(bool value) {
    // inactive -> resumed (dialogs/notification shade) is not a new launch.
    // hidden -> paused is also only one transition into the background.
    if (_foreground == value) return;
    _foreground = value;
    debugPrint('[parking] foreground=$value');
    if (!value) {
      _generation++;
      if (busy) parkingApi.cancel();
    } else if (busy) {
      _pending = true;
    } else {
      refresh();
    }
  }

  void stop() {
    _started = false;
    _foreground = false;
    _generation++;
    _pending = false;
    _config.removeListener(_changed);
    if (busy) parkingApi.cancel();
  }

  Future<void> refresh() async {
    if (!_started || !_foreground || busy) return;
    if (!_config.enabled || !_config.hasCredentials) {
      status = _config.enabled
          ? '請先填入 TDX Client ID 與 Client Secret'
          : '停車功能已停用';
      notifyListeners();
      return;
    }
    if (parkingApi.busy) return;
    final gen = ++_generation;
    bool current() => _started && _foreground && gen == _generation;
    busy = true;
    status = '檢查位置資料…';
    notifyListeners();
    try {
      // Global refresh guard can avoid GPS/geocoding entirely on repeated opens.
      if (_config.city != 'auto' &&
          !await parkingApi.staticUpdateDue(_config.city)) {
        if (current()) status = '位置資料未滿 7 天，沿用快取';
        return;
      }
      final city = parkingCities.containsKey(_config.city)
          ? _config.city
          : await parkingCity(await parkingPosition(), 'auto');
      if (!current()) return;
      if (!await parkingApi.staticUpdateDue(city)) {
        if (current()) status = '${parkingCities[city]}位置資料未滿 7 天，沿用快取';
        return;
      }
      if (!current()) return;
      final cache = await parkingApi.downloadStatic(
        city: city,
        id: _config.clientId,
        secret: _config.clientSecret,
        progress: (message) {
          if (current()) {
            status = message;
            notifyListeners();
          }
        },
      );
      if (current())
        status = '${parkingCities[city]}位置已更新：${cache.lots.length} 筆';
    } catch (e) {
      if (current()) status = '位置更新未完成：${e is StateError ? e.message : e}';
    } finally {
      busy = false;
      if (!current() && _started) status = '位置更新已停止，保留上次完整資料';
      notifyListeners();
      if (_pending) {
        _pending = false;
        refresh();
      }
    }
  }
}
