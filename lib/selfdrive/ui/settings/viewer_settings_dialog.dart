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

class ViewerSettingsDialog extends StatelessWidget {
  final ViewerSettings settings;
  /// 取得 comma IP（OP 設定網頁用）；null = 不顯示
  final String? Function()? opHost;
  const ViewerSettingsDialog({super.key, required this.settings, this.opHost});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([settings, system.pipSupported, system.brightnessSupported, _logResult,
      TdxTrafficService.instance.status, ParkingConfig.instance]),
    builder: (context, _) => AlertDialog(
      title: const Text('手機顯示設定'),
      content: SizedBox(width: 420, child: SingleChildScrollView(child: Column(
        mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButton<ViewerLayout>(value: settings.layout, isExpanded: true,
            items: const [
              DropdownMenuItem(value: ViewerLayout.dashboard, child: Text('儀表介面')),
              DropdownMenuItem(value: ViewerLayout.classic, child: Text('原版介面')),
              DropdownMenuItem(value: ViewerLayout.detailed, child: Text('儀表＋車輛資訊')),
            ], onChanged: (v) { if (v != null) settings.setLayout(v); }),
          SwitchListTile(contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.speed),
            title: const Text('顯示儀表卡片'),
            subtitle: const Text('關閉後不顯示車速卡片（直向空間讓給 LINE 與停車）'),
            value: !settings.hideHudCard, onChanged: (v) => settings.setHideHudCard(!v)),
          SwitchListTile(contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.gradient),
            title: const Text('彩虹模式'),
            subtitle: Text(settings.layout == ViewerLayout.classic
                ? '行駛路徑改為流動彩虹色（原版介面不適用，切到儀表介面才看得到）'
                : '行駛路徑改為流動彩虹色'),
            value: settings.rainbowPath, onChanged: settings.setRainbowPath),
          // 側欄 / 操作列的 km/h 按鈕已移除，單位只在這裡切換
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('公制 km/h'),
            value: settings.metric, onChanged: settings.setMetric),
          // 交通部 TDX：路況與停車共用同一組金鑰與每分鐘 5 次額度（手機端抓取，不需要 comma 分支支援）
          const Divider(),
          const Text('交通部 TDX'),
          const Text('路況顯示與停車查詢共用同一組金鑰與每分鐘 5 次額度，皆使用手機定位與手機網路。',
            style: TextStyle(fontSize: 12, color: Colors.white54)),
          ListTile(contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.vpn_key_outlined,
              color: ParkingConfig.instance.hasCredentials ? null : Colors.orangeAccent),
            title: const Text('TDX 金鑰'),
            subtitle: Text(ParkingConfig.instance.hasCredentials
                ? '已設定（路況、停車共用）'
                : '尚未設定：路況與停車查詢都需要 Client ID / Client Secret',
              style: ParkingConfig.instance.hasCredentials
                  ? null : const TextStyle(color: Colors.orangeAccent)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showParkingSettings(context)),
          SwitchListTile(contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.traffic_outlined),
            title: const Text('TDX 路況顯示'),
            subtitle: Text('前方車速與路況事件跑馬燈'
                '${settings.tdx ? '\n狀態：${TdxTrafficService.instance.status.value}' : ''}'),
            value: settings.tdx, onChanged: settings.setTdx),
          if (settings.tdx)
            SwitchListTile(contentPadding: const EdgeInsets.only(left: 40),
              secondary: const Icon(Icons.trending_down_rounded, color: Color(0xFFF2B731)),
              title: const Text('國道車速驟降嗶聲'),
              subtitle: const Text('國道上前方 2 公里內開始回堵（低於 40 km/h），且比本車慢 40 km/h 以上時，'
                '顯示黃色「車速驟降 前方1.5公里 降至25km」並嗶一聲（3 分鐘內不重複；直向在路況卡、橫向在上方警示列）。'
                '關閉只取消聲音，畫面照常顯示。'
                '國道另顯示回堵長度與前方偵測器的各車道車速｜直向、橫向。'),
              value: settings.tdxDropBeep, onChanged: settings.setTdxDropBeep),
          ListTile(contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.local_parking), title: const Text('附近停車場與空位'),
            subtitle: Text(ParkingConfig.instance.enabled
                ? '已開啟｜半徑 ${ParkingConfig.instance.radius} 公尺，顯示在直向資訊區'
                : '已關閉｜點此開啟與設定'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showParkingSettings(context)),
          const Divider(),
          SwitchListTile(contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.chat_bubble_outline, color: Color(0xFF06C755)),
            title: const Text('顯示 LINE 通知（直向）'),
            subtitle: const Text('直向資訊區顯示 LINE 訊息，每則 30 秒；需授權「通知存取權」，訊息不會寫入 log。'
                '與停車查詢同時開啟時，LINE 在上、停車在下'),
            value: settings.lineNotify, onChanged: (v) async {
              settings.setLineNotify(v);
              if (v && !await hasNotificationAccess() && context.mounted) {
                await _askNotificationAccess(context);
              }
            }),
          const Divider(),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('打開 App 自動進入 opview'),
            subtitle: const Text('開啟後跳過主畫面，直接進入 opview 畫面'),
            value: settings.autoEnterOpview, onChanged: settings.setAutoEnterOpview),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('自動進入全螢幕'),
            subtitle: const Text('連線且畫面開始更新後 3 秒進入全螢幕並轉為橫向；點右上角可退出，下次連線再自動進入'),
            value: settings.autoFullscreen, onChanged: settings.setAutoFullscreen),
          const Divider(),
          const Text('停等與起步提醒'),
          const Text('畫面提示（道路畫面右側圓形）與前車起步、綠燈起步的聲音，直向、橫向都有。'
            '只在停車中且 openpilot 未啟用時運作，提醒僅供參考，起步前請自行確認路況。',
            style: TextStyle(fontSize: 12, color: Colors.white54)),
          SwitchListTile(contentPadding: EdgeInsets.zero,
            secondary: stopGoSettingIcon(StopGoKind.leadDepart),
            title: const Text('前車起步偵測'),
            subtitle: const Text('停在前車後方（8 公尺內）時，前車開走即提醒｜畫面與聲音：直向、橫向'),
            value: settings.leadDepartAlert, onChanged: settings.setLeadDepartAlert),
          SwitchListTile(contentPadding: EdgeInsets.zero,
            secondary: stopGoSettingIcon(StopGoKind.greenLight),
            title: const Text('綠燈起步偵測'),
            subtitle: const Text('停車且前方 8 公尺內沒有車時，模型判斷前方可通行（綠燈）即提醒｜畫面與聲音：直向、橫向'),
            value: settings.greenLightAlert, onChanged: settings.setGreenLightAlert),
          SwitchListTile(contentPadding: EdgeInsets.zero,
            secondary: stopGoSettingIcon(null),
            title: const Text('車輛停等計時'),
            subtitle: const Text('車輛靜止時在 HUD 顯示停等時間（分:秒）｜直向、橫向'),
            value: settings.standstillTimer, onChanged: settings.setStandstillTimer),
          Row(children: [
            const Expanded(child: Text('起步提醒聲音（直向、橫向）')),
            DropdownButton<AlertSoundMode>(value: settings.alertSound,
              items: [for (final m in AlertSoundMode.values)
                DropdownMenuItem(value: m, child: Text(alertSoundLabel(m)))],
              onChanged: (v) { if (v != null) settings.setAlertSound(v); }),
            IconButton(tooltip: '試聽', icon: const Icon(Icons.volume_up_outlined),
              onPressed: settings.alertSound == AlertSoundMode.mute ? null
                  : () => playStopGoSound(StopGoKind.leadDepart, settings.alertSound)),
          ]),
          // 試聽結果：例如「媒體音量 0/15（靜音…）」「手機沒有中文語音資料…」，方便現場判斷沒聲音的原因
          ValueListenableBuilder<String?>(valueListenable: lastAlertSoundStatus,
            builder: (context, s, _) => s == null || settings.alertSound == AlertSoundMode.mute
                ? const SizedBox.shrink()
                : Text('試聽結果：$s', style: const TextStyle(fontSize: 12, color: Colors.white54))),
          if (settings.alertSound == AlertSoundMode.voice)
            const Text('Google 語音使用手機 Google 文字轉語音的台灣中文預設聲音；'
              '男聲或女聲由系統決定，要換聲音請到系統「文字轉語音」設定更改。',
              style: TextStyle(fontSize: 12, color: Colors.white54)),
          SwitchListTile(contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.play_circle_outline),
            title: const Text('背景執行（保留起步語音）'),
            subtitle: const Text('在 opview 畫面切到其他 App 或關閉螢幕時，繼續連線並播放前車起步、綠燈起步語音'
              '（需開啟其中一項偵測、聲音不是靜音）。通知列會顯示「opview 背景執行中」，可按「停止」結束；'
              '耗電與流量和前景相同。小米等手機請把 opview 的省電策略設為「無限制」。'),
            value: settings.backgroundRun, onChanged: settings.setBackgroundRun),
          const Divider(),
          SwitchListTile(contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.warning_amber_rounded, color: Color(0xFFFF3B30)),
            title: const Text('近距離警示'),
            subtitle: const Text('行進中（20–60 km/h）前方有目標但模型信心度只有 0.2 以上、未達 0.5（openpilot 不會當成前車），'
              '在行駛路徑左右 0.9 公尺內、距車頭 2 公尺（20 km/h）～3 公尺（60 km/h）內，且連續 5 幀（約 0.25 秒）時，'
              '道路畫面顯示紅色箭頭、事件位置顯示「碰撞注意」並嗶一聲（30 秒內只嗶一次；不受起步提醒聲音設定影響）｜直向、橫向。'
              '需要 comma 端 webrtcd 已更新（送出 leadsV3）；僅供參考，不會控制車輛。'),
            value: settings.proximityAlert, onChanged: settings.setProximityAlert),
          if (system.brightnessSupported.value)
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('亮度跟隨系統'),
            value: settings.brightness == null,
            onChanged: (v) => settings.setBrightness(v ? null : .6)),
          if (system.brightnessSupported.value && settings.brightness != null) ...[
            Text('App 亮度 ${(settings.brightness! * 100).round()}%'),
            Slider(min: .05, max: 1, value: settings.brightness!,
              onChanged: settings.setBrightness),
          ],
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('降低儀表更新頻率'),
            subtitle: const Text('約 5 Hz；路徑與警告不降頻'),
            value: settings.hudEvery == 4, onChanged: (v) => settings.setHudEvery(v ? 4 : 1)),
          if (opHost != null) ...[
            const Divider(),
            const Text('OP 設定網頁'),
            Text('dragonpilot：以瀏覽器開啟 comma 的設定頁（http://${opHost!() ?? '<comma IP>'}:$opSettingsPort）；'
              'sunnypilot：開啟 sunnylink（$sunnylinkUrl）。限 offroad 或 P 檔。',
              style: const TextStyle(fontSize: 12, color: Colors.white54)),
            Wrap(spacing: 8, children: [
              OutlinedButton.icon(icon: const Icon(Icons.open_in_browser, size: 18), label: const Text('開啟 OP 設定'),
                onPressed: () => openOpSettings(context, opHost!())),
              TextButton(child: const Text('手動輸入 IP'),
                onPressed: () => openOpSettings(context, opHost!(), forceAsk: true)),
            ]),
          ],
          const Divider(),
          const Text('連線紀錄（log）'),
          const Text('記錄連線、探索、WebRTC、影像、各資料收到筆數，可分享給開發者排查。',
            style: TextStyle(fontSize: 12, color: Colors.white54)),
          Wrap(spacing: 8, children: [
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
          ]),
          if (_logResult.value != null)
            Text(_logResult.value!, style: const TextStyle(fontSize: 12, color: Colors.white70)),
        ],
      ))),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('完成'))],
    ),
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
