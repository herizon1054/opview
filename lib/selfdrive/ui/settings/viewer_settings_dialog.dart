import 'package:flutter/material.dart';
import 'package:opview/services/viewer_settings.dart';
import 'package:opview/services/viewer_system.dart' as system;
import 'package:opview/services/app_log.dart';
import 'op_settings_link.dart';
import 'package:opview/services/tdx_support.dart';

// 分享 / 清除 log 的結果文字（顯示在對話框底部）
final _logResult = ValueNotifier<String?>(null);

class ViewerSettingsDialog extends StatelessWidget {
  final ViewerSettings settings;
  /// 取得 comma IP（OP 設定網頁用）；null = 不顯示
  final String? Function()? opHost;
  const ViewerSettingsDialog({super.key, required this.settings, this.opHost});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([settings, system.pipSupported, system.brightnessSupported, _logResult, tdxSupport]),
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
          // 目前連線的 comma 分支沒有 tdx service：開關停用並註明
          if (tdxSupport.value == false)
            const SwitchListTile(contentPadding: EdgeInsets.zero, title: Text('TDX 路況顯示'),
              subtitle: Text('$tdxUnsupportedText（comma 端沒有 tdx 服務）',
                style: TextStyle(color: Colors.orangeAccent)),
              value: false, onChanged: null)
          else
            SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('TDX 路況顯示'),
              subtitle: const Text('前方車速與路況事件跑馬燈（只影響手機端顯示）'),
              value: settings.tdx, onChanged: settings.setTdx),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('打開 App 自動進入 opview'),
            subtitle: const Text('開啟後跳過主畫面，直接進入 opview 畫面'),
            value: settings.autoEnterOpview, onChanged: settings.setAutoEnterOpview),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('自動進入全螢幕'),
            subtitle: const Text('連線且畫面開始更新後 3 秒收起側欄；點右上角可叫回，下次連線再自動收起'),
            value: settings.autoFullscreen, onChanged: settings.setAutoFullscreen),
          if (system.pipSupported.value)
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('子母畫面 PiP'),
            subtitle: const Text('連線時按 Home 保留畫面'),
            value: settings.pictureInPicture,
            onChanged: settings.setPip),
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
