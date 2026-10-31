import 'package:flutter/services.dart';

/// Self-contained status-bar control for app.dart, including older opview hosts
/// whose viewer_system.dart does not expose setStatusBarVisible.
bool? _applied;
Future<void>? _pending;
bool _wanted = false;

Future<void> setParkingAppStatusBarVisible(bool show) {
  _wanted = show;
  return _pending ??= _apply().whenComplete(() => _pending = null);
}

Future<void> _apply() async {
  try {
    while (_applied != _wanted) {
      final target = _wanted;
      await SystemChrome.setEnabledSystemUIMode(
        target ? SystemUiMode.manual : SystemUiMode.immersiveSticky,
        overlays: target ? const [SystemUiOverlay.top] : const [],
      );
      if (target) {
        SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
      }
      _applied = target;
    }
  } on PlatformException {
    _applied = null;
  } on MissingPluginException {
    _applied = null;
  }
}
