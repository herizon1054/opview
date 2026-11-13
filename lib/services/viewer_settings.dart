import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'viewer_system.dart' as system;
import 'alert_sound.dart';

enum ViewerLayout { dashboard, classic, detailed }

class ViewerSettings extends ChangeNotifier {
  ViewerLayout layout = ViewerLayout.dashboard;
  bool metric = true;
  bool pictureInPicture = false;
  bool tdx = true; // TDX 路況顯示（opview 手機內建抓取：前方車速 + 事件跑馬燈）
  bool autoFullscreen = false; // 連線後自動收起側欄
  bool autoEnterOpview = false; // 打開 App 直接進入 opview 畫面（跳過主畫面）
  // 停等與起步提醒（移植自 sunnypilot：LeadDepartAlert / GreenLightAlert / StandstillTimer）
  bool leadDepartAlert = false;
  bool greenLightAlert = false;
  bool standstillTimer = false;
  AlertSoundMode alertSound = AlertSoundMode.mute; // 預設靜音
  bool backgroundRun = true; // 背景執行：離開 App 時保留起步語音（見 app.dart _wantBackground）
  bool lineNotify = false; // 直向下方顯示 LINE 通知（需通知存取權）
  bool rainbowPath = false; // 彩虹模式：儀表介面的行駛路徑改為流動彩虹色
  bool hideHudCard = false; // 儀表介面不顯示儀表卡片（直向空間讓給 LINE / 停車）
  bool tdxDropBeep = true; // 國道車速驟降嗶聲（TDX：前方 2 公里內回堵，且比本車慢 40 km/h 以上）
  bool proximityAlert = false; // 近距離警示：20–60 km/h、低信心目標（0.2 ≤ 機率 < 0.5）在路徑 ±0.9 m、車頭 2 m（20 km/h）～3 m（60 km/h）內、連續 5 幀、30 秒內只嗶一次 → 箭頭 + 嗶一聲
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
    // v23：取消子母畫面（PiP）功能，一律關閉（舊設定忽略）
    pictureInPicture = false;
    tdx = prefs.getBool('viewer_tdx') ?? true;
    autoFullscreen = prefs.getBool('viewer_auto_fullscreen') ?? false;
    autoEnterOpview = prefs.getBool('viewer_auto_enter_opview') ?? false;
    leadDepartAlert = prefs.getBool('viewer_lead_depart_alert') ?? false;
    greenLightAlert = prefs.getBool('viewer_green_light_alert') ?? false;
    standstillTimer = prefs.getBool('viewer_standstill_timer') ?? false;
    final snd = prefs.getString('viewer_alert_sound');
    alertSound = AlertSoundMode.values.firstWhere((e) => e.name == snd, orElse: () => AlertSoundMode.mute);
    backgroundRun = prefs.getBool('viewer_background_run') ?? true;
    lineNotify = prefs.getBool('viewer_line_notify') ?? false;
    rainbowPath = prefs.getBool('viewer_rainbow_path') ?? false;
    hideHudCard = prefs.getBool('viewer_hide_hud_card') ?? false;
    proximityAlert = prefs.getBool('viewer_proximity_alert') ?? false;
    tdxDropBeep = prefs.getBool('viewer_tdx_drop_beep') ?? true;
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
  void setHideHudCard(bool value) {
    hideHudCard = value; _prefs?.setBool('viewer_hide_hud_card', value); notifyListeners();
  }
  void setTdxDropBeep(bool value) {
    tdxDropBeep = value; _prefs?.setBool('viewer_tdx_drop_beep', value); notifyListeners();
  }
  void setProximityAlert(bool value) {
    proximityAlert = value; _prefs?.setBool('viewer_proximity_alert', value); notifyListeners();
  }
  void setRainbowPath(bool value) {
    rainbowPath = value; _prefs?.setBool('viewer_rainbow_path', value); notifyListeners();
  }
  void setLineNotify(bool value) {
    lineNotify = value; _prefs?.setBool('viewer_line_notify', value); notifyListeners();
  }
  void setLeadDepartAlert(bool value) {
    leadDepartAlert = value; _prefs?.setBool('viewer_lead_depart_alert', value); notifyListeners();
  }
  void setGreenLightAlert(bool value) {
    greenLightAlert = value; _prefs?.setBool('viewer_green_light_alert', value); notifyListeners();
  }
  void setStandstillTimer(bool value) {
    standstillTimer = value; _prefs?.setBool('viewer_standstill_timer', value); notifyListeners();
  }
  void setAlertSound(AlertSoundMode value) {
    alertSound = value; _prefs?.setString('viewer_alert_sound', value.name); notifyListeners();
  }
  void setBackgroundRun(bool value) {
    backgroundRun = value; _prefs?.setBool('viewer_background_run', value); notifyListeners();
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
