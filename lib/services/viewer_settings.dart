import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'viewer_system.dart' as system;

enum ViewerLayout { dashboard, classic, detailed }

class ViewerSettings extends ChangeNotifier {
  ViewerLayout layout = ViewerLayout.dashboard;
  bool metric = true;
  bool pictureInPicture = false;
  bool tdx = true; // dplcc TDX 路況顯示（前方車速 + 事件跑馬燈）
  bool autoFullscreen = false; // 連線後自動收起側欄
  bool autoEnterOpview = false; // 打開 App 直接進入 opview 畫面（跳過主畫面）
  double? brightness;
  int hudEvery = 4; // HUD ~5 Hz when modelV2 is 20 Hz; path and alerts unchanged.
  SharedPreferences? _prefs;
  bool _disposed = false;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    if (_disposed) return;
    _prefs = prefs;
    final name = prefs.getString('viewer_layout');
    layout = ViewerLayout.values.firstWhere((e) => e.name == name, orElse: () => ViewerLayout.dashboard);
    metric = prefs.getBool('viewer_metric') ?? true;
    pictureInPicture = prefs.getBool('viewer_pip') ?? false;
    tdx = prefs.getBool('viewer_tdx') ?? true;
    autoFullscreen = prefs.getBool('viewer_auto_fullscreen') ?? false;
    autoEnterOpview = prefs.getBool('viewer_auto_enter_opview') ?? false;
    final b = prefs.getDouble('viewer_brightness');
    brightness = b != null && b.isFinite && b >= 0 ? b.clamp(.05, 1.0).toDouble() : null;
    hudEvery = prefs.getInt('viewer_hud_every') == 1 ? 1 : 4;
    await system.setAppBrightness(brightness);
    if (!_disposed) notifyListeners();
  }
  void setLayout(ViewerLayout value) {
    layout = value; _prefs?.setString('viewer_layout', value.name); notifyListeners();
  }
  void setMetric(bool value) {
    metric = value; _prefs?.setBool('viewer_metric', value); notifyListeners();
  }
  void setTdx(bool value) {
    tdx = value; _prefs?.setBool('viewer_tdx', value); notifyListeners();
  }
  void setAutoFullscreen(bool value) {
    autoFullscreen = value; _prefs?.setBool('viewer_auto_fullscreen', value); notifyListeners();
  }
  void setAutoEnterOpview(bool value) {
    autoEnterOpview = value; _prefs?.setBool('viewer_auto_enter_opview', value); notifyListeners();
  }
  void setPip(bool value) {
    pictureInPicture = value; _prefs?.setBool('viewer_pip', value); notifyListeners();
  }
  void setBrightness(double? value) {
    brightness = value == null || !value.isFinite ? null : value.clamp(.05, 1.0).toDouble();
    system.setAppBrightness(brightness);
    _prefs?.setDouble('viewer_brightness', brightness ?? -1);
    notifyListeners();
  }
  void setHudEvery(int value) {
    hudEvery = value == 1 ? 1 : 4;
    _prefs?.setInt('viewer_hud_every', hudEvery); notifyListeners();
  }
  @override
  void dispose() { _disposed = true; super.dispose(); }
}
