import 'package:flutter/material.dart';
import '../ui_state.dart';

// Uses only fields from carState already present on the existing stream.
// 方向燈、盲點不在這裡列文字：方向燈 = 儀表卡片兩側箭頭，盲點 = 影像左右邊緣黃色光暈（直向 / 橫向相同）。
class VehicleDetails extends StatelessWidget {
  final UIState state;
  final bool stale;
  const VehicleDetails({super.key, required this.state, required this.stale});
  @override
  Widget build(BuildContext context) => IgnorePointer(child: Align(
    alignment: Alignment.topRight,
    child: Container(margin: const EdgeInsets.fromLTRB(0, 12, 12, 0),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: const Color(0xD010191D), borderRadius: BorderRadius.circular(14)),
      child: Text(
        '方向盤  ${stale ? "—" : state.steeringAngleDeg?.toStringAsFixed(1) ?? "—"}°\n'
        '加速度  ${stale ? "—" : state.aEgo?.toStringAsFixed(2) ?? "—"} m/s²',
        style: const TextStyle(color: Colors.white70, fontSize: 11, height: 1.5)),
    ),
  ));
}
