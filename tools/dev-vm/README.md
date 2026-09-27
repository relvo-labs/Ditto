# G0 開發 VM

依 [D-25](../../.agents/notes/decisions/2026-09-27-d25-vm-first-automation.md)，這是 G0 自動化測試的第一線：會中斷工作階段、重啟 GDM 或需要反覆登入的測試，都先在這台 VM 通過，才上實體參考機。

**VM 的結果只是開發證據。** 它沒有實體 GPU，核心與平台事實也和參考機不同，不能替代 EX-01～EX-09 的任何一項。

## 組成

| 項目 | 值 |
| --- | --- |
| libvirt domain | `ditto-g0-vm`（`qemu:///system`，NAT 網路 `default`） |
| 系統 | Ubuntu 24.04 cloud image（建立時為 24.04.5／kernel 6.8）、4 vCPU、8 GiB、60 GiB、virtio-gpu |
| 桌面 | GDM 自動登入到「Ditto G0 (Wayfire)」；Wayfire、Qt／Quickshell、Node 從參考機的凍結前綴複製 |
| 快照 | `ditto-base`：每次執行都從這裡還原 |
| 本機狀態 | `~/.config/ditto-vm/`（登入密碼、cloud-init、known_hosts）、`~/.ssh/ditto-vm_ed25519`；都不進倉庫 |

## 使用

```sh
bash tools/dev-vm/create.sh      # 第一次：下載並驗證映像、建立 VM、佈建、存快照
bash tools/dev-vm/provision.sh   # 凍結前綴或登入設定改變後：重新佈建並覆寫快照
bash tools/dev-vm/run.sh         # 還原快照 → 安裝目前工作樹 → 測試 → 取回 artifacts → 關機
bash tools/dev-vm/run.sh login   # 只跑其中一組：fixtures、login、input-method、cold-login、cold-login-full
```

預設跑 `fixtures login input-method cold-login`。`cold-login-full` 約 90 分鐘，只在要求時執行。

`run.sh` 的結果寫在 `artifacts/g0-vm/<run_id>/summary.jsonl`，每一項檢查另有 log。VM 內產生的 artifacts 也會複製回同一個目錄。`.github/workflows/vm-regression.yml` 在相關 PR 與每天 00:00（台北）自動執行它。

| 組 | 檢查 |
| --- | --- |
| `fixtures` | window-matrix、identity-negative、shell-session、shell-restart-survival、hotpath、avatar-hit-region、compositor-probe（開發模式，標籤 `development-vm`） |
| `login` | 經 GDM 重新登入後四個分層 scope 都成立；SIGKILL GDM 後 drop-in 結束孤兒工作階段，新的登入正常 |
| `input-method` | 在 GDM 登入工作階段裡，以核心 uinput 鍵盤（`tests/g0/input-method/uinput-keyboard.py`）照 `manual-session.sh` 的步驟輸入：QML、foot、Kate 各以 Ctrl+Space 切到拼音、`nihaox`、Backspace、選字，逐一從應用本身回讀；再做三方剪貼簿。候選窗位置只存截圖，不由腳本判定 |
| `cold-login` | 三次 GDM 自動登入各跑一次縮短的 cold-login 格式檢查並產生報告；`avatar-off` 與 `reduced-motion` 各登入一次 |
| `cold-login-full` | 同 `cold-login`，但使用 EX-05 的完整時長（暖機 300 秒、採樣 600 秒）；驗證的是完整流程能跑完，數字仍不是 EX-05 證據 |

## 注意

- VM 不得在參考機量測時執行：它會吃掉 CPU 與記憶體，汙染幀時與 PSS。`run.sh` 結束時一律關機；runner 只有一台，工作本來就逐一執行。
- 快照保留建立時的 DHCP 租約；租約在主機端過期後，`domifaddr` 的 lease 表查不到位址，`lib.sh` 因此改查 ARP 與 guest agent。
- 核心 uinput 鍵盤不是實體鍵盤，也沒有人觀察候選窗；`input-method` 通過只表示鏈路在登入工作階段中成立，EX-08 仍需實體鍵盤、操作員與錄影。
- 夾具以開發模式執行：只用終端夾具，不用 Firefox／Kate。三個參考應用改由 cold-login 檢查在真正的登入工作階段中開啟。
- 夾具與 VM 的已登入桌面可同時存在：`tests/g0/lib/session.sh` 為每次夾具指定獨立的 Core socket 與 `DITTO_DATA_DIR`，避免爭用登入桌面的資料庫鎖。Shell 夾具從本次建置的內建套件建立自己的 Profile。
- 佈建時若發現凍結前綴缺少系統函式庫，`provision.sh` 會失敗並列出缺少的項目；應補進 `packaging/reference-image/apt-packages.txt`，而不是只裝進 VM。
