# G0 中文輸入法鏈路報告

| 項目 | 結果 |
| --- | --- |
| 日期 | 2026-09-22 |
| 工作包 | [G0-PLAT-04](../../plan/02/06-workplan.md#g0-plat-04-輸入法鏈路驗證) |
| 對應門檻 | [EX-08](../../plan/02/01-scope-and-exit-criteria.md#ex-08-中文輸入鏈路成立加嚴項) |
| 環境 | 參考機 `ditto-ref-ws-rtx4060-01` 上的隔離 headless Wayfire 工作階段；**不是登入管理器工作階段，不能代替實體鍵盤驗證** |
| 結論 | **功能鏈路已成立，EX-08 證據封存尚未完成**。v2 路徑在實體登入 session 重現 relay 故障；改用 Wayfire 的 v1 bridge 後，自動與實體鍵盤 QML 回讀皆提交 `你好`，候選窗位置截圖正確，操作員確認 Kate 拼音與複製貼上可用。驗收 foot 在最終 JSON 寫入前被關閉，且尚未附錄影位置，因此不能把 EX-08 標為正式通過 |

本報告依 [plan/02 §6](../../plan/02/02-platform-and-compositor.md#6-輸入法鏈路g0-plat-04) 的五步驟記錄。自動探針的斷言讀回 QML `TextInput.text`，不以 Fcitx 已啟動、日誌沒有錯誤或畫面看似正常代替提交結果。

## 1. 測試環境與路徑

| 元件 | 實測值／設定 |
| --- | --- |
| OS | Ubuntu 24.04.2 LTS 參考機 `ditto-ref-ws-rtx4060-01` |
| 合成器 | Wayfire `0.11.0-d3990237`、wlroots 0.20.2、headless backend、Pixman renderer |
| Qt／Quickshell | Qt 6.10.2／Quickshell 0.3.1 |
| 輸入法 | Fcitx 5.1.7、`wayland` 與 `waylandim` addon、拼音引擎 |
| Wayland client 路徑 | Qt `QWaylandTextInputv3` → `zwp_text_input_v3` |
| 輸入法路徑 | Qt `zwp_text_input_v3` → Wayfire `input-method-v1` bridge → Fcitx5 |
| Wayfire 前提 | 載入 `input-method-v1` 且停用 `workarounds/enable_input_method_v2`；兩條 bridge 不可同時啟用 |
| 隔離 | 每次建立私有 `XDG_RUNTIME_DIR`、session bus、Fcitx 設定與 Wayfire 工作階段，不讀寫使用者的 Fcitx profile |

[Fcitx 的 Wayland 說明](https://fcitx-im.org/wiki/Using_Fcitx_5_on_Wayland/en)指出，Qt 6.7 之後可用 `QT_IM_MODULES` 選擇 Wayland input context；本機實測還需要明確設定單數的 `QT_IM_MODULE=wayland`，否則自建 Qt 6.10.2 選到 compose input context。測試夾具因此使用：

```sh
XMODIFIERS=@im=fcitx
QT_QPA_PLATFORM=wayland
QT_IM_MODULES=wayland
QT_IM_MODULE=wayland
```

系統的 Fcitx Qt plugin 是針對 Ubuntu Qt 6.4.2 編譯，不能載入自建 Qt 6.10.2，故沒有把 `QT_IM_MODULE=fcitx` 當成 Quickshell 的可用路徑。正式工作階段要採用哪些全域與逐程序環境變數，仍須等實體應用驗證後固定，不能由這次 headless 測試推定。

## 2. 五步驟結果

| 步驟 | 結果 | 證據與缺口 |
| --- | --- | --- |
| 1. 框架與 Wayland 後端 | **開發環境已確認** | Qt 綁定 `zwp_text_input_manager_v3`；Wayfire v1 bridge 與 Fcitx5 完成提交。v2 路徑已由實體鍵盤證明會失敗，不再採用 |
| 2. 工作階段環境 | **夾具已設定，正式工作階段未定案** | 上述四個變數可讓 Qt 綁定 text-input-v3；登入管理器工作階段尚未用實體輸入驗證 |
| 3. QML 元件 | **自動與實體提交通過** | v2 路徑回讀原始 `nihao` 且 Wayfire 記錄 popup 無 text input；改用 v1 bridge 後，自動探針與實體鍵盤日誌皆回讀 `你好`。證據：`artifacts/g0/input-method-2026-09-22T16:58:05Z-6dfa.json`、`artifacts/g0/input-method-physical-qml-2026-09-22T17:16:12Z-6dfa.log` |
| 3a. 候選窗位置 | **通過（截圖）** | `artifacts/g0/input-method-physical-candidate-2026-09-22T17:16:12Z-6dfa.png` 顯示候選窗貼近 QML 輸入游標 |
| 4. 參考終端與編輯器 | **人工操作成立，證據未封存** | foot 與 Kate 已由操作員實測；Kate 必須使用系統 Qt 對應的 `QT_IM_MODULE=fcitx`，腳本已修正。最終 JSON 在視窗關閉前未寫出 |
| 5. 三方剪貼簿 | **人工操作成立，證據未封存** | 操作員確認複製貼上可用；最終 JSON 在視窗關閉前未寫出 |

每次執行會在 `artifacts/g0/` 留下同一 `run_id` 的 `input-method-*.json`、候選窗截圖，以及 QML、Fcitx、Wayfire 三份原始日誌。`artifacts/` 是本機執行產物；重跑時以新 `run_id` 產生，不把舊結果當成當前結果。

重現方式：

```sh
export PATH="$HOME/wayfire/bin:$PATH"
export LD_LIBRARY_PATH="$HOME/wayfire/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
DITTO_WORKSPACE="$PWD" DITTO_ARTIFACTS="$PWD/artifacts/g0" \
  DITTO_ENVIRONMENT_LABEL=development-workstation \
  bash tests/g0/input-method/run.sh
```

測試目前預期以非零狀態結束，但會先保留 JSON 與截圖。只有 QML 實際回讀到中文時才會通過。

## 3. 已知與未知的邊界

已知：

- Wayfire 的兩個必要 global 在指定設定下存在。
- Qt 的 text-input-v3 input context 已對焦點 surface 啟用。
- Fcitx 的 D-Bus 介面可用且焦點 input context 選到 `pinyin`。
- 由 `stipc` 注入的按鍵直接成為 QML 文字，沒有出現候選窗，也沒有中文提交。

仍未知：

- `stipc` 建立的虛擬鍵盤是否繞過 input-method keyboard grab；若是，這個自動化路徑只能驗證協定啟用，不能代替實體鍵盤。
- 實體鍵盤走相同 Wayfire/Fcitx 路徑時是否能組字。
- 若實體鍵盤也失敗，缺陷位於 Wayfire text-input/input-method relay、Fcitx 對接，或工作階段啟動順序的哪一層。

因此這次結果不能單獨證明 Wayfire 的輸入法實作故障，也不能證明 C-08 支援。它把問題縮小到「協定已接起，但尚未觀察到中文提交」。

## 4. 後續處理與 EX-08 判定

1. 從登入管理器進入 Ditto Wayfire 工作階段，執行 `tests/g0/input-method/manual-session.sh`；它會要求以實體鍵盤在最小 QML、foot 與 Kate 重跑 `切換拼音 → nihaox → 退格 → 候選 → 選字 → 送出`，並驗證同一段中文可貼入三者，保留提交文字、候選窗截圖與人工位置判定。另依 EX-08 要求錄影並把位置補進本報告。
2. 若實體鍵盤成功，把自動探針標為虛擬輸入限制，保留它做協定與輸入上下文診斷；不得把它當 EX-08 的提交測試。
3. 若實體鍵盤失敗，同時擷取 Qt client、Fcitx input-method client 與 Wayfire 的 Wayland protocol trace，再以本報告的最小 xdg-toplevel 夾具製作上游重現案例；修正前 C-08 維持未通過。
4. QML 成功後，同一支腳本會繼續在凍結的參考終端與編輯器重跑序列並驗證三者間中文剪貼簿；任何一處失敗都以非零結束。
5. 候選窗必須貼近游標；若中文可輸入但位置錯誤，依計畫記為「部分支援」並說明影響，不得把 EX-08 標記通過。

目前 **G0-PLAT-04 為進行中，EX-08 未通過**。參考機與真機 runner 已就緒，但仍須在登入管理器工作階段以實體鍵盤完整重跑；隔離 headless 結果不能升格為 EX-08 出口證據。

## 5. 2026-09-27：登入工作階段中的核心鍵盤（開發 VM）

依 [D-25](../../.agents/notes/decisions/2026-09-27-d25-vm-first-automation.md)，把 `manual-session.sh` 的步驟做成無人值守的 `tests/g0/input-method/login-session-auto.sh`，在開發 VM 由 GDM 自動登入的「Ditto G0 (Wayfire)」工作階段中執行，也就是該工作階段自己的 Wayfire、Fcitx 與 session bus。按鍵來自 `uinput-keyboard.py` 建立的核心 evdev 裝置。從 libinput 看，它和 USB 鍵盤是同一類裝置，不像 `stipc` 那樣走合成器內部的虛擬鍵盤。

| 項目 | 結果（`artifacts/g0-vm/2026-09-27T05:43:05Z-45e3/`） |
| --- | --- |
| 切換方式 | 三個應用都以 Ctrl+Space 切到拼音（只在焦點輸入上下文未啟用時按） |
| QML | 回讀 `你好`；組字期間出現 `DITTO_INPUT_COMPOSING` |
| foot | 終端的 `read` 收到 `你好` |
| Kate | `Ctrl+A`、`Ctrl+C` 後的剪貼簿為 `你好` |
| 三方剪貼簿 | `剪貼簿互通` 貼入 foot、Kate 與 QML，三者回讀一致 |
| 候選窗 | 三張截圖都顯示候選列緊貼輸入游標下方，第一候選是「你好」。這是看截圖的判斷，腳本不判定 |

這回答了 §3 留下的第一個未知：**同一條 Wayfire input-method-v1 bridge 對核心層鍵盤可以正常組字；`stipc` 自動路徑失敗，是它繞過輸入法鍵盤 grab 的限制。** 因此 §4 第 2 步成立，自動探針（`run.sh`）只保留作協定與輸入上下文診斷。

仍然**不是 EX-08 證據**：VM 不是參考機，按鍵不是人按的，也沒有錄影。EX-08 剩下的是：在參考機上從登入管理器登入，以實體鍵盤跑一次 `manual-session.sh` 讓最終 JSON 寫出，並把錄影位置補進本報告。
