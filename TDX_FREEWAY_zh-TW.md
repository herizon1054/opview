# TDX 國道擴充：回堵長度、車速驟降、各車道車速（2026-11-12）

只在**國道**（TDX auth = Freeway）顯示；省道、市區不變。只供顯示，不送回 comma、不影響控車。

## ① 回堵長度
- 資料：原本就在抓的路段即時車速 `v2/Road/Traffic/Live/Freeway`，**不多呼叫 API**。
- 沿前方路段（同前方車速的路徑，最遠約 5 公里），找第一段車速 < 40 km/h（國道壅塞分級 congested）的路段，
  起點要在前方 3 公里內；接著把連續 < 40 的路段長度加總，遇到 ≥ 40 或沒有即時資料就結束。
- 到路徑盡頭仍在回堵 → 「以上」。均速依長度加權。
- 顯示：`回堵 1.2公里起 3.5公里｜均速 25`；已經在回堵裡：`回堵中 還有 3.5公里以上｜均速 25`。

## ② 車速驟降
- 條件：回堵起點在前方 **2 公里內**，且**本車車速（comma carState.vEgo）− 回堵最慢路段 ≥ 40 km/h**。
- 事件位置（直向事件列、橫向上方跑馬燈）改顯示黃底黑字 `車速驟降  前方 1.5公里 降到 25 km/h`。
  優先順序：碰撞注意（紅）> 車速驟降（黃）> TDX 事件。
- 條件成立的那一刻嗶兩聲（同起步提醒的嗶嗶聲，不受起步提醒聲音設定影響），**3 分鐘內不重複**。
  顯示設定「交通部 TDX → 國道車速驟降嗶聲」可關掉聲音（預設開），畫面照常顯示。
- TDX 路段車速是 1–5 分鐘平均，回堵尾端實際位置可能比顯示的更近，看到提醒就該開始注意前車。

## ③ 前方各車道車速
- 靜態：`v2/Road/Traffic/VD/Freeway`（偵測器位置與方向，存手機 7 天）。
- 即時：`v2/Road/Traffic/Live/VD/Freeway?$filter=VDID eq '…' or …`，只抓路徑上同向、前方最近 8 支偵測器
  （約 4–6 KB），每 60 秒一次。TDX 若不接受 `$filter`（HTTP 400）→ log 記一筆並改為每 3 分鐘下載全部國道偵測器。
  這支 API 失敗不會讓路段車速、事件跟著停 60 秒。
- 顯示前方 150 m–3 km 內第一支有即時資料的偵測器（Status = 0、15 分鐘內、車速 > 0 的車道），
  依 LaneID 排序：`1.8公里 車道 內 92｜85｜38 外`，數字顏色依國道壅塞分級（≥ 80 綠、40–80 黃、< 40 紅）。
- **待實車確認**：LaneID 是否「0 = 內側車道」。我查不到 TDX 對 LaneID 的正式定義，目前假設由內往外編號。
  第一次看到某支偵測器時 log 會記
  `[tdx] 偵測器 <VDID> 原始車道：LaneID 0/種類 1/92、…`，若方向相反請回報，改一個排序即可。
  路肩（LaneType）是否會出現在資料裡也一併從 log 確認。

## 畫面位置
- 2026-11-12 版面統一後：回堵、車道車速併入「路況卡」（前方車速下方各一行），直向在儀表卡片下方、橫向在左上角；
  車速驟降在道路畫面上方的警示列。見 `LAYOUT_UNIFY_zh-TW.md`、`docs/layout_unified.png`
  （`docs/tdx_freeway_mock.png` 是統一前的版本，僅供對照）。

## 額度
國道每輪 3 次（路段車速 + 事件 + 前方偵測器），與停車查詢共用每分鐘 5 次的本機節流。

## 檔案
| 檔案 | 說明 |
|---|---|
| `lib/services/tdx/tdx_traffic_core.dart` | `tdxQueueAhead`、`tdxShrinkVds`、`tdxLiveVds`、`TdxVdIndex`；`tdxReport` 多回傳 `queue` / `vdAhead` / `lanes` |
| `lib/services/tdx/tdx_traffic_service.dart` | VD 靜態快取、`_roundVd`（篩選、退回全部）、`_callBytes(optional:)`、log |
| `lib/selfdrive/ui/ui_state.dart` | `tdxQueueText`、`tdxLanes`、`tdxDropText`、`tdxDropEvents`；`eventBanner` 多 `warn` |
| `lib/selfdrive/ui/onroad/freeway_info.dart` | 新增：路況卡 `TdxRouteCard`（版面統一後） |
| `lib/selfdrive/ui/onroad/portrait_panel.dart`、`augmented_road_view.dart`、`tdx_marquee.dart` | 顯示、黃色樣式 |
| `lib/services/viewer_settings.dart`、`viewer_settings_dialog.dart`、`alert_sound.dart`、`lib/app.dart` | 嗶聲開關與播放 |
| `test/tdx_freeway_test.dart` | 新增；`test/collision_banner_test.dart` 配合 `warn` 欄位 |

## 尚未驗證
本環境沒有 Flutter SDK，未編譯。請跑 `flutter analyze` 與
`flutter test test/tdx_freeway_test.dart test/tdx_traffic_core_test.dart test/tdx_test.dart test/collision_banner_test.dart`。
`$filter` 是否被 Live VD 接受、LaneID 方向、VD 靜態資料大小，都要實際開一趟國道看 log。

## Python 測試程式 `tools/tdx_freeway_check.py`
計算邏輯逐行移植自 `tdx_traffic_core.dart` / `ui_state.dart`（常數相同），用真實 TDX 國道資料檢查。
只用 Python 標準函式庫（3.9 以上），Windows 用 `py`。金鑰直接填在程式開頭的 `CLIENT_ID` / `CLIENT_SECRET`（也可用 `--id` / `--secret` 或環境變數 `TDX_CLIENT_ID` / `TDX_CLIENT_SECRET` 覆蓋）。填了金鑰的檔案不要傳給別人或上傳 GitHub。

| 指令 | 做什麼 | TDX 呼叫 |
|---|---|---|
| `py tools\tdx_freeway_check.py selftest` | 離線自我測試（同 `test/tdx_freeway_test.dart` 的案例） | 0 |
| `py tools\tdx_freeway_check.py scan --kph 100` | 全國道每個路段每 250 m 模擬一次（同 opview 開車時連續計算）：列出每段回堵、最早在幾公里前報出 / 觸發車速驟降，並檢查高架 ↔ 平面串接；列出現在所有回堵、會觸發車速驟降的位置；自動檢查矛盾（起點 / 長度 / 車速 / 漏報）、路段長度、路段串接 | 第一次 3 + 1，之後 1 |
| `… scan --road 國道1號` | 只看一條路 | 同上 |
| `… scan --queue-kph 60` | 測試用：暫時把回堵門檻調高（opview 固定 40），沒塞車時也能用真實路網測回堵邏輯 | 同上 |
| `… point --lat 24.99 --lon 121.30 --heading 180 --kph 100` | 單點：前方路段車速、回堵、驟降、前方偵測器與車道車速（opview 會顯示的內容） | 第一次 4 + 2，之後 2 |
| `… vdtest --lat … --lon … --heading …` | 測 Live VD 的 `$filter` 有沒有生效、全部下載有多大，印出前方偵測器原始 LaneID / LaneType | 2–3 |

- `--heading`：行車方向，北 0、東 90、南 180、西 270。
- `--save 資料夾`：把抓到的原始 JSON 存起來；`--load 資料夾`：用存好的資料重跑（不連 TDX）。遇到奇怪結果請 `--save` 後把資料夾壓縮給我。
- 靜態資料快取在 `%USERPROFILE%\.tdx_freeway_cache`，7 天內不重抓。
- 建議：塞車時段（例如週五傍晚）跑一次 `scan`，對照高速公路局 1968 的路況，看回堵位置與長度是否合理；
  在常走的國道路段跑 `vdtest`，對照實際車道確認 LaneID 方向。

## 真實資料驗證（2026-11-12 中午，`scan --queue-kph 60`）
- 465 個國道路段、442 段有即時車速；判斷邏輯沒有矛盾（167 個「前方 3 公里內有慢路段」的位置都正確報出回堵）。
- **路段很長**：中位數 4.1 km、p90 8.6 km、最長 16.7 km。TDX 的路段車速是整段平均，短的回堵可能被平均掉，
  回堵起點也只能精確到路段起點。改善方向（未做）：用前方偵測器（約每 1 km 一支）找回堵起點。
- **TDX 國道線形有缺口 / 重疊 → 已修**：原本只接 120 m 內的下一段，41 段接不下去；汐止五股高架在缺口處
  （五股轉接道 2.5 km、泰山轉接道）會接到平面，平面在泰山轉接道會接到高架。
  `TdxSections._next(bridge: true)`（只用在國道）：同一條路（RoadName 相同）優先——300 m 內不限方位（重疊），
  300 m–3 km 要在行車方向正前方 20° 內（缺口），且該段終點要在前方；找不到才照原規則接 120 m 內別條路。
  跨缺口時距離加上缺口長度。結果：接不到 3 公里的起點 39 → 27，高架 ↔ 平面切換剩 2 處：
  汐止端（高架結束併回平面，正確）、校前路到中壢轉接二（TDX 缺「中壢轉接二到中豐」高架線形，無法接回高架）。
- 已知仍接不好：國道1號高雄端（「高雄端到漁港路」線形比實際長，蓋過下一段起點）。
- 與 comma 端 `tdx_traffic.py` 不同（它只接 120 m 內）。

## 早上尖峰驗證（2026-11-13 07:32，正式門檻 < 40 km/h）
- 抓到 10 段真實回堵：國1 大華系統→五堵→汐止（28/31）、桃園到林口（26，7.7 km）、五股轉接道到三重（25）、
  國2 南桃園到機場系統（14）、國1 仁德到大灣（28）、國8 新吉到台南系統（19）等；都在 2.3–2.9 km 前報出、
  1.8–2.0 km 前觸發車速驟降（模擬每 250 m 一次；實際每秒算，會在 3.0 / 2.0 km 左右）。矛盾檢查 307 個位置全過。
- 又找到一種 TDX 線形問題 → 已修：**線形畫過頭**，下一段起點落在本段線上、終點前 300–900 m
  （國8 台南端到新吉 306 m、汐五高架 中壢轉接二到校前路 912 m），原本接不到或跳過一段。
  `tdxOverlapM`：起點落在本段最後 2 km、橫向 40 m 內的同路段也算下一段，距離扣掉重疊；`tdxQueueAhead` 不重複算重疊長度。
  結果：接不到 3 公里的起點 27 → 24；高架 ↔ 平面只剩汐止端（正確）；汐五高架北上在中壢轉接二不再掉到平面。
- 仍不完美：國1 高雄端線形畫過頭太多，會跳過 200–270 m 的短路段（漁港路–中山四路）。
- 國10 左營端到鼎金系統（21）沒有上游可報：左營端是國10起點，正常。
