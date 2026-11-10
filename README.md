<p align="center">
  <img src="assets/logo.png" width="128" alt="opview">
</p>

# opview — opview-stopcar

**繁體中文** | [English（原版說明）](README_en.md)

目前版本：**v2.0.6**（[更新內容](#更新紀錄)）

opview 在手機上即時顯示 [openpilot](https://github.com/commaai/openpilot) 的行車畫面，包括道路影像、預測路徑、車道線、前車和警示，並加上儀表介面與台灣用路資訊。

| 原作者 | 授權 |
|---|---|
| [Rick Lan](https://github.com/efinilan)（[efinilan/opview](https://github.com/efinilan/opview)） | Copyright (c) 2026, Rick Lan。**非商業用途**授權，全文見 [LICENSE](LICENSE) |

本分支以原作者的 opview 為基礎修改，原有版權聲明與授權條款全部保留，詳見文末「[版權與授權](#版權與授權)」。

<p align="center">
  <a href="https://youtube.com/shorts/r0O_RzXd_0k">
    <img src="https://img.youtube.com/vi/r0O_RzXd_0k/maxresdefault.jpg" width="600" alt="opview 示範">
  </a>
</p>

## 分支

| 分支 | 說明 |
|---|---|
| `opview-uber` | 含 LINE 通知讀取 |
| `opview-stopcar` | 含附近停車場與空位查詢，不含 LINE 通知讀取 |
| `opview-tdx` | 含附近停車場與空位查詢、手機內建 TDX 路況、LINE 通知讀取 |

**本分支：`opview-tdx`**，含附近停車場與空位查詢、手機內建 TDX 路況（不再讀 comma 的 tdx）、LINE 通知讀取。

## 功能介紹

### 連線
- **自動找 comma**：用 mDNS 搜尋，找不到時掃描區域網路。也可以手動輸入 IP。手機當熱點時一樣可以連。
- **只在需要時才傳影像**：
  - 主畫面只連到 comma 讀取狀態與車型，不建立 WebRTC。
  - 進入 opview 畫面後才開始傳影像和資料，離開就停止，省電也省流量。
- **不會累積延遲**：
  - 資料只處理最新的一筆，畫面和資料不會越來越慢。
  - 資料延遲時，畫面顯示「資料延遲」，不會繼續顯示過時的車速。
  - 影像卡住時會自動恢復。
- **相容不同分支**：
  - comma 端 webrtcd 沒有更新時，會顯示提示。

### 主畫面
- 顯示連線狀態。讀取車型與設定車型時，狀態會標示為已讀取、上次讀取、讀取中或未連線。車型沒有變更時不會再跳出確認。
- **OP 設定網頁**：
  - dragonpilot 開啟 comma 的 `:5088` 設定頁，sunnypilot 開啟 sunnylink。
  - 只能在 offroad 或 P 檔時使用。
- 錯誤訊息只顯示一行重點，不會擠亂版面。
- 顯示手機的狀態列（電量、訊號、時間）。

### opview 畫面
- **三種介面**：
  - 儀表介面（CommaView 風格）
  - 原版介面（openpilot 原廠 HUD）
  - 儀表＋車輛資訊
- **直向**：
  - 上方是道路畫面，中間是儀表卡片，下方依序是 前方車速 → TDX 路況跑馬燈 → LINE 通知（開啟時） → 附近停車場（開啟停車功能時）。
  - 會顯示手機的狀態列。
- **橫向**：
  - 道路畫面佔滿螢幕，左側是按鈕列。
  - 點「全螢幕」或開啟「自動進入全螢幕」時，會自動轉成橫向。
- **道路畫面**：
  - **路徑與車道**：預測路徑、車道線、道路邊緣。
    - 彩虹模式（顯示設定）：儀表介面的路徑改為沿路徑排列的彩虹色帶，持續流動；原版介面不受影響。
  - **前車**：
    - leadOne（主要前車）：鎖定框，大小跟著前車在畫面上的車身尺寸（寬 1.8 m、高 1.5 m 投影）變化。
      - 遠距離：四角括號 + 十字線，標籤（距離 · 前車速度）在框下方。
      - 近距離（車身寬超過原本框的上限）：改成框住整台車的方框（半透明底、四角加粗），
        標籤放大並移到框內約車牌位置；框最寬為畫面寬 70%。
    - leadTwo：目標下方的紅色向上箭頭。和 leadOne 位置幾乎重疊時不畫（距離差 3 m 內且橫向差 1.5 m 內）。
      - openpilot 的 leadTwo 不是「第二台車」，而是模型對「2 秒後前車」的預測所配對到的目標，大多數時間就是 leadOne 那台車，所以箭頭平常不會出現。只有在切入、變換車道、前車離開等情況下才會看到。
      - log 每 60 秒會記錄一行「前車資料」，可以看到 leadTwo 和 leadOne 不同的次數。
      - 同時支援 dragonpilot（欄位 `status`）與 sunnypilot（欄位 `present`）。
  - **方向燈**：顯示在儀表卡片兩側。
  - **盲點**：道路畫面左右邊緣的黃色光暈，由外往內淡化。
  - **comma 事件**：例如「請接管方向盤」，顯示在道路畫面底部，高度依文字大小調整。

### 停等與起步提醒
移植自 sunnypilot（`e2e_alerts_helper.py`、`circular_alerts.py`），並改在手機端計算，所以 dragonpilot 等沒有 `longitudinalPlanSP` 的分支也能用。

- **前車起步偵測**：停在前車後方 8 公尺內時，前車開走就提醒。
- **綠燈起步偵測**：停車且前方 8 公尺內沒有車（沒有前車，或前車在 8 公尺外，例如停在較遠的機車後面）時，模型判斷前方可以通行（綠燈）就提醒。同一次停等已提醒過前車起步，就不會再提醒綠燈。（sunnypilot 原本只要有前車就不偵測綠燈，opview 刻意放寬。）
- **車輛停等計時**：車輛靜止時，在道路畫面右側顯示停等時間（分:秒）。

三項提醒的運作方式：
- 畫面提示在直向、橫向都會顯示：道路畫面右側的圓形，起步提醒會閃爍 3 秒。
- 前車起步與綠燈起步的聲音可在設定中選擇：靜音（預設）、Google 語音或嗶嗶聲。
  - **Google 語音**：使用手機「文字轉語音」裡 Google 引擎的台灣中文預設聲音，以 1.4 倍語速播放，男聲或女聲由系統設定決定。要換聲音，請到系統的「文字轉語音」設定更改。手機沒有中文語音資料或引擎失敗時，自動改播嗶嗶聲。
  - **嗶嗶聲**：播放 App 內建的 `assets/sounds/beep.wav`（兩聲 1 kHz 短音），失敗時改用程式產生的短音。
  - 語音和嗶嗶聲都跟著**媒體音量**（音訊用途為媒體），播放時音樂會短暫被壓低。媒體音量為 0 時聽不到。
  - 提醒聲音固定從**手機喇叭**播出，接著車機藍牙時也不會走藍牙。
  - 沒有聲音時，按顯示設定的試聽按鈕，下方會顯示原因，同樣也會寫入 log，例如：
    - 「媒體音量 0/15」。
    - 「手機沒有中文語音資料，改播嗶嗶聲」：請到系統「文字轉語音」下載中文（台灣）語音。
    - 「文字轉語音初始化失敗」。
- 只在 openpilot 未啟用且車輛停止時運作。
- 圓形固定在道路畫面右上角（直向上緣 8 dp、橫向上緣 48 dp），不會跟著 comma 底部橫幅警示（events.py，例如「自動煞車維持中」）移動；橫幅特別高時只縮小，不會重疊。只有全螢幕警示，或空間小到放不下時，才會暫時隱藏。聲音不受警示影響。
- 提醒僅供參考，起步前仍須自行確認路況。

### 背景執行（保留起步語音）
- 在 opview 畫面切到其他 App（例如導航）或關閉螢幕時，opview 會繼續連線，綠燈起步、前車起步照常播放語音。
- **啟用條件**：
  - 「背景執行」開啟（預設開啟）。
  - 前車起步或綠燈起步偵測至少開啟一項。
  - 起步提醒聲音不是靜音。
  - 不符合條件時維持原本行為：離開 App 就暫停連線，回來再重連。
- **背景執行期間**：
  - 通知列顯示「opview 背景執行中」，按通知可回到 App，按「停止」可結束。
  - 回到 App 或從最近使用清除 App 時自動結束。最長維持 6 小時。
- **耗電與流量**：和開著畫面相同，影像仍持續接收。
- **Android 設定**：
  - Android 13 以上第一次會詢問通知權限。不允許的話仍會背景執行，只是通知列看不到。
  - 小米、OPPO 等手機請把 opview 的省電策略設為「無限制」，並允許自動啟動，否則系統仍可能把它停掉。

### TDX 路況
- **內建在 opview**：手機自己定位、自己向交通部 TDX 抓資料，不再讀 comma 端的 tdx 服務，任何分支都能用。
- **金鑰**：顯示設定「交通部 TDX → TDX 金鑰」，與停車查詢共用同一組 Client ID / Client Secret（停車查詢可以關著，金鑰有填就好）。
- **資料**：所在道路（國道、省道，或有即時資料的縣市道路）的路段車速與即時事件，沿 TDX 路段線形往前追 3 公里，
  只報行車方向上的事件；不在路段上時，報同一條路正前方 1.5 公里內的事件（道路名稱用手機反向地理編碼）。
- **頻率與流量**：opview 畫面開著時每 60 秒一輪、最多 2 次 API；與停車查詢共用每分鐘 5 次的本機節流，
  停車查詢進行中路況暫停。路段線形與名稱存在手機，7 天更新一次。沒網路就安靜略過，60 秒後再試。
- 直向顯示前方車速（前方 3 公里內最慢路段）與路況事件跑馬燈，「目前 / 前方」每 10 秒輪替。
- 橫向會在道路畫面上顯示通知。
- 只供顯示，不會送回 comma、不影響控車。

### LINE 通知
- 直向資訊區顯示 LINE 訊息，每則顯示 30 秒，至少兩行；行數依可用高度自動決定。
- 與停車查詢同時開啟時：LINE 在上、停車在下，LINE 佔剩餘高度約 40%（至少兩行），停車拿其餘（至少 100）；
  高度不夠放停車面板時只顯示 LINE。只開 LINE、停車查詢關閉時，剩餘高度全給 LINE。
- LINE 區高度固定預留（沒有訊息時是空白），儀表卡片與停車面板不會因訊息出現 / 消失而跳動。
- 群組訊息顯示為「群組名 · 寄件者」。
- 需要在 Android「通知存取權」授權 opview。第一次開啟時會引導到系統設定頁。
  - 從 APK 安裝的 App 在 Android 13 以後屬於「受限制的設定」：要先到「應用程式資訊 → ⋮ → 允許受限制的設定」，才能打開通知存取權。
- 讀不到時，log 會每 60 秒記錄一行診斷：授權狀態、服務是否連線、收到幾則等；分享 log 前也會補一行。
  - 已授權但服務沒有連線時，會自動要求系統重新綁定，最多 3 次。
- **隱私**：訊息只放在記憶體，30 秒後移除，不寫入 log，log 只記錄數量。

### 附近停車場與空位（本分支限定）
- 用手機定位查詢附近的路邊、路外停車場和剩餘車位，顯示在直向資訊區。點選場地會用導航 App 開啟。
- **資料來源**：
  - 交通部 TDX：需要自己申請 Client ID / Client Secret，在顯示設定「交通部 TDX → TDX 金鑰」填入（與 TDX 路況共用）。
  - 新北市、新竹市政府開放資料。
  - 每筆場地都會標示來源。
- **搜尋範圍**：半徑 1000／1200 公尺可選（測試模式另有 10 km），以直線距離計算。
- **更新方式**：
  - 空位要手動按按鈕查詢，有 30 秒防連點，不會自動輪詢。
  - 場地位置下載成功後快取 7 天。只在開啟 App 或回到前景時檢查是否要更新，不做背景下載。
- **安全**：金鑰與 token 存在手機的安全儲存區，不寫入 log。
- **其他文件**：
  - 細節與版本紀錄：[PARKING_zh-TW.md](PARKING_zh-TW.md)
  - 資料來源與授權：[PARKING_SOURCES_zh-TW.md](PARKING_SOURCES_zh-TW.md)

### 顯示設定（右側 ⚙）

| 設定 | 預設 | 說明 |
|---|---|---|
| 介面 | 儀表介面 | 儀表介面／原版介面／儀表＋車輛資訊 |
| 彩虹模式 | 關 | 儀表介面的路徑改為流動彩虹色 |
| 公制 km/h | 開 | 關閉時顯示 mph |
| 交通部 TDX：TDX 金鑰 | — | 路況顯示與停車查詢共用；未設定時圖示與文字顯示為橘色 |
| 交通部 TDX：TDX 路況顯示 | 開 | 手機定位抓取前方車速與事件；下方顯示即時狀態 |
| 交通部 TDX：附近停車場與空位 | — | 開關、搜尋半徑；另有測試模式（與金鑰在同一個設定頁） |
| 顯示 LINE 通知（直向） | 關 | 見上方「LINE 通知」 |
| 打開 App 自動進入 opview | 關 | 跳過主畫面 |
| 自動進入全螢幕 | 關 | 連線且畫面開始更新 3 秒後進入全螢幕並轉為橫向 |
| 前車起步偵測／綠燈起步偵測／車輛停等計時 | 關 | 見上方「停等與起步提醒」 |
| 起步提醒聲音 | 靜音 | 靜音／Google 語音／嗶嗶聲，旁邊有試聽按鈕，下方顯示試聽結果 |
| 背景執行（保留起步語音） | 開 | 見上方「背景執行」 |
| 亮度跟隨系統／App 亮度 | 跟隨系統 | |
| 降低儀表更新頻率 | 開 | 儀表約 5 Hz；路徑與警示不降頻 |
| 連線紀錄（log） | — | 分享或清除 log |

### 連線紀錄（log）
- **內容**：連線、探索、WebRTC、影像、各類資料收到的筆數、延遲、閃退原因（Android ApplicationExitInfo）和 libwebrtc 原生 log。
- 只保留 3 天，可在顯示設定裡直接分享給開發者。

## 使用方式

1. 手機和 comma 裝置連到**同一個 WiFi**，或讓 comma 連上手機熱點。
2. 安裝並開啟 opview。
3. 主畫面找到 comma 後進入 opview。裝置進入 onroad 時就會看到即時畫面。

**需求：**
- comma 端需要能從 port 5001 連到 `webrtcd`。
- 建議使用已更新 webrtcd 的 dragonpilot／sunnypilot 分支。這些分支支援 opview 的新版協定：`initCamera`、`clockSync`、精簡 modelV2，以及傳送佇列不會堆積。
- 原廠 openpilot 也可以使用，但要先依照下方說明啟用 webrtcd。

**在原廠 openpilot 啟用 webrtcd：**

在 `selfdrive/manager/process_config.py` 找到 `webrtcd` 和 `stream_encoderd`，將條件從 `notcar` 改為 `or_(notcar, only_onroad)`：
```python
PythonProcess("webrtcd", "system.webrtc.webrtcd", or_(notcar, only_onroad)),
NativeProcess("stream_encoderd", "system/loggerd", ["./encoderd", "--stream"], or_(notcar, only_onroad)),
```

**修復音訊裝置錯誤（ALSA「Device unavailable」）：**

連線時如果出現 `500` 錯誤，且錯誤訊息包含 `pa_linux_alsa.c` 和 `OSError: [Errno -9985] Device unavailable`，代表 webrtcd 開不了音訊輸入裝置。修正方式是在 `system/webrtc/webrtcd.py` 把音訊串流初始化包進 try/except：
```python
# 約第 144 行，將：
builder.add_audio_stream(AudioInputStreamTrack() if not debug_mode else AudioStreamTrack())

# 改為：
try:
    builder.add_audio_stream(AudioInputStreamTrack() if not debug_mode else AudioStreamTrack())
except OSError:
    pass
```

## 建置

**環境需求：**
- Flutter 3.38.x：`pubspec.lock` 需要 3.38.4 以上，CI 固定使用 3.38.x。
- JDK 17。
- Android 建置：AGP 8.x、Gradle 8.14.3、compileSdk 36、minSdk 21。

```bash
flutter pub get
flutter analyze --no-fatal-infos
flutter test --exclude-tags golden
flutter build apk --release          # 輸出 build/app/outputs/flutter-apk/app-release.apk

# 或使用腳本
scripts/build.sh                     # Android
scripts/build.sh ios                 # iOS（需要 macOS + Xcode）
```

`third_party/flutter_webrtc` 是修改過的 flutter_webrtc 1.3.0：預設停用 Android network monitor，讓手機當熱點時 WebRTC 可以使用熱點介面。說明見 [OPVIEW_PATCH_zh-TW.md](third_party/flutter_webrtc/OPVIEW_PATCH_zh-TW.md)。

## GitHub Actions

| Workflow | 觸發時機 | 內容 |
|---|---|---|
| **CI**（`ci.yml`） | 推送到任何分支、PR、手動執行 | ① `flutter analyze`（info 不擋、warning 會失敗）＋ `flutter test`（略過 golden）<br>② 建置 release APK，上傳到該次執行的 **Artifacts**<br>③ iOS 建置只在手動執行時才跑，失敗也不影響整體結果 |
| **Release**（`release.yml`） | 推送 `v*` 標籤 | 分析、測試、建置 APK，並建立 GitHub Release |
| **APK Size**（`apk-size.yml`） | PR | 比較目標分支與 PR 的 APK 大小，結果留言在 PR |
| **Screenshots**（`screenshots.yml`） | 手動執行 | 產生各尺寸、各情境的截圖並上傳到 Artifacts |

**下載 CI 建置的 APK：**
1. 到 GitHub 的 Actions → CI，點進最新一次成功的執行。
2. 在頁面下方 Artifacts 下載 `opview-apk-…`。
3. 解壓縮後安裝。

**發布 Release：**
```bash
scripts/release.sh 2.0.6      # 發布 v2.0.6（標籤 v2.0.6-stopcar）；X.Y.0 的標籤會省略結尾 .0，例如 v2.1
scripts/release.sh            # 升級修訂號；在 opview-stopcar 分支會建立 vX.Y.Z-stopcar 標籤
scripts/release.sh minor      # 升級次版號
scripts/release.sh 0.3.0      # 指定版本
```
這個指令會：
- 更新 `pubspec.yaml`、commit，再推送分支與標籤。
- 在 `main` 以外的分支，標籤自動加上分支名稱，同一個 repo 的兩個分支不會撞標籤。
- 標籤推送後，Release workflow 會自動建置 APK 並建立 Release。

**固定簽章（建議設定）：**

沒有設定時，CI 每次都用臨時產生的 debug 金鑰簽章，不同次建置的 APK 簽章不同。這時更新 App 必須先移除舊版，設定也會一起被清掉。設定一次固定金鑰後，就可以直接覆蓋安裝：

1. 在自己的電腦產生金鑰（只需要做一次，並妥善保管）：
   ```bash
   keytool -genkeypair -v -keystore opview-release.jks -alias opview \
     -keyalg RSA -keysize 2048 -validity 10000
   base64 -w0 opview-release.jks > keystore.b64     # macOS：base64 -i opview-release.jks -o keystore.b64
   ```
2. 到 GitHub repo 的 Settings → Secrets and variables → Actions → New repository secret，新增以下 secrets：

   | Secret | 內容 |
   |---|---|
   | `ANDROID_KEYSTORE_BASE64` | `keystore.b64` 的內容 |
   | `ANDROID_KEYSTORE_PASSWORD` | keystore 密碼 |
   | `ANDROID_KEY_ALIAS` | `opview` |
   | `ANDROID_KEY_PASSWORD` | 金鑰密碼（和 keystore 密碼相同時可以不設） |

3. 之後 CI 與 Release 會自動使用這把金鑰，執行結果摘要會顯示用的是哪一種簽章。
   - 第一次換成固定金鑰時，仍然要先移除舊版一次。
   - 本機建置時，可以自行建立 `android/key.properties`，欄位見 `scripts/ci_signing.sh`。這個檔案已列在 `.gitignore`，不會被提交。

## 架構

```
├── .github/workflows/                     # CI / Release / APK Size / Screenshots
├── scripts/
│   ├── build.sh  release.sh               # 建置、發布
│   ├── ci_signing.sh                      # CI 固定簽章（從 secrets 產生 key.properties）
│   └── generate_icons.py                  # 從 assets/logo.png 產生圖示
├── assets/sounds/beep.wav                 # 起步提醒的嗶嗶聲
├── third_party/flutter_webrtc/            # 修改過的 flutter_webrtc 1.3.0
├── lib/
│   ├── main.dart  app.dart                # 進入點、方向、生命週期（含背景執行）、設定套用
│   ├── common/transformations.dart        # 相機內參、座標轉換
│   ├── selfdrive/ui/
│   │   ├── ui_state.dart                  # 遙測資料 → 畫面狀態
│   │   ├── home/home_page.dart            # 主畫面：探索、車型、OP 設定
│   │   ├── settings/                      # 顯示設定、OP 設定網頁連結
│   │   └── onroad/
│   │       ├── augmented_road_view.dart   # opview 畫面：直向／橫向版面、圖層
│   │       ├── model_renderer.dart        # 路徑（含彩虹模式）、車道、道路邊緣、leadOne 鎖定框（近距離放大）、leadTwo 箭頭
│   │       ├── dashboard_hud.dart  compact_hud.dart  hud_renderer.dart  throttled_hud.dart
│   │       ├── alert_renderer.dart        # comma 事件（道路畫面底部）
│   │       ├── blindspot_glow.dart        # 盲點黃色光暈
│   │       ├── portrait_panel.dart        # 直向資訊區
│   │       ├── tdx_marquee.dart           # TDX 跑馬燈
│   │       └── stop_go_overlay.dart       # 起步提醒／停等計時圓形提示
│   ├── system/webrtc/                     # WebRTC client、webrtcd API、生命週期佇列
│   └── services/
│       ├── connection_manager.dart        # 探索 → 傳輸 → 轉接 → UIState
│       ├── impl/                          # mDNS、子網掃描、WebRTC 傳輸、cereal 轉接
│       ├── stop_go_alerts.dart            # 起步偵測（移植 sunnypilot）＋停等計時
│       ├── alert_sound.dart               # 提醒聲音
│       ├── app_log.dart  latency_tracker.dart  webrtc_native_log.dart
│       ├── viewer_settings.dart  viewer_system.dart  comma_models_api.dart
│       ├── line_notifications.dart        # LINE 通知接收、30 秒到期、診斷
│       ├── tdx/                           # TDX 路況（手機內建）：tdx_traffic_core 計算、tdx_traffic_service 定位與抓取
│   │   └── parking/                        # 停車查詢：TDX / 地方政府資料、快取、節流、定位（本分支）
├── android/app/src/main/kotlin/org/dragonpilot/opview/
        ├── OpviewKeepAliveService.kt      # 背景執行前景服務（保留起步語音）
        ├── MainActivity.kt                # 系統通道：亮度、狀態列、閃退原因、提醒聲音（TTS / 嗶聲）、LINE 診斷
        └── OpviewNotificationListener.kt  # 讀取 LINE 通知
└── test/                                  # 單元／Widget 測試；test/golden 為截圖測試（CI 略過）
```

## 移植來源

| 來源 | 內容 |
|---|---|
| `openpilot/selfdrive/ui/` | UIState、augmented_road_view、model_renderer、hud_renderer、alert_renderer |
| `openpilot/common/transformations/` | 相機內參、rotFromEuler、view_frame_from_device_frame |
| `openpilot/system/webrtc/webrtcd.py` | POST /stream API、資料通道格式 |
| `dashy` | 依影像縮放的校準、H264 SDP 改寫、NaN 處理、`}{` 分割、NSD 探索 |
| sunnypilot `e2e_alerts_helper.py`、`circular_alerts.py` | 前車起步、綠燈起步偵測與停等計時 |

## 更新紀錄

### v2.0.6（2026-11-04）
- **提醒聲音固定從手機喇叭播出**：嗶嗶聲、預先合成的 Google 語音一律指定手機喇叭，不走車機藍牙、也不會被導到聽筒。這樣可以避開藍牙喚醒吃掉開頭、或系統把聲音送到其他裝置的情況。log 會顯示「輸出：手機喇叭（固定，不走藍牙）」。
  - 例外：預先合成還沒完成時，Google 語音改用即時合成，這時無法指定輸出裝置，由系統決定（通常只在 App 剛開啟的幾秒內發生）。

### v2.0.5（2026-11-04）
- **提醒聲音：試聽聽得到、開車時聽不到（OPPO 實測）**：
  - log 每次都寫「播放中」，實際卻沒有聲音，原本的 log 無法分辨原因。
  - 預先載入的嗶嗶聲與語音改用 AudioTrack 播放（原本是 SoundPool）。播放 0.4 秒後檢查是否真的有播出：沒有播出就立刻改用備用方式（MediaPlayer 嗶嗶聲或即時語音）。
  - log 會記錄「已播出 N ms，實際輸出 手機喇叭／聽筒／藍牙…」，以及媒體是否靜音、手機是否在通話或網路通話模式。
  - 音訊用途由「導航語音」改為「媒體」，和設定裡顯示的媒體音量一致。

### v2.0.4（2026-11-04）
- **起步提醒圓形位置固定**：圓形固定在道路畫面右上角（直向上緣 8 dp、橫向上緣 48 dp、右緣 12 dp），不再隨 comma 底部橫幅（例如「自動煞車維持中」）出現或消失而移動；橫幅特別高、仍會碰到時只縮小，不重疊。

### v2.0.3（2026-11-03）
- **Google 語音加快**：語速 1.4 倍（字數不變），並去掉合成語音開頭／結尾的靜音。
- **提醒聲音延遲**：取消 v2.0.2 的「藍牙先送 0.8 秒靜音」。嗶嗶聲改為 App 啟動時預先載入，觸發時直接播放（原本每次都重新建立播放器，log 實測 110～630 ms 才開始播）；Google 語音在引擎就緒後先把兩句提醒合成成音檔，觸發時直接播放，不必每次即時合成。log 會記錄每次「送出 N ms」與播放方式（預先載入／即時合成）。

### v2.0.2（2026-11-03）
- **提醒聲音接車機藍牙時聽不到**：藍牙輸出閒置時，車機喚醒連線會吃掉開頭約 0.5～1 秒，0.4 秒的嗶聲整段消失。改為輸出是藍牙時先送 0.8 秒靜音喚醒再播放，並在播放期間要求短暫音訊焦點（音樂壓低）；試聽結果與 log 會顯示目前的輸出（藍牙／手機喇叭）。

### v2.0.1（2026-11-03）
直接覆蓋安裝 v2.0 即可，設定會保留（若 v2.0 與 v2.0.1 都是用同一把固定金鑰簽章；CI 臨時金鑰簽的版本需先移除舊版）。

- **Google 語音修正**：補上 Android 11 以上必要的語音服務宣告，修正 Google 語音完全沒有聲音的問題；試聽按鈕下方會顯示播放結果（例如媒體音量 0）。選項名稱改為「Google 語音」。
- **嗶嗶聲**：改用內建的 `beep.wav`，跟著媒體音量，不再受通知音量、勿擾模式影響。
- **起步提醒圓形**：依 comma 警示橫幅（例如「自動煞車維持中」）的實際位置自動避開，必要時縮小，不再被蓋住或重疊。
- **綠燈起步**：前車在 8 公尺外（例如停在較遠的機車後面）也會偵測綠燈；同一次停等已提醒前車起步就不再提醒綠燈。
- **新北市停車資料**：改用新北開放資料平台的 JSON 查詢（原本的 CSV 下載會被拒絕），路外停車場位置與即時剩餘車位可以正常取得。
- **前車資料**：同時支援 dragonpilot（`status`）與 sunnypilot（`present`）的前車欄位；log 每 60 秒記錄前車資料統計。
- **CI**：修正 3 個測試、測試失敗原因直接印在 log。

### v2.0（2026-11-02）
- 前車起步、綠燈起步、車輛停等計時（直向、橫向），提醒聲音，背景執行。
- leadOne 十字線、leadTwo 紅色箭頭；移除子母畫面。
- flutter analyze、GitHub Actions 修正；README 重寫。

## 版權與授權

- **opview**：Copyright (c) 2026, Rick Lan（[efinilan/opview](https://github.com/efinilan/opview)）。
  - 以**非商業用途**授權：可以使用、複製、修改、合併、發布、散布、再授權，但必須保留上述版權聲明與授權條款。
  - 未經版權所有人書面同意，不得用於商業用途。
  - 全文見 [LICENSE](LICENSE)。本分支的修改同樣依此授權散布。
- **openpilot**：設計參考 comma.ai openpilot，MIT License，Copyright (c) 2018 comma.ai。見 [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES)。
- **flutter_webrtc**：`third_party/flutter_webrtc` 為 flutter-webrtc 1.3.0（MIT License），保留其原始授權檔。
- **停車資料**：
  - 交通部 TDX 運輸資料流通服務。
  - 新北市政府、新竹市政府開放資料，依「政府資料開放授權條款第 1 版」使用。
  - App 會標示每筆資料的來源。資料合併、座標轉換與篩選都由 opview 處理，不代表政府機關背書。

