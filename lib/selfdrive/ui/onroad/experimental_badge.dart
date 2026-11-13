// 實驗模式圖示：開啟實驗模式時顯示在道路畫面上（直向、橫向、儀表 / 原版介面都顯示）。
// 狀態以 comma 回報的 selfdriveState.experimentalMode 為準（UIState.experimentalMode），資料中斷時不顯示。
// 圖案（2026-11-12）：改用 openpilot HUD 的實驗模式圖示 selfdrive/assets/icons/experimental.png
// （onroad/exp_button.py 的 _txt_exp；檔案 sha256 1e58deb1…，與分支 LFS 指標一致），
// 畫法同 ExpButton：黑色半透明圓底（alpha 166）＋圖示（openpilot 按鈕 192 / 圖示 140 ≈ 0.73）。
// 位置：直向在道路畫面左側中上；橫向在右上角（同 openpilot），全螢幕叫回按鈕、起步提醒圈、車輛資訊框依序往下讓位。

import 'package:flutter/material.dart';

const experimentalIconAsset = 'assets/icons/experimental.png';

class ExperimentalBadge extends StatelessWidget {
  final double size;
  const ExperimentalBadge({super.key, required this.size});

  @override
  Widget build(BuildContext context) => IgnorePointer(child: Container(
    width: size, height: size,
    alignment: Alignment.center,
    decoration: const BoxDecoration(color: Color(0xA6000000), shape: BoxShape.circle),
    child: Image.asset(experimentalIconAsset, width: size * .73, height: size * .73,
      filterQuality: FilterQuality.medium, semanticLabel: '實驗模式',
      // 資產載入失敗（不該發生）時退回原本的燒杯圖示
      errorBuilder: (context, error, stack) => Icon(Icons.science, color: Colors.amberAccent, size: size * .58)),
  ));
}
