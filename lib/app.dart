// opview app shell
// 主畫面（車型選擇 / 進入 opview / 顯示設定 / 裝置設定 / 離開）⇄ opview 畫面
// 顯示設定「打開 App 自動進入 opview」開啟時直接進 opview 畫面；opview 畫面「退出」或 Android 返回鍵回主畫面。
// 主畫面只搜尋 comma、讀寫車型（:5088），不建立 WebRTC；進入 opview 畫面才連 webrtcd（ConnectionManager.setStreaming）。

import 'package:flutter/material.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/selfdrive/ui/home/home_page.dart';
import 'package:opview/services/connection_manager.dart';
import 'package:opview/services/viewer_settings.dart';
import 'package:opview/services/line_notifications.dart';
import 'package:opview/services/viewer_system.dart' as system;
import 'package:opview/selfdrive/ui/settings/op_settings_link.dart' show opSettingsGuardState;

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
  int _lifecycleEpoch = 0;
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;

  void _updatePipOffer() {
    // 主畫面不提供子母畫面（只在 opview 畫面）
    final want = !_onHome && _uiState.isConnected && _settings.pictureInPicture && !_streamPaused;
    if (want == _pipOffered) return;
    _pipOffered = want;
    system.setPipEnabled(want);
  }
  void _settingsChanged() {
    _uiState.isMetric = _settings.metric;
    _uiState.tdxEnabled = _settings.tdx;
    _uiState.modernOverlay = _settings.layout != ViewerLayout.classic;
    LineNotifications.instance.setEnabled(_settings.lineNotify);
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
        if (mounted && epoch == _lifecycleEpoch && !system.pipMode.value &&
            _lifecycle == AppLifecycleState.paused) {
          _pauseStream();
        }
      });
    }
  }
  void _pauseStream() {
    if (_streamPaused) return;
    _streamPaused = true;
    _connectionManager.pause();
    _updatePipOffer();
  }
  void _goHome() {
    if (_onHome) return;
    debugPrint('[opview] → home');
    setState(() => _onHome = true);
    _connectionManager.setStreaming(false);
    _updatePipOffer();
  }
  void _enterOpview() {
    if (!_onHome) return;
    debugPrint('[opview] → opview view');
    setState(() => _onHome = false);
    _connectionManager.setStreaming(true);
    _updatePipOffer();
  }
  Future<void> _loadSettings() async {
    await _settings.load();
    _onHome = !_settings.autoEnterOpview;
    _connectionManager.setStreaming(!_onHome);
    if (mounted) setState(() => _ready = true);
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
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
    _lifecycle = state;
    final epoch = ++_lifecycleEpoch;
    if (state == AppLifecycleState.resumed && _streamPaused) {
      _streamPaused = false;
      _connectionManager.reconnect(automatic: true);
      _updatePipOffer();
    } else if (state == AppLifecycleState.paused) {
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
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: Colors.black,
      ),
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
                  onPopInvokedWithResult: (didPop, _) { if (!didPop) _goHome(); },
                  child: ListenableBuilder(
                    listenable: Listenable.merge([_uiState, _settings, system.pipMode, system.pipSupported, _connectionManager.rendererChanges]),
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
