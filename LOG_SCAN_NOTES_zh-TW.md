# opview：連線 log ＋ 熱點網段掃描（不含手機 GPS）

## 新增功能
1. **網段掃描探索**（`lib/services/impl/subnet_scan_discovery.dart`，新增）
   mDNS 搜尋 3 秒後，同時掃描手機各網路介面（含熱點介面、排除行動網路）所在 /24 的 port 5001，
   以 `GET /schema?services=carState` 確認是 webrtcd 才連線；找不到每 10 秒重掃。
   解決「手機開熱點、comma 連熱點」時 mDNS 掃不到、快取家用 IP 因網段不同被略過的問題。
2. **持久化 log**（`lib/services/app_log.dart`，新增）
   攔截所有 debugPrint 與未捕捉例外，寫入 App 私有目錄 `opview.log`（1 MB 輪替，最多約 2 MB）。
   內容：App/手機資訊、網路介面 IP、WiFi 變化、連線狀態列、mDNS/掃描、WebRTC（answer/ice/pc/data channel/track）、
   `video frame WxH`（手機實際解出影像）、每 10 秒各 service 收到筆數（rx 10s）、App 前景/背景。
3. **分享 log**：顯示設定 → 連線紀錄（log）→「分享 log」。
   Android 10+ 存到「下載/opview/opview-log-日期時間.txt」並開啟系統分享選單；Android 9 以下分享最後 100 KB 文字。
   「清除 log」可在測試前清空。

## 修改檔案（相對原 opview-20261027.zip）
- 新增：`lib/services/app_log.dart`、`lib/services/impl/subnet_scan_discovery.dart`
- 修改：`lib/main.dart`、`lib/app.dart`、`lib/services/connection_manager.dart`、
  `lib/system/webrtc/webrtc_client.dart`、`lib/selfdrive/ui/settings/viewer_settings_dialog.dart`、
  `android/app/src/main/kotlin/org/dragonpilot/opview/MainActivity.kt`
- 未改：WebRTC 請求內容（9 個訂閱＋tdx 選用）、AndroidManifest（不要求定位權限）、comma 端不需修改。

## 驗證狀態
已做：所有修改的 Dart / Kotlin 檔 tree-sitter 語法解析無錯誤。
未做：`flutter analyze`、測試、APK 編譯、實機（環境無 Flutter SDK）。

```sh
flutter pub get
flutter analyze --no-fatal-infos
flutter build apk --release
```
