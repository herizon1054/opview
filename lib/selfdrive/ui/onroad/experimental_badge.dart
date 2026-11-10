// 實驗模式圖示：開啟實驗模式時顯示在道路畫面左側中上（直向、橫向、儀表 / 原版介面都顯示）。
// 狀態以 comma 回報的 selfdriveState.experimentalMode 為準（UIState.experimentalMode），資料中斷時不顯示。
// openpilot 原廠在右上角；opview 右上角已有起步提醒圓圈、車輛資訊框與全螢幕叫回按鈕，刻意改放左側中上。
// 圖示用琥珀色燒杯，與側欄「實驗 開」按鈕、直向卡片的 EXP 一致。

import 'package:flutter/material.dart';

class ExperimentalBadge extends StatelessWidget {
  final double size;
  const ExperimentalBadge({super.key, required this.size});

  @override
  Widget build(BuildContext context) => IgnorePointer(child: Container(
    width: size, height: size,
    decoration: BoxDecoration(
      color: const Color(0xCC10191D),
      shape: BoxShape.circle,
      border: Border.all(color: Colors.amberAccent, width: size * .06),
    ),
    child: Icon(Icons.science, color: Colors.amberAccent, size: size * .58,
        semanticLabel: '實驗模式'),
  ));
}
