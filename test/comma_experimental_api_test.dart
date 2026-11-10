// 實驗模式開關：comma 端點 POST :5088/api/experimental_mode
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opview/services/comma_experimental_api.dart';
import 'package:opview/services/comma_models_api.dart';

void main() {
  test('posts enabled flag to :5088 and returns the value comma reports', () async {
    late http.Request sent;
    final client = MockClient((r) async {
      sent = r;
      return http.Response('{"experimental_mode": true}', 200);
    });
    expect(await setCommaExperimentalMode('192.168.43.10', true, client: client), isTrue);
    expect(sent.method, 'POST');
    expect(sent.url.toString(), 'http://192.168.43.10:5088/api/experimental_mode');
    expect(jsonDecode(sent.body), {'enabled': true});
  });

  test('comma may refuse: value in reply wins', () async {
    final client = MockClient((_) async => http.Response('{"experimental_mode": false}', 200));
    expect(await setCommaExperimentalMode('h', true, client: client), isFalse);
  });

  test('404 means the comma branch has no endpoint yet', () async {
    final client = MockClient((_) async => http.Response('not found', 404));
    expect(() => setCommaExperimentalMode('h', true, client: client),
        throwsA(isA<CommaApiException>().having((e) => e.message, 'message', contains('請更新 comma 分支'))));
  });

  test('error message from comma is shown as-is', () async {
    final client = MockClient((_) async =>
        http.Response(jsonEncode({'error': '此車不支援 openpilot 縱向控制'}), 409,
            headers: {'content-type': 'application/json; charset=utf-8'}));
    expect(() => setCommaExperimentalMode('h', true, client: client),
        throwsA(isA<CommaApiException>().having((e) => e.message, 'message', '此車不支援 openpilot 縱向控制')));
  });
}
