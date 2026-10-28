// libwebrtc 原生 log → opview log（可分享）
//
// 目的：找出硬體解碼器為什麼退回軟體解碼
//   （log 出現 dec=c2.android.avc.decoder (fallback from: c2.qti.avc.decoder)）。
// flutter_webrtc 在 PeerConnectionFactory.initialize 時用 setInjectableLogger 把 libwebrtc 的 Java / C++ log
// （AndroidVideoDecoder、VideoDecoderSoftwareFallbackWrapper 等）送到 Dart 的 NativeLogsListener。
// 這裡只收 warning 以上，並限流避免洗版：
//   - 與解碼 / 編解碼器 / 畫布相關的行：每 10 秒最多 60 行
//   - 其他 warning / error：每 10 秒最多 8 行
//   超出的行數會在下一個視窗開頭記一行「略過 N 行」。
//
// 必須在任何 WebRTC 呼叫之前（main() 一開始）呼叫 install()：log 等級只在 flutter_webrtc 第一次初始化時設定。

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show NativeLogsListener;
import 'package:logger/logger.dart';

class WebrtcNativeLog {
  WebrtcNativeLog._();

  static final _important = RegExp(
      r'decod|codec|fallback|h264|avc|mediacodec|c2\.|surface|egl|texture|frame',
      caseSensitive: false);
  static const _window = Duration(seconds: 10);
  static const _maxImportant = 60;
  static const _maxOther = 8;

  static final _clock = Stopwatch()..start();
  static Duration _windowStart = Duration.zero;
  static int _importantCount = 0, _otherCount = 0, _skipped = 0;
  static bool _installed = false;

  static void install() {
    if (_installed) return;
    _installed = true;
    NativeLogsListener.instance.setLogger(
      Logger(filter: _AllFilter(), printer: _PlainPrinter(), output: _Forward()),
      'warning',
    );
  }

  static void _handle(String line) {
    final now = _clock.elapsed;
    if (now - _windowStart >= _window) {
      if (_skipped > 0) debugPrint('[webrtc] (前 10 秒略過 $_skipped 行原生 log)');
      _windowStart = now;
      _importantCount = 0;
      _otherCount = 0;
      _skipped = 0;
    }
    final text = line.startsWith('webrtc: ') ? line.substring(8) : line;
    if (_important.hasMatch(text)) {
      if (_importantCount++ < _maxImportant) {
        debugPrint('[webrtc] ${text.trimRight()}');
        return;
      }
    } else if (_otherCount++ < _maxOther) {
      debugPrint('[webrtc] ${text.trimRight()}');
      return;
    }
    _skipped++;
  }
}

class _AllFilter extends LogFilter {
  @override
  bool shouldLog(LogEvent event) => true; // release 版也要記錄（預設 DevelopmentFilter 會全部濾掉）
}

class _PlainPrinter extends LogPrinter {
  @override
  List<String> log(LogEvent event) => ['${event.message}'];
}

class _Forward extends LogOutput {
  @override
  void output(OutputEvent event) {
    for (final l in event.lines) {
      WebrtcNativeLog._handle(l);
    }
  }
}
