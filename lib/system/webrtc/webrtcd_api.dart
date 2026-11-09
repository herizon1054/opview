// webrtcd API client
// POST /stream to negotiate WebRTC session
// ported from openpilot system/webrtc/webrtcd.py

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:opview/data/models.dart';

// everything the stock UI subscribes to
const bridgeServicesOut = [
  'carState',
  'selfdriveState',
  'controlsState',
  'modelV2',
  'liveCalibration',
  'radarState',
  'longitudinalPlan',
  'deviceState',
  'roadCameraState',
];

// TDX 路況已內建在 opview（lib/services/tdx/），不再向 comma 訂閱 tdx service，
// 所以也不需要「帶 optional service 失敗再退回」的重試。

class WebrtcdHttpException implements Exception {
  final int statusCode;
  final String body;
  /// 新格式請求被拒（HTTP 500），comma 端 webrtcd 可能是更新前的舊版
  final bool outdatedServer;
  WebrtcdHttpException(this.statusCode, this.body, {this.outdatedServer = false});
  @override
  String toString() => 'webrtcd returned $statusCode: $body';
}

/// exchange SDP with webrtcd, returns answer SDP
Future<Map<String, dynamic>> postStream(String host, String offerSdp, {String camera = 'road', http.Client? client}) async {
  try {
    return await _postStream(host, offerSdp, camera, bridgeServicesOut, client);
  } on WebrtcdHttpException catch (e) {
    if (e.statusCode != 500) rethrow;
    // 最常見是 comma 端 webrtcd 還是舊版（只認 "cameras"，不認 "initCamera"）
    throw WebrtcdHttpException(500, '${e.body}（comma 端 webrtcd 可能未更新：請更新 comma 分支後重開）',
        outdatedServer: true);
  }
}

Future<Map<String, dynamic>> _postStream(
    String host, String offerSdp, String camera, List<String> services, http.Client? client) async {
  final request = StreamRequest(
    sdp: offerSdp,
    cameras: [camera],
    bridgeServicesOut: services,
  );

  final body = request.toJson()..remove('cameras');
  body['initCamera'] = camera;
  final url = Uri(scheme: 'http', host: host, port: 5001, path: '/stream');
  final response = await (client?.post ?? http.post)(
    url,
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode(body),
  ).timeout(const Duration(seconds: 10));

  if (response.statusCode != 200) {
    throw WebrtcdHttpException(response.statusCode, response.body);
  }

  return jsonDecode(response.body) as Map<String, dynamic>;
}
