# opview（不含 LINE 通知讀取）

以 opview-main 原始版本為基礎，整合到 v22 的所有修改，**不含 LINE 通知讀取**。另一份 `opview-line` 多了 LINE 通知功能，其餘完全相同。

## 和原始版本的差異（摘要）
- **連線**
  - 新版 webrtcd 協定（`initCamera`、`connectionReplaced`、`clockSync`、TDX 選用服務、comma 端未更新時顯示提示）。
  - 主畫面只搜尋 comma，進入 opview 畫面才建立 WebRTC。
  - 資料只處理最新的一筆，資料延遲時改顯示「資料延遲」。
  - 影像卡住時自動恢復；有延遲紀錄。
- **畫面**
  - 儀表介面（CommaView 風格），提供直向、橫向兩種排版。
  - 方向燈顯示在儀表卡片兩側；盲點顯示為道路畫面左右邊緣的黃色光暈。
  - comma 事件顯示在道路畫面底部，直向時高度依字體調整。
  - 直向下方依序為：前方車速 → TDX 跑馬燈。
  - 點「全螢幕」或自動全螢幕時轉為橫向；主畫面與直向畫面顯示狀態列。
- **主畫面**
  - 車型讀取與設定，並顯示狀態（已讀取／上次讀取／讀取中／未連線）。
  - 裝置設定：dp 開啟 :5088，sp 開啟 sunnylink；限 offroad 或 P 檔。
  - 分支沒有 TDX 時顯示「此分支不支援 TDX」。
- **LINE 通知**：本分支沒有。不需要「通知存取權」，AndroidManifest 不宣告通知讀取服務，也不查詢 LINE 是否安裝。
- **log**
  - 記錄閃退原因（ApplicationExitInfo）和 libwebrtc 原生 log。
  - 只保留 3 天。
- **修正**
  - 移除解碼器 configure 測試：它在 Android 16 會因 SurfaceTexture finalize 而閃退。
  - IPv6 link-local 位址的網址處理。

## 編譯
- 需要 `flutter pub get`：pubspec 新增了 logger，並使用 `third_party/flutter_webrtc`。
- 修改是在沒有 Flutter SDK 的環境下完成的，只做過語法檢查。請先在 CI 跑 `flutter analyze` 和 `flutter test`。
