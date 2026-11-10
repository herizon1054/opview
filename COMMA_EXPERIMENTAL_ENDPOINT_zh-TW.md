# comma 端：實驗模式開關端點（給 opview 第一顆按鈕使用）

opview 側欄 / 直向操作列的第一顆按鈕改為「實驗模式」開關。opview 本身只接收 webrtcd 的資料，
沒有寫入 comma 參數的管道，所以需要在 comma 端與車型選擇**同一個服務**（port 5088）加一個端點：

- dragonpilot 分支：`dragonpilot/dashy/serverd.py`
- sunnypilot 分支：opviewd

> **已實作**（2026-11-10）：openpilot-dp0111pre、openpilot-dplcc（`dragonpilot/dashy/serverd.py`）、
> openpilot-test（sunnypilot，`openpilot/sunnypilot/opview/opviewd.py`）。條件已對照各分支的
> `selfdrive/ui/layouts/settings/toggles.py`、`selfdrive/ui/ui_state.py`、`selfdrive/selfdrived/selfdrived.py` 確認。
> 另有 `GET /api/experimental_mode` → `{"experimental_mode", "available", "confirmed"}` 供診斷。

## 介面

```
POST http://<comma>:5088/api/experimental_mode
Content-Type: application/json

{"enabled": true}        // 或 false
```

| 狀態 | 回應 | opview 顯示 |
|---|---|---|
| 200 | `{"experimental_mode": true}`（寫入後的實際值） | 「已開啟實驗模式」/「已關閉實驗模式」；值與要求不同時「comma 未切換實驗模式」 |
| 403 / 409 | `{"error": "<原因>"}` | 直接顯示原因 |
| 404 | — | 「comma 端沒有實驗模式設定（請更新 comma 分支）」 |
| 逾時 / 連不到 | — | 「連不到 comma，實驗模式未切換」 |

- opview 只在**已連線**時送出（未連線顯示「未連線 comma，無法切換實驗模式」）。
- 按鈕顯示的狀態一律以 webrtcd 傳來的 `selfdriveState.experimentalMode` 為準，不是以 HTTP 回應為準。
- 逾時 5 秒；opview 不重試。

## comma 端應檢查的條件（比照 openpilot 設定頁）

1. **只有 openpilot 縱向控制可用時才允許開啟**（與 `ui_state.has_longitudinal_control` 相同：車輛有 alpha 縱向時看
   `AlphaLongitudinalEnabled`，否則看 `CarParamsPersistent.openpilotLongitudinalControl`）；否則回 409。
   從未發動（沒有 `CarParamsPersistent`）也回 409。
2. **不要替使用者自動寫入 `ExperimentalModeConfirmed`**：那是 openpilot 設定頁的實驗模式說明確認。
   尚未確認時回 409 `{"error": "請先在 comma 設定頁開啟一次實驗模式並確認說明"}`。
3. 關閉一律允許。
4. 行駛中切換：selfdrived 的 `params_thread` 每 0.1 秒重讀 `ExperimentalMode`（且需 `openpilotLongitudinalControl`），
   與原廠設定頁 / onroad 按鈕相同，寫入後即生效（三個分支皆已確認）。

## 參考實作（Python，框架無關）

```python
from openpilot.common.params import Params
from cereal import car


def set_experimental_mode(enabled: bool) -> tuple[int, dict]:
  params = Params()
  if enabled:
    # 1) 需要 openpilot 縱向控制（讀 CarParamsPersistent；分支若用其他鍵名請改）
    cp_bytes = params.get("CarParamsPersistent")
    if cp_bytes:
      with car.CarParams.from_bytes(cp_bytes) as CP:
        if not CP.openpilotLongitudinalControl:
          return 409, {"error": "此車未使用 openpilot 縱向控制，無法開啟實驗模式"}
    # 2) 實驗模式說明需由使用者在 comma 設定頁確認過
    if not params.get_bool("ExperimentalModeConfirmed"):
      return 409, {"error": "請先在 comma 設定頁開啟一次實驗模式並確認說明"}
  params.put_bool("ExperimentalMode", enabled)
  return 200, {"experimental_mode": params.get_bool("ExperimentalMode")}
```

接到 HTTP 路由（依 serverd / opviewd 實際使用的框架改寫）：

```python
# 讀 JSON body → enabled = bool(body.get("enabled"))
# status, payload = set_experimental_mode(enabled)
# 以 status 回應 JSON（Content-Type: application/json; charset=utf-8）
```

## 測試

opview 端：`test/comma_experimental_api_test.dart`（請求格式、comma 拒絕時以回應值為準、404、錯誤原因）、
`test/rail_test.dart`（第一顆是實驗模式開關、沒有 km/h、未連線時提示、狀態依 selfdriveState 顯示）。

comma 端建議手動確認：
1. `curl -X POST -H 'Content-Type: application/json' -d '{"enabled":true}' http://<comma>:5088/api/experimental_mode`
2. 不支援縱向控制的車：應回 409。
3. 行駛中切換後，opview 按鈕在約 1 秒內變為「實驗 開」（selfdriveState 回報）。
