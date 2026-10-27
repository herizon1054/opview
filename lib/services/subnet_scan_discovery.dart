// 網段掃描探索（mDNS 的備援）
//
// 情境：手機自己開熱點、comma 連上該熱點，同一支手機跑 opview。
// Android 在熱點介面上 NSD/mDNS 常常掃不到，快取的家用 IP 也因網段不同被略過，
// 結果永遠找不到裝置。這裡直接掃手機每個 IPv4 介面（含熱點介面）所在 /24 的
// port 5001，找到後再以 GET /schema 確認對方確實是 webrtcd。
//
// 只做 TCP 連線探測 + 一次 HTTP GET，不送 /stream，不會在 comma 端建立 session。

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:opview/services/discovery.dart';

const _webrtcdPort = 5001;

// 行動網路 / VPN 等介面不掃（不會有 comma，且網段可能很大）
const _skipIfacePrefixes = ['rmnet', 'ccmni', 'dummy', 'tun', 'ppp', 'v4-', 'clat', 'ipsec'];

class SubnetScanDiscovery implements Discovery {
  final Duration initialDelay;
  final Duration retryInterval;
  final Duration probeTimeout;
  final int concurrency;

  SubnetScanDiscovery({
    this.initialDelay = const Duration(seconds: 3),
    this.retryInterval = const Duration(seconds: 10),
    this.probeTimeout = const Duration(milliseconds: 400),
    this.concurrency = 64,
  });

  final _devicesController = StreamController<DiscoveredDevice>.broadcast();
  int _gen = 0; // stop() 時遞增，讓進行中的掃描自行結束

  @override
  Stream<DiscoveredDevice> get devices => _devicesController.stream;

  @override
  Future<void> start() async {
    final gen = ++_gen;
    unawaited(_loop(gen));
  }

  Future<void> _loop(int gen) async {
    await Future.delayed(initialDelay);
    while (gen == _gen && !_devicesController.isClosed) {
      final host = await _scanOnce(gen);
      if (gen != _gen || _devicesController.isClosed) return;
      if (host != null) {
        _devicesController.add(DiscoveredDevice(
          host: host,
          displayName: 'comma ($host)',
        ));
        return; // 找到就停；連線失敗時 ConnectionManager 會重新 start()
      }
      await Future.delayed(retryInterval);
    }
  }

  /// 回傳第一個確認為 webrtcd 的 IP；沒有則 null
  Future<String?> _scanOnce(int gen) async {
    final prefixes = <String>{};
    final selfAddrs = <String>{};
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in ifaces) {
        final name = iface.name.toLowerCase();
        if (_skipIfacePrefixes.any(name.startsWith)) continue;
        for (final addr in iface.addresses) {
          final b = addr.rawAddress;
          if (b.length != 4) continue;
          if (b[0] == 169 && b[1] == 254) continue; // link-local
          selfAddrs.add(addr.address);
          prefixes.add('${b[0]}.${b[1]}.${b[2]}');
        }
      }
    } catch (e) {
      debugPrint('[opview] subnet scan: list interfaces failed: $e');
      return null;
    }
    if (prefixes.isEmpty) return null;
    debugPrint('[opview] subnet scan: ${prefixes.map((p) => '$p.0/24').join(', ')}');

    for (final prefix in prefixes) {
      final candidates = [
        for (var i = 1; i < 255; i++) '$prefix.$i',
      ]..removeWhere(selfAddrs.contains);

      for (var from = 0; from < candidates.length; from += concurrency) {
        if (gen != _gen) return null;
        final to = math.min(from + concurrency, candidates.length);
        final batch = candidates.sublist(from, to);
        final open = await Future.wait(batch.map(_portOpen));
        for (var i = 0; i < batch.length; i++) {
          if (!open[i]) continue;
          if (await _isWebrtcd(batch[i])) return batch[i];
        }
      }
    }
    return null;
  }

  Future<bool> _portOpen(String ip) async {
    try {
      final s = await Socket.connect(ip, _webrtcdPort, timeout: probeTimeout);
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _isWebrtcd(String ip) async {
    try {
      final r = await http
          .get(Uri.parse('http://$ip:$_webrtcdPort/schema?services=carState'))
          .timeout(const Duration(seconds: 2));
      return r.statusCode == 200 && r.body.contains('carState');
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> stop() async {
    _gen++;
  }

  @override
  void dispose() {
    _gen++;
    _devicesController.close();
  }
}

/// 同時跑多個 Discovery，合併成一個裝置串流（mDNS + 網段掃描）
class CompositeDiscovery implements Discovery {
  final List<Discovery> _children;
  final _devicesController = StreamController<DiscoveredDevice>.broadcast();
  final List<StreamSubscription> _subs = [];

  CompositeDiscovery(this._children) {
    for (final c in _children) {
      _subs.add(c.devices.listen((d) {
        if (!_devicesController.isClosed) _devicesController.add(d);
      }));
    }
  }

  @override
  Stream<DiscoveredDevice> get devices => _devicesController.stream;

  @override
  Future<void> start() async {
    await Future.wait(_children.map((c) => c.start()));
  }

  @override
  Future<void> stop() async {
    await Future.wait(_children.map((c) => c.stop()));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    for (final c in _children) {
      c.dispose();
    }
    _devicesController.close();
  }
}
