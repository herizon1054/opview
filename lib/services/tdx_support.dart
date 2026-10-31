// comma 分支是否支援 TDX（dplcc 的 tdx service）
//
// opview 的 webrtcd 請求會帶 optional service「tdx」；沒有 tdx 的分支（services.py 沒登記）
// webrtcd 建 SubMaster 時 KeyError → HTTP 500，opview 改用不帶 tdx 的請求重試（webrtcd_api.dart）。
// 連線成功後由 ConnectionManager 依實際用的請求設定：
//   true  = 帶 tdx 的請求成功（分支支援）
//   false = 帶 tdx 失敗、不帶 tdx 成功（此分支不支援 TDX）
//   null  = 尚未連線過，未知
// 顯示設定（TDX 開關）與主畫面讀這個值顯示「此分支不支援 TDX」。

import 'package:flutter/foundation.dart';

final tdxSupport = ValueNotifier<bool?>(null);

const tdxUnsupportedText = '此分支不支援 TDX';
