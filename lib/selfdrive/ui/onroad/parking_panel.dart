import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../services/parking/parking_api.dart';
import '../../../services/parking/parking_catalog.dart';
import '../../../services/parking/parking_config.dart';
import '../../../services/parking/parking_location.dart';
import '../../../services/parking/parking_model.dart';
import '../../../services/parking/parking_quota_store.dart';
import '../../../services/parking/parking_startup.dart';
import '../ui_state.dart';
import '../settings/parking_settings_dialog.dart';

class ParkingPanel extends StatefulWidget {
  final UIState state;
  final bool stale;
  const ParkingPanel({super.key, required this.state, required this.stale});
  @override
  State<ParkingPanel> createState() => _ParkingPanelState();
}

class _ParkingPanelState extends State<ParkingPanel>
    with WidgetsBindingObserver {
  final _config = ParkingConfig.instance;
  Timer? _timer;
  bool _ready = false, _busy = false, _foreground = true, _clockBusy = false;
  int _generation = 0, _remaining = 0, _radius = 1000;
  String _message = '按下按鈕後查詢', _city = '';
  Position? _position;
  ParkingResult? _result;
  final _startup = ParkingStartup.instance;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _config.addListener(_changed);
    _startup.addListener(_startupChanged);
    _load();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _countdown());
  }

  Future<void> _load() async {
    try {
      await _config.load();
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      if (mounted) setState(() => _message = '設定讀取失敗，請重新設定');
    }
    await _countdown();
  }

  void _startupChanged() {
    if (mounted) setState(() {});
  }

  void _changed() {
    if (!mounted) return;
    _generation++;
    if (_busy) parkingApi.cancel();
    setState(() {
      _ready = true;
      _busy = false;
      _result = null;
      _city = '';
      _message = '設定已更新，請手動查詢';
    });
  }

  Future<void> _countdown() async {
    if (!mounted || !_foreground || _clockBusy) return;
    _clockBusy = true;
    try {
      final seconds = await parkingGate.remaining();
      if (mounted) setState(() => _remaining = seconds);
    } catch (_) {
      if (mounted) setState(() => _message = '無法讀取查詢冷卻紀錄');
    } finally {
      _clockBusy = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _foreground = false;
      _generation++;
      if (_busy) parkingApi.cancel();
      if (mounted)
        setState(() {
          _busy = false;
          _message = '已暫停，回到前景後可手動查詢';
        });
    } else if (state == AppLifecycleState.resumed) {
      _foreground = true;
      _countdown();
    }
  }

  Future<void> _query() async {
    if (!_ready ||
        !_config.enabled ||
        !_config.hasCredentials ||
        _startup.busy ||
        _busy ||
        !_foreground ||
        _remaining > 0)
      return;
    final gen = ++_generation;
    bool current() => mounted && gen == _generation && _foreground;
    setState(() {
      _busy = true;
      _result = null;
      _message = '取得手機位置…';
    });
    try {
      final p = await parkingPosition();
      if (!current()) return;
      final city = await parkingCity(p, _config.city);
      if (!current()) return;
      setState(() {
        _position = p;
        _city = city;
        _radius = _config.radius;
        _message = '讀取本地場地資料…';
      });
      final cache = await parkingApi.cached(city);
      if (!current()) return;
      if (cache == null) {
        setState(() {
          _message = '${parkingCities[city]}尚無位置資料；${_startup.status}';
        });
        return;
      }
      setState(() => _message = '查詢路外與路邊空位…');
      final result = await parkingApi.nearby(
        city: city,
        id: _config.clientId,
        secret: _config.clientSecret,
        lat: p.latitude,
        lon: p.longitude,
        radius: _radius,
      );
      if (!current()) return;
      setState(() {
        _result = result;
        _message = result.warning ?? '本次位置的直線距離 · 點右側箭頭導航';
      });
    } catch (e) {
      if (current())
        setState(
          () =>
              _message = e is StateError ? e.message.toString() : e.toString(),
        );
    } finally {
      if (current()) {
        setState(() => _busy = false);
        await _countdown();
      }
    }
  }

  void _cancel() {
    _generation++;
    parkingApi.cancel();
    setState(() {
      _busy = false;
      _message = '已取消，不會自動重試';
    });
    _countdown();
  }

  Future<void> _navigate(ParkingLot lot) async {
    final url = Uri.https('www.google.com', '/maps/dir/', {
      'api': '1',
      'destination': '${lot.lat},${lot.lon}',
      'travelmode': 'driving',
    });
    try {
      if (!await launchUrl(url, mode: LaunchMode.externalApplication))
        throw StateError('navigation');
    } catch (_) {
      if (mounted) setState(() => _message = '無法開啟導航：${lot.lat}, ${lot.lon}');
    }
  }

  @override
  void dispose() {
    _generation++;
    if (_busy) parkingApi.cancel();
    _timer?.cancel();
    _config.removeListener(_changed);
    _startup.removeListener(_startupChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final compact = box.maxHeight < 170;
      // Keep off-street locations; roadside rows need a positive vacancy count.
      // Match the display priority: cars first, then unclassified spaces.
      final lots = (_result?.lots ?? <ParkingLot>[]).where((lot) {
        final a = lot.availability;
        return !lot.onStreet || ((a?.cars ?? a?.unclassified ?? 0) > 0);
      }).toList();
      final now = DateTime.now();
      final mode = _config.hasCredentials ? 'TDX 會員' : '尚未設定金鑰';
      return Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xFF0D151B),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 48,
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed:
                          !_ready ||
                              !_config.enabled ||
                              !_config.hasCredentials ||
                              _startup.busy ||
                              _busy ||
                              _remaining > 0
                          ? null
                          : _query,
                      icon: const Icon(Icons.local_parking, size: 26),
                      style: FilledButton.styleFrom(
                        textStyle: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      label: Text(
                        _startup.busy
                            ? '更新位置資料…'
                            : !_config.hasCredentials
                            ? '請先設定 TDX 金鑰'
                            : _busy
                            ? '處理中…'
                            : _remaining > 0
                            ? '請等 $_remaining 秒'
                            : '查詢周遭車位',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '停車查詢設定',
                    onPressed: _busy
                        ? null
                        : () => showParkingSettings(context),
                    icon: const Icon(Icons.settings_outlined, size: 20),
                  ),
                  if (_busy)
                    IconButton(
                      tooltip: '取消',
                      onPressed: _cancel,
                      icon: const Icon(Icons.close),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            if (!compact)
              Text(
                '$mode · ${parkingCities[_city] ?? '手機定位'} · ${_result == null ? _config.radius : _radius} m · 僅所選縣市',
                maxLines: 1,
                style: const TextStyle(fontSize: 13, color: Colors.white54),
              ),
            Text(
              !_config.enabled
                  ? '已停用，請從右側設定開啟'
                  : !_config.hasCredentials
                  ? '必須填入 Client ID 與 Client Secret'
                  : _startup.busy || _result == null
                  ? _startup.status + ' · ' + _message
                  : _message,
              maxLines: compact ? 1 : 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: Colors.white70),
            ),
            if (!compact)
              Expanded(
                child: lots.isEmpty
                    ? Center(
                        child: Text(
                          _result == null ? '按上方按鈕查詢周遭車位' : '此範圍內無可顯示的停車資料',
                          style: TextStyle(fontSize: 16, color: Colors.white38),
                        ),
                      )
                    : ListView.builder(
                        padding: EdgeInsets.zero,
                        itemCount: lots.length,
                        itemBuilder: (context, i) {
                          final lot = lots[i], a = lot.availability;
                          final p = _position!;
                          final distance = parkingDistance(
                            p.latitude,
                            p.longitude,
                            lot.lat,
                            lot.lon,
                          ).round();
                          final rawLabel = a?.label(now);
                          final label = switch (rawLabel) {
                            null || '無空位資料' || '空位未知' => '無資料',
                            '汽車已滿' => '無空位',
                            _ => rawLabel!.replaceFirstMapped(
                              RegExp(r'^汽車 (\d+) 位$'),
                              (m) => '剩餘 ${m[1]} 格',
                            ),
                          };
                          final t = (a?.sourceTime ?? a?.receivedAt)?.toLocal();
                          final time = t == null
                              ? '時間不明'
                              : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 5),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${lot.onStreet ? '路邊' : '路外'}｜${lot.name}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      Text(
                                        '$distance m · ${a?.sourceTime == null && a?.receivedAt != null ? '取得' : ''}$time · ${lot.address}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 13,
                                          color: Colors.white54,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  label,
                                  style: TextStyle(
                                    fontSize: 16,
                                    color:
                                        a != null &&
                                            a.fresh(now) &&
                                            a.serviceStatus == 1 &&
                                            (a.cars ?? 0) > 0
                                        ? Colors.tealAccent
                                        : Colors.white60,
                                  ),
                                ),
                                SizedBox(
                                  width: 48,
                                  child: IconButton(
                                    padding: EdgeInsets.zero,
                                    tooltip: '導航 ${lot.lat}, ${lot.lon}',
                                    onPressed: () => _navigate(lot),
                                    icon: const Icon(
                                      Icons.directions,
                                      size: 28,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
          ],
        ),
      );
    },
  );
}
