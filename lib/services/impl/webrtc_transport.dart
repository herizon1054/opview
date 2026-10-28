// WebRTC transport implementation
// Connects to webrtcd for video + data channel

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:opview/services/transport.dart';
import 'package:opview/system/webrtc/webrtc_client.dart';

class WebRTCTransport implements Transport {
  final WebRTCClient _client = WebRTCClient();
  final _stateController = StreamController<TransportState>.broadcast();

  StreamSubscription? _clientStateSub;
  TransportState _state = TransportState.disconnected;

  @override
  TransportState get currentState => _state;

  void _emit(TransportState s) {
    _state = s;
    _stateController.add(s);
  }

  @override
  Stream<String> get dataStream => _client.dataStream;

  @override
  Stream<TransportState> get stateStream => _stateController.stream;

  @override
  dynamic get videoRenderer => _client.videoRenderer;

  @override
  Listenable get rendererChanges => _client.renderer;

  @override
  Future<bool> sendControl(String type, Map<String, dynamic> data) => _client.sendControl(type, data);

  @override
  Future<void> connect(String host, {String camera = 'road'}) async {
    // Listen to WebRTC connection state and translate to TransportState
    _clientStateSub?.cancel();
    _state = TransportState.connecting;
    _clientStateSub = _client.stateStream.listen((state) {
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
          _emit(TransportState.connecting);
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _emit(TransportState.connected);
        // opview：disconnected 常是暫時的（WebRTC 會自行恢復），交給 ConnectionManager 寬限處理
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          _emit(TransportState.disconnected);
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          _emit(TransportState.failed);
        default:
          break;
      }
    });

    await _client.connect(host, camera: camera);
  }

  @override
  Future<String?> statsSummary() => _client.statsSummary();

  @override
  VideoCounters? get lastVideoCounters => _client.lastVideoCounters;

  @override
  Future<void> close() async {
    _state = TransportState.disconnected;
    _clientStateSub?.cancel();
    _clientStateSub = null;
    await _client.close();
  }

  @override
  Future<void> dispose() async {
    _clientStateSub?.cancel();
    await _client.dispose();
    await _stateController.close();
  }
}
