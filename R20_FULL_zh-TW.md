# R20 完整專案覆蓋包

解壓縮內容直接覆蓋專案根目錄（pubspec.yaml 所在層），包含 third_party/flutter_webrtc 本機套件。不需刪除檔案。

本次僅修改 lib/selfdrive/ui/onroad/parking_panel.dart 的顯示文字：缺少資料顯示「無資料」、有效汽車 0 格顯示「無空位」、有效正數顯示「剩餘 N 格」。保留時間不明、資料過期、非營業中與未分類標記；地方資料未附來源時間時仍顯示「回報 N 位*」。路邊無資料或 0 格仍隱藏。

包含 R19 放大字體與導航圖示、R18 預設 1000 公尺及預設關閉測試功能。
已通過 Dart 格式檢查與壓縮包完整性核對。未編譯 APK，未執行 Flutter UI 測試；先前四項 UI 測試失敗並未在此修正。

覆蓋後執行 flutter pub get，再執行 flutter build apk --release。
