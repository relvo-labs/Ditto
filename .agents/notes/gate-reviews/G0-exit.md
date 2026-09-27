# G0 出口評審

| 欄位 | 內容 |
| --- | --- |
| 評審日期 | 2026-09-22（預檢；尚未達成出口） |
| 版本指紋 | Ditto `6dfa07d` ＋未提交工作樹；Rust 1.98.1；Node 22.23.2；pnpm 10.11.0；Qt 6.10.2；Quickshell 0.3.1；Wayfire 0.11.0-d3990237／wlroots 0.20.2 |
| 參考機 | `ditto-ref-ws-rtx4060-01`；Ubuntu 24.04.2、kernel 6.17.0-40、Ryzen 9 7945HX、RTX 4060／570.211.01、1920×1080@60 Hz、scale 1 |
| 出席 | 產品 owner Lei-k；本紀錄為自動化預檢，尚待正式評審與工作流 owner 確認 |

本預檢不把未提交工作樹、縮短量測或 headless 虛擬輸入升格成出口證據。九項門檻未全數通過，**G0 尚未出口**。

## 1. 門檻逐項結果

| 門檻 | 結果 | 證據 | 備註／解除條件 |
| --- | --- | --- | --- |
| EX-01 原生應用可控 | 條件通過 | `artifacts/g0/window-matrix-2026-09-22T15:03:52Z-6dfa.jsonl` | Firefox／foot／Kate 得到 30 項回讀驗證、40 項讀取、3 項 close request 送達、0 項 `unsupported`。變更進版後以該 commit 重跑，讓 artifact 與來源版本一對一，即可解除條件。2026-09-27 已以已進版的 `7333c20` 在參考機重跑三次（36303881879／36303886123／36303890347），每次都是 30 項回讀驗證、43 項讀取、0 項 `unsupported`；待出口評審確認解除 |
| EX-02 合成器缺口與 D-02 | 未通過 | `artifacts/g0/compositor-probe-wayfire-0.11.0-d3990237-2026-09-22T15:36:44Z-6dfa.json`；[能力差異表](../../../docs/platform/compositor-capability-matrix.md)；[D-02](../decisions/2026-09-22-d02-compositor-wayfire.md) | C-01～07 與 C-09～14 在 G0 要求範圍均有結論；阻斷列 C-08 尚未觀察到中文提交 |
| EX-03 Shell 重啟存活 | 條件通過 | `artifacts/g0/shell-restart-2026-09-22T15:05:18Z-6dfa.json` | 10 次 TERM＋10 次 KILL 全部存活；Kate 未儲存緩衝雜湊一致；重啟中位數 115 ms。變更進版後以該 commit 重跑即可解除條件。2026-09-27 以 `7333c20` 重跑三次，每次 20／20 存活、Kate 緩衝不變、重啟中位數 63～64 ms；待出口評審確認解除 |
| EX-04 幀時與熱路徑 | 條件通過；**2026-09-27 新數據待評審** | `artifacts/g0/frametime-2026-09-22T15:17:18Z-6dfa.jsonl`、`...15:17:56Z...`、`...15:18:34Z...` 與同 run id 的 `hotpath-rpc-count-*`／`presentation-*` | 三次均達幀時門檻且熱路徑 RPC 為 0。2026-09-27 以已進版的 `7333c20` 在參考機重跑三次（見 EX-09）：熱路徑 RPC 都是 0，QML 各段 ≥98.5%；但第 1 次（36303881879）的 `wp_presentation` 整段只有 94.41% ≤16.7 ms、p95 16.701 ms，低於 95%，另兩次為 97.77%、96.09%。nightly 腳本不擋這一項，因此綠燈不代表 EX-04 成立 |
| EX-05 資源預算與配額核定 | 未通過 | `artifacts/g0/quota-baseline-2026-09-22T14:46:14Z-6dfa.json`；[D-06b](../decisions/2026-09-22-d06b-tool-quotas.md) | 配額已核定；仍缺三次真正 cold login、300 秒暖機、600 秒採樣，以及角色關閉／減少動畫兩組。`resource-report-2026-09-22T14:40:17Z-6dfa.md` 是縮短試跑，報告本身已標明不可作 EX-05 證據 |
| EX-06 契約與目錄一致性 | 條件通過 | 本機 CI 等價檢查：Rust 41 tests、TS 9 tests、fmt、clippy、schema 新鮮度、15 個 skill lint 均通過 | GitHub 上的 workflow 尚未包含本工作樹；變更進版並由 `contracts.yml` 成功執行後解除條件 |
| EX-07 身分無法自述 | 條件通過；**CI 紀錄已產生** | 參考機執行 `tests/g0/identity-negative/run.sh`：正例成功、三項負例皆 `identity_rejected` | 2026-09-27 起 `nightly-refmachine` 內含此步驟，`7333c20` 的三次參考機執行都成功，可作為 CI 執行紀錄 |
| EX-08 中文輸入鏈路 | 未通過 | [輸入法報告](../../../docs/platform/input-method-report.md) §5；`artifacts/g0-vm/2026-09-27T05:43:05Z-45e3/` | 2026-09-27 開發 VM：在 GDM 登入工作階段中以核心 uinput 鍵盤輸入，QML／foot／Kate 都提交 `你好`，三方剪貼簿一致，候選窗截圖貼近游標。這證明 `stipc` 失敗是注入器的限制。仍缺參考機上實體鍵盤的最終 JSON 與錄影 |
| EX-09 真機 runner nightly | 未通過 | [D-19](../decisions/2026-09-22-d19-reference-runner.md)、[D-36](../decisions/2026-09-27-d36-ex09-same-day-runs.md)；run 36269089432 | 2026-09-26 第一晚測試步驟全綠，但因上傳拒收含 `:` 的檔名而判失敗，已修正。D-36 把判準放寬為同一 commit 的 3 次獨立參考機執行。`7333c20`：VM 三輪 9／9，參考機 36303881879／36303886123／36303890347 全數成功並上傳。**依 D-36 判準成立，待出口評審確認** |

## 2. 量測數字與條件

### 2.1 EX-04 三次參考機量測

| Run ID | `wp_presentation` 樣本 | p95 ms | ≤16.7 ms | QML 最低合格比例 | 動畫熱路徑 RPC | 明確工作區命令 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `2026-09-22T15:17:18Z-6dfa` | 179 | 16.202484 | 100% | 100% | 0 | 5 |
| `2026-09-22T15:17:56Z-6dfa` | 179 | 16.226993 | 99.44% | 99.67% | 0 | 5 |
| `2026-09-22T15:18:34Z-6dfa` | 179 | 16.227353 | 100% | 99.84% | 0 | 5 |

條件：實體參考機、Wayfire headless output 1920×1080@60 Hz、GLES2、每段 10 秒；動畫熱路徑包含 idle／pointer／drag，語意命令另列。`wp_presentation` 與 QML 中位數相差小於 1 ms。這是 G0 的 NFR-05 初測，不是 G4 的完整 NFR-05 驗收。

### 2.2 EX-05 現況

D-06b 的三項控制器案例已成立：記憶體超限只終止 scope、CPU quota 實測 0.200、`TasksMax=16` 時成功建立 15 個子程序。PSS 試跑確定 Core／Shell／合成器可分層且 cgroup 對應正確，但因不是三次 cold login 且採樣只有 2 秒，數字不列入本評審。Cordis 宿主、Agent、無 Node 救援模式與完整桌面總量在 G0 不可量測。

## 3. 未達標項目

| 項目 | 已知事實 | 調整提案與解除方式 |
| --- | --- | --- |
| C-08／EX-08 | 自動注入未產生中文，不能區分 `stipc` 限制與 Wayfire/Fcitx relay 問題 | 從登入管理器進入「Ditto G0 (Wayfire)」，執行 `tests/g0/input-method/manual-session.sh`；若實體鍵盤亦失敗，擷取 Qt／Fcitx／Wayfire protocol trace 後修正，不降低門檻 |
| EX-05 | 自動 session fixture 不是 cold login；縮短試跑無效 | 在三次獨立登入中執行既定 300＋600 秒流程，另跑角色關閉與減少動畫；完成後建立 D-06a，不引用現有試跑數字。2026-09-27 開發 VM 已用完整時長跑完這套流程（`artifacts/g0-vm/2026-09-27T05:50:23Z-45e3/`，8／8），證明流程本身可以無人值守完成；數字來自軟體算繪 VM，不引用 |
| EX-06／07 的 CI 證據 | 本機等價檢查通過，但遠端仍是舊 commit | 經 owner 核准後 commit／push；由 self-hosted `ditto-ci` runner 跑正式 workflow |
| EX-09 | runner 已在線，但連續三晚尚未發生 | 變更進版後依排程累積三個不同夜晚；任何一晚失敗重新計數 |
| G0-SHELL-01 | 登入項目與受控啟動器已安裝，尚未從 display manager 實際登入 | 與 EX-08 同一次實體登入完成桌面、參考應用啟動與退出驗證 |
| G0-PLAT-01 | lock、preflight、安裝器已在本機通過，尚缺第二人重建 | 由另一位開發者在另一台符合資格的參考機依 `packaging/reference-image/README.md` 重建並保存 preflight 輸出；一般開發機不受此限制 |

## 4. 本階段產生的新風險與新決策

- 已回寫 `milestones/01/05`：D-01、D-02、D-03、D-06b、D-13、D-14、D-19、D-22、D-23、D-24，以及 runner／參考機相關風險。
- GitHub-hosted job 目前受帳務／spending limit 阻擋，標準工作流已改投 `self-hosted`＋`ditto-ci`；在變更進版前，這只是本機工作樹，不能宣稱遠端 CI 已恢復。
- 2026-09-26：snapd 自動把 Firefox 更新為 156.0.1 rev 8969，preflight 因而拒絕量測；使用者決定採用新版（[D-01a](../decisions/2026-09-26-d01a-firefox-156-0-1.md)）。新版預設的 Wayland proxy 在 headless 夾具中不會映射視窗，夾具已改為直接連線。舊的 EX-01／03／04 結果不能與新指紋續接。snap 仍未 hold。
- 2026-09-26：當參考機同時登入 Ditto 工作階段時，參考夾具會與登入中的 Core／Shell 共用 `$XDG_RUNTIME_DIR/ditto/`。夾具 Core 綁定失敗，`dittoctl` 與 Shell 改連到登入中的 Core，被以 `identity_rejected` 拒絕；hotpath 的明確命令也送不到夾具 Shell。window-matrix 還把全部沒有回應的探測記錄成一份空矩陣並判為通過。已改成：Core、`dittoctl` 與 Shell 接受 `DITTO_RUNTIME_DIR`，參考夾具使用自己的目錄；沒有回應的探測記為不通過的格；空矩陣判為失敗；hotpath 的 phase 記錄改為每次執行各自一份。
- 2026-09-26：Ditto 登入工作階段沒有把 `WAYLAND_DISPLAY` 匯入 systemd／D-Bus activation 環境，`xdg-desktop-portal-gtk` 因此以 `cannot open display` 失敗。Firefox snap 強制 `GTK_USE_PORTAL=1`，每次 portal 呼叫都要等約 25 秒逾時。`ditto-g0-session` 已補上 `dbus-update-activation-environment --systemd`，重新執行 `install-session.sh` 並重新登入後生效。
- 以上修正後，參考機以軟體算繪（這時 seat 在 GDM greeter，沒有 GPU）跑的 window-matrix、shell-restart、shell-session、hotpath（功能部分）、avatar-hit-region、identity-negative 全部通過。這些是未進版工作樹、非 GPU 的開發證據，不列為出口證據。
- 2026-09-26：登入畫面擋住登入（`Couldn't find session for user`）。原因是 21:02 從 tty3 重啟 GDM 時，舊 Ditto 工作階段的 `gdm-session-worker` 5 秒內沒結束，GDM 就放棄了它；新的 GDM 沒有這個工作階段的紀錄，卻拒絕同一使用者再登入。已新增 `gdm.service` drop-in：GDM 停止與啟動時只結束執行 `ditto-g0-session` 的工作階段；`ditto-g0-relogin` 也改成不再結束 tty 登入。
- 2026-09-26：實際登入時，Wayfire、Core、Shell、Fcitx 與 GDM 的輔助程序同在一個 `session-N.scope`，`ditto-measure` 無法依 cgroup 分出 Core／Shell／合成器，所以 EX-05 的 cold-login 量測原本無法執行。登入 script 已把四者各放進 user scope（Shell 由 Core 的受控啟動器以 `systemd-run --scope` 就地 exec，PID、token fd 與 `/proc/<pid>/exe` 都不變，身分負例照常通過），登出或上一次登入殘留時都會清理；另新增 `tests/g0/measure/cold-login.sh` 與 `DITTO_AVATAR=off`。
- 參考機是一種可驗證角色，不是唯一開發環境。其他機器可開發與跑非出口測試；效能數字不得跨機混算。

## 5. 下一階段的估算修正

D-02 選擇 Wayfire 後，Core 的 13 項 G0 能力與轉接已落地；C-04／05 的 Wayfire IPC 成本不再是未知數。D-21 的 G0 估算修正仍需產品／工作流 owner 核定；本次預檢不代替人力承諾。G1 在本評審仍有未通過項目時不得以「G0 已出口」為前提啟動依賴它們的工作。
