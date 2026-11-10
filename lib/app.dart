// opview app shell
// 主畫面（車型選擇 / 進入 opview / 顯示設定 / 裝置設定 / 離開）⇄ opview 畫面
// 顯示設定「打開 App 自動進入 opview」開啟時直接進 opview 畫面；opview 畫面「退出」或 Android 返回鍵回主畫面。
// 主畫面只搜尋 comma、讀寫車型（:5088），不建立 WebRTC；進入 opview 畫面才連 webrtcd（ConnectionManager.setStreaming）。

import 'dart:async';
import 'package:flutter/material.dart';

import 'services/parking/parking_startup.dart';
import 'services/parking/parking_system_ui.dart';

import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/selfdrive/ui/home/home_page.dart';
import 'package:opview/services/connection_manager.dart';
import 'package:opview/services/viewer_settings.dart';
import 'package:opview/services/stop_go_alerts.dart';
import 'package:opview/services/tdx/tdx_traffic_service.dart';
import 'package:opview/services/line_notifications.dart';
import 'package:opview/services/alert_sound.dart';
import 'package:opview/services/viewer_system.dart' as system;
import 'package:opview/selfdrive/ui/settings/op_settings_link.dart'
    show opSettingsGuardState;

class OpviewApp extends StatefulWidget {
  const OpviewApp({super.key});

  @override
  State<OpviewApp> createState() => _OpviewAppState();
}

class _OpviewAppState extends State<OpviewApp> with WidgetsBindingObserver {
  late final UIState _uiState;
  late final ConnectionManager _connectionManager;
  final _settings = ViewerSettings();
  bool _ready = false;
  bool _onHome = true;
  bool _streamPaused = false;
  bool? _pipOffered;
  StreamSubscription<StopGoKind>? _stopGoSub;
  int _lifecycleEpoch = 0;
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;
  bool _inBackground = false; // 背景執行中（保持連線、播放起步語音）
  bool? _bgWishSent;

  void _updatePipOffer() {
    // 主畫面不提供子母畫面（只在 opview 畫面）
    final want =
        !_onHome &&
        _uiState.isConnected &&
        _settings.pictureInPicture && // v23：PiP 已取消，load() 一律為 false

        !_streamPaused;
    if (want == _pipOffered) return;
    _pipOffered = want;
    system.setPipEnabled(want);
  }

  void _settingsChanged() {
    _uiState.isMetric = _settings.metric;
    _uiState.tdxEnabled = _settings.tdx;
    _syncTdx();
    LineNotifications.instance.setEnabled(_settings.lineNotify);
    _uiState.modernOverlay = _settings.layout != ViewerLayout.classic;
    _uiState.rainbowPath = _settings.rainbowPath;
    _uiState.hideHudCard = _settings.hideHudCard;
    StopGoAlerts.instance.configure(greenLight: _settings.greenLightAlert,
        leadDepart: _settings.leadDepartAlert, standstillTimer: _settings.standstillTimer);
    _syncBackgroundWish();
    prepareStopGoSounds(_settings.alertSound);
    _uiState.notifyNow();
    _updatePipOffer();
  }

  void _pipChanged() {
    // Closing a floating window may not emit another paused lifecycle event.
    if (!system.pipMode.value && _lifecycle == AppLifecycleState.paused) {
      final epoch = _lifecycleEpoch;
      // Expansion can report PiP=false just before resumed. Give that transition
      // time to complete instead of tearing down a healthy connection.
      Future<void>.delayed(const Duration(milliseconds: 250), () {
        if (mounted &&
            epoch == _lifecycleEpoch &&
            !system.pipMode.value &&
            _lifecycle == AppLifecycleState.paused) {
          if (!_inBackground) _pauseStream();
        }
      });
    }
  }

  // ---- 背景執行（保留綠燈起步 / 前車起步語音）----
  // 條件：顯示設定「背景執行」開啟、在 opview 畫面、前車或綠燈起步偵測至少一項開啟、聲音不是靜音。
  // 符合時離開 App 不中斷連線（不呼叫 _pauseStream），Android 端啟動前景服務避免被系統凍結；
  // 不符合時維持原行為：離開 App 就暫停串流，回來再重連。
  bool get _wantBackground =>
      _settings.backgroundRun &&
      !_onHome &&
      (_settings.greenLightAlert || _settings.leadDepartAlert) &&
      _settings.alertSound != AlertSoundMode.mute;

  void _syncBackgroundWish() {
    final want = _wantBackground;
    if (want == _bgWishSent) return;
    _bgWishSent = want;
    system.setBackgroundKeepAlive(want);
  }

  void _enterBackground() {
    if (_inBackground) return;
    _inBackground = true;
    _connectionManager.backgroundMode = true;
    debugPrint('[opview] 背景執行：保持連線，綠燈起步 / 前車起步照常播放語音');
  }

  void _leaveBackground() {
    if (!_inBackground) return;
    _inBackground = false;
    _connectionManager.backgroundMode = false;
    debugPrint('[opview] 背景執行結束：回到前景');
  }

  // TDX 路況（手機內建）：只在 opview 畫面、TDX 開啟、串流沒暫停時抓（見 tdx_traffic_service.dart）
  void _syncTdx() => TdxTrafficService.instance
      .setActive(_ready && _settings.tdx && !_onHome && !_streamPaused, _uiState);

  void _pauseStream() {
    if (_streamPaused) return;
    _streamPaused = true;
    _syncTdx();
    _connectionManager.pause();
    _updatePipOffer();
  }

  void _goHome() {
    if (_onHome) return;
    debugPrint('[opview] → home');
    setState(() => _onHome = true);
    _connectionManager.setStreaming(false);
    _syncTdx();
    _syncBackgroundWish();
    _updatePipOffer();
  }

  void _enterOpview() {
    if (!_onHome) return;
    debugPrint('[opview] → opview view');
    setState(() => _onHome = false);
    _connectionManager.setStreaming(true);
    _syncTdx();
    _syncBackgroundWish();
    _updatePipOffer();
  }

  Future<void> _loadSettings() async {
    await _settings.load();
    _onHome = !_settings.autoEnterOpview;
    _connectionManager.setStreaming(!_onHome);
    _syncBackgroundWish();
    if (mounted) setState(() => _ready = true);
    _syncTdx();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _uiState = UIState();
    opSettingsGuardState = _uiState; // 裝置設定只允許 offroad 或 P 檔
    _connectionManager = ConnectionManager(_uiState);
    system.listenForPip();
    system.pipMode.addListener(_pipChanged);
    _settings.addListener(_settingsChanged);
    _uiState.addListener(_updatePipOffer);
    _updatePipOffer();
    _loadSettings();
    _connectionManager.start();
    // 前車起步 / 綠燈起步：聲音在直向、橫向都播放
    _stopGoSub = StopGoAlerts.instance.events.listen((k) => playStopGoSound(k, _settings.alertSound));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ParkingStartup.instance.start();
    });
  }

  @override
  void dispose() {
    _stopGoSub?.cancel();
    system.setBackgroundKeepAlive(false);
    WidgetsBinding.instance.removeObserver(this);
    ParkingStartup.instance.stop();
    TdxTrafficService.instance.setActive(false, _uiState);
    _lifecycleEpoch++;
    _uiState.removeListener(_updatePipOffer);
    _settings.removeListener(_settingsChanged);
    system.pipMode.removeListener(_pipChanged);
    system.setPipEnabled(false);
    system.stopListeningForPip();
    _settings.dispose();
    // async cleanup — best-effort, State.dispose() is sync
    _connectionManager.dispose();
    _uiState.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint('[opview] lifecycle ${state.name}');
    if (state == AppLifecycleState.resumed) {
      ParkingStartup.instance.foreground(true);
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      ParkingStartup.instance.foreground(false);
    }
    _lifecycle = state;
    final epoch = ++_lifecycleEpoch;
    if (state == AppLifecycleState.resumed) _leaveBackground();
    if (state == AppLifecycleState.resumed && _streamPaused) {
      _streamPaused = false;
      _syncTdx();
      _connectionManager.reconnect(automatic: true);
      _updatePipOffer();
    } else if (state == AppLifecycleState.paused) {
      if (_wantBackground) {
        _enterBackground();
        return;
      }
      // Query native state to avoid racing the PiP callback while entering PiP.
      system.isInPip().then((pip) {
        if (!mounted || epoch != _lifecycleEpoch) return;
        if (!pip) _pauseStream();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'opview',
      debugShowCheckedModeBanner: false,
      // 主畫面、直向 opview 畫面顯示狀態列（電量 / 訊號 / 時間）；橫向、全螢幕、子母畫面隱藏
      builder: (context, child) => ValueListenableBuilder<bool>(
        valueListenable: system.pipMode,
        builder: (context, pip, _) =>
            _SystemUiSync(onHome: _onHome, pip: pip, child: child!),
      ),
      theme: ThemeData.dark(
        useMaterial3: true,
      ).copyWith(scaffoldBackgroundColor: Colors.black),
      home: !_ready
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : _onHome
          ? HomePage(
              settings: _settings,
              hostGetter: () => _connectionManager.lastKnownHost,
              onHostUnreachable: _connectionManager.refreshHost,
              onEnterOpview: _enterOpview,
            )
          // opview 畫面：Android 返回鍵回主畫面（不直接關 App）
          : PopScope(
              canPop: false,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop) _goHome();
              },
              child: ListenableBuilder(
                listenable: Listenable.merge([
                  _uiState,
                  _settings,
                  system.pipMode,
                  system.pipSupported,
                  _connectionManager.rendererChanges,
                ]),
                builder: (context, _) => AugmentedRoadView(
                  settings: _settings,
                  pip: system.pipMode.value,
                  uiState: _uiState,
                  videoRenderer: _connectionManager.videoRenderer,
                  opHost: () => _connectionManager.lastKnownHost,
                  onExit: _goHome,
                  onReconnect: () => _connectionManager.reconnect(),
                ),
              ),
            ),
    );
  }
}

/// 依目前畫面決定是否顯示狀態列：主畫面一律顯示；opview 畫面只有直向顯示
/// （點「全螢幕」會鎖定橫向，所以全螢幕時自然隱藏）；子母畫面隱藏。
class _SystemUiSync extends StatelessWidget {
  final bool onHome, pip;
  final Widget child;
  const _SystemUiSync({
    required this.onHome,
    required this.pip,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final portrait = size.height > size.width;
    final show = !pip && (onHome || portrait);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => setParkingAppStatusBarVisible(show),
    );
    return child;
  }
}
