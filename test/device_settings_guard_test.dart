// 裝置設定只允許 offroad 或 P 檔（未連線顯示「未連線」）；dp / sp 分支判斷；TDX 支援判斷
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opview/selfdrive/ui/settings/op_settings_link.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/system/webrtc/webrtcd_api.dart';

UIState _state({required bool connected, bool started = true, String gear = 'drive', bool fresh = true}) {
  return UIState()
    ..isConnected = connected
    ..started = started
    ..gearShifter = gear
    ..lastModelAt = fresh ? DateTime.now() : DateTime.now().subtract(const Duration(seconds: 10));
}

void main() {
  group('opview 連線中（有即時檔位）', () {
    test('offroad 或 P 檔允許', () {
      expect(decideOpSettings(_state(connected: true, started: false), null), isNull);
      expect(decideOpSettings(_state(connected: true, gear: 'park'), null), isNull);
    });
    test('D / R / 未知檔位不允許', () {
      expect(decideOpSettings(_state(connected: true, gear: 'drive'), null), contains('P 檔'));
      expect(decideOpSettings(_state(connected: true, gear: 'reverse'), null), isNotNull);
      expect(decideOpSettings(_state(connected: true, gear: 'unknown'), null), isNotNull);
    });
  });

  group('opview 未連線（或資料過期）→ 看 comma serverd', () {
    test('連不到 comma → 未連線', () {
      expect(decideOpSettings(_state(connected: false), null), opSettingsNotConnected);
      expect(decideOpSettings(null, null), opSettingsNotConnected);
      expect(decideOpSettings(_state(connected: true, fresh: false), null), opSettingsNotConnected);
    });
    test('serverd 回報 offroad → 允許', () {
      expect(decideOpSettings(_state(connected: false), true), isNull);
    });
    test('serverd 回報 onroad → 無法確認檔位，不允許', () {
      expect(decideOpSettings(_state(connected: false), false), contains('onroad'));
    });
  });

  group('判斷 comma 分支（dp / sp）', () {
    test('dp：:5088/api/init 有 dp_dev_dashy → dp，並取得 isOffroad', () async {
      final c = MockClient((r) async {
        expect(r.url.path, '/api/init');
        expect(r.url.port, 5088);
        return http.Response('{"dp_dev_dashy": true, "isOffroad": true}', 200);
      });
      final p = await probeComma('dp.test', client: c);
      expect(p.branch, CommaBranch.dp);
      expect(p.offroad, isTrue);
    });

    test('sp：:5088 連線被拒（主機在、沒有 dashy）→ sp', () async {
      final c = MockClient((r) async {
        if (r.url.port == 5088) {
          throw http.ClientException('SocketException: Connection refused (OS Error: Connection refused, errno = 111)');
        }
        return http.Response('{"selfdriveStateSP": {}}', 200); // :5001/schema
      });
      final p = await probeComma('sp.test', client: c);
      expect(p.branch, CommaBranch.sp);
      expect(p.offroad, isNull);
    });

    test('連不到 comma（逾時 / 網路不通）→ unknown', () async {
      final c = MockClient((_) async => throw http.ClientException('No route to host'));
      expect((await probeComma('down.test', client: c)).branch, CommaBranch.unknown);
    });
  });

  test('branch without tdx: request falls back and host is marked unsupported', () async {
    final client = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if ((body['bridge_services_out'] as List).contains('tdx')) return http.Response('KeyError', 500);
      return http.Response('{"sdp":"answer","type":"answer"}', 200);
    });
    expect(hostSupportsOptionalServices('notdx.test'), isNull);
    await postStream('notdx.test', 'offer', client: client);
    expect(hostSupportsOptionalServices('notdx.test'), isFalse);
    client.close();
  });

  test('branch with tdx is marked supported', () async {
    final client = MockClient((_) async => http.Response('{"sdp":"answer","type":"answer"}', 200));
    await postStream('withtdx.test', 'offer', client: client);
    expect(hostSupportsOptionalServices('withtdx.test'), isTrue);
    client.close();
  });
}
