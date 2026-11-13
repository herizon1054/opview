// 手機顯示設定（2026-11-14 重新整理）
//
// 每個選項一行：圖示｜名稱（＋必要的一行狀態）｜ⓘ 說明按鈕｜開關或下拉選單。
// 原本寫在副標題的長說明都移到 ⓘ（點了跳出說明視窗），清單本身只留名稱與即時狀態。
// 分組順序（常用到少用）：
//   畫面 → 行車提醒 → 停等與起步 → 交通部 TDX → 通知 → 啟動 → 工具（OP 設定網頁、連線紀錄）

import 'package:flutter/material.dart';
import 'package:opview/services/viewer_settings.dart';
import 'package:opview/services/viewer_system.dart' as system;
import 'package:opview/services/app_log.dart';
import 'op_settings_link.dart';
import 'parking_settings_dialog.dart';
import 'package:opview/services/stop_go_alerts.dart';
import 'package:opview/services/alert_sound.dart';
import '../onroad/stop_go_overlay.dart' show stopGoSettingIcon;
import 'package:opview/services/tdx/tdx_traffic_service.dart';
import 'package:opview/services/parking/parking_config.dart';
import 'package:opview/services/line_notifications.dart';

// 分享 / 清除 log 的結果文字（顯示在對話框底部）
final _logResult = ValueNotifier<String?>(null);

const _muted = TextStyle(fontSize: 12, color: Colors.white54);
const _warnColor = Colors.orangeAccent;

// ---- 說明文字（ⓘ）----
const _helpLayout = '儀表介面：opview 的版面（路況卡、儀表卡片、提示都整理在畫面上）。\n'
    '原版介面：與 comma 螢幕相同的 openpilot 畫面。\n'
    '儀表＋車輛資訊：儀表介面再加上右上角的車輛資訊框。';
const _helpHudCard = '關閉後不顯示車速卡片（MAX｜車速｜前車），直向下方的空間讓給路況卡、LINE 與停車。';
const _helpRainbow = '行駛路徑改為流動彩虹色。只在儀表介面有效，原版介面看不到。';
const _helpHudEvery = '儀表文字約 5 Hz 更新一次，省電、減少發熱。行駛路徑與警示不降頻。';
const _helpProximity = '行進中（20–60 km/h）前方有目標，但模型信心度只有 0.2 以上、未達 0.5（openpilot 不會當成前車），'
    '且在行駛路徑左右 0.9 公尺內、距車頭 2 公尺（20 km/h）～3 公尺（60 km/h）內，連續 5 幀（約 0.25 秒）時：\n'
    '・道路畫面顯示紅色箭頭\n・上方警示列顯示「碰撞注意」\n・嗶一聲（1.6 kHz；30 秒內只嗶一次）\n\n'
    '直向、橫向都有；不受起步提醒聲音設定影響。需要 comma 端 webrtcd 已更新（送出 leadsV3）。'
    '僅供參考，不會控制車輛。';
const _helpDisengage = '行駛中 openpilot 解除（踩煞車、按取消、系統解除）時：\n'
    '・滴滴兩聲（2.0 kHz，類似豐田解除定速）\n・道路畫面上方顯示藍色「巡航解除」2 秒\n\n'
    '踩油門介入不算解除；停車中解除不提示。直向、橫向都有；不受起步提醒聲音設定影響。';
const _helpStopGo = '畫面提示（道路畫面右側圓形）與聲音，直向、橫向都有。\n'
    '只在停車中且 openpilot 未啟用時運作；提醒僅供參考，起步前請自行確認路況。';
const _helpLeadDepart = '停在前車後方（8 公尺內）時，前車開走即提醒。\n\n$_helpStopGo';
const _helpGreenLight = '停車且前方 8 公尺內沒有車時，模型判斷前方可通行（綠燈）即提醒。\n\n$_helpStopGo';
const _helpStandstill = '車輛靜止時在畫面上顯示停等時間（分:秒），直向、橫向都有。';
const _helpAlertSound = '前車起步、綠燈起步提醒要播的聲音：靜音／Google 語音／嗶嗶聲。按喇叭圖示可試聽。\n\n'
    'Google 語音使用手機 Google 文字轉語音的台灣中文預設聲音；男聲或女聲由系統決定，'
    '要換聲音請到系統「文字轉語音」設定更改。\n\n'
    '近距離警示、巡航解除、車速驟降的提示音不受這個設定影響。';
const _helpBackground = '在 opview 畫面切到其他 App 或關閉螢幕時，繼續連線並播放前車起步、綠燈起步提醒'
    '（需開啟其中一項偵測、聲音不是靜音）。\n\n'
    '通知列會顯示「opview 背景執行中」，可按「停止」結束；耗電與流量和前景相同。'
    '小米等手機請把 opview 的省電策略設為「無限制」。';
const _helpTdxKey = '交通部 TDX 的 Client ID / Client Secret。路況顯示與停車查詢共用同一組金鑰與每分鐘 5 次額度，'
    '都使用手機定位與手機網路，不需要 comma 分支支援。';
const _helpTdx = '前方車速、壅塞分級與路況事件，顯示在路況卡（儀表介面）或上方警示列（原版介面）。\n'
    '國道另顯示回堵長度與前方偵測器的各車道車速。';
const _helpTdxDrop = '國道上前方 2 公里內開始回堵（低於 40 km/h），且比本車慢 40 km/h 以上時，'
    '顯示黃色「車速驟降」並嗶一聲（1.0 kHz；3 分鐘內不重複）。\n\n'
    '儀表介面在路況卡，原版介面在上方警示列。關閉只取消聲音，畫面照常顯示。';
const _helpParking = '查詢附近停車場與剩餘空位，顯示在直向資訊區。半徑與開關在停車設定裡。';
const _helpLine = '直向資訊區顯示 LINE 訊息，每則 30 秒；與停車查詢同時開啟時，LINE 在上、停車在下。\n\n'
    '需授權「通知存取權」；訊息內容不會寫入 log。';
const _helpAutoEnter = '開啟後跳過主畫面，打開 App 直接進入 opview 畫面。';
const _helpAutoFullscreen = '連線且畫面開始更新後 3 秒進入全螢幕並轉為橫向；點右上角可退出，下次連線再自動進入。';
const _helpLog = '記錄連線、探索、WebRTC、影像、各資料收到的筆數，可分享給開發者排查問題。';

Future<void> _showHelp(BuildContext context, String title, String text) => showDialog<void>(
  context: context,
  builder: (ctx) => AlertDialog(
    title: Text(title),
    content: SingleChildScrollView(child: Text(text, style: const TextStyle(height: 1.45))),
    actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了'))],
  ));

/// 分組標題
class _Section extends StatelessWidget {
  final String title;
  const _Section(this.title);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 2),
    child: Row(children: [
      Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.primary, letterSpacing: .5)),
      const SizedBox(width: 8),
      const Expanded(child: Divider(height: 1)),
    ]),
  );
}

/// 一個選項：圖示｜名稱（＋狀態）｜ⓘ｜控制項。點整行 = 切換開關或開啟子頁。
class _Opt extends StatelessWidget {
  final Widget? icon;
  final String title;
  /// 一行即時狀態（例如 TDX 連線狀態、尚未設定）；說明文字請放 [help]
  final String? status;
  final Color? statusColor;
  final String? help;
  final Widget? control;
  /// 較寬的控制項（下拉選單、多個按鈕）放在名稱下面一行，避免窄螢幕把名稱擠扁
  final Widget? below;
  final VoidCallback? onTap;
  final bool indent;
  const _Opt({this.icon, required this.title, this.status, this.statusColor, this.help, this.control,
      this.below, this.onTap, this.indent = false});

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: EdgeInsets.only(left: indent ? 28 : 0),
      child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 48), child: Row(children: [
        SizedBox(width: 36, child: icon == null ? null : IconTheme.merge(
            data: const IconThemeData(size: 22), child: icon!)),
        Expanded(child: Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Column(
          mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 15)),
            if (status != null && status!.isNotEmpty)
              Text(status!, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: _muted.copyWith(color: statusColor)),
          ]))),
        if (help != null)
          IconButton(tooltip: '說明：$title', visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.info_outline, size: 20, color: Colors.white60),
            onPressed: () => _showHelp(context, title, help!)),
        if (control != null) control!,
      ])),
    );
    final body = below == null ? row : Column(mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      row,
      Padding(padding: EdgeInsets.only(left: (indent ? 28 : 0) + 36, bottom: 4),
        child: Align(alignment: Alignment.centerLeft, child: below)),
    ]);
    return onTap == null ? body : InkWell(onTap: onTap, borderRadius: BorderRadius.circular(8), child: body);
  }
}

/// 開關選項（點整行也會切換）
_Opt _switch({Widget? icon, required String title, String? status, Color? statusColor, String? help,
    required bool value, required ValueChanged<bool> onChanged, bool indent = false}) =>
  _Opt(icon: icon, title: title, status: status, statusColor: statusColor, help: help, indent: indent,
    control: Switch(value: value, onChanged: onChanged), onTap: () => onChanged(!value));

class ViewerSettingsDialog extends StatelessWidget {
  final ViewerSettings settings;
  /// 取得 comma IP（OP 設定網頁用）；null = 不顯示
  final String? Function()? opHost;
  const ViewerSettingsDialog({super.key, required this.settings, this.opHost});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([settings, system.pipSupported, system.brightnessSupported, _logResult,
      TdxTrafficService.instance.status, ParkingConfig.instance]),
    builder: (context, _) {
      final classic = settings.layout == ViewerLayout.classic;
      final hasKey = ParkingConfig.instance.hasCredentials;
      return AlertDialog(
        title: const Text('手機顯示設定'),
        contentPadding: const EdgeInsets.fromLTRB(20, 4, 12, 0),
        content: SizedBox(width: 440, child: SingleChildScrollView(child: Column(
          mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── 畫面 ──
            const _Section('畫面'),
            _Opt(icon: const Icon(Icons.dashboard_outlined), title: '介面樣式', help: _helpLayout,
              below: DropdownButton<ViewerLayout>(value: settings.layout, underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: ViewerLayout.dashboard, child: Text('儀表介面')),
                  DropdownMenuItem(value: ViewerLayout.classic, child: Text('原版介面')),
                  DropdownMenuItem(value: ViewerLayout.detailed, child: Text('儀表＋車輛資訊')),
                ], onChanged: (v) { if (v != null) settings.setLayout(v); })),
            _switch(icon: const Icon(Icons.speed), title: '顯示儀表卡片', help: _helpHudCard,
              value: !settings.hideHudCard, onChanged: (v) => settings.setHideHudCard(!v)),
            _switch(icon: const Icon(Icons.gradient), title: '彩虹模式', help: _helpRainbow,
              status: classic ? '原版介面不適用' : null,
              value: settings.rainbowPath, onChanged: settings.setRainbowPath),
            // 側欄 / 操作列的 km/h 按鈕已移除，單位只在這裡切換
            _switch(icon: const Icon(Icons.straighten), title: '公制 km/h',
              value: settings.metric, onChanged: settings.setMetric),
            if (system.brightnessSupported.value) ...[
              _switch(icon: const Icon(Icons.brightness_6_outlined), title: '亮度跟隨系統',
                value: settings.brightness == null, onChanged: (v) => settings.setBrightness(v ? null : .6)),
              if (settings.brightness != null)
                Padding(padding: const EdgeInsets.only(left: 36), child: Row(children: [
                  Text('${(settings.brightness! * 100).round()}%', style: _muted),
                  Expanded(child: Slider(min: .05, max: 1, value: settings.brightness!,
                    onChanged: settings.setBrightness)),
                ])),
            ],
            _switch(icon: const Icon(Icons.battery_saver_outlined), title: '降低儀表更新頻率', help: _helpHudEvery,
              value: settings.hudEvery == 4, onChanged: (v) => settings.setHudEvery(v ? 4 : 1)),

            // ── 行車提醒（行駛中）──
            const _Section('行車提醒'),
            _switch(icon: const Icon(Icons.warning_amber_rounded, color: Color(0xFFFF3B30)),
              title: '近距離警示', help: _helpProximity,
              value: settings.proximityAlert, onChanged: settings.setProximityAlert),
            _switch(icon: const Icon(Icons.pause_circle_filled_rounded, color: Color(0xFF4A90D9)),
              title: '巡航解除提示', help: _helpDisengage,
              value: settings.disengageAlert, onChanged: settings.setDisengageAlert),

            // ── 停等與起步 ──
            const _Section('停等與起步'),
            _switch(icon: stopGoSettingIcon(StopGoKind.leadDepart), title: '前車起步偵測', help: _helpLeadDepart,
              value: settings.leadDepartAlert, onChanged: settings.setLeadDepartAlert),
            _switch(icon: stopGoSettingIcon(StopGoKind.greenLight), title: '綠燈起步偵測', help: _helpGreenLight,
              value: settings.greenLightAlert, onChanged: settings.setGreenLightAlert),
            _switch(icon: stopGoSettingIcon(null), title: '車輛停等計時', help: _helpStandstill,
              value: settings.standstillTimer, onChanged: settings.setStandstillTimer),
            _Opt(icon: const Icon(Icons.campaign_outlined), title: '起步提醒聲音', help: _helpAlertSound,
              below: Row(mainAxisSize: MainAxisSize.min, children: [
                DropdownButton<AlertSoundMode>(value: settings.alertSound, underline: const SizedBox.shrink(),
                  items: [for (final m in AlertSoundMode.values)
                    DropdownMenuItem(value: m, child: Text(alertSoundLabel(m)))],
                  onChanged: (v) { if (v != null) settings.setAlertSound(v); }),
                IconButton(tooltip: '試聽', icon: const Icon(Icons.volume_up_outlined),
                  onPressed: settings.alertSound == AlertSoundMode.mute ? null
                      : () => playStopGoSound(StopGoKind.leadDepart, settings.alertSound)),
              ])),
            // 試聽結果：例如「媒體音量 0/15（靜音…）」「手機沒有中文語音資料…」，方便現場判斷沒聲音的原因
            ValueListenableBuilder<String?>(valueListenable: lastAlertSoundStatus,
              builder: (context, s, _) => s == null || settings.alertSound == AlertSoundMode.mute
                  ? const SizedBox.shrink()
                  : Padding(padding: const EdgeInsets.only(left: 36, bottom: 4),
                      child: Text('試聽結果：$s', style: _muted))),
            _switch(icon: const Icon(Icons.play_circle_outline), title: '背景執行（保留起步提醒）', help: _helpBackground,
              value: settings.backgroundRun, onChanged: settings.setBackgroundRun),

            // ── 交通部 TDX ──
            const _Section('交通部 TDX'),
            _Opt(icon: Icon(Icons.vpn_key_outlined, color: hasKey ? null : _warnColor), title: 'TDX 金鑰',
              status: hasKey ? '已設定（路況、停車共用）' : '尚未設定：路況與停車都需要',
              statusColor: hasKey ? null : _warnColor, help: _helpTdxKey,
              control: const Icon(Icons.chevron_right), onTap: () => showParkingSettings(context)),
            _switch(icon: const Icon(Icons.traffic_outlined), title: 'TDX 路況顯示', help: _helpTdx,
              status: settings.tdx ? TdxTrafficService.instance.status.value : null,
              value: settings.tdx, onChanged: settings.setTdx),
            if (settings.tdx)
              _switch(icon: const Icon(Icons.trending_down_rounded, color: Color(0xFFF2B731)), indent: true,
                title: '國道車速驟降嗶聲', help: _helpTdxDrop,
                value: settings.tdxDropBeep, onChanged: settings.setTdxDropBeep),
            _Opt(icon: const Icon(Icons.local_parking), title: '附近停車場與空位', help: _helpParking,
              status: ParkingConfig.instance.enabled ? '已開啟｜半徑 ${ParkingConfig.instance.radius} 公尺' : '已關閉',
              control: const Icon(Icons.chevron_right), onTap: () => showParkingSettings(context)),

            // ── 通知 ──
            const _Section('通知'),
            _switch(icon: const Icon(Icons.chat_bubble_outline, color: Color(0xFF06C755)),
              title: 'LINE 通知（直向）', help: _helpLine,
              value: settings.lineNotify, onChanged: (v) async {
                settings.setLineNotify(v);
                if (v && !await hasNotificationAccess() && context.mounted) {
                  await _askNotificationAccess(context);
                }
              }),

            // ── 啟動 ──
            const _Section('啟動'),
            _switch(icon: const Icon(Icons.login), title: '打開 App 自動進入 opview', help: _helpAutoEnter,
              value: settings.autoEnterOpview, onChanged: settings.setAutoEnterOpview),
            _switch(icon: const Icon(Icons.fullscreen), title: '自動進入全螢幕', help: _helpAutoFullscreen,
              value: settings.autoFullscreen, onChanged: settings.setAutoFullscreen),

            // ── 工具 ──
            const _Section('工具'),
            if (opHost != null)
              _Opt(icon: const Icon(Icons.open_in_browser), title: 'OP 設定網頁',
                help: 'dragonpilot：以瀏覽器開啟 comma 的設定頁（http://${opHost!() ?? '<comma IP>'}:$opSettingsPort）。\n'
                  'sunnypilot：開啟 sunnylink（$sunnylinkUrl）。\n\n限 offroad 或 P 檔。'
                  '自動找不到 comma 時，按「輸入 IP」手動輸入。',
                below: Wrap(spacing: 4, children: [
                  OutlinedButton.icon(icon: const Icon(Icons.open_in_browser, size: 18), label: const Text('開啟 OP 設定'),
                    onPressed: () => openOpSettings(context, opHost!())),
                  TextButton(child: const Text('輸入 IP'),
                    onPressed: () => openOpSettings(context, opHost!(), forceAsk: true)),
                ])),
            _Opt(icon: const Icon(Icons.receipt_long_outlined), title: '連線紀錄（log）', help: _helpLog,
              status: _logResult.value,
              below: Wrap(spacing: 4, children: [
                OutlinedButton.icon(icon: const Icon(Icons.share, size: 18), label: const Text('分享 log'),
                  onPressed: () async {
                    _logResult.value = '匯出中…';
                    // 開啟 LINE 通知時，分享前補一行目前的 LINE 診斷（只有數量與狀態，不含訊息內容）
                    if (LineNotifications.instance.enabled) {
                      await LineNotifications.instance.logDiagnostics(force: true);
                    }
                    _logResult.value = await AppLog.instance.share();
                  }),
                TextButton(child: const Text('清除 log'),
                  onPressed: () async {
                    await AppLog.instance.clear();
                    _logResult.value = 'log 已清除';
                  }),
              ])),
            const SizedBox(height: 8),
          ],
        ))),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('完成'))],
      );
    },
  );
}

/// 尚未授權通知存取權：說明後開啟系統設定頁
Future<void> _askNotificationAccess(BuildContext context) => showDialog<void>(context: context,
  builder: (ctx) => AlertDialog(
    title: const Text('需要通知存取權'),
    content: const Text('opview 需要「通知存取權」才能讀取 LINE 通知。\n\n'
      '請在接下來的系統設定中找到 opview 並開啟。\n'
      '若開關無法開啟（Android 13 以上的側載 App），請先到「應用程式資訊 → opview → 右上角選單 → 允許受限制的設定」。'),
    actions: [
      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('稍後')),
      FilledButton(onPressed: () { Navigator.pop(ctx); openNotificationAccessSettings(); },
        child: const Text('前往設定')),
    ],
  ));
