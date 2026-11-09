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
          ListTile(contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.local_parking), title: const Text('附近停車場與空位'),
            subtitle: Text(ParkingConfig.instance.enabled
                ? '已開啟｜半徑 ${ParkingConfig.instance.radius} 公尺，顯示在直向資訊區'
                : '已關閉｜點此開啟與設定'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showParkingSettings(context)),
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
