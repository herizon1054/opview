// opview app shell
// dark theme, single screen, no navigation needed

import 'package:flutter/material.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/selfdrive/ui/onroad/augmented_road_view.dart';
import 'package:opview/services/connection_manager.dart';
import 'package:opview/services/viewer_settings.dart';
import 'package:opview/services/viewer_system.dart' as system;

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
  bool _streamPaused = false;
  bool? _pipOffered;
  int _lifecycleEpoch = 0;
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;

  void _updatePipOffer() {
    final want = _uiState.isConnected && _settings.pictureInPicture && !_streamPaused;
    if (want == _pipOffered) return;
    _pipOffered = want;
    system.setPipEnabled(want);
  }
  void _settingsChanged() {
    _uiState.isMetric = _settings.metric;
    _uiState.modernOverlay = _settings.layout != ViewerLayout.classic;
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
            _lifecycle == AppLifecycleState.paused) _pauseStream();
      });
    }
  }
  void _pauseStream() {
    if (_streamPaused) return;
    _streamPaused = true;
    _connectionManager.pause();
    _updatePipOffer();
  }
  Future<void> _loadSettings() async {
    await _settings.load();
    if (mounted) setState(() => _ready = true);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _uiState = UIState();
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
    _lifecycle = state;
    final epoch = ++_lifecycleEpoch;
    if (state == AppLifecycleState.resumed && _streamPaused) {
      _streamPaused = false;
      _connectionManager.reconnect();
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
      home: ListenableBuilder(
        listenable: Listenable.merge([_uiState, _settings, system.pipMode, system.pipSupported]),
        builder: (context, _) => !_ready
            ? const Scaffold(body: Center(child: CircularProgressIndicator()))
            : AugmentedRoadView(
          settings: _settings,
          pip: system.pipMode.value,
          uiState: _uiState,
          videoRenderer: _connectionManager.videoRenderer,
        ),
      ),
    );
  }
}
