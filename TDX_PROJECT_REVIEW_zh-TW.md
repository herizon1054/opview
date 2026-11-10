# opview-tdx 分支統整與審查（2026-11-10）

本文件整理 opview-tdx 分支相對原始 opview-stopcar 的所有變更、逐檔審查結果、這次修正的問題、
畫面配置的合理性檢查，以及仍存在的限制。可單獨閱讀，也可提供給其他分支開發者參考。

> 本環境沒有 Flutter / Dart SDK，以下審查為人工逐行閱讀＋Python 對照驗算，**未經編譯**。
> 請以 CI 的 `flutter analyze` 與 `flutter test` 為準（指令見第 6 節）。

---

## 1. 功能總覽

| # | 功能 | 主要檔案 | 說明文件 |
|---|---|---|---|
| 1 | TDX 路況內建（手機 GPS + TDX API，不再讀 comma 的 tdx service） | `lib/services/tdx/tdx_traffic_core.dart`、`tdx_traffic_service.dart` | `TDX_BUILTIN_zh-TW.md` |
| 2 | TDX 金鑰與停車查詢共用設定、共用每分鐘 5 次額度 | `parking_settings_dialog.dart`、`viewer_settings_dialog.dart` | `PARKING_zh-TW.md` |
| 3 | LINE 通知監控（移植自 opview-uber） | `lib/services/line_notifications.dart`、`OpviewNotificationListener.kt`、`MainActivity.kt`、`AndroidManifest.xml` | 本文件 §3.3 |
| 4 | 直向資訊區重新配置（卡片變矮、LINE / 停車共用剩餘高度、EXP 標記） | `portrait_panel.dart`、`parking_panel.dart`、`dashboard_hud.dart` | 本文件 §4 |
| 5 | 「顯示儀表卡片」開關（直向空間讓給 LINE / 停車） | `viewer_settings.dart`、`dashboard_hud.dart`、`portrait_panel.dart` | — |
| 6 | 側欄 / 操作列：移除 km/h，第一顆改為實驗模式開關，其餘按鈕放大（直向列高維持 64） | `augmented_road_view.dart`、`lib/services/comma_experimental_api.dart` | `COMMA_EXPERIMENTAL_ENDPOINT_zh-TW.md` |
| 7 | 道路畫面實驗模式圖示（左側中上） | `experimental_badge.dart`、`augmented_road_view.dart` | — |
| 8 | 彩虹模式路徑（依參考影片校正）＋近距離前車鎖定框放大 | `model_renderer.dart` | 本文件 §3.5 |
| 9 | comma 端實驗模式端點（dp0111pre、dplcc：`dragonpilot/dashy/serverd.py`；openpilot-test：`sunnypilot/opview/opviewd.py`） | 各分支 | `COMMA_EXPERIMENTAL_ENDPOINT_zh-TW.md` |

---

## 2. TDX 資料流

```
手機 GPS（geolocator，精度 ≤ 30 m、5 秒內有效；車速 > 3 m/s 才更新航向）
   │
   ├─ OS 反向地理編碼（每 150 m、最多 15 秒一次）→ 縣市代碼、目前道路名
   │
   ▼  每秒 _onTick（UI isolate，純計算）
TdxSections.locate()  國道 → 省道 → 縣市（有即時資料的縣市）依序找腳下且同向的路段
   │
   ▼
tdxReport()  沿線形往前追 5 km：前方 3 km 內最慢路段車速、路徑 60 m 內的事件（最多 3 則）
   │          → {nextSpeed, congestion, events[]}（欄位同原 custom.Tdx）
   ▼
UIState.applyTdx()  →  直向 TDX 列 / 事件跑馬燈、橫向卡片右欄 / 上方跑馬燈
                       （超過 10 秒沒更新自動隱藏）

背景（同時只做一件事，_maybeWork）
  1. 磁碟快取 → TdxSections（compute isolate）
  2. 每 60 秒：所在 auth 的 Live（車速）＋ LiveEvent（事件）；不在路段上時只抓縣市事件
  3. 其餘時間：缺少或超過 7 天的 SectionShape / Section（一次一筆）
```

### 額度（與停車共用 `parkingGate`，每分鐘 5 次）

| 情境 | 每分鐘 TDX 呼叫 |
|---|---|
| 國道 / 省道 / 有即時資料且有事件的縣市 | 2（Live＋LiveEvent） |
| 彰化、雲林縣市道路（有車速、沒有事件資料） | 1（Live）← 本次修正 |
| 不在路段上、所在縣市有事件資料 | 1（LiveEvent） |
| 停車查詢一次 | 最多 2 |
| 合計最壞情況 | 4 ≤ 5，額度滿時路況該輪直接略過、不排隊 |

---

## 3. 程式碼審查結果

### 3.1 本次修正

| # | 檔案 | 問題 | 修正 |
|---|---|---|---|
| F1 | `tdx_traffic_service.dart` | 彰化、雲林在「有即時車速」清單但不在「有事件」清單；開到這兩縣市的道路時仍去抓 `LiveEvent/City/…`，TDX 回 404 → 被當成離線，**整個 TDX 暫停 60 秒**，每輪還浪費 1 次額度 | 加 `_hasEvents(auth)`：國道 / 省道一律抓，縣市只在 `tdxEventCities` 內才抓 |
| F2 | `tdx_traffic_service.dart` | 設定頁狀態：金鑰錯（401/403）、額度滿（429）都顯示「無網路」；停車中沒有航向時顯示「不在 TDX 路段上」；離開 opview 畫面顯示「未啟用」（看起來像開關沒開） | 分別顯示「TDX 金鑰錯誤或未授權」「TDX 額度已滿」「TDX 拒絕存取」「無網路」＋「60 秒後重試」；沒航向時顯示「等待行駛方向（車速 11 km/h 以上）」；待命時顯示「待命（進入 opview 畫面後開始）」 |
| F3 | `dashboard_hud.dart` | 橫向關閉「顯示儀表卡片」時，TDX 前方車速（原本在卡片右欄）**完全看不到** | 無卡片時在原卡片位置底部顯示小膠囊「前方車速 72 km/h 順暢」（依壅塞上色）；有卡片時不變 |
| F4 | `vehicle_details.dart`、`stop_go_overlay.dart` | 實驗模式圖示曾放右上角時加的 `top` / `minTop` 參數，改到左側中上後已無人使用，註解也過時 | 還原為原始檔（行為不變） |
| F5 | `augmented_road_view.dart` | 直向 `invalidateKey` 重複列了 `experimentalMode` | 移除重複（無行為差異） |
| F6 | `comma_experimental_api.dart` | 檔頭註解寫「開啟時一併寫 ExperimentalModeConfirmed」，與實作 / 端點文件（不代替使用者確認，未確認回 409）矛盾 | 改正註解 |
| F7 | `model_renderer.dart` | 彩虹模式的 `clamp()` 結果與 `stops.add(0)` 依賴 Dart 的型別推斷 | 明確 `.toDouble()`、`0.0 / 1.0`，`step` 改用 `max(1, …)` |

新增測試：`test/dashboard_test.dart`（橫向無卡片仍顯示 TDX 膠囊）、`test/rainbow_path_test.dart`（直向 / 橫向 × 有 / 無前車，彩虹路徑繪製不丟例外）。

### 3.2 TDX 核心（`tdx_traffic_core.dart`）— 確認無誤的重點

- **座標順序**：WKT 是 `lon lat`；`tdxShrinkShapes` 存成 `[lat, lon]`，`TdxSections` 以 `q[0]=lat, q[1]=lon` 讀回；事件 `lat = pts.first.$2`。三處一致。
- **網格鍵**：`i × 1048576 + j`；台灣 x ≈ 1.2×10⁷ m / 500 → i ≈ 24 000，y → j ≈ 4 400–5 600，不會碰撞。
- **路徑起點**：從車子在路段上的投影點開始（`tdx_traffic.py` 從下一個線形點開始，線形點稀疏時會漏掉車子與下一點之間的事件）。這是刻意差異，已在檔頭與 `TDX_BUILTIN_zh-TW.md` 標明。
- **下一段串接**：起點在本段終點 120 m 內、轉角 ≤ 60°，同路名優先、其次最直；`seen` 防止繞回。
- **目前 / 前方輪替**：偶數 10 秒優先「目前」（沒有就顯示前方），奇數 10 秒優先「前方」（沒有就顯示目前），與 tdxd 相同。
- **壅塞分級**：國道 80/40（同 tdxd）、省道 50/30、市區 30/15；`auth` 以 `split(':')` 取 `City`。
- **時間**：`DateTime.tryParse` 可解析 TDX 的 `+08:00` 時區；Live 超過 15 分鐘、事件過期或尚未生效都丟掉。
- **與 Python 的刻意差異**（不抓 VD、OS 地理編碼取代縣市界線、前方最慢路段、7 天快取、EventID 去重）均已在 `TDX_BUILTIN_zh-TW.md` 列出。

### 3.3 TDX 服務、LINE、實驗模式 API — 確認無誤的重點

- `setActive` 以 `_gen` 世代號保護所有 await 之後的寫入；停止時取消 timer、GPS、HTTP client 並清空畫面上的 TDX。
- 只在「opview 畫面＋TDX 開＋串流沒暫停」時執行（`app.dart _syncTdx`，6 個狀態轉換點都有呼叫）。
- 靜態資料寫入用 `.tmp` → `rename`，中途被殺不會留下半個 JSON；單筆上限 64 MB；回 HTML（WAF 拒絕頁）視為失敗。
- 429 讀 `Retry-After` 封鎖共用節流；401 清 token；停車查詢 / 啟動下載進行中，路況讓路。
- LINE：只收 `jp.naver.line.android`，略過群組摘要與無內容通知；2 秒內同寄件者同內容去重；最多保留 6 則、每則 30 秒；log 只記數量與結構，不記內容。
- 實驗模式按鈕：未連線先擋；顯示狀態以 `selfdriveState.experimentalMode` 為準，不以 HTTP 回應為準；404 / 409 / 逾時各有訊息。

### 3.4 comma 端端點（三個分支）

`POST /api/experimental_mode`：開啟需 openpilot 縱向控制（有 alpha 縱向時看 `AlphaLongitudinalEnabled`，否則看 `CarParamsPersistent.openpilotLongitudinalControl`），且需已在設定頁確認過實驗模式說明；關閉一律允許。selfdrived `params_thread` 每 0.1 秒重讀，寫入即生效。詳見 `COMMA_EXPERIMENTAL_ENDPOINT_zh-TW.md`。

### 3.5 彩虹模式（依參考影片 66–74 秒逐格取樣校正）

| 項目 | 影片實測 | 舊版 | 現版 |
|---|---|---|---|
| 色相分布 | 依實際距離（近處大片同色、遠處色帶密） | 依畫面高度平均 | 每公尺 3.4° |
| 同時可見色相 | 前車約 46 m 時約 140°（紅→黃→綠） | 200° | 同影片 |
| 流動速度 | 每點每秒 −50°（約 7 秒一輪） | −60° | −50° |
| 透明度 | 遠近一致約 50% | 近 62% → 遠 30% | 固定 50% |
| 飽和 / 亮度 | 純色 | HSL .95 / .55 | HSL 1 / .5 |

實作：把路徑中心線各點投影到畫面，以投影 y 當漸層位置、以該點距離算色相，最多 24 個色標；路徑被前車截短時同樣在截短點插值。

---

## 4. 畫面配置與合理性檢查

### 4.1 直向（以 390 × 844 dp 為例）

```
┌──────────────────────────────┐
│ 道路影像（相機比例 1928:1208，約 244 dp 高）
│  ⚗ ← 實驗模式圖示 34 dp，左緣 12，中心在 35% 高
│                     ◯ ← 起步提醒（右上）
│  ▓▓ comma alert（貼影像底部，依字級決定高度）
├──────────────────────────────┤ ← 留白 2
│ ◀ [EXP] MAX │ 車速儀表 │ 前車 ▶ │ 卡片高約 90（內容依 113 計算，字級不變）
│ 前方車速 72 km/h      TDX 順暢 │ 有 TDX 資料才出現（73）
│ 目前: 施工 300公尺 …           │ 有事件才出現（44，過長捲動）
│ ┌LINE · 2 則┐────────────────┐ │
│ │ 甲：……                      │ │ LINE 與停車共用剩餘高度：
│ └────────────────────────────┘ │  ・LINE 無訊息 → 停車全拿
│ ┌ [P 查詢周遭車位]   ⚙        ┐ │  ・停車沒在用 → 停車精簡 90，LINE 拿其餘
│ └ 狀態一行                    ┘ │  ・停車查詢中 / 有結果 → LINE 只留兩行
├──────────────────────────────┤
│ ● LIVE                         │
│ [⚗實驗] [⚙顯示設定] [⛶全螢幕] [⎋退出] │ 操作列高 64（固定）
└──────────────────────────────┘
```

試算（390 × 844、TDX 列＋事件＋LINE 都出現）：資訊區約 496 dp，固定項目約 230 dp，卡片 90 dp 放得下，**不會因 TDX 列出現 / 消失而讓卡片跳動**；只有在很短的螢幕才會一起縮小，並以 `ClipRect` 防溢出。

### 4.2 橫向（以 844 × 385 dp 為例）

```
┌─────┬──────────────────────────────────────────┐
│LIVE │ opview        [ 目前: 施工 300公尺 … ]     ◯ │ ← 跑馬燈置中，最寬 70%
│⚗實驗│                                         │
│⚙設定│ ⚗ ← 實驗模式圖示（36–56 dp，35% 高）       │
│⛶全螢│              彩虹路徑                    │
│⎋退出│ EXPERIMENTAL                             │
│     │ ENGAGED   ◀ [MAX│車速│前方車速/前車] ▶     │
│     │      （無卡片時：( 前方車速 72 km/h 順暢 )）│ ← F3
└─────┴──────────────────────────────────────────┘
```

### 4.3 檢查結果

| 項目 | 結果 |
|---|---|
| 實驗模式圖示與其他元件重疊 | 左側中上沒有其他元件（opview 標題在左上、狀態徽章在左下、起步提醒 / 車輛資訊 / 全螢幕叫回都在右側）✔ |
| 橫向跑馬燈與 opview 標題 | 跑馬燈置中、最寬為影像區的 70%；844 寬的手機扣掉側欄後影像區約 703，跑馬燈最左約 x≈105，標題在 18–83 ✔ |
| 直向卡片跳動 | 一般手機不會（見 4.1 試算）✔ |
| 橫向無卡片時 TDX 消失 | **已修正（F3）** |
| LINE 標籤頂到上方元件 | 標籤上凸 8 px，LINE 欄上方預留 6＋間距 8 ✔ |
| LINE 行數 | 以像素計算、strut 鎖行高，訊息間距只扣 6 px ✔ |
| 直向操作列高度 | 固定 64；圖示 28＋間距 4＋字 14 × 1.2（系統字型上限）× 1.15 ≈ 51 ≤ 58 ✔ |
| 未連線時 | 側欄 / 操作列保留，「重新連線」在右下，不蓋狀態徽章 ✔ |

### 4.4 建議（未更動，請你決定）

1. **橫向實驗模式有三重提示**：左側中上圖示＋左下 `EXPERIMENTAL` 文字徽章＋側欄琥珀色按鈕。可考慮橫向拿掉 `EXPERIMENTAL` 文字徽章，讓左下只留 ENGAGED 狀態。
2. **LINE 只在直向顯示**（沿用 opview-uber 的設計）。如果橫向也要，需要另外決定位置（例如跑馬燈下方的小卡）。
3. **原版介面（classic）直向**只顯示 TDX 事件，不顯示 TDX 前方車速列（原版 HUD 沒有這個欄位）。

---

## 5. 已知限制

- **背景執行**：Android 背景不給前景以外的定位，路況會停住（10 秒後自動隱藏）；靜態資料下載仍會在背景進行。
- **市區道路的方向**：縣市事件 TDX 多半沒有標方向；在有線形的縣市道路上，對向車道（路徑 60 m 內）的事件也可能被算進來。
- **涵蓋清單**：哪些縣市有即時車速 / 事件，取自 `tdx_traffic.py` 的 swagger 列舉（2026-10-18）；TDX 之後若增加縣市，需更新 `tdxLiveCities` / `tdxEventCities`。
- **首次使用**：需下載國道與省道路段線形（大小未實測），這段期間只有縣市事件（依道路名稱判斷）。
- **彩虹模式**：每公尺 3.4° 是從影片單一片段（前車約 46 m）擬合；沒有前車、路徑長 100 m 時遠處會擠進較多顏色（畫面上只占很小一塊）。若覺得太多，調低 `_rainbowDegPerMeter`。

---

## 6. 測試

```
flutter analyze
flutter test test/tdx_traffic_core_test.dart test/tdx_test.dart test/webrtc_migration_test.dart \
  test/device_settings_guard_test.dart test/line_notifications_test.dart test/parking/parking_panel_test.dart \
  test/dashboard_test.dart test/orientation_test.dart test/rail_test.dart test/experimental_badge_test.dart \
  test/comma_experimental_api_test.dart test/viewer_features_test.dart test/rainbow_path_test.dart
```

或直接 `flutter test` 全部。

實車建議確認：
1. 國道上：設定頁狀態顯示「國道 ○○ – ○○，車速 N 秒前」，直向 TDX 列有前方車速。
2. 彰化 / 雲林市區：狀態不應出現「60 秒後重試」（F1）。
3. 故意填錯金鑰：狀態顯示「TDX 金鑰錯誤或未授權，60 秒後重試」（F2）。
4. 橫向關閉「顯示儀表卡片」：原卡片位置出現前方車速膠囊（F3）。
