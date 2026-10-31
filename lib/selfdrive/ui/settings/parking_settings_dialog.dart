import 'package:flutter/material.dart';

import '../../../services/parking/parking_catalog.dart';
import '../../../services/parking/parking_config.dart';
import '../../../services/parking/parking_startup.dart';
import '../../../services/parking/parking_quota_store.dart';
import 'parking_test_dialog.dart';

Future<void> showParkingSettings(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const ParkingSettingsDialog(),
);

class ParkingSettingsDialog extends StatefulWidget {
  const ParkingSettingsDialog({super.key});
  @override
  State<ParkingSettingsDialog> createState() => _ParkingSettingsDialogState();
}

class _ParkingSettingsDialogState extends State<ParkingSettingsDialog> {
  final _id = TextEditingController(), _secret = TextEditingController();
  final _startup = ParkingStartup.instance;
  bool _enabled = true, _ready = false, _saving = false;
  String _city = 'auto', _error = '';
  int _radius = 1000;
  bool _testMode = false;

  @override
  void initState() {
    super.initState();
    _startup.addListener(_updated);
    _load();
  }

  void _updated() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      final c = ParkingConfig.instance;
      await c.load();
      if (!mounted) return;
      setState(() {
        _id.text = c.clientId;
        _secret.text = c.clientSecret;
        _enabled = c.enabled;
        _city = parkingCities.containsKey(c.city) ? c.city : 'auto';
        _radius = c.radius == 1200 ? 1200 : 1000;
        _ready = true;
      });
    } catch (_) {
      if (mounted)
        setState(() {
          _ready = true;
          _error = '設定讀取失敗，請重新設定';
        });
    }
  }

  Future<void> _save() async {
    if (_enabled && (_id.text.trim().isEmpty || _secret.text.trim().isEmpty)) {
      setState(() => _error = '必須填入 Client ID 與 Client Secret 才能啟用');
      return;
    }
    setState(() => _saving = true);
    try {
      await ParkingConfig.instance.save(
        _enabled,
        _id.text,
        _secret.text,
        selectedCity: _city,
        selectedRadius: _radius,
      );
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted)
        setState(() {
          _saving = false;
          _error = '無法儲存設定';
        });
    }
  }

  @override
  void dispose() {
    _startup.removeListener(_updated);
    _id.dispose();
    _secret.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('停車查詢設定'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('啟用停車查詢'),
              value: _enabled,
              onChanged: !_ready || _saving
                  ? null
                  : (v) => setState(() => _enabled = v),
            ),
            const Text('必須使用自己的 TDX Client ID 與 Client Secret，不提供匿名模式。'),
            TextField(
              controller: _id,
              enabled: _ready && !_saving,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Client ID（必填）'),
            ),
            TextField(
              controller: _secret,
              enabled: _ready && !_saving,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Client Secret（必填）'),
            ),
            DropdownButton<String>(
              isExpanded: true,
              value: _city,
              items: [
                const DropdownMenuItem(value: 'auto', child: Text('依手機定位辨識縣市')),
                for (final e in parkingCities.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: _saving || !_ready
                  ? null
                  : (v) {
                      if (v != null) setState(() => _city = v);
                    },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('測試模式'),
              subtitle: const Text('預設關閉；開啟後可選 10 km 與執行縣市端點測試'),
              value: _testMode,
              onChanged: !_ready || _saving
                  ? null
                  : (v) => setState(() {
                      _testMode = v;
                      if (!v && _radius == 10000) _radius = 1000;
                    }),
            ),
            DropdownButtonFormField<int>(
              initialValue: _radius,
              key: ValueKey(_radius),
              decoration: const InputDecoration(labelText: '搜尋半徑'),
              items: [
                const DropdownMenuItem(value: 1000, child: Text('1000 公尺')),
                const DropdownMenuItem(value: 1200, child: Text('1200 公尺')),
                if (_testMode)
                  const DropdownMenuItem(
                    value: 10000,
                    child: Text('10 km（僅測試）'),
                  ),
              ],
              onChanged: _saving || !_ready
                  ? null
                  : (v) {
                      if (v != null) setState(() => _radius = v);
                    },
            ),
            const Text(
              '開啟 App／回到前景時自動檢查位置資料，距上次成功更新滿 7 天才重新下載。首次儲存金鑰後也會檢查，不必重開 App。',
            ),
            const SizedBox(height: 8),
            const Text(
              '每次僅更新當次選定縣市。只有完整下載並儲存成功才計次；失敗或取消保留舊資料，下次開啟 App 可再試。更換縣市或金鑰不會重設更新紀錄。',
            ),
            const SizedBox(height: 8),
            const Text(
              '空位仍須按「查詢周遭車位」，30 秒防連點。位置快取與 Token 會重用；靜態分頁與空位共用每分鐘 5 筆節流。',
            ),
            const SizedBox(height: 8),
            const Text('路外另接新北市／新竹市政府資料。新北「回報 N 位*」未附來源時間，請以現場為準。'),
            const SizedBox(height: 12),
            if (_testMode)
              const Text(
                '縣市測試只抽查端點，不下載完整 TDX 清單、不修改七天快取。會消耗 API 額度；無總時間限制，依序測完所有已支援端點；認證或存取限制可能提前停止。',
              ),
            if (_testMode)
              OutlinedButton(
                onPressed: !_ready || _saving || _startup.busy
                    ? null
                    : () async {
                        if (_id.text.trim().isEmpty ||
                            _secret.text.trim().isEmpty) {
                          setState(() => _error = '請先輸入完整 TDX 金鑰');
                          return;
                        }
                        if (parkingApi.busy) {
                          setState(() => _error = '請等待目前下載或查詢完成');
                          return;
                        }
                        await showDialog<void>(
                          context: context,
                          barrierDismissible: false,
                          builder: (_) => ParkingTestDialog(
                            id: _id.text.trim(),
                            secret: _secret.text.trim(),
                          ),
                        );
                      },
                child: const Text('開始各縣市完整測試'),
              ),
            const SizedBox(height: 8),
            Text(
              _startup.status,
              style: const TextStyle(color: Colors.white70),
            ),
            if (_startup.busy) const LinearProgressIndicator(),
            if (_error.isNotEmpty)
              Text(_error, style: const TextStyle(color: Colors.orangeAccent)),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: const Text('關閉'),
      ),
      FilledButton(
        onPressed: _saving || !_ready ? null : _save,
        child: const Text('儲存'),
      ),
    ],
  );
}
