// Transport layer abstraction
// Handles connection to the device

import 'dart:async';
import 'package:flutter/foundation.dart';

/// Transport connection state
enum TransportState {
  disconnected,
  connecting,
  connected,
  failed,
}

/// 影像接收累計計數（WebRTC inbound-rtp，連線建立後從 0 起算）
class VideoCounters {
  final int packets, framesReceived, framesDecoded, framesDropped;
  /// jitter buffer 累計等待秒數 / 累計送出幀數；累計解碼秒數；目前 RTT（秒，null = 無）
  final double jitterDelaySec, decodeSec;
  final int jitterEmitted;
  final double? rttSec;
  const VideoCounters({required this.packets, required this.framesReceived,
    required this.framesDecoded, required this.framesDropped,
    this.jitterDelaySec = 0, this.jitterEmitted = 0, this.decodeSec = 0, this.rttSec});
}

/// Abstract transport interface
abstract class Transport {
  /// Stream of incoming data messages
  Stream<String> get dataStream;

  /// Stream of connection state changes
  Stream<TransportState> get stateStream;

  /// Latest connection state (so callers that subscribe late don't miss it)
  TransportState get currentState;

  /// Video renderer (if supported by transport)
  /// Returns null if transport doesn't support video
  dynamic get videoRenderer;

  Listenable get rendererChanges;

  Future<bool> sendControl(String type, Map<String, dynamic> data);

  /// Connect to a host
  Future<void> connect(String host, {String camera = 'road'});

  /// Connection statistics summary for logging (null if unsupported / not connected)
  Future<String?> statsSummary();

  /// 最近一次 [statsSummary] 取得的影像累計計數（影像卡住偵測用）；不支援 / 尚未取得 = null
  VideoCounters? get lastVideoCounters => null;

  /// Close current connection
  Future<void> close();

  /// Clean up resources
  Future<void> dispose();
}
