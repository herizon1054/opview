import 'package:flutter/material.dart';
import '../ui_state.dart';
import 'dashboard_hud.dart' show opviewPanel;

// Uses only fields from carState already present on the existing stream.
// 方向燈、盲點不在這裡列文字：方向燈 = 儀表卡片兩側箭頭，盲點 = 影像左右邊緣黃色光暈（直向 / 橫向相同）。
class VehicleDetails extends StatelessWidget {
  final UIState state;
  final bool stale;
  /// 上緣（橫向右上角有實驗模式圖示時往下讓位）
  final double top;
  const VehicleDetails({super.key, required this.state, required this.stale, this.top = 12});
  @override
  Widget build(BuildContext context) => IgnorePointer(child: Align(
    alignment: Alignment.topRight,
    child: Container(margin: EdgeInsets.fromLTRB(0, top, 12, 0),
      padding: const EdgeInsets.all(10),
      decoration: opviewPanel(),
      child: Text(
        '方向盤  ${stale ? "—" : state.steeringAngleDeg?.toStringAsFixed(1) ?? "—"}°\n'
        '加速度  ${stale ? "—" : state.aEgo?.toStringAsFixed(2) ?? "—"} m/s²',
        style: const TextStyle(color: Colors.white70, fontSize: 11, height: 1.5)),
    ),
  ));
}
