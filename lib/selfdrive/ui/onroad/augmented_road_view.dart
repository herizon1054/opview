// augmented road view — the main onroad screen
// ported from openpilot selfdrive/ui/onroad/augmented_road_view.py
// + dashy augmented_road_view.js for video-scale-aware calibration
//
// layer stack (matches stock render order):
//   0. RTCVideoView (BoxFit.cover)
//   1. ClipRect -> ModelRenderer + HudRenderer + AlertRenderer
//   2. EngagementBorder (on top of everything)

import 'dart:math';
import 'dart:async';
import 'dashboard_hud.dart';
import 'portrait_panel.dart';
import 'compact_hud.dart';
import 'throttled_hud.dart';
import 'tdx_marquee.dart';
import 'blindspot_glow.dart';
import 'vehicle_details.dart';
import '../settings/viewer_settings_dialog.dart';
import 'package:opview/services/viewer_settings.dart';
import 'package:opview/services/viewer_system.dart' as system;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:opview/common/transformations.dart';
import 'package:opview/selfdrive/ui/ui_state.dart';
import 'package:opview/selfdrive/ui/onroad/model_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/hud_renderer.dart';
import 'package:opview/selfdrive/ui/onroad/alert_renderer.dart';

// -- border colors (augmented_road_view.py:23-27) --

const borderColors = {
  UIStatus.disengaged: Color(0xFF122839),
  UIStatus.override_: Color(0xFF89928D),
  UIStatus.engaged: Color(0xFF167F40),
};

class AugmentedRoadView extends StatefulWidget {
  final UIState uiState;
  final RTCVideoRenderer? videoRenderer;
  final bool initialRailVisible;
  final bool showControls;
  final ViewerSettings? settings;
  final bool pip;
  /// 取得 comma IP（傳給顯示設定的「OP 設定網頁」）
  final String? Function()? opHost;
  /// 退出到主畫面；null = 不顯示「退出」
  final VoidCallback? onExit;
  final VoidCallback? onReconnect;

  const AugmentedRoadView({
    super.key,
    required this.uiState,
    this.videoRenderer,
    this.initialRailVisible = true,
    this.showControls = true,
    this.settings,
    this.pip = false,
    this.opHost,
    this.onExit,
    this.onReconnect,
  });

  @override
  State<AugmentedRoadView> createState() => _AugmentedRoadViewState();
}

class _AugmentedRoadViewState extends State<AugmentedRoadView> {
  late bool _showRail;
  bool _showDetails = false;
  Timer? _freshnessTimer;

  // -- 自動進入全螢幕（顯示設定）--
  // 連線（false→true）或剛開啟此設定時排程；畫面資料開始更新後倒數 3 秒收起側欄。
  // 使用者在倒數期間點了側欄任何按鈕就取消；手動叫回側欄後不再自動收起，直到下次連線。
  static const autoFullscreenDelay = Duration(seconds: 3);
  Timer? _autoFsTimer;
  bool _autoFsArmed = false;
  bool _wasConnected = false;
  bool _wasAutoFs = false;

  bool get _autoFsSetting => widget.settings?.autoFullscreen == true;

  void _checkAutoFullscreen() {
    final connected = widget.uiState.isConnected;
    final enabled = _autoFsSetting && widget.showControls && !widget.pip;
    if (!connected || !enabled) {
      _cancelAutoFullscreen();
    } else if (!_wasConnected || !_wasAutoFs) {
      _autoFsArmed = true;  // 新連線或剛打開設定
    }
    _wasConnected = connected;
    _wasAutoFs = enabled;
    // 等到真的有畫面資料（非 stale）才開始倒數，避免還在 Connecting 就收起
    if (_autoFsArmed && _autoFsTimer == null && !_stale && _showRail) {
      _autoFsTimer = Timer(autoFullscreenDelay, _autoFullscreenFire);
    }
  }

  void _autoFullscreenFire() {
    _autoFsTimer = null;
    if (!mounted || !_autoFsArmed) return;
    if (!widget.uiState.isConnected || !_autoFsSetting || !_showRail) { _autoFsArmed = false; return; }
    // 顯示設定對話框還開著 → 等關掉再重新倒數
    if (ModalRoute.of(context)?.isCurrent == false) {
      _autoFsTimer = Timer(autoFullscreenDelay, _autoFullscreenFire);
      return;
    }
    _autoFsArmed = false;
    _enterFullscreen();
  }

  void _cancelAutoFullscreen() {
    _autoFsTimer?.cancel();
    _autoFsTimer = null;
    _autoFsArmed = false;
  }

  @override
  void didUpdateWidget(AugmentedRoadView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _checkAutoFullscreen();
  }
  bool get _stale => !widget.uiState.isConnected || widget.uiState.dataLagging ||
      (widget.uiState.lastModelAt == null || DateTime.now()
        .difference(widget.uiState.lastModelAt!).inMilliseconds > 2000);

  @override
  void initState() {
    super.initState();
    _showRail = widget.initialRailVisible;
    // Watchdog runs on the phone, with no polling or network requests.
    _freshnessTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _stale) setState(() {});
    });
    _checkAutoFullscreen();
  }

  @override
  void dispose() {
    _freshnessTimer?.cancel();
    _autoFsTimer?.cancel();
    super.dispose();
  }

  Future<void> _openSettings() async {
    if (widget.uiState.alertSize != 0) return;
    BuildContext? dialogContext;
    bool closing = false;
    void checkAlert() {
      if ((widget.uiState.alertSize == 0 && !system.pipMode.value) || closing || dialogContext == null) return;
      closing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = dialogContext;
        if (ctx != null && ctx.mounted) Navigator.of(ctx).pop();
      });
    }
    widget.uiState.addListener(checkAlert);
    system.pipMode.addListener(checkAlert);
    try {
      await showDialog<void>(context: context, builder: (ctx) {
        dialogContext = ctx;
        return ViewerSettingsDialog(settings: widget.settings!, opHost: widget.opHost);
      });
    } finally {
      dialogContext = null;
      widget.uiState.removeListener(checkAlert);
      system.pipMode.removeListener(checkAlert);
    }
  }

  // -- 側欄尺寸 --
  // 內容區寬度固定；左側瀏海 / 挖孔安全區另外加寬，不再從內容寬度裡扣
  static const double _railContentWidth = 88;
  // 按鈕高度依側欄可用高度自動分配：所有按鈕盡量一屏放下不用捲動。
  // 圖示 / 字級隨按鈕高度在 min~max 之間等比縮放；低於最小可點高度才改為捲動。
  static const double _railBtnMaxH = 62, _railBtnMinH = 44;
  static const double _railIconMax = 24, _railIconMin = 19;
  static const double _railFontMax = 13, _railFontMin = 11;
  static const double _railBtnGapV = 2;          // 按鈕上下間距（各邊）
  static const double _railHeaderH = 30;         // 頂部 LIVE / OFFLINE 區
  static const double _railFooterH = 6;

  // 單行；FittedBox 只當極端情況的保險，正常字級下不會縮
  static Widget _railLabel(String text, TextStyle style) => FittedBox(
    fit: BoxFit.scaleDown,
    child: Text(text, maxLines: 1, softWrap: false, style: style));

  Widget _railButton(_RailItem item, double height, double t) {
    final iconSize = _railIconMin + (_railIconMax - _railIconMin) * t;
    final fontSize = _railFontMin + (_railFontMax - _railFontMin) * t;
    return Padding(padding: const EdgeInsets.symmetric(vertical: _railBtnGapV, horizontal: 6),
      child: SizedBox(height: height, child: Material(
        color: const Color(0xFF182127), borderRadius: BorderRadius.circular(12 + 2 * t),
        clipBehavior: Clip.antiAlias,
        // 點任何側欄按鈕都視為使用者在操作，取消這次的自動全螢幕
        child: InkWell(onTap: () { _cancelAutoFullscreen(); item.onTap(); },
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(item.icon, color: dashboardTeal, size: iconSize),
              SizedBox(height: 2 + 2 * t),
              _railLabel(item.label, TextStyle(fontSize: fontSize, height: 1.15,
                  color: Colors.white70)),
            ]))),
      )));
  }

  void _enterFullscreen() {
    setState(() { _showRail = false; _showDetails = false; });
    // 系統列可能被手勢叫出後未收回，進全螢幕時重新套用 immersive
    system.reapplyImmersive();
  }

  List<_RailItem> _railItems() => [
    _RailItem(Icons.dashboard_outlined, widget.uiState.modernOverlay ? '儀表介面' : '原版介面', () {
      if (widget.settings != null) {
        widget.settings!.setLayout(widget.uiState.modernOverlay ? ViewerLayout.classic : ViewerLayout.dashboard);
      } else {
        setState(() { widget.uiState.modernOverlay = !widget.uiState.modernOverlay; });
      }
      widget.uiState.notifyNow();
    }),
    _RailItem(Icons.straighten, widget.uiState.isMetric ? 'km/h' : 'mph', () {
      if (widget.settings != null) {
        widget.settings!.setMetric(!widget.uiState.isMetric);
      } else {
        setState(() { widget.uiState.isMetric = !widget.uiState.isMetric; });
      }
      widget.uiState.notifyNow();
    }),
    // TDX 路況顯示開關已移到「顯示設定」
    if (widget.settings != null && widget.uiState.alertSize == 0)
      _RailItem(Icons.settings_outlined, '顯示設定', _openSettings),
    if (widget.settings?.pictureInPicture == true && system.pipSupported.value && widget.uiState.isConnected)
      _RailItem(Icons.picture_in_picture_alt, '子母畫面', () async {
        final entered = await system.enterPip();
        if (!entered && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Android 未允許進入子母畫面')));
        }
      }),
    _RailItem(Icons.fullscreen, '全螢幕', _enterFullscreen),
    if (widget.onExit != null)
      _RailItem(Icons.logout, '退出', widget.onExit!),
  ];

  // 系統字型放大最多跟到 1.2 倍：看得清楚，但不會撐爆固定寬度的側欄
  Widget _rail() {
    final mq = MediaQuery.of(context);
    final inset = mq.padding;
    final items = _railItems();
    return MediaQuery(
    data: mq.copyWith(textScaler: mq.textScaler.clamp(minScaleFactor: 1.0, maxScaleFactor: 1.2)),
    child: Container(width: _railContentWidth + inset.left, color: const Color(0xFF0D151B),
    padding: EdgeInsets.only(left: inset.left, top: inset.top, bottom: inset.bottom),
    child: LayoutBuilder(builder: (context, box) {
      final avail = box.maxHeight - _railHeaderH - _railFooterH;
      final slot = avail / items.length - 2 * _railBtnGapV;
      final h = slot.isFinite ? slot.clamp(_railBtnMinH, _railBtnMaxH).toDouble() : _railBtnMaxH;
      final t = (h - _railBtnMinH) / (_railBtnMaxH - _railBtnMinH);
      return SingleChildScrollView(child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(height: _railHeaderH, child: Center(child: _railLabel(
          widget.uiState.isConnected ? '● LIVE' : '○ OFFLINE',
          const TextStyle(color: dashboardTeal, fontSize: 11, fontWeight: FontWeight.bold)))),
        for (final item in items) _railButton(item, h, t),
        const SizedBox(height: _railFooterH),
      ]));
    })));
  }

  // 退出全螢幕按鈕：放在最外層 Stack 最上面，不會被邊框 / Connecting 遮罩吃掉點擊
  // 放右上角：左上角是儀表介面的 "opview" 標題，放那裡會蓋住
  Widget _exitFullscreenButton() => Positioned(top: 0, right: 0,
    child: SafeArea(left: false, bottom: false, child: Padding(
      padding: const EdgeInsets.all(10),
      child: Material(color: const Color(0xB3182127), shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: IconButton(
          tooltip: '顯示操作列', iconSize: 26,
          icon: const Icon(Icons.fullscreen_exit, color: dashboardTeal),
          onPressed: () { _cancelAutoFullscreen(); setState(() => _showRail = true); })))));

  // TDX 事件跑馬燈：畫面上方。儀表介面在左上 "opview" 標題右側；
  // 原版介面放在 header（目前車速 / MAX 框）下方，避免蓋到車速
  // TDX 路況事件：畫面上方置中小膠囊，最寬 60% 畫面寬（上限 420dp），超過才捲動。
  // 原版介面放在 header（車速 / MAX 框）下方。
  // events.py 的 alert 不在這裡，維持 stock AlertRenderer（small / mid 底部橫幅、full 全螢幕）。
  Widget _tdxMarquee(double scale, double screenW) {
    final modern = widget.uiState.modernOverlay;
    if (!widget.uiState.isConnected || widget.uiState.tdxEventText.isEmpty) {
      return const SizedBox.shrink();
    }
    return Positioned(
      top: modern ? 12 : 300 * scale + 6,
      left: 16, right: 16,
      child: IgnorePointer(child: RepaintBoundary(
        child: TdxMarquee(text: widget.uiState.tdxEventText,
          maxWidth: screenW * .6 < 420 ? screenW * .6 : 420))));
  }

  Widget _details() => Positioned(top: 50, bottom: 20, right: 16,
    child: Container(width: 270, padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: const Color(0xED10191D), borderRadius: BorderRadius.circular(18)),
      child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        const Text('連線資訊', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text('傳輸：WebRTC\n相機：${widget.uiState.streamType}\n裝置：${widget.uiState.deviceType.isEmpty ? "未知" : widget.uiState.deviceType}\n校正：${widget.uiState.calStatus}\n資料：${_stale ? "等待更新" : "接收中"}\n介面運算：手機端',
          style: const TextStyle(fontSize: 12, height: 1.6, color: Colors.white70)),
        const SizedBox(height: 8),
        ...widget.uiState.connectionLog.take(3).map((line) => Text(line,
          maxLines: 2, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 10, color: Colors.white54))),
      ]))));

  // cached transform inputs — only recompute when these change
  List<double> _cachedRpyCalib = [];
  List<double> _cachedWideFromDeviceEuler = [];
  String _cachedCalStatus = '';
  String _cachedDeviceType = '';
  String _cachedSensor = '';
  String _cachedStreamType = '';
  double _cachedScreenW = 0;
  double _cachedScreenH = 0;
  List<List<double>> _cachedTransform = [
    [0, 0, 0], [0, 0, 0], [0, 0, 0],
  ];

  /// 直向：操作列放到影像下方（橫向放左側）。PiP 小窗一律視為橫向。
  bool _isPortrait(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return !widget.pip && size.height > size.width;
  }

  @override
  Widget build(BuildContext context) {
    final portrait = _isPortrait(context);
    final showBar = _showRail && widget.showControls && !widget.pip;
    final videoStack = LayoutBuilder(builder: (context, constraints) {
        final screenW = constraints.maxWidth;
        final screenH = constraints.maxHeight;
        // HUD / 警示 / 邊框依「短邊」縮放：橫向 = 高（與原本相同），直向 = 寬（避免直向時被放大到超出寬度）
        final scale = min(screenW, screenH) / 1080.0;
        final borderSize = (widget.pip || widget.uiState.modernOverlay ? 3 : uiBorderSize) * scale;

        // recompute transform only when inputs change
        final transform = _getTransform(screenW, screenH);

        // content rect (inside border)
        final contentRect = Rect.fromLTWH(
          borderSize, borderSize,
          screenW - 2 * borderSize, screenH - 2 * borderSize,
        );

        return MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // layer 0 + 1a: video + model overlay
              _videoLayer(),
              if (!_stale) ClipRect(
                clipper: _ContentClipper(contentRect),
                child: CustomPaint(
                  size: Size(screenW, screenH),
                  painter: ModelRendererPainter(
                    state: widget.uiState,
                    carSpaceTransform: transform,
                    contentRect: contentRect,
                  ),
                ),
              ),

              // layer 1b: HUD + alerts — always visible
              // RepaintBoundary isolates widget rebuilds from the video/model layer
              Padding(
                padding: EdgeInsets.all(borderSize),
                child: RepaintBoundary(
                  child: ClipRect(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (widget.pip)
                          CompactHud(state: widget.uiState, stale: _stale)
                        else ...[
                          ThrottledHud(
                            version: widget.uiState.version,
                            every: widget.settings?.hudEvery ?? 4,
                            invalidateKey: (screenW, screenH, _stale, widget.uiState.isMetric,
                              widget.uiState.modernOverlay, widget.uiState.status,
                              widget.uiState.experimentalMode, widget.uiState.alertSize,
                              widget.uiState.leadDistance != null, widget.settings?.layout,
                              widget.uiState.tdxNextSpeedDisplay, widget.uiState.tdxCongestion,
                              widget.uiState.tdxEnabled,
                              widget.uiState.leftBlinker, widget.uiState.rightBlinker,
                              widget.uiState.gearShifter),
                            builder: () => Stack(fit: StackFit.expand, children: [
                              // 直向（方案 B）：儀表卡片與兩側方向燈都在影像下方的 PortraitPanel
                              if (widget.uiState.modernOverlay) ...[
                                if (!portrait) DashboardHud(state: widget.uiState, stale: _stale),
                              ] else if (!_stale) HudRenderer(uiState: widget.uiState, scale: scale),
                              if (widget.settings?.layout == ViewerLayout.detailed)
                                VehicleDetails(state: widget.uiState, stale: _stale),
                            ]),
                          ),
                        ],
                        if (!widget.pip && _showDetails && widget.uiState.alertSize == 0) _details(),
                        if (!widget.pip && !portrait) _tdxMarquee(scale, screenW),
                        // comma 事件（接管方向盤等 alert）：直向、橫向都貼在道路畫面底部。
                        // 直向影像只有約 244 dp 高，依短邊算的 scale 太小 → 改用寬度 / 1500（字約 16 sp），
                        // 且高度依字級決定（不用 stock 固定高度，避免蓋掉太多道路畫面）
                        if (!widget.pip) AlertRenderer(uiState: widget.uiState,
                          scale: portrait ? max(scale, screenW / 1500) : scale,
                          compact: widget.uiState.modernOverlay, fitHeight: portrait),
                      ],
                    ),
                  ),
                ),
              ),

              // layer 1c: 盲點邊緣光暈（從螢幕邊緣向內淡化）；盲點 + 同側方向燈 → 快閃
              if (!widget.pip && !_stale && widget.uiState.leftBlindspot)
                Positioned(left: borderSize, top: borderSize, bottom: borderSize,
                  child: IgnorePointer(child: BlindspotGlow(left: true,
                    fastBlink: widget.uiState.leftBlinker, width: screenW * .09))),
              if (!widget.pip && !_stale && widget.uiState.rightBlindspot)
                Positioned(right: borderSize, top: borderSize, bottom: borderSize,
                  child: IgnorePointer(child: BlindspotGlow(left: false,
                    fastBlink: widget.uiState.rightBlinker, width: screenW * .09))),

              // layer 2: engagement border — always visible
              // IgnorePointer: 無 child 的 CustomPaint 預設 hitTest 為 true，
              // 會吃掉整個畫面的點擊（原本退出全螢幕按鈕因此按不到）
              IgnorePointer(child: CustomPaint(
                size: Size(screenW, screenH),
                painter: _EngagementBorderPainter(
                  status: widget.uiState.status,
                  borderSize: borderSize,
                ),
              )),

              // layer 3: connecting overlay with rolling status log
              // Container(color:) 是 opaque hit test，同樣需讓點擊穿透
              if (!widget.pip && !widget.uiState.isConnected)
                IgnorePointer(child: Container(
                  color: const Color(0xCC000000),
                  alignment: Alignment.center,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Connecting…',
                        style: TextStyle(
                          color: const Color(0x99FFFFFF),
                          fontSize: 40 * scale,
                          fontWeight: FontWeight.w300,
                        ),
                      ),
                      SizedBox(height: 20 * scale),
                      ...widget.uiState.connectionLog.map((line) => Text(
                        line,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: const Color(0x66FFFFFF),
                          fontSize: 16 * scale,
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w300,
                        ),
                      )),
                    ],
                  ),
                )),

              if (!widget.pip && !widget.uiState.isConnected && widget.onReconnect != null)
                Positioned(
                  bottom: 24,
                  left: 24,
                  child: ElevatedButton.icon(
                    onPressed: widget.onReconnect,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重新連線'),
                  ),
                ),

              // layer 4: 退出全螢幕（永遠在最上層）
              if (!widget.pip && !_showRail && widget.showControls)
                _exitFullscreenButton(),
            ],
          ),
        );
      });
    if (!portrait) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (showBar) _rail(),
          Expanded(child: videoStack),
        ]),
      );
    }
    // 直向（方案 B）：影像依相機比例完整顯示在上方 → 儀表 / TDX / 警示區 → 操作列
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(bottom: false, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AspectRatio(aspectRatio: _videoAspect(), child: videoStack),
        Expanded(child: Padding(
          padding: EdgeInsets.only(bottom: showBar ? 0 : bottomInset),
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
            child: ThrottledHud(
              version: widget.uiState.version,
              every: widget.settings?.hudEvery ?? 4,
              invalidateKey: (_stale, widget.uiState.isMetric, widget.uiState.modernOverlay,
                widget.uiState.status, widget.uiState.experimentalMode,
                widget.uiState.alertSize, widget.uiState.alertText1, widget.uiState.leadDistance != null,
                widget.uiState.tdxNextSpeedDisplay, widget.uiState.tdxCongestion,
                widget.uiState.tdxEventText, widget.uiState.gearShifter,
                widget.uiState.leftBlinker, widget.uiState.rightBlinker,
                widget.settings?.lineNotify ?? false),
              builder: () => PortraitPanel(state: widget.uiState, stale: _stale,
                  lineEnabled: widget.settings?.lineNotify ?? false),
            ),
          ),
        )),
        if (showBar) _bottomBar(),
      ])),
    );
  }

  /// 直向影像區比例 = 目前串流相機（road / wideRoad）的原始比例，
  /// 影像以 cover 填入時剛好不裁切，投影（路徑、前車框）與畫面一致
  double _videoAspect() {
    final cam = _lookupCamera();
    final c = widget.uiState.streamType == 'wideRoad' ? cam.ecam : cam.fcam;
    return c.width > 0 && c.height > 0 ? c.width / c.height : 1928 / 1208;
  }

  // 直向操作列：畫面最下方一排按鈕（同側欄的按鈕與順序），左側小字顯示 LIVE / OFFLINE
  static const double _barHeight = 64;
  Widget _bottomBar() {
    final mq = MediaQuery.of(context);
    final inset = mq.padding;
    final items = _railItems();
    return MediaQuery(
      data: mq.copyWith(textScaler: mq.textScaler.clamp(minScaleFactor: 1.0, maxScaleFactor: 1.2)),
      child: Container(
        color: const Color(0xFF0D151B),
        padding: EdgeInsets.only(left: inset.left + 4, right: inset.right + 4, bottom: inset.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(height: 18, child: Center(child: _railLabel(
            widget.uiState.isConnected ? '● LIVE' : '○ OFFLINE',
            const TextStyle(color: dashboardTeal, fontSize: 10, fontWeight: FontWeight.bold)))),
          SizedBox(height: _barHeight, child: Row(children: [
            for (final item in items) Expanded(child: Padding(
              padding: const EdgeInsets.fromLTRB(2, 0, 2, 6),
              child: Material(
                color: const Color(0xFF182127), borderRadius: BorderRadius.circular(12),
                clipBehavior: Clip.antiAlias,
                child: InkWell(onTap: () { _cancelAutoFullscreen(); item.onTap(); },
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(item.icon, color: dashboardTeal, size: 20),
                    const SizedBox(height: 3),
                    Padding(padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: _railLabel(item.label, const TextStyle(fontSize: 11, height: 1.15, color: Colors.white70))),
                  ])),
              ),
            )),
          ])),
        ]),
      ),
    );
  }

  /// video layer: RTCVideoView with BoxFit.cover, or black placeholder
  Widget _videoLayer() {
    if (widget.videoRenderer == null) {
      return Container(color: Colors.black);
    }
    return RTCVideoView(
      widget.videoRenderer!,
      key: ObjectKey(widget.videoRenderer),
      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
    );
  }

  /// return cached transform, recompute only when inputs changed
  List<List<double>> _getTransform(double screenW, double screenH) {
    final st = widget.uiState;
    if (screenW == _cachedScreenW &&
        screenH == _cachedScreenH &&
        st.calStatus == _cachedCalStatus &&
        st.deviceType == _cachedDeviceType &&
        st.sensor == _cachedSensor &&
        st.streamType == _cachedStreamType &&
        listEquals(st.rpyCalib, _cachedRpyCalib) &&
        listEquals(st.wideFromDeviceEuler, _cachedWideFromDeviceEuler)) {
      return _cachedTransform;
    }

    _cachedScreenW = screenW;
    _cachedScreenH = screenH;
    _cachedCalStatus = st.calStatus;
    _cachedDeviceType = st.deviceType;
    _cachedSensor = st.sensor;
    _cachedStreamType = st.streamType;
    _cachedRpyCalib = List.of(st.rpyCalib);
    _cachedWideFromDeviceEuler = List.of(st.wideFromDeviceEuler);
    _cachedTransform = _calcFrameMatrix(screenW, screenH);
    return _cachedTransform;
  }

  /// compute the 3D->2D projection matrix
  /// ported from augmented_road_view.py:161-218 + dashy augmented_road_view.js
  List<List<double>> _calcFrameMatrix(double screenW, double screenH) {
    final isWideCamera = widget.uiState.streamType == 'wideRoad';

    // camera config — ecam for wide, fcam for road (augmented_road_view.py:174-175)
    final deviceCamera = _lookupCamera();
    final camConfig = isWideCamera ? deviceCamera.ecam : deviceCamera.fcam;
    final intrinsic = camConfig.intrinsics;
    final camW = camConfig.width.toDouble();
    final camH = camConfig.height.toDouble();

    // zoom: 2.0 for wide, 1.1 for road (augmented_road_view.py:177)
    final zoom = isWideCamera ? 2.0 : 1.1;

    // calibration: wide uses view_from_wide_calib, road uses view_from_calib (augmented_road_view.py:176)
    final calibration = isWideCamera ? _computeWideViewFromCalib() : _computeViewFromCalib();

    // video scale matches BoxFit.cover: use the larger ratio
    final videoScale = max(screenW / camW, screenH / camH);
    final focalScaled = intrinsic[0][0] * videoScale * zoom;

    // scaled intrinsic: positive focal for Flutter Canvas (Y-down)
    // stock openpilot uses -focal for OpenGL (Y-up), dashy uses -focal + canvas transform
    final scaledIntrinsic = [
      [focalScaled, 0.0, screenW / 2],
      [0.0, focalScaled, screenH / 2],
      [0.0, 0.0, 1.0],
    ];

    // final transform: scaledIntrinsic @ calibration
    return matmul3x3(scaledIntrinsic, calibration);
  }

  /// look up camera by device type + sensor, fallback to default
  DeviceCameraConfig _lookupCamera() {
    final st = widget.uiState;
    if (st.deviceType.isNotEmpty && st.sensor.isNotEmpty) {
      return deviceCameras[(st.deviceType, st.sensor)] ?? defaultDeviceCamera;
    }
    return defaultDeviceCamera;
  }

  /// road camera: view_from_calib = VIEW_FRAME_FROM_DEVICE_FRAME @ device_from_calib
  List<List<double>> _computeViewFromCalib() {
    final st = widget.uiState;
    if (st.rpyCalib.length != 3 || st.calStatus != 'calibrated') {
      return viewFrameFromDeviceFrame;
    }
    final deviceFromCalib = rotFromEuler(st.rpyCalib);
    return matmul3x3(viewFrameFromDeviceFrame, deviceFromCalib);
  }

  /// wide camera: view_from_wide_calib = VIEW_FRAME_FROM_DEVICE_FRAME @ wide_from_device @ device_from_calib
  /// (augmented_road_view.py:157-159)
  List<List<double>> _computeWideViewFromCalib() {
    final st = widget.uiState;
    if (st.rpyCalib.length != 3 || st.calStatus != 'calibrated') {
      return viewFrameFromDeviceFrame;
    }
    final deviceFromCalib = rotFromEuler(st.rpyCalib);
    if (st.wideFromDeviceEuler.length == 3) {
      final wideFromDevice = rotFromEuler(st.wideFromDeviceEuler);
      return matmul3x3(viewFrameFromDeviceFrame, matmul3x3(wideFromDevice, deviceFromCalib));
    }
    // fallback: same as road calibration
    return matmul3x3(viewFrameFromDeviceFrame, deviceFromCalib);
  }
}

// -- content area clipper (replaces scissor mode from stock) --

class _ContentClipper extends CustomClipper<Rect> {
  final Rect contentRect;
  _ContentClipper(this.contentRect);

  @override
  Rect getClip(Size size) => contentRect;

  @override
  bool shouldReclip(_ContentClipper oldClipper) => oldClipper.contentRect != contentRect;
}

// -- engagement border painter --

class _EngagementBorderPainter extends CustomPainter {
  final UIStatus status;
  final double borderSize;

  _EngagementBorderPainter({required this.status, required this.borderSize});

  @override
  void paint(Canvas canvas, Size size) {
    // outer black border
    final outerRect = Offset.zero & size;
    canvas.drawRect(outerRect, Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderSize);

    // inner colored rounded rect
    final innerRect = Rect.fromLTWH(
      borderSize / 2, borderSize / 2,
      size.width - borderSize, size.height - borderSize,
    );
    final borderColor = borderColors[status] ?? borderColors[UIStatus.disengaged]!;
    final rrect = RRect.fromRectAndRadius(innerRect, Radius.circular(borderSize * 1.2));
    canvas.drawRRect(rrect, Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderSize);
  }

  @override
  bool shouldRepaint(_EngagementBorderPainter old) =>
    old.status != status || old.borderSize != borderSize;
}

// -- 側欄按鈕定義 --

class _RailItem {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _RailItem(this.icon, this.label, this.onTap);
}
