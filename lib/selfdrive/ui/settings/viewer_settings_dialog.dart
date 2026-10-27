import 'package:flutter/material.dart';
import 'package:opview/services/viewer_settings.dart';
import 'package:opview/services/viewer_system.dart' as system;
import 'package:opview/services/app_log.dart';

// 分享 / 清除 log 的結果文字（顯示在對話框底部）
final _logResult = ValueNotifier<String?>(null);

class ViewerSettingsDialog extends StatelessWidget {
  final ViewerSettings settings;
  const ViewerSettingsDialog({super.key, required this.settings});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([settings, system.pipSupported, system.brightnessSupported, _logResult]),
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
