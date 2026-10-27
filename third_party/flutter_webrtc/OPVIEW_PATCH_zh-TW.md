# flutter_webrtc 1.3.0 — opview 修改說明

## 來源
- flutter-webrtc/flutter-webrtc GitHub tag `v1.3.0`（commit `ce76f49 release: 1.3.0 (#1988)`），
  與 opview `pubspec.lock` 鎖定的 `flutter_webrtc 1.3.0` 同版號。
- 未含 `example/`、`test/`、`Documentation/`、`.github/`。
- 未能從 pub.dev 下載發布檔比對 sha256（環境無法連線 pub.dev），以 GitHub release tag 為準。
- 依賴的 libwebrtc：`io.github.webrtc-sdk:android:137.7151.04`（M137，見 `android/build.gradle`）。

## 修改內容（只有一個檔）
`android/src/main/java/com/cloudwebrtc/webrtc/MethodCallHandlerImpl.java`
1. `initialize(...)` 新增參數 `disableNetworkMonitor`，設定 `PeerConnectionFactory.Options.disableNetworkMonitor`。
2. `"initialize"` method call 讀取 `options["disableNetworkMonitor"]`（Boolean），**預設 true**。
   flutter_webrtc 會在第一次呼叫任何 API 時自動 initialize（只帶 `logSeverity`），
   所以預設值必須是 true 才保證生效；需要原行為可傳 `false`。

## 為什麼要改（libwebrtc M137 原始碼依據）
1. `sdk/android/api/org/webrtc/NetworkMonitorAutoDetect.java`：Android 網路清單來自
   `ConnectivityManager.getAllNetworks()`（另可選 WifiDirect）。手機「開熱點」時的熱點介面
   （swlan0 / ap0 / wlan1 等，依廠牌而異）**不是** ConnectivityManager 的 Network。
2. `sdk/android/src/jni/android_network_monitor.cc` `GetInterfaceInfo()`：找不到 Network handle 的介面
   回傳 `available = false`（除非 field trial `WebRTC-AndroidNetworkMonitor-IsAdapterAvailable/Disabled/`）。
3. 同檔 `BindSocketToNetwork()`：就算介面可用，綁定時找不到 Network handle 回傳 `ADDRESS_NOT_FOUND`；
   `rtc_base/physical_socket_server.cc` 對此直接 `return -1` 放棄該 socket。
   → 只開 field trial 不夠，熱點介面仍無法建立 socket。
4. `sdk/android/src/jni/pc/peer_connection_factory.cc`：`options->disable_network_monitor` 為 true 時
   不建立 `AndroidNetworkMonitorFactory` → 無 network binder，BasicNetworkManager 以 getifaddrs 列舉所有介面、
   直接 bind IP → 熱點介面可產生 host candidate。

症狀對照：手機當熱點時 `POST /stream`（Dart 一般 socket）成功，但 WebRTC 只能用行動網路位址，
comma 回不來 → 影像/資料不通（黑畫面），ICE 逾時或 disconnected → 斷線重連。

## 影響與取捨
- 失去 Android 網路切換偵測（WiFi ↔ 行動網路自動切換、依網路類型綁定）。opview 只在區域網路連 comma，
  連線中斷時本來就會重連，影響可忽略。
- 介面類型改由名稱推斷（rmnet → cellular、wlan → wifi，其餘 unknown），`networkIgnoreMask` 預設不忽略任何類型。
- iOS / 其他平台未修改。

## 驗證狀態
- 已做：Java 檔 tree-sitter 語法解析；以上 libwebrtc M137 / flutter_webrtc 1.3.0 原始碼行為逐一對照。
- 未做：Gradle 編譯、實機熱點測試。實機判斷方式：opview log 的 `ice local` 應出現熱點介面位址
  （例如 `host 192.168.x.1:xxxxx/udp`），`webrtc stats` 的 pair 應為熱點位址 → comma 位址，且 `frames dec` 持續增加。
