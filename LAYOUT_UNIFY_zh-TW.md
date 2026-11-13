# 直向 / 橫向版面統一（2026-11-12）

示意圖：`docs/layout_unified.png`。原則：同一種資訊在兩個方向用同一個元件、同一種外觀，只有位置與大小不同。

## 元件與位置
| 元件 | 內容 | 直向 | 橫向 |
|---|---|---|---|
| ① 警示列 | 橫向：碰撞注意（紅）＞ 車速驟降（黃）＞ TDX 事件（深色）；**直向只剩碰撞注意**（2026-11-13，事件與車速驟降收進路況卡） | 道路畫面上方置中（字級 16） | 道路畫面上方置中（字級約 22） |
| ② 儀表卡片 | MAX｜車速｜前車距離 / 車頭時距；兩側方向燈 | 道路畫面下方 | 畫面下方置中 |
| ③ 路況卡 `TdxRouteCard` | 前方車速＋分級；直向再加 TDX 事件（捲動）；國道再加車速驟降或回堵、車道車速各一行 | 儀表卡片下方（× 1.3） | 左上角，opview 標題與警示列下方（寬 ≤ 270） |
| ④ LINE / 停車 | — | 路況卡下方 | 不顯示（同前） |
| 實驗模式圖示 | openpilot HUD 圖案 `selfdrive/assets/icons/experimental.png` | 道路畫面左側中上 | 右上角 |

## 跟之前不同的地方
- 直向的事件列從下方資訊區移到道路畫面上方（與橫向相同），出現 / 消失不再推動卡片與 LINE。
- 直向的「前方車速列＋兩列國道資訊」→ 一張路況卡。
- 橫向卡片右欄原本有 TDX 時改成「前方車速」，現在固定是前車（與直向相同）；前方車速改在路況卡。
  「無卡片」時的前方車速膠囊、上方國道膠囊都拿掉（路況卡取代）。
- ENGAGED / EXPERIMENTAL 文字徽章（橫向左下）、直向卡片角落的 EXP 拿掉；狀態看卡片顏色，實驗模式看圖示。
  資料中斷 / 延遲時，橫向左下仍顯示警告徽章。
- 實驗模式圖示從 Material 燒杯改成 openpilot HUD 的圖案（黑色半透明圓底，同 `onroad/exp_button.py`）。
  檔案取自分支（openpilot-test 的 `selfdrive/assets/icons/experimental.png` 是 LFS 指標，
  實際檔案用 dplcc `dragonpilot/dashy/web/dist/icons/exp/experimental.png`，sha256 與 LFS oid `1e58deb1…` 相同）。
- 橫向右上角由上往下：全螢幕叫回按鈕（全螢幕時）→ 實驗模式圖示 → 起步提醒圈 / 車輛資訊框，不重疊。
  起步提醒圈在警示列出現時也會往下讓位（直向、橫向）。
- 面板外觀統一 `opviewPanel()`：半透明深底 0xDC0D171C、青綠細邊框、圓角 14
  （儀表卡片、路況卡、停車面板、車輛資訊框；LINE 同底色、綠色邊框）。
- 側欄 / 操作列的「實驗 開／關」按鈕圖示**沒有改**（仍是 Material 燒杯，按鈕列都用同一套 Material 圖示）。

## 檔案
| 檔案 | 說明 |
|---|---|
| `lib/selfdrive/ui/onroad/freeway_info.dart` | 改為路況卡 `TdxRouteCard`（取代前一版的 FreewayInfo） |
| `lib/selfdrive/ui/onroad/portrait_panel.dart` | 卡片 → 路況卡 → LINE / 停車；拿掉 TDX 列、國道列、事件列 |
| `lib/selfdrive/ui/onroad/augmented_road_view.dart` | 警示列兩個方向都在道路畫面上；橫向路況卡；實驗模式圖示位置；右上角讓位 |
| `lib/selfdrive/ui/onroad/dashboard_hud.dart` | `opviewPanel`、`tdxCongestionLabel`；拿掉狀態徽章（資料中斷除外）、無卡片膠囊、右欄 TDX、卡片 EXP |
| `lib/selfdrive/ui/onroad/experimental_badge.dart` | openpilot 圖案 |
| `lib/selfdrive/ui/onroad/stop_go_overlay.dart`、`vehicle_details.dart`、`parking_panel.dart` | 讓位、共用外觀 |
| `assets/icons/experimental.png`、`pubspec.yaml` | 新資產 |
| `test/*` | tdx_test、dashboard_test、line_notifications_test、orientation_test、experimental_badge_test 依新版面更新 |

## 尚未驗證
本環境沒有 Flutter SDK，未編譯。請跑 `flutter analyze` 與 `flutter test --exclude-tags golden`。
golden 截圖（`test/golden/goldens`）會跟著變，CI 本來就略過；要更新請在本機 `flutter test --update-goldens --tags golden`。
