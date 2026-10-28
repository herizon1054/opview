// opview 主畫面
//   最上方：車型選擇（品牌 / 車型）→ 確認按鈕 → 顯示目前 comma 車型
//   下方四個按鈕：進入 opview / 顯示設定 / 裝置設定（瀏覽器開啟 comma IP:5088）/ 離開程式
//
// 車型讀寫透過 comma 的 dashy serverd（lib/services/comma_models_api.dart），offroad 也能用；
// 寫入 dp_dev_model_selected，comma 重新開機後生效。

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:opview/services/comma_models_api.dart';
import 'package:opview/services/viewer_settings.dart';
import 'package:opview/selfdrive/ui/settings/viewer_settings_dialog.dart';
import 'package:opview/selfdrive/ui/settings/op_settings_link.dart';

const _teal = Color(0xFF48D1CC);
const _card = Color(0xFF0D151B);

class HomePage extends StatefulWidget {
  final ViewerSettings settings;
  /// 目前或最近一次找到的 comma IP（ConnectionManager.lastKnownHost）
  final String? Function() hostGetter;
  final VoidCallback onEnterOpview;

  const HomePage({
    super.key,
    required this.settings,
    required this.hostGetter,
    required this.onEnterOpview,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  CommaModels? _models;
  String? _host;
  String? _brand; // null = 自動偵測
  String? _model;
  String? _status;
  bool _loading = false;
  bool _saving = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _status = '尋找 comma 中…';
    _tryLoad();
    // comma 還沒找到 / 還沒開機：每 3 秒再試，讀到車型清單就停
    _poll = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_models == null) _tryLoad();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<String?> _resolveHost() async => widget.hostGetter() ?? await loadManualCommaHost();

  Future<void> _tryLoad({bool force = false}) async {
    if (_loading || (_models != null && !force)) return;
    final host = await _resolveHost();
    if (!mounted) return;
    if (host == null) {
      setState(() => _status = '尋找 comma 中…（可按「設定 IP」手動輸入）');
      return;
    }
    _loading = true;
    setState(() => _status = '讀取車型清單（$host）…');
    try {
      final m = await fetchCommaModels(host);
      if (!mounted) return;
      _host = host;
      _models = m;
      _model = m.selected.isEmpty ? null : m.selected;
      _brand = _model == null ? null : m.brandOf(_model!);
      _status = null;
      debugPrint('[opview] home: models loaded from $host (${m.byBrand.length} brands, selected=${m.selected.isEmpty ? 'AUTO' : m.selected})');
    } catch (e) {
      _status = '無法讀取車型（$host）：$e';
      debugPrint('[opview] home: load models failed $host: $e');
    } finally {
      _loading = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _setIp() async {
    final v = await askCommaHost(context, _host ?? widget.hostGetter());
    if (v == null || !mounted) return;
    setState(() { _models = null; _host = null; });
    // 手動 IP 只在找不到 comma 時使用；這裡直接用輸入的 IP 讀一次
    _loading = true;
    setState(() => _status = '讀取車型清單（$v）…');
    try {
      final m = await fetchCommaModels(v);
      if (!mounted) return;
      _host = v; _models = m;
      _model = m.selected.isEmpty ? null : m.selected;
      _brand = _model == null ? null : m.brandOf(_model!);
      _status = null;
    } catch (e) {
      _status = '無法讀取車型（$v）：$e';
    } finally {
      _loading = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _confirm() async {
    final host = _host;
    final messenger = ScaffoldMessenger.of(context);
    if (host == null || _models == null) return;
    if (_brand != null && _model == null) {
      messenger.showSnackBar(const SnackBar(content: Text('請選擇車型')));
      return;
    }
    final target = _brand == null ? null : _model; // null = 自動偵測
    setState(() => _saving = true);
    try {
      await selectCommaModel(host, target);
      debugPrint('[opview] home: model set to ${target ?? 'AUTO'} on $host');
      final m = await fetchCommaModels(host);
      if (!mounted) return;
      setState(() => _models = m);
      messenger.showSnackBar(SnackBar(content: Text(
          '已設定為「${target ?? '自動偵測'}」，comma 重新開機後生效')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('設定失敗：$e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String get _currentText {
    final m = _models;
    if (m == null) return '—';
    return m.selected.isEmpty ? '自動偵測' : m.selected;
  }

  bool get _pendingDiffers {
    final m = _models;
    if (m == null) return false;
    final pending = _brand == null ? '' : (_model ?? '');
    return pending != m.selected;
  }

  Widget _modelSection({required bool portrait}) {
    final m = _models;
    final brands = m?.byBrand.keys.toList() ?? const <String>[];
    final models = (m != null && _brand != null) ? (m.byBrand[_brand] ?? const <String>[]) : const <String>[];
    final brandDd = DropdownButton<String?>(
      isExpanded: true,
      value: _brand,
      hint: const Text('品牌'),
      items: [
        const DropdownMenuItem<String?>(value: null, child: Text('自動偵測')),
        for (final b in brands) DropdownMenuItem<String?>(value: b, child: Text(b, overflow: TextOverflow.ellipsis)),
      ],
      onChanged: m == null ? null : (v) => setState(() { _brand = v; _model = null; }),
    );
    final modelDd = DropdownButton<String>(
      isExpanded: true,
      value: models.contains(_model) ? _model : null,
      hint: Text(_brand == null ? '自動偵測（不指定車型）' : '車型'),
      items: [for (final x in models) DropdownMenuItem(value: x, child: Text(x, overflow: TextOverflow.ellipsis))],
      onChanged: (m == null || _brand == null) ? null : (v) => setState(() => _model = v),
    );
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Icon(Icons.directions_car_outlined, color: _teal, size: 20),
          const SizedBox(width: 8),
          const Text('車型選擇', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const Spacer(),
          Flexible(child: Text(_host != null ? 'comma $_host' : (widget.hostGetter() != null ? 'comma ${widget.hostGetter()}' : '尚未找到 comma'),
            overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Colors.white54))),
          TextButton(onPressed: _setIp, child: const Text('設定 IP')),
          IconButton(tooltip: '重新讀取', icon: const Icon(Icons.refresh, size: 20),
            onPressed: _loading ? null : () => _tryLoad(force: true)),
        ]),
        const SizedBox(height: 6),
        // 直向：品牌 / 車型上下排；橫向：左右並排
        if (portrait) ...[brandDd, modelDd]
        else Row(children: [
          Expanded(flex: 2, child: brandDd),
          const SizedBox(width: 12),
          Expanded(flex: 3, child: modelDd),
        ]),
        const SizedBox(height: 8),
        SizedBox(height: 44, child: FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: _teal, foregroundColor: Colors.black),
          onPressed: (m == null || _saving) ? null : _confirm,
          icon: _saving
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.check),
          label: const Text('確認', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        )),
        const SizedBox(height: 8),
        Text.rich(TextSpan(children: [
          const TextSpan(text: '目前車型：', style: TextStyle(color: Colors.white70)),
          TextSpan(text: _currentText, style: const TextStyle(color: _teal, fontWeight: FontWeight.bold)),
          if (_pendingDiffers)
            TextSpan(text: '　（待確認：${_brand == null ? '自動偵測' : (_model ?? '未選車型')}）',
              style: const TextStyle(color: Colors.orangeAccent)),
        ]), style: const TextStyle(fontSize: 14)),
        if (_models != null)
          const Text('變更車型後需重新開機 comma 才會生效',
            style: TextStyle(fontSize: 11, color: Colors.white38)),
        if (_status != null)
          Padding(padding: const EdgeInsets.only(top: 4),
            child: Text(_status!, style: const TextStyle(fontSize: 12, color: Colors.white54))),
      ]),
    );
  }

  Widget _button(IconData icon, String label, VoidCallback onTap, {Color? color}) {
    return Expanded(child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: Material(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: SizedBox(height: 86, child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 30, color: color ?? _teal),
            const SizedBox(height: 6),
            FittedBox(child: Text(label, style: const TextStyle(fontSize: 15))),
          ])),
        ),
      ),
    ));
  }

  Future<void> _openSettings() => showDialog<void>(context: context,
      builder: (_) => ViewerSettingsDialog(settings: widget.settings, opHost: widget.hostGetter));

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final portrait = size.height > size.width;
    final buttons = [
      _button(Icons.play_circle_outline, '進入 opview', widget.onEnterOpview),
      _button(Icons.settings_outlined, '顯示設定', _openSettings),
      _button(Icons.tune, '裝置設定', () => openOpSettings(context, widget.hostGetter() ?? _host)),
      _button(Icons.power_settings_new, '離開程式', () => SystemNavigator.pop(), color: Colors.redAccent),
    ];
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Padding(padding: EdgeInsets.only(left: 4, bottom: 8),
            child: Text('opview', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: _teal))),
          _modelSection(portrait: portrait),
          const SizedBox(height: 14),
          // 直向 2×2，橫向一排四個
          if (portrait) ...[
            Row(children: [buttons[0], buttons[1]]),
            const SizedBox(height: 10),
            Row(children: [buttons[2], buttons[3]]),
          ] else
            Row(children: buttons),
        ]),
      )),
    );
  }
}
