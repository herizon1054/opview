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

11. **直向 / 橫向自動切換排版**
   - 解除橫向鎖定：`main.dart`（portraitUp + landscapeLeft/Right，不含倒立直向）、AndroidManifest
     `screenOrientation="fullUser"`（依手機「自動旋轉」設定；`configChanges` 已含 orientation|screenSize，旋轉不重建畫面、
     不中斷 WebRTC）、iOS Info.plist 加入 Portrait。
   - **opview 畫面**：直向時操作列改成影像下方一排按鈕（同側欄的按鈕與順序，含 LIVE / OFFLINE）；橫向維持左側側欄。
     影像仍為 BoxFit.cover 置中裁切，投影公式 `videoScale = max(W/camW, H/camH)`、主點在中心，直向一樣對齊。
   - HUD / 警示 / 邊框 / 前車框改依**短邊**縮放（`min(W, H)`）：橫向 = 高，與原本完全相同；直向 = 寬，避免放大超出寬度。
   - 儀表卡片直向放寬到畫面寬 66%；狀態徽章移到卡片上方；方向燈箭頭依卡片外側剩餘空間自動縮小（橫向不受影響）。
   - **主畫面**：直向時品牌 / 車型下拉上下排、四個按鈕 2×2；橫向維持原排版。
   - 新增 `test/orientation_test.dart`（390×844 直向：下方操作列、全螢幕、方向燈不溢出；844×390 橫向側欄；主畫面 2×2）。

12. **直向 opview 改用方案 B（影像在上完整顯示、儀表在下）**
   - 影像區高度 = 寬 ×（相機高 / 寬），依目前串流相機（road / wideRoad）的原始比例 1928×1208，影像**不裁切**；
     因比例相同，cover 投影等於完整顯示，路徑與前車框仍對齊。
   - 影像下方新增 `PortraitPanel`（`lib/selfdrive/ui/onroad/portrait_panel.dart`），由上而下：
     徽章（ENGAGED / EXPERIMENTAL）＋ opview 字樣 → 儀表卡片（寬 = 畫面寬 − 32，高 = 寬 × 0.42，上限 150，空間不足自動縮）
     → TDX 列「前方車速 ＋ TDX 順暢 / 車多 / 壅塞」（有資料才顯示）→ TDX 事件（過長自動捲動）→ 警示區。
   - 直向儀表卡片右欄固定顯示**前車距離 / 車頭時距**（TDX 前方車速移到獨立一列）；橫向仍照原本，右欄有 TDX 時顯示前方車速。
   - 警示（alert）：small / mid 貼在資訊區底部（操作列上方），字級依畫面寬；full 蓋滿資訊區。直向影像上不再疊警示 / TDX 跑馬燈。
   - 方向燈箭頭：直向放在影像左下 / 右下角（卡片佔滿寬度，兩側沒有空間）。
   - 操作列維持一排在最下方；全螢幕時操作列收起、資訊區往下延伸，右上角叫回按鈕不變。
   - 原版介面（三角形標記）直向：原版 HUD 疊在影像上，資訊區只放 TDX 事件與警示。
   - 儀表卡片抽成共用的 `DashboardCard`（`dashboard_hud.dart`），橫向 `DashboardHud` 外觀不變。
   - `test/orientation_test.dart`：影像高 = 390×1208/1928、卡片在影像下方且寬 > 85%、方向燈在影像內；TDX 列 / 事件 / 警示位置。

13. **影像卡住（畫面不同步）自動恢復**
   - 現象（2026-10-28 17:08–17:13 log＋影片）：儀表數字持續更新，影像停在舊畫面、偶爾整片綠色。
     統計：封包每秒約 107 個、lost=0、位元率正常（comma 有照常送），但手機每 10 秒只解出約 6–7 幀、丟棄約 190 幀
     （正常為每 10 秒解 200 幀、丟 0–14 幀）。17:13 App 切回前景重新建立連線後立刻恢復 20 fps。
   - 判斷：問題在手機端接收 / 解碼器狀態，不是網路或熱點；熱點連線本身正常（pair 為 172.20.10.x wifi）。
   - 修正：`ConnectionManager` 每 5 秒檢查一次；資料有在流（≥100 封包）但解碼 < 5 fps，連續 2 次（約 10 秒）
     就自動重建影像連線。2 分鐘內最多自動重建 3 次，避免無限重連。log 會出現 `video stall?` 與 `restarting video stream`。
   - log 的 `webrtc stats` 新增：`fps`、`decMs`（平均解碼時間）、`jbMs`（平均 jitter buffer 延遲）、`nack` / `pli` / `fir`、
     `freeze`（凍結次數 / 秒數）、`dec=`（解碼器實作名稱）。下次再發生可分辨是解碼器慢還是緩衝等待。

14. **（Impeller 版：此項未套用，manifest 維持 Flutter 預設的 Impeller）影像卡住：關閉 Impeller 做對照測試**（`AndroidManifest.xml` 加 `io.flutter.embedding.android.EnableImpeller=false`）
   - 使用者回報：手機重開、App 重開、不開其他 App 仍會發生 → 不是偶發的解碼器狀態，較可能是固定路徑上的問題。
   - libwebrtc M137 `AndroidVideoDecoder.deliverTextureFrame`：上一張解出的畫面紋理還沒被釋放時，新解出的畫面直接丟棄
     （`releaseOutputBuffer(index, false)`，註解 "We are still waiting for texture for the previous frame, drop this one"）；
     這些幀計入 framesDropped、不計入 framesDecoded。與卡住時的統計（封包全到、每秒解 0.6 幀、丟 19 幀）吻合。
   - 紋理釋放取決於 flutter_webrtc 的 `SurfaceTextureRenderer`（EglRenderer）把畫面畫進 Flutter 的 SurfaceProducer；
     Flutter 3.38 在 Android API 29+ 預設 Impeller。關閉後改用 OpenGL 渲染器，若卡住 / 綠畫面消失即可確認。
   - 要恢復 Impeller：刪掉該 meta-data 即可。

15. **傳輸延遲記錄**（`lib/services/latency_tracker.dart`，每 10 秒一行 `latency 10s:`）
   - 資料：webrtcd 每筆訊息帶 comma 的 `logMonoTime`；手機收到時間 − logMonoTime = 延遲 + 兩台時鐘固定差。
     兩台沒對時，取 60 秒內最小差值為基準，記錄**比最順那筆多出的延遲**（平均 / p95 / 最大）與訊息最大到達間隔（gap）。
     例：`data +3ms avg / +12 p95 / +85 max (n=480), gap max 140ms`。正常約個位數 ms；持續變大 = 排隊 / 網路 / comma 忙碌。
   - 影像：由 WebRTC 統計的本視窗差值算出 jitter buffer 平均等待＋平均解碼時間＋RTT/2，
     例：`video jb 45ms + dec 8ms + rtt/2 7ms ≈ 60ms`（手機端可量到的部分，不含 comma 編碼與送出前排隊）。
   - 限制：沒有對時，量不到絕對的「comma → 手機」總延遲；記錄的是延遲變化與手機端影像延遲。
   - 新增 `test/latency_tracker_test.dart`。

## 修改檔案（相對原 opview-20261027.zip）
- 新增：`lib/services/app_log.dart`、`lib/services/impl/subnet_scan_discovery.dart`、`lib/selfdrive/ui/settings/op_settings_link.dart`、`lib/selfdrive/ui/home/home_page.dart`、`lib/services/comma_models_api.dart`、`lib/selfdrive/ui/onroad/portrait_panel.dart`、`lib/services/latency_tracker.dart`、`test/latency_tracker_test.dart`、
  `test/home_page_test.dart`、`third_party/flutter_webrtc/`（修改版）
- 修改：`pubspec.yaml`（dependency_overrides）
- 修改：`lib/main.dart`、`lib/app.dart`、`lib/services/connection_manager.dart`、`lib/services/transport.dart`、`lib/services/impl/webrtc_transport.dart`、
  `lib/system/webrtc/webrtc_client.dart`、`lib/selfdrive/ui/settings/viewer_settings_dialog.dart`、`lib/selfdrive/ui/onroad/augmented_road_view.dart`、`lib/services/viewer_system.dart`、`lib/services/viewer_settings.dart`、`lib/selfdrive/ui/onroad/model_renderer.dart`、`lib/selfdrive/ui/onroad/dashboard_hud.dart`、`lib/main.dart`、`ios/Runner/Info.plist`、`test/orientation_test.dart`（新增）、`test/rail_test.dart`、`test/dashboard_test.dart`、`test/tdx_test.dart`、
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

## 16. 硬體解碼器退回軟體解碼的診斷＋renderer 建立時機（2026-10-29）
- 實測（Xiaomi 26012RN62Y，Android 16）：`dec=c2.android.avc.decoder (fallback from: c2.qti.avc.decoder)`，平均解碼 122 ms/幀，
  影像延遲約 190 ms（jb ≈70 + dec ≈122）。comma 端（opview_link_test CSV）全幀送出、webrtcd CPU 17–31%，問題在手機端。
- 新增 `lib/services/webrtc_native_log.dart`：透過 flutter_webrtc 的 `NativeLogsListener`（injectable logger）把 libwebrtc
  原生 warning / error 寫進 opview log（行首 `[webrtc]`），解碼相關每 10 秒最多 60 行、其他 8 行。用來看硬體解碼為何失敗。
  需在 `main()` 任何 WebRTC 呼叫前 `install()`（log 等級只在 flutter_webrtc 首次初始化時生效）。
  - `third_party/flutter_webrtc/lib/flutter_webrtc.dart` 加 `export 'src/native_logs_listener.dart' show NativeLogsListener;`
  - `pubspec.yaml` 加 `logger: ^2.6.2`（原本即為 flutter_webrtc 的間接依賴，版本 2.6.2）
- `webrtc_client.dart`：影像 renderer 改在 webrtcd 回 answer 之後才建立；comma 沒開 webrtcd（Connection refused）時的重試
  不再每次建立 / 釋放 Flutter 畫布（實測 11 分鐘重試建了 30 個）。onTrack 早於 renderer 建立時先暫存 stream。
- 2026-10-29 01:36 實測原生 log 找到原因：`c2.qti.avc.decoder` 在 `MediaCodec.configure()` 拋 `IllegalArgumentException`
  （`AndroidVideoDecoder.initDecodeInternal` → `initDecode failed` → `Decoder falling back to software decoding`）。
  「Trying to create decoder for unsupported format」是 libwebrtc 內建軟體解碼器不含 H.264 的正常訊息，與失敗無關。
  推測：該機高通解碼器不支援 1928×1208（超過 1920×1088）。App 啟動時新增 `codec ...` 行（MainActivity `codecs`）
  記錄每個 H.264 解碼器的寬高範圍與 `1928x1208=true/false`，用來確認。
- 原生 log 濾掉每次建 PeerConnection 都會出現的無關訊息（duplicate codecs 等）。

## 17. comma 端 webrtcd 未更新的提示（2026-10-29 車上實測 comma-5dd6a0e1 全部 HTTP 500）
- 原因：該台 comma 尚未更新到新版 webrtcd（只認 `cameras`），新版 opview 只送 `initCamera`。
- 決定：**不相容舊格式**（comma 端一律更新）。新格式＋tdx、新格式兩次都 500 時，錯誤訊息加上
  「comma 端 webrtcd 可能未更新：請更新 comma 分支後重開」，會出現在連線畫面的狀態列與 log；
  `WebrtcdHttpException.outdatedServer = true`。
- 測試：`test/webrtc_migration_test.dart` 新增一項（兩次 500 → outdatedServer，且不改送舊格式）。

## 18. 裝置設定限 offroad / P 檔；不支援 TDX 的分支顯示提示（2026-10-29）
- 裝置設定（comma 設定網頁 :5088，主畫面按鈕與顯示設定內的「開啟 OP 設定」），`op_settings_link.dart` 的
  `decideOpSettings()`：
  - opview 連線中且資料 3 秒內有更新：`deviceState.started == false`（offroad）或 `gearShifter == park` 才允許。
  - 否則問 comma serverd（always_run）`GET :5088/api/init` 的 `isOffroad`：offroad 允許；
    onroad 但 opview 沒連上 → 無法確認檔位，不允許；**連不到 comma → 顯示「未連線」**。
  - offroad 時 webrtcd 不跑、opview 一定未連線，所以 offroad 靠 serverd 確認（不改 comma 端）。
- TDX：沒有 tdx service 的分支，帶 tdx 的請求 500 → 不帶 tdx 重試成功（原有機制）。新增
  `hostSupportsOptionalServices(host)` 與 `lib/services/tdx_support.dart` 的 `tdxSupport`（true / false / null）。
  不支援時：顯示設定的「TDX 路況顯示」開關停用並顯示「此分支不支援 TDX（comma 端沒有 tdx 服務）」，
  主畫面車型區塊下方顯示「此分支不支援 TDX」，log 記一行 `TDX: 此分支不支援 TDX`。
- 測試：`test/device_settings_guard_test.dart`。

