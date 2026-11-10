# TDX 路況內建到 opview（取消讀取 comma 的 tdx service）

## 變更摘要
- opview 不再向 webrtcd 訂閱 `tdx`，也移除「帶 tdx 失敗 → 不帶 tdx 重試」與「此分支不支援 TDX」判斷。
  任何 comma 分支（含沒有 tdxd 的）都直接用一般請求連線；webrtcd 回 500 時直接提示 webrtcd 未更新。
- TDX 改由手機自己抓：手機 GPS 定位 + 停車設定裡的 TDX Client ID / Secret。
- 畫面元件不變：服務每秒呼叫 `UIState.applyTdx()`，欄位與原 custom.Tdx 相同
  （`nextSpeed` / `congestion` / `events[].description` / `events[].isCurrentSection`）。

## 檔案
| 檔案 | 說明 |
|---|---|
| `lib/services/tdx/tdx_traffic_core.dart` | 新增。純計算（可單元測試、在 isolate 執行）：WKT 解析、路段網格、找腳下路段、沿線形追前方路徑、事件 / 車速解析、組成畫面資料 |
| `lib/services/tdx/tdx_traffic_service.dart` | 新增。手機 GPS、OS 反向地理編碼（縣市 / 道路名）、TDX Token、API 呼叫、靜態快取 |
| `lib/services/tdx_support.dart` | **刪除** |
| `lib/system/webrtc/webrtcd_api.dart` | 移除 optional services（tdx）與退回重試 |
| `lib/services/impl/cereal_adapter.dart` | 不再處理 `tdx` 訊息 |
| `lib/services/connection_manager.dart` | 移除 tdxSupport 設定 |
| `lib/app.dart` | `_syncTdx()`：opview 畫面、TDX 開、串流未暫停時啟動服務 |
| `lib/selfdrive/ui/settings/viewer_settings_dialog.dart` | 新增「交通部 TDX」區塊：TDX 金鑰（共用，未設定顯示橘色）、TDX 路況顯示（含即時狀態）、附近停車場與空位 |
| `lib/selfdrive/ui/settings/parking_settings_dialog.dart` | 標題改「TDX 金鑰與停車查詢」；金鑰在上、標明共用並顯示路況狀態，停車查詢開關移到下方；節流說明含路況 |
| `lib/selfdrive/ui/onroad/parking_panel.dart` | 設定按鈕提示改「TDX 金鑰與停車查詢設定」 |
| `lib/selfdrive/ui/home/home_page.dart` | 移除「此分支不支援 TDX」 |
| `lib/selfdrive/ui/ui_state.dart`、`tdx_marquee.dart`、`viewer_settings.dart` | 註解 |
| `test/tdx_traffic_core_test.dart` | 新增 |
| `test/tdx_test.dart`、`test/webrtc_migration_test.dart`、`test/device_settings_guard_test.dart` | 依新行為更新 |
| `README.md` | TDX 路況段落 |

## 演算法來源與刻意差異
主要移植自 comma 端 `tdx_traffic.py`（TDX v2 路段線形 + v1 RoadEvent，含國道 / 省道 / 縣市）；
`tdxd.py` / `tdx.py`（高公局 XML）只參考輸出格式與「目前 / 前方每 10 秒輪替」。

與 `tdx_traffic.py` 的差異：
1. **不抓 VD 車道車速**：opview 沒有顯示位置，省每輪一次 API 與 VD 靜態資料。
2. **縣市判斷**改用手機 OS 反向地理編碼（每 150 m、最多 15 秒一次），不下載縣市界線。
   不在路段上時用地理編碼的 `thoroughfare` 取代 mapd 的 RoadName。
3. **路徑起點修正**：Python `path()` 的折線從車子之後的第一個線形點開始，線形點稀疏時，
   車子與下一點之間的事件會被漏掉（測試資料中 330 m 外的事件 Python 回傳 None）。Dart 版從車子的投影點開始。
4. **前方車速**：前方 3 公里內最慢路段的車速（沒有就用目前路段）。壅塞分級門檻依道路種類：
   國道 80 / 40（同 tdxd）、省道 50 / 30、市區 30 / 15（省道、市區的慢速門檻取自 SLOW_KPH）。
5. **靜態快取 7 天**（Python 1 天）：手機多半用行動網路。過期照用，背景再更新。
6. **事件去重**：多個 auth 的事件以 EventID 去重。

## 頻率與額度
- 每 60 秒一輪：所在 auth 的 `Live` + `LiveEvent`（2 次）；彰化、雲林縣市道路沒有事件資料，只抓 `Live`（1 次）；
  不在路段上時只抓縣市 `LiveEvent`（1 次）。
- 與停車共用 `parkingGate`（每分鐘 5 次，存在 secure storage），額度滿就略過該次，不排隊；
  停車查詢 / 啟動下載進行中，路況暫停。429 會依 Retry-After 封鎖共用節流。
- 失敗（含沒網路）60 秒後再試；靜態資料單筆失敗 5 分鐘後再試，格式異常 1 小時。

## 已知限制
- 本環境沒有 Flutter / Dart SDK，**未經編譯與測試執行**；預期數值是用原 Python 對同一組資料算出來對照的。
  請先 `flutter analyze` 與 `flutter test test/tdx_traffic_core_test.dart test/tdx_test.dart test/webrtc_migration_test.dart test/device_settings_guard_test.dart`。
- 背景執行（離開 App）時 Android 不給前景以外的定位，路況會停住（過 10 秒自動隱藏）。
- 首次使用會下載國道與省道的路段線形 / 名稱（大小未實測；單筆上限 64 MB）。
