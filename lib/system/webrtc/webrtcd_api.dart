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

// fork 專屬 service：只有部分 fork 的 services.py 有登記。
// stock webrtcd 遇到未知 service 時 SubMaster 會丟 KeyError → HTTP 500，
// 所以先帶著請求，失敗再退回只用 bridgeServicesOut 重試一次。
//   tdx — dplcc 高公局即時路況（custom.Tdx）
const optionalBridgeServicesOut = [
  'tdx',
];

// 已確認不支援 optional services 的主機（只在退回重試成功後才記錄）
final _hostsWithoutOptional = <String>{};
// 帶 optional services 的請求成功過的主機
final _hostsWithOptional = <String>{};

/// 這台主機的分支是否支援 optional services（tdx）：true / false / null（還沒成功連線過）
bool? hostSupportsOptionalServices(String host) => _hostsWithOptional.contains(host)
    ? true : _hostsWithoutOptional.contains(host) ? false : null;

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
  if (_hostsWithoutOptional.contains(host)) {
    return _postStream(host, offerSdp, camera, bridgeServicesOut, client);
  }
  try {
    final answer = await _postStream(host, offerSdp, camera,
        [...bridgeServicesOut, ...optionalBridgeServicesOut], client);
    _hostsWithOptional.add(host);
    return answer;
  } on WebrtcdHttpException catch (e) {
    if (e.statusCode != 500) rethrow;
    // 失敗的請求在建立 session 前就丟例外，同一份 offer 可以直接重送
    final Map<String, dynamic> answer;
    try {
      answer = await _postStream(host, offerSdp, camera, bridgeServicesOut, client);
    } on WebrtcdHttpException catch (e2) {
      if (e2.statusCode != 500) rethrow;
      // 兩種請求都 500：最常見是 comma 端 webrtcd 還是舊版（只認 "cameras"，不認 "initCamera"）
      throw WebrtcdHttpException(500, '${e2.body}（comma 端 webrtcd 可能未更新：請更新 comma 分支後重開）',
          outdatedServer: true);
    }
    _hostsWithoutOptional.add(host);
    _hostsWithOptional.remove(host);
    return answer;
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
