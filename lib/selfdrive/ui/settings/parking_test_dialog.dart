import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../services/parking/parking_quota_store.dart';

class ParkingTestDialog extends StatefulWidget {
  final String id, secret;
  const ParkingTestDialog({super.key, required this.id, required this.secret});
  @override
  State<ParkingTestDialog> createState() => _ParkingTestDialogState();
}

class _ParkingTestDialogState extends State<ParkingTestDialog>
    with WidgetsBindingObserver {
  Map<String, String> _results = {};
  String _status = '準備測試…';
  bool _running = true;
  final _watch = Stopwatch();
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _watch.start();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _run();
  }

  Future<void> _run() async {
    try {
      await parkingApi.testCities(
        id: widget.id,
        secret: widget.secret,
        report: (rows) {
          if (mounted) setState(() => _results = rows);
        },
        progress: (message) {
          debugPrint('[parking-test] $message');
          if (mounted) setState(() => _status = message);
        },
      );
    } catch (_) {
      if (mounted) setState(() => _status = '無法啟動測試，請確認無其他查詢進行中');
    } finally {
      _timer?.cancel();
      _watch.stop();
      for (final e in _results.entries) {
        debugPrint('[parking-test] ${e.key}: ${e.value}');
      }
      if (mounted) setState(() => _running = false);
    }
  }

  void _stop() {
    if (_running) parkingApi.cancel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached)
      _stop();
  }

  String get _report =>
      'R13 停車端點測試／${_watch.elapsed.inSeconds} 秒\n$_status\n'
      'TDX 每端點最多取 1 筆樣本；不代表全縣市或即時空位正確。\n'
      '${_results.entries.map((e) => '${e.key}: ${e.value}').join('\n')}';
  @override
  void dispose() {
    _stop();
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('各縣市測試（不限時間）'),
    content: SizedBox(
      width: 520,
      height: 420,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('已用 ${_watch.elapsed.inSeconds} 秒 · $_status'),
          const Text('請保持前景。切到背景或關閉即停止，不會自動重跑。'),
          if (_running) const LinearProgressIndicator(),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              children: [
                for (final e in _results.entries)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Text('${e.key}\n${e.value}'),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: _report));
        },
        child: const Text('複製報告'),
      ),
      if (_running) TextButton(onPressed: _stop, child: const Text('停止')),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('關閉'),
      ),
    ],
  );
}
