import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:opview/system/webrtc/lifecycle_queue.dart';
import 'package:opview/system/webrtc/webrtcd_api.dart';

void main() {
  test('native cleanup completes before the next connection starts', () async {
    final queue = LifecycleQueue();
    final released = Completer<void>();
    final events = <String>[];
    final old = queue.run(() async {
      events.add('detach');
      await released.future;
      events.add('disposed');
    });
    final next = queue.run(() async { events.add('new renderer'); });
    await Future<void>.delayed(Duration.zero);
    expect(events, ['detach']);
    released.complete();
    await Future.wait([old, next]);
    expect(events, ['detach', 'disposed', 'new renderer']);
  });

  test('failed operation reaches caller and does not poison lifecycle queue', () async {
    final queue = LifecycleQueue();
    final failed = queue.run(() async { throw StateError('native failure'); });
    await expectLater(failed, throwsStateError);
    var ran = false;
    await queue.run(() async { ran = true; });
    expect(ran, isTrue);
  });

  test('migrated servers receive initCamera and unchanged telemetry services', () async {
    for (final host in ['dplcc.test', 'dp0111pre.test']) {
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(request.url.path, '/stream');
        expect(body['initCamera'], 'wideRoad');
        expect(body.containsKey('cameras'), isFalse);
        expect(body['sdp'], 'offer');
        expect(body['bridge_services_in'], isEmpty);
        expect(body['bridge_services_out'], containsAll(bridgeServicesOut));
        return http.Response('{"sdp":"answer","type":"answer"}', 200);
      });
      final answer = await postStream(host, 'offer', camera: 'wideRoad', client: client);
      expect(answer['sdp'], 'answer');
      client.close();
    }
  });

  test('tdx is no longer requested from the comma (built into opview)', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['initCamera'], 'road');
      expect(body['bridge_services_out'], isNot(contains('tdx')));
      return http.Response('{"sdp":"answer","type":"answer"}', 200);
    });
    await postStream('notdx.test', 'offer', client: client);
    expect(requests, 1);
    client.close();
  });

  test('outdated comma webrtcd (500) is reported clearly', () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response('500 Internal Server Error', 500);
    });
    await expectLater(postStream('outdated.test', 'offer', client: client),
        throwsA(isA<WebrtcdHttpException>()
            .having((e) => e.outdatedServer, 'outdatedServer', isTrue)
            .having((e) => e.toString(), 'message', contains('未更新'))));
    expect(requests, 1); // 只送新格式；不會改送舊格式、也不再有 tdx 退回重試
    client.close();
  });

  test('400 is surfaced without retrying a new session', () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response('invalid request', 400);
    });
    await expectLater(postStream('invalid.test', 'offer', client: client),
        throwsA(isA<WebrtcdHttpException>()));
    expect(requests, 1);
    client.close();
  });
}
