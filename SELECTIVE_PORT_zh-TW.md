# 選擇性移植：手機 UI、PiP、亮度、繪圖節流

## 功能與使用方式

這一版是在先前 CommaView 風格 opview 上，選擇性移植／調整 opview-rivian-support 的手機端功能。不是整份 Rivian 分支覆蓋，也不是原 Enhanced / Detailed 介面逐像素複製。

左側「顯示設定」可選：
- 儀表介面：保留半圓速度錶、MAX、青綠色路徑及前車標記。
- 原版介面：原 opview HUD。
- 儀表＋車輛資訊：增加方向盤角度、加速度、左右方向燈與盲點狀態。只讀取原本已訂閱的 carState；未知數值顯示「—」。
- 公英制、PiP、App 亮度、降低儀表更新頻率。設定存於手機，重開可恢復。

PiP 預設關閉。在支援 PiP 的 Android 8+ 裝置開啟後，連線時按 Home，或按側欄「子母畫面」進入。Android 12+ 使用系統自動進入模式；8–11 使用 onUserLeaveHint。裝置／系統設定若拒絕，PiP 可能不可用。小窗沿用同一個 RTCVideoRenderer 與連線，隱藏側欄、大儀表和設定面板，保留簡化車速、MAX、前車與最多三行警告。長警告可能省略，完整內容需回到大畫面。

亮度僅修改 App 視窗，範圍 5–100%；「跟隨系統」交回 Android 控制。不要求修改系統亮度權限。iOS 不提供這套 Android PiP／亮度原生功能。

HUD 預設每 4 次 UI 版本更新重建一次，模型 20 Hz 時約 5 Hz，可關閉節流。路徑、前車投影與警告不放入節流快取；作動狀態、資料逾時、版面、單位、視窗尺寸等變化會立即使儀表快取失效。不是降低模型推論頻率，也不是降低 comma 訊息頻率。實際節省手機 CPU/GPU 幅度尚未量測。

## comma 負擔及 dplcc 相容性

- 現有 WebRTC、connection_manager、cereal_adapter、data/models.dart 均未修改。
- 保持原本 9 個訂閱：carState / selfdriveState / controlsState / modelV2 / liveCalibration / radarState / longitudinalPlan / deviceState / roadCameraState。
- 請求不加入 Rivian 版的 enabled 參數，保持相容本次提供的 dplcc StreamRequestBody。
- 不加入 Sunnypilot 額外訂閱、不改 comma 端、不加第二條串流、不安裝 commaviewd。
- PiP 顯示期間，原串流會持續使用 comma 編碼及傳輸資源；相比原本按 Home 就停止，持續時間會增加。退出 PiP／真正進入背景才關閉連線。
- 未移植新版協定、APK 更新器、速限與路名資料訂閱、Rivian 角度／扭矩模式判斷。

## 本次修改／新增檔案

修改：
- lib/app.dart
- lib/selfdrive/ui/ui_state.dart
- lib/selfdrive/ui/onroad/augmented_road_view.dart
- android/app/src/main/AndroidManifest.xml
- android/app/src/main/kotlin/org/dragonpilot/opview/MainActivity.kt

新增：
- lib/services/viewer_settings.dart
- lib/services/viewer_system.dart
- lib/selfdrive/ui/settings/viewer_settings_dialog.dart
- lib/selfdrive/ui/onroad/compact_hud.dart
- lib/selfdrive/ui/onroad/throttled_hud.dart
- lib/selfdrive/ui/onroad/vehicle_details.dart
- test/viewer_features_test.dart

保留原始授權；所參考 Rivian 分支亦為 Rick Lan 的 opview 授權。本次未加入其圖示素材或更新器。沒有需要刪除的程式檔。壓縮檔為完整累積版本，包含先前的 CommaView 風格修改。

## 驗證狀態

已執行：Dart tree-sitter 語法解析、Android Manifest XML 解析、原有 11 個傳輸與資料模型檔案逐位元組比對、以 dplcc 原請求類別驗證 9 服務請求可建構、確認車輛資訊新增欄位存在於 dplcc car.capnp。

新增 Flutter 測試：設定保存與亮度重置、PiP 通道、HUD 節流與狀態強制刷新、320×180 小窗與警告。原有三種橫向尺寸測試仍保留。

尚未執行 Flutter analyze、Flutter tests、Android APK 編譯、實際畫面驗證與 PiP 手機測試。環境沒有 Flutter SDK，嘗試的 SDK 下載回傳 404，沒有把語法解析當成編譯成功。這份交付是待編譯／實機驗證的原始碼。

使用 Flutter >= 3.38.4 / Dart >= 3.10.3 及 Android SDK，在專案目錄執行：

```sh
flutter pub get
flutter analyze --no-fatal-infos
flutter test
flutter build apk --release
```

實機檢查重點：Home 進入 PiP、展開小窗是否保持串流、關閉小窗後是否斷線、一般背景切換及鎖屏、亮度跟隨系統、設定保存、警告出現時自動關閉設定視窗。各廠牌 Android 的 PiP 與 Flutter 生命週期仍需實測。

## 無作用控制項清理

- Android 不支援或未允許 PiP 時，隱藏 PiP 設定與入口，不顯示灰色開關；進入失敗時顯示原因並隱藏入口。
- 亮度原生呼叫不可用或失敗時，隱藏亮度開關及滑桿。
- 有警告時隱藏原本會直接返回的顯示設定按鈕；連線資訊按鈕僅在已連線且無警告時出現，避免面板被遮住卻仍可按。
- 未實作錄影、地圖、回放等功能，沒有其按鈕。
- 新增不支援原生功能時隱藏控制項的 widget 測試，尚未執行 Flutter 測試。
