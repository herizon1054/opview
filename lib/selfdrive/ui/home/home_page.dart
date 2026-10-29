// opview 主畫面
//   最上方：車型選擇（品牌 / 車型）→ 確認按鈕 → 顯示目前 comma 車型
//   下方四個按鈕：進入 opview / 顯示設定 / 裝置設定（瀏覽器開啟 comma IP:5088）/ 離開程式
//
// 車型讀寫透過 comma 的 dashy serverd（lib/services/comma_models_api.dart），offroad 也能用；
// 寫入 dp_dev_model_selected，comma 重新開機後生效。
//
// 主畫面只需要找到 comma（mDNS / 快取 IP / 手動 IP）並連 :5088，不建立 WebRTC（見 ConnectionManager.setStreaming）。
// 讀到的車型清單存在 _lastModels（App 存活期間）：從 opview 畫面返回主畫面時立即顯示，再於背景更新；
// 背景更新失敗不清掉清單（只把狀態標成「上次讀取」）。錯誤只顯示一行簡短原因，完整內容寫 log。

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:opview/services/comma_models_api.dart';
import 'package:opview/services/viewer_settings.dart';
import 'package:opview/selfdrive/ui/settings/viewer_settings_dialog.dart';
import 'package:opview/selfdrive/ui/settings/op_settings_link.dart';
import 'package:opview/services/tdx_support.dart';

const _teal = Color(0xFF48D1CC);
const _card = Color(0xFF0D151B);

// App 存活期間保留最後一次讀到的車型清單（HomePage 每次回到主畫面都會重建）
CommaModels? _lastModels;
String? _lastModelsHost;

class HomePage extends StatefulWidget {
  final ViewerSettings settings;
  /// 目前或最近一次找到的 comma IP（ConnectionManager.lastKnownHost）
  final String? Function() hostGetter;
  final VoidCallback onEnterOpview;
  /// 讀不到 comma 時呼叫（重新搜尋 comma，IP 可能變了）
  final VoidCallback? onHostUnreachable;

  const HomePage({
    super.key,
    required this.settings,
    required this.hostGetter,
    required this.onEnterOpview,
    this.onHostUnreachable,
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
  bool _fresh = false; // 這次進主畫面後已成功讀過（false = 顯示的是上次讀取的清單）
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    final cached = _lastModels;
    if (cached != null) {
      _applyModels(_lastModelsHost, cached);
      _status = null;
    } else {
      _status = '尋找 comma 中…';
    }
    _tryLoad(force: cached != null);
    // comma 還沒找到 / 還沒開機：每 3 秒再試，讀到車型清單就停
    _poll = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!_fresh) _tryLoad(force: true);
    });
  }

  void _applyModels(String? host, CommaModels m) {
    _host = host;
    _models = m;
    _model = m.selected.isEmpty ? null : m.selected;
    _brand = _model == null ? null : m.brandOf(_model!);
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
      if (_models == null) setState(() => _status = '尋找 comma 中…');
      return;
    }
    _loading = true;
    if (_models == null) setState(() => _status = '讀取車型中…');
    try {
      final m = await fetchCommaModels(host);
      if (!mounted) return;
      // 使用者正在改選（待確認）時不要蓋掉下拉選單，只更新清單與目前車型
      final keepPending = _models != null && _pendingDiffers;
      final brand = _brand, model = _model;
      _applyModels(host, m);
      if (keepPending) { _brand = brand; _model = model; }
      _lastModels = m;
      _lastModelsHost = host;
      _fresh = true;
      _status = null;
      debugPrint('[opview] home: models loaded from $host (${m.byBrand.length} brands, selected=${m.selected.isEmpty ? 'AUTO' : m.selected})');
    } catch (e) {
      // 已有清單（上次讀取）時不清掉、也不顯示錯誤，只把狀態標成「上次讀取」
      if (_models == null) _status = '未連線：${shortCommaError(e)}';
      debugPrint('[opview] home: load models failed $host: $e');
      widget.onHostUnreachable?.call();
    } finally {
      _loading = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _setIp() async {
    final v = await askCommaHost(context, _host ?? widget.hostGetter());
    if (v == null || !mounted) return;
    // 手動 IP 只在找不到 comma 時使用；這裡直接用輸入的 IP 讀一次
    _loading = true;
    setState(() => _status = '讀取車型中…');
    try {
      final m = await fetchCommaModels(v);
      if (!mounted) return;
      _applyModels(v, m);
      _lastModels = m;
      _lastModelsHost = v;
      _fresh = true;
      _status = null;
    } catch (e) {
      _status = '未連線：${shortCommaError(e)}（$v）';
      debugPrint('[opview] home: load models failed $v: $e');
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
      _lastModels = m;
      _lastModelsHost = host;
      setState(() => _applyModels(host, m));
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
          const SizedBox(width: 8),
          _stateChip(),
          const Spacer(),
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
          // 選擇與 comma 目前車型相同時不需要再確認：按鈕停用並顯示「已是目前車型」
          onPressed: (m == null || _saving || !_pendingDiffers) ? null : _confirm,
          icon: _saving
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(m != null && !_pendingDiffers ? Icons.check_circle_outline : Icons.check),
          label: Text(m != null && !_pendingDiffers ? '已是目前車型' : '確認變更',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
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
            child: Text(_status!, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Colors.white54))),
        ValueListenableBuilder<bool?>(valueListenable: tdxSupport, builder: (context, tdx, _) =>
          tdx == false
            ? const Padding(padding: EdgeInsets.only(top: 4), child: Text(tdxUnsupportedText,
                style: TextStyle(fontSize: 12, color: Colors.orangeAccent)))
            : const SizedBox.shrink()),
      ]),
    );
  }

  /// 標題旁的狀態：已讀取 / 上次讀取 / 讀取中 / 未連線
  Widget _stateChip() {
    final (text, color) = _models != null
        ? (_fresh ? ('已讀取', _teal) : ('上次讀取', Colors.white54))
        : (_loading ? ('讀取中', Colors.white54) : ('未連線', Colors.orangeAccent));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withAlpha(140))),
      child: Text(text, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
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
