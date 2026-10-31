# Opview R19 完整原始碼

此包包含原始 opview-noline 完整專案與 R19 停車功能修改，並非僅覆蓋檔。

1. 解壓縮後進入 opview-r19 資料夾（此層有 pubspec.yaml）。
2. 執行 flutter pub get。
3. 執行 flutter build apk --release。

third_party/flutter_webrtc 必須與 pubspec.yaml 一起保留並提交 Git；這是本機修改版，請勿移除 dependency_overrides 來繞過缺檔。
外部 Flutter、Android SDK 與套件仍需由建置環境安裝或下載，此包不是離線工具鏈或 APK。

已確認原始專案檔案與 R19 覆蓋檔合併、path 套件存在及 ZIP 完整性。未在本環境完成 flutter pub get、Flutter 全套測試或 APK 編譯。先前 CI 回報的四項 UI 測試失敗仍待詳細輸出確認，本包未宣稱修正。
