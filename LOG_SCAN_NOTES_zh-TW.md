# opview：主畫面 ＋ 連線 log ＋ 熱點網段掃描 ＋ 熱點 WebRTC 修正（不含手機 GPS、不含 Google Maps 通知讀取）

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

4. **手機當熱點時 WebRTC 不通的修正**
   - 專案內附修改版 flutter_webrtc 1.3.0（`third_party/flutter_webrtc`，`pubspec.yaml` 以 `dependency_overrides` 指向），
     停用 Android network monitor，讓 WebRTC 能使用熱點介面。原因與原始碼依據見 `third_party/flutter_webrtc/OPVIEW_PATCH_zh-TW.md`。
   - 連線判定：`POST /stream` 成功後等待 WebRTC 真正 connected（最多 12 秒）才顯示 LIVE；逾時顯示
     `WebRTC failed: no media path …` 並重連（以前 signaling 成功就顯示 LIVE，實際影像沒通也看不出來）。
   - **與原行為不同**：WebRTC `disconnected` 改為寬限 5 秒，期間恢復就不重連（以前立即當作失敗重連）；
     `failed` / `closed` 仍立即重連。
5. **WebRTC 統計 log**：每 10 秒 `webrtc stats`（實際位址組、影像收包、收到 / 解出幀數、解析度）、手機端 `ice local` 候選位址。

6. **OP 設定網頁入口**（`lib/selfdrive/ui/settings/op_settings_link.dart`，新增）
   以手機瀏覽器開啟 comma 的 dashy 設定頁 `http://<comma IP>:5088`（dp0111pre `serverd` 為 always_run，offroad 也可開；
   可在此打開「啟用 opview」等設定）。
   - **側欄「OP 設定」只在未連線時顯示**（此時「連線資訊 / 子母畫面」隱藏，空間足夠；連線中 8 顆按鈕會超出
     `test/rail_test.dart` 的 385px 版面限制）。連線後由「顯示設定 → OP 設定網頁」進入。
   - IP 來源：目前連線 / mDNS 找到（連線失敗也保留）/ 快取的 comma IP；都沒有時跳出輸入框，手動輸入的 IP 會記住。
     「顯示設定」另有「手動輸入 IP」。
   - 透過 Android `ACTION_VIEW` 開啟系統瀏覽器（`MainActivity.kt` 的 `openUrl`），不需新增套件或權限。

7. **主畫面**（`lib/selfdrive/ui/home/home_page.dart`，新增）
   - 最上方「車型選擇」：品牌 / 車型下拉（第一項「自動偵測」）→「確認」→ 顯示「目前車型」（comma 實際值；
     與下拉不同時標示「待確認」）。
   - 車型讀寫走 comma dashy serverd（`lib/services/comma_models_api.dart`）：`GET /api/models`、`POST /api/models/select`
     （對照 dp0111pre `dragonpilot/dashy/serverd.py`）。寫入 `dp_dev_model_selected`；`launch_chffrplus.sh` 的
     `set_model_fingerprint` 只在開機啟動時讀取 → **comma 重新開機後生效**（畫面上有提示）。serverd 為 always_run，offroad 可用。
   - comma IP：沿用 opview 探索結果（mDNS / 網段掃描 / 快取）；找不到時每 3 秒重試，或按「設定 IP」手動輸入（記住）。
   - 下方四個按鈕：進入 opview／顯示設定／裝置設定（瀏覽器開啟 comma IP:5088）／離開程式。
   - 連線（探索 / WebRTC）在主畫面時也持續：進入 opview 立即有畫面。主畫面不提供子母畫面。
8. **顯示設定**：新增「打開 App 自動進入 opview」（預設關閉，開啟後跳過主畫面）；「TDX 路況顯示」開關從側欄移到這裡。
9. **opview 畫面側欄**：移除「連線資訊」與「TDX 開關」；新增「退出」回主畫面。Android 返回鍵在 opview 畫面也回主畫面。
   側欄「OP 設定」已移除（改由主畫面「裝置設定」或顯示設定 →「OP 設定網頁」進入）。
   測試同步更新：`rail_test`（按鈕清單、退出按鈕）、`dashboard_test`（移除連線資訊面板檢查）、`tdx_test`（TDX 開關改直接切 state）；
   新增 `home_page_test`（主畫面版面、車型清單解析、設定保存）。

10. **前車鎖定框標籤**（`lib/selfdrive/ui/onroad/model_renderer.dart`，儀表介面）
   - 原本框下方「距離 · 車距時間」改為框下方「距離 · 前車速度」，例如 `32 m · 58 km` / `32 m · 36 mph`（**不顯示 /h**）。
     一律放在框下方；只有超出畫面底部時往上收，左右限制在畫面內。
   - 速度 = radarState `LeadData.vLead`（前車絕對速度，m/s；對照 dp0111pre `cereal/log.capnp`），缺值時用 `vEgo + vRel`；
     單位跟著 km/h / mph 設定。距離固定公尺（與右側儀表卡片一致）；車距時間仍在右側儀表卡片。
   - **本車比前車快超過 20 km/h**（`(vEgo − vLead) × 3.6 > 20`，以 km/h 判斷，不受顯示單位影響）→ 標籤底色改為系統紅色
     `0xF1C92231`（同 `alert_renderer.dart` critical 警示底色；openpilot 原版 0xC92231）。
   - leadOne / leadTwo 各自顯示。原版介面（三角形標記）不變。
   - 尺寸沿用原公式（縮放 = 畫面高 / 600，夾在 0.6–2.0；字 12 × 縮放）：844×390 手機上字約 7 dp。

## 修改檔案（相對原 opview-20261027.zip）
- 新增：`lib/services/app_log.dart`、`lib/services/impl/subnet_scan_discovery.dart`、`lib/selfdrive/ui/settings/op_settings_link.dart`、`lib/selfdrive/ui/home/home_page.dart`、`lib/services/comma_models_api.dart`、
  `test/home_page_test.dart`、`third_party/flutter_webrtc/`（修改版）
- 修改：`pubspec.yaml`（dependency_overrides）
- 修改：`lib/main.dart`、`lib/app.dart`、`lib/services/connection_manager.dart`、`lib/services/transport.dart`、`lib/services/impl/webrtc_transport.dart`、
  `lib/system/webrtc/webrtc_client.dart`、`lib/selfdrive/ui/settings/viewer_settings_dialog.dart`、`lib/selfdrive/ui/onroad/augmented_road_view.dart`、`lib/services/viewer_system.dart`、`lib/services/viewer_settings.dart`、`lib/selfdrive/ui/onroad/model_renderer.dart`、`test/rail_test.dart`、`test/dashboard_test.dart`、`test/tdx_test.dart`、
  `android/app/src/main/kotlin/org/dragonpilot/opview/MainActivity.kt`
- 未改：WebRTC 請求內容（9 個訂閱＋tdx 選用）、AndroidManifest（不要求定位權限）、comma 端不需修改。

## 驗證狀態
已做：所有修改的 Dart / Kotlin / Java 檔 tree-sitter 語法解析無錯誤；熱點問題機制已對照 libwebrtc M137 原始碼。
未做：`flutter analyze`、測試、APK 編譯、實機（環境無 Flutter SDK）。

```sh
flutter clean          # 換成 path 版 flutter_webrtc，建議先清掉舊的建置快取
flutter pub get        # pubspec.lock 的 flutter_webrtc 會變成 source: path
flutter analyze --no-fatal-infos
flutter build apk --release
```
