// WebRTC client — PeerConnection, data channel, H264 preference
// ported from dashy web/src/js/core/webrtc.js
//
// creates a recvonly video connection with a data channel.
// H264 preferred for hardware decode on mobile.
// exposes video renderer + raw data stream.

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:opview/services/transport.dart' show VideoCounters;
import 'package:opview/system/webrtc/webrtcd_api.dart';
import 'package:opview/system/webrtc/lifecycle_queue.dart';

class WebRTCClient {
  RTCPeerConnection? _pc;
  RTCDataChannel? _dataChannel;
  final ValueNotifier<RTCVideoRenderer?> renderer = ValueNotifier(null);
  RTCVideoRenderer? get videoRenderer => renderer.value;
  final _lifecycle = LifecycleQueue();
  bool _disposed = false;

  Future<void> _serial(Future<void> Function() operation) => _lifecycle.run(operation);
  int _connectGen = 0; // generation counter — stale connects bail out

  // data channel messages as a stream
  final _dataController = StreamController<String>.broadcast();
  Stream<String> get dataStream => _dataController.stream;

  // connection state
  final _stateController = StreamController<RTCPeerConnectionState>.broadcast();
  Stream<RTCPeerConnectionState> get stateStream => _stateController.stream;

  /// Counters belong to the current PeerConnection only.
  VideoCounters? lastVideoCounters;

  Future<void> connect(String host, {String camera = 'road'}) {
    final gen = ++_connectGen;
    return _serial(() async {
      if (_disposed || gen != _connectGen) return;
      await _cleanup();
      if (_disposed || gen != _connectGen) return;
      try {
        await _connect(host, camera, gen);
      } catch (_) {
        await _cleanup();
        rethrow;
      }
    });
  }

  Future<void> _connect(String host, String camera, int gen) async {
    // 影像 renderer（Flutter 畫布）等 webrtcd 回應 answer 後才建立：
    // comma 沒開 webrtcd（Connection refused）時的重試不會一直建立 / 釋放畫布。
    RTCVideoRenderer? output;
    MediaStream? pendingStream; // onTrack 若早於 renderer 建立，先暫存

    // create peer connection — no ICE servers needed for LAN
    _pc = await createPeerConnection({'iceServers': []});
    if (gen != _connectGen) return;

    // data channel for cereal messages
    _dataChannel = await _pc!.createDataChannel('data', RTCDataChannelInit());
    if (gen != _connectGen) return;
    _setupDataChannel(_dataChannel!, gen);

    // also handle server-created data channel (fallback)
    _pc!.onDataChannel = (channel) {
      if (gen != _connectGen) return;
      _dataChannel = channel;
      _setupDataChannel(channel, gen);
    };

    // video: recvonly
    _pc!.onTrack = (event) {
      if (gen != _connectGen) return;
      debugPrint('[opview] webrtc track ${event.track.kind} (streams: ${event.streams.length})');
      if (event.track.kind == 'video' && event.streams.isNotEmpty) {
        final o = output;
        if (o != null) {
          o.srcObject = event.streams[0];
        } else {
          pendingStream = event.streams[0];
        }
      }
    };

    // connection state changes — ignore if superseded
    _pc!.onConnectionState = (state) {
      if (gen != _connectGen) return;
      debugPrint('[opview] webrtc pc ${state.name}');
      _stateController.add(state);
    };
    _pc!.onIceConnectionState = (state) {
      if (gen == _connectGen) debugPrint('[opview] webrtc ice ${state.name}');
    };
    // 手機端 ICE 候選位址（判斷熱點介面有沒有被 WebRTC 使用）
    _pc!.onIceCandidate = (c) {
      if (gen != _connectGen) return;
      final s = c.candidate ?? '';
      final m = RegExp(r'candidate:\S+ \d+ (\w+) \d+ (\S+) (\d+) typ (\w+)').firstMatch(s);
      debugPrint('[opview] ice local ${m == null ? s : '${m.group(4)} ${m.group(2)}:${m.group(3)}/${m.group(1)}'}');
    };

    // add recvonly video transceiver
    await _pc!.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );

    if (gen != _connectGen) return;

    // create offer, prefer H264
    final offer = await _pc!.createOffer();
    if (gen != _connectGen) return;
    offer.sdp = preferH264(offer.sdp!);
    await _pc!.setLocalDescription(offer);
    if (gen != _connectGen) return;

    // exchange SDP with webrtcd
    final answer = await postStream(host, offer.sdp!, camera: camera);
    if (gen != _connectGen) return;
    debugPrint('[opview] webrtc answer received');

    final r = RTCVideoRenderer();
    await r.initialize();
    if (gen != _connectGen) {
      await r.dispose();
      return;
    }
    output = r;
    renderer.value = r; // _cleanup() 由 renderer.value 取得並釋放
    r.onResize = () {
      if (gen != _connectGen) return;
      debugPrint('[opview] video texture=${r.textureId} ${r.videoWidth}x${r.videoHeight}');
    };
    debugPrint('[opview] new video renderer texture=${r.textureId} generation=$gen');

    await _pc!.setRemoteDescription(
      RTCSessionDescription(answer['sdp'] as String, answer['type'] as String),
    );
    if (gen != _connectGen) return;
    final early = pendingStream;
    if (early != null && r.srcObject == null) r.srcObject = early;
  }

  /// WebRTC 統計摘要（log 用）：實際使用的網路位址、影像收包/解碼數
  Future<String?> statsSummary() async {
    final pc = _pc;
    if (pc == null) return null;
    try {
      final reports = await pc.getStats();
      if (!identical(pc, _pc)) return null;
      lastVideoCounters = null;
      final byId = {for (final r in reports) r.id: r};
      String? pair;
      String? video;
      double? rtt;
      for (final r in reports) {
        final v = r.values;
        if (r.type == 'candidate-pair' && (v['nominated'] == true || v['nominated'] == 'true') &&
            '${v['state']}' == 'succeeded') {
          String ep(String? id) {
            final c = id == null ? null : byId[id]?.values;
            if (c == null) return '?';
            return '${c['candidateType'] ?? '?'} ${c['address'] ?? c['ip'] ?? '?'}:${c['port'] ?? '?'}'
                '${c['networkType'] != null ? ' ${c['networkType']}' : ''}';
          }
          final r0 = v['currentRoundTripTime'];
          rtt = r0 is num ? r0.toDouble() : double.tryParse('$r0');
          pair = 'pair ${ep(v['localCandidateId']?.toString())} -> ${ep(v['remoteCandidateId']?.toString())}'
              ' rtt=${v['currentRoundTripTime'] ?? '?'}';
        }
        if (r.type == 'inbound-rtp' && ('${v['kind'] ?? v['mediaType']}' == 'video')) {
          int n(String k) => (v[k] is num) ? (v[k] as num).toInt() : int.tryParse('${v[k]}') ?? 0;
          double d(String k) => (v[k] is num) ? (v[k] as num).toDouble() : double.tryParse('${v[k]}') ?? 0;
          final dec = n('framesDecoded');
          final emitted = n('jitterBufferEmittedCount');
          // 平均解碼時間 / 平均 jitter buffer 延遲（ms）：判斷是「解碼器慢」還是「緩衝等待」
          final decMs = dec > 0 ? (d('totalDecodeTime') / dec * 1000).toStringAsFixed(1) : '?';
          final jbMs = emitted > 0 ? (d('jitterBufferDelay') / emitted * 1000).toStringAsFixed(0) : '?';
          lastVideoCounters = VideoCounters(packets: n('packetsReceived'),
              framesReceived: n('framesReceived'), framesDecoded: dec, framesDropped: n('framesDropped'),
              jitterDelaySec: d('jitterBufferDelay'), jitterEmitted: emitted, decodeSec: d('totalDecodeTime'));
          video = 'video rx=${v['bytesReceived'] ?? '?'}B pkts=${v['packetsReceived'] ?? '?'} lost=${v['packetsLost'] ?? '?'}'
              ' frames rx=${v['framesReceived'] ?? '?'} dec=$dec drop=${v['framesDropped'] ?? '?'}'
              ' ${v['frameWidth'] ?? '?'}x${v['frameHeight'] ?? '?'} kf=${v['keyFramesDecoded'] ?? '?'}'
              ' fps=${v['framesPerSecond'] ?? '?'} decMs=$decMs jbMs=$jbMs'
              ' nack=${v['nackCount'] ?? '?'} pli=${v['pliCount'] ?? '?'} fir=${v['firCount'] ?? '?'}'
              ' freeze=${v['freezeCount'] ?? '?'}/${v['totalFreezesDuration'] ?? '?'}s'
              ' dec=${v['decoderImplementation'] ?? '?'}';
        }
      }
      // RTT 來自 candidate-pair，可能在 inbound-rtp 之後才讀到 → 最後補進計數
      final c = lastVideoCounters;
      if (c != null && rtt != null) {
        lastVideoCounters = VideoCounters(packets: c.packets, framesReceived: c.framesReceived,
            framesDecoded: c.framesDecoded, framesDropped: c.framesDropped,
            jitterDelaySec: c.jitterDelaySec, jitterEmitted: c.jitterEmitted, decodeSec: c.decodeSec,
            rttSec: rtt);
      }
      return '${pair ?? 'pair (none succeeded)'} | ${video ?? 'video (no inbound-rtp)'}';
    } catch (e) {
      return 'stats failed: $e';
    }
  }

  Future<bool> sendControl(String type, Map<String, dynamic> data) async {
    final dc = _dataChannel;
    if (dc == null || dc.state != RTCDataChannelState.RTCDataChannelOpen) return false;
    try {
      await dc.send(RTCDataChannelMessage(jsonEncode({'type': type, 'data': data})));
      return identical(dc, _dataChannel);
    } catch (e) {
      debugPrint('[opview] control $type failed: $e');
      return false;
    }
  }

  Future<void> close() {
    _connectGen++;
    return _serial(_cleanup);
  }

  void _setupDataChannel(RTCDataChannel dc, int gen) {
    dc.onDataChannelState = (s) {
      if (gen != _connectGen) return;
      debugPrint('[opview] data channel ${dc.label} ${s.name}');
    };
    dc.onMessage = (msg) {
      if (gen != _connectGen || _disposed) return;
      try {
        final text = msg.isBinary ? utf8.decode(msg.binary) : msg.text;
        if (text.isNotEmpty) _dataController.add(text);
      } catch (_) {}
    };
  }

  Future<void> _cleanup() async {
    final pc = _pc;
    final dc = _dataChannel;
    final output = renderer.value;
    _pc = null;
    _dataChannel = null;
    lastVideoCounters = null;
    renderer.value = null;
    // Detach the native sink before destroying its peer and surface.
    try {
      if (output != null) await output.setSrcObject(stream: null);
    } finally {
      try {
        await dc?.close();
      } finally {
        try {
          await pc?.close();
        } finally {
          try {
            await pc?.dispose();
          } finally {
            await output?.dispose();
          }
        }
      }
    }
  }

  Future<void> dispose() {
    _disposed = true;
    _connectGen++;
    return _serial(() async {
      await _cleanup();
      renderer.dispose();
      await _dataController.close();
      await _stateController.close();
    });
  }

}

// -- SDP rewriting (webrtc.js:302-337) --

/// reorder SDP to prefer H264 over VP8/VP9
String preferH264(String sdp) {
  final lines = sdp.split('\r\n');
  int mLineIndex = -1;
  final h264Payloads = <String>[];

  // find m=video line and H264 payload types
  for (int i = 0; i < lines.length; i++) {
    if (lines[i].startsWith('m=video')) {
      mLineIndex = i;
    } else if (lines[i].contains('H264/90000')) {
      final match = RegExp(r'a=rtpmap:(\d+) H264/90000').firstMatch(lines[i]);
      if (match != null) h264Payloads.add(match.group(1)!);
    }
  }

  if (mLineIndex == -1 || h264Payloads.isEmpty) return sdp;

  // find associated RTX payloads (apt= and rtpmap are on separate SDP lines)
  // step 1: collect all rtx payload types
  final rtxMap = <String, String>{}; // rtx payload → apt payload
  for (final line in lines) {
    final fmtp = RegExp(r'a=fmtp:(\d+) apt=(\d+)').firstMatch(line);
    if (fmtp != null) rtxMap[fmtp.group(1)!] = fmtp.group(2)!;
  }
  // step 2: keep only rtx payloads that point to our H264 payloads
  final rtxPayloads = <String>[];
  for (final entry in rtxMap.entries) {
    if (h264Payloads.contains(entry.value)) {
      // verify it's actually rtx/90000
      final isRtx = lines.any((l) => l.contains('a=rtpmap:${entry.key} rtx/90000'));
      if (isRtx) rtxPayloads.add(entry.key);
    }
  }

  // reorder m-line: H264 payloads first
  final allH264 = [...h264Payloads, ...rtxPayloads];
  final parts = lines[mLineIndex].split(' ');
  final others = parts.sublist(3).where((p) => !allH264.contains(p));
  lines[mLineIndex] = [...parts.sublist(0, 3), ...allH264, ...others].join(' ');

  return lines.join('\r\n');
}
