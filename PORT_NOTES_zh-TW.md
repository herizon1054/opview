# opview：CommaView 風格行車介面

這是依照 https://commaview.com/#features 公開 Live View 圖片，在 Flutter opview 重新實作的手機介面。不是 CommaView 官方 App，也未複製 commaviewd 的原始碼。保留 opview 名稱、原始授權與第三方聲明。

## 本版已實作

- 左側可捲動操作列：儀表／原版介面切換、連線資訊、公英制切換、全螢幕與返回操作列。
- 底部半圓速度錶、MAX 巡航設定、前車距離／車距時間；啟用／覆寫／未啟用與實驗模式標示。
- 青綠色路徑和投影前車角框；保留原有車道線、道路邊界及校正流程。
- 操作列縮放道路視窗時，影片和車道投影使用同一個新的可用視窗尺寸。
- 前車時間為 dRel / vEgo，單位秒，是車距時間，不是 TTC；自車速度 <= 1 m/s 顯示破折號。前車距離固定公尺，不隨速度單位切換。
- 前車框是雷達位置的圖示，尺寸是顯示啟發式估計，不是視覺辨識車身邊框。
- 模型資料超過 2 秒未更新：停止顯示路徑與舊速度，標示資料中斷；檢查週期 1 秒，因此實際提示約在 2–3 秒後。雷達超過 2 秒未更新時隱藏前車資料。
- 原警告置於儀表之上；警告期間隱藏連線資訊面板。

## comma 與手機的工作分配

新增的畫面繪製、速度錶弧線、雷達位置標記、車距時間、單位換算與逾時檢查都在手機。沿用 opview 的 WebRTC 連線、相機選擇、資料訂閱與更新頻率。沒有安裝 commaviewd、UI export hook、第二路影像或增加 cereal 訂閱。

第一版曾比對 76 個 services/system/android/ios 原檔一致；本次新增 PiP 與亮度後，Android MainActivity、Manifest 已修改。現有 11 個 services/system/data 傳輸與資料模型原檔仍與最初 ZIP 一致。因此本修改沒有新增服務端傳輸要求；但現有 WebRTC 影像／資料串流本來就有負擔，沒有實機 CPU、溫度、網路與耗電量測，不能保證零負載或特定效能。

不改模型推論、radard、MPC、縱向／橫向控制與 CAN。介面按鈕只改本機顯示，不控制車輛。

## 與網站不同之處

本版範圍是橫向 Live View 介面，不是整套 CommaView 功能。沒有新增首頁車輛模型、地圖定位、行程統計、錄影、回放或帳號系統（本次已加入 PiP），也沒有放入假功能按鈕。沒有可靠的道路速限資料來源，因此不顯示網站的速限牌；右側改顯示真實前車資訊。沒有獨立橫向／縱向作動欄位，故不仿造網站的 STEERING ACTIVE / SPEED ACTIVE 判定。

保留原專案橫向顯示限制。介面選擇、速度單位、PiP 開關、亮度與 HUD 節流會保存於手機。斷流時影片仍可能保留 WebRTC 最後一格，請依連線／資料中斷提示判斷。各服務獨立失聯的全面新鮮度管理不在本次範圍。

## 修改檔案

必要程式檔（資料夾結構照原專案）：

1. lib/selfdrive/ui/ui_state.dart
2. lib/selfdrive/ui/onroad/augmented_road_view.dart
3. lib/selfdrive/ui/onroad/model_renderer.dart
4. lib/selfdrive/ui/onroad/dashboard_hud.dart（新增）

原 hud_renderer.dart 和 alert_renderer.dart 仍會使用，不要刪除。沒有需要刪除的檔案；comma 端不用替換檔案。

測試：新增 test/dashboard_test.dart；調整 test/golden/mock_ui_state.dart 與 test/golden/screenshot_test.dart，讓舊 golden 保持測試原版介面並釋放計時器。

## 驗證狀態與編譯

已完成：所有 Dart 檔案通過 tree-sitter Dart 語法解析；現有 11 個傳輸／資料模型原檔逐位元組比對一致；ZIP 完整性檢查。

尚未完成：Flutter 型別分析、單元／widget／golden 測試實際執行、畫面渲染驗證、Android APK 編譯、手機及 comma 實機測試。環境無 Flutter SDK，取得 SDK 的嘗試未成功。語法解析不等於編譯成功，本交付是待編譯驗證原始碼，不是 APK。

原有 pubspec.lock 要求 Flutter >= 3.38.4、Dart >= 3.10.3。安裝符合要求的 Flutter 與 Android SDK，在 opview-main 目錄執行：

```sh
flutter pub get
flutter analyze --no-fatal-infos
flutter test test/dashboard_test.dart test/viewer_features_test.dart
flutter test
flutter build apk --release
```

APK 路徑：build/app/outputs/flutter-apk/app-release.apk。

新增測試覆蓋三種橫向尺寸、按鈕操作、警告優先顯示、資料逾時、車距時間及無效／過期雷達資料。這些測試已提供但尚未執行。實機仍需確認路徑對位、警告可讀性、字型、畫面流暢度與手機溫度。舊 golden 如有差異，應先檢視差異，不要直接更新基準掩蓋問題。
