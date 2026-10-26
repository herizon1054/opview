// Small-window presentation adapted to the existing dplcc telemetry fields.
import 'package:flutter/material.dart';
import '../ui_state.dart';

class CompactHud extends StatelessWidget {
  final UIState state;
  final bool stale;
  const CompactHud({super.key, required this.state, required this.stale});
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
    final u = c.maxHeight / 100;
    Widget pill(String text, double font) => Container(
      padding: EdgeInsets.all(3 * u), color: const Color(0xCC10191D),
      child: Text(text, style: TextStyle(fontSize: font * u, color: Colors.white,
        fontWeight: FontWeight.bold, height: 1.1)),
    );
    return IgnorePointer(child: Stack(children: [
      Positioned(top: 3*u, left: 3*u, child: pill(stale ? '—' :
        '${state.displaySpeed.round()} ${state.isMetric ? "km/h" : "mph"}', 12)),
      Positioned(top: 3*u, right: 3*u, child: pill(
        'MAX ${!stale && state.isCruiseSet ? state.setSpeed.round() : "—"}', 8)),
      if (!stale && state.leadDistance != null)
        Positioned(bottom: 3*u, left: 0, right: 0, child: Center(child: pill(
          '${state.leadDistance!.round()} m · ${state.leadHeadway?.toStringAsFixed(1) ?? "—"} s', 7))),
      if (stale) Positioned(bottom: 3*u, left: 0, right: 0,
        child: Center(child: pill('資料中斷', 8))),
      if (state.alertSize != 0)
        Positioned(bottom: 0, left: 0, right: 0, child: Container(
          color: state.alertStatus == 2 ? const Color(0xFFCC2233) : const Color(0xEE533C16),
          padding: EdgeInsets.all(3*u),
          child: Text([state.alertText1, state.alertText2].where((s) => s.isNotEmpty).join('\n'),
            maxLines: 3, overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Colors.white, fontSize: 7*u, fontWeight: FontWeight.bold)),
        )),
    ]));
  });
}
