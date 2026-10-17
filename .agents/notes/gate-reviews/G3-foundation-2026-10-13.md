# G3 獨立基礎設施歷史快照｜2026-10-13

此檔保留 D-46 前、`27abec9` 時的事實；目前整合與出口狀態見 [G3-exit](G3-exit.md)，本歷史快照不代表目前缺口。

| 欄位 | 內容 |
| --- | --- |
| 日期／狀態 | 2026-10-13；**未評審，G3 尚未完成** |
| 計畫／追蹤 | [plan/05](../../../plan/05/README.md)；[#34](https://github.com/relvo-labs/Ditto/issues/34)，#15～#33 已逐項閱讀 |
| 分支／版本 | `codex/g3-restricted-generation`；計畫 `b42c932`，獨立實作 `d77b4e7566fd86c7983e476ce906462220f4298b` |
| G2 基底 | `a88bce89b8976d546497345777c642d9f2b7de59`；依 D-45 保留 G2 Core／Store／協定／confine／Agent／Shell／schema 原樣 |
| 評審者 | owner；本檔只整理事實，不裁定出口 |

## 1. 五項出口逐項

| 原出口門檻 | 狀態 | 已有證據／仍缺什麼 |
| --- | --- | --- |
| AT-06：生成待辦摘要與快捷動作面板，有新產物、驗證與預覽，可啟用並繼續修改。 | **未執行** | SDK 只有可檢視描述與固定 QML；沒有正式 artifact、真實模型生成、獨立預覽、啟用或再次修改 |
| AT-07：無效 QML／逾時／非法 imports 不進主 Shell；顯示失敗且桌面可用。 | **未執行** | 描述拒絕程式碼、宿主逾時有開發證據；未有五關管線、產品失敗卡片、真桌面同 PID／revision 證據 |
| AT-18：三類固定上游能力運行，功能、來源、相容性與修改均可追溯。 | **待 G2 評審與 G3 彙整** | 來源盤點沿用 [harness-g2-port](../../../docs/upstream/harness-g2-port.md)；本批未新增外部源碼移植，沒有重跑三類完整矩陣 |
| AT-22：新插件資料 schema 升級後回退，依快照／相容政策回復。 | **未執行** | 政策提案見 plan/05/03；沒有 Core 資料遷移與舊版實際讀取 |
| 生成插件在隔離宿主中受檔案／網路／程序與時間邊界限制；無法執行時降為可檢視候選。 | **部分開發證據，未驗收** | 固定診斷政策十項 VM 檢查通過、舊 ABI／無 bus 拒絕；尚未承載生成候選、禁止任意 exec 的生產政策、正式 Core／UI 回報或參考機出口 |

AT-26／29 也尚未驗收：本批證明固定 probe 的 OS 邊界與清理，未證明生成工作池第三項排隊、取消狀態持久化、未信任套件三種執行入口及真桌面存活。`diagnostic-v1:full` 不可當成生成候選可啟用。

## 2. 實作與 issue 狀態

| issue | 本批結果 | 後續 |
| --- | --- | --- |
| #15 | plan/05 與 D-45 已獨立文件提交 | 文件可獨立審查；沒有送出 PR 或裁定 G2 交接 |
| #16／17／18 | 獨立 systemd service、實際 cgroup／deadline 回讀、私有 confine handshake、分項 full／partial／unavailable、OOM／取消／整組清理 | 正式候選 runner、Core／UI 接線、參考機與桌面同 PID 證據 |
| #22 | 有界描述 SDK、兩個固定 QML 模板、內容雜湊、拒絕 raw code／未知欄位、QtTest | 正式產物格式、能力代理／ProviderHost 接線；D-17 仍未核定 |
| #19／20／21 | 計畫與所有權／契約／遷移政策提案 | G2 參考機量測完成後才修改 Core／Store／wire |
| #23 | 診斷政策加非 Unix socket seccomp；imports／raw code 不在描述格式中 | 生產檔案／網路／程序白名單、能力代理與整合負例 |
| #24／25／26／27／28 | 未實作 | 五關、真預覽、啟用回復、持久三輪修復、新版本／回退、真實模型兩類產物 |
| #29 | 現有來源與取用方式已盤點 | 九欄／四欄矩陣與三類實際運行證據彙整 |
| #30／31／32 | 固定診斷的失敗／超限／拒絕路徑有開發證據 | 真正候選／工作池／UI／桌面與參考機驗收 |
| #33 | 本檔建立，五出口與 G4 交接有明確缺口 | 全部必要證據到齊後由 owner 評審 |

## 3. 開發驗證紀錄

原始 artifacts 保存在本 checkout 的 `artifacts/`（gitignored）；本檔保留版本、方法、數字與路徑摘要。沒有原始檔的 checkout 可依 `tests/g3/README.md` 重跑；不能把摘要當作另一台機器的量測。

### 3.1 乾淨 commit 的開發 VM

執行 `bash tools/dev-vm/run-g3.sh`，run [2026-10-13T13-45-28Z-d77b4e7](../../../artifacts/g3-vm/2026-10-13T13-45-28Z-d77b4e7/summary.jsonl)。快照 `ditto-g2`，核心 `7.0.0-38-generic`，Landlock ABI 8；`development-vm`、git `dirty:false`。fixture 只是固定診斷程式，沒有模型。建置／九個 Rust 單元測試／QML lint／QtTest（3 個行為測試＋init／cleanup 共 5 項）／拒絕路徑／OS 矩陣全部通過。

OS 原始資料：[host-2026-10-13T13-45-41Z-3114](../../../artifacts/g3-vm/2026-10-13T13-45-28Z-d77b4e7/suite-records/host-2026-10-13T13-45-41Z-3114/summary.json)。scope 外見證程序 PID 3114（測試 driver，不是 Core／Shell）。每個候選的 cgroup 都在 `/user.slice/user-1000.slice/user@1000.service/app.slice/ditto-generated-test-<隨機值>.service`；逐次 JSON 保存完整對應，回讀 `memory.max=536870912`、`memory.swap.max=0`、`cpu.max="100000 100000"`、`pids.max=64`，service deadline 3000 ms（取消案例 10000 ms）。

| 診斷 | 實際結果 | 本次耗時（不是效能門檻量測） |
| --- | --- | --- |
| files | 越界讀／寫、symlink／hardlink 拒絕；工作區內讀寫成功 | 109 ms |
| network | TCP／UDP／IPv6／netlink／Unix datagram 與未授權 named endpoint 拒絕 | 104 ms |
| signals | scope 外見證程序 signal 0 被拒，見證持續存活 | 108 ms |
| spawn | 59 個子程序後 fork 被拒（64 tasks 含 runner／helper／執行緒）；全部回收 | 109 ms |
| spoof | stdout 的偽造 `generated-v1/full` 只留在不可信診斷文字，沒有改變政策／啟用資格 | 見原始 JSON |
| memory | 512 MiB 硬上限觸發 `oom-kill`，候選 service 清空 | 188 ms |
| busy／timeout | service 結果 `timeout`，程序被終止 | 3083／3087 ms |
| orphan | 子程序確認 `setsid` 成功後仍由整個 cgroup deadline 清理 | 3310 ms |
| cancel | SIGTERM 到控制器後整個候選 service 清理，結果 `cancelled` | 啟動起 1024 ms（測試在 1 秒時取消，非取消延遲指標） |

十項全部確認 `cleanup_complete:true`，`candidate_activation_available:false`；`diagnostic-v1` 的實際四種邊界成立。CPU 只回讀實際 quota 並驗證忙碌工作逾時，沒有量測 CPU／wall 比或資源穩態 PSS。

### 3.2 舊核心的真實 partial 拒絕

執行 `DITTO_VM_SNAPSHOT=ditto-base DITTO_G3_EXPECT_OLD_ABI=1 bash tools/dev-vm/run-g3.sh`，run [2026-10-13T13-45-56Z-d77b4e7](../../../artifacts/g3-vm/2026-10-13T13-45-56Z-d77b4e7/summary.jsonl)。舊 6.8 核心實測 ABI 4；描述與固定模板檢查仍通過，隔離回報 `partial`、`landlock_abi_below_6`，`completion:null`、`candidate_activation_available:false`、cgroup 已清空。拒絕案例通過，完整候選執行矩陣標 `not_run`，整體 runner 退出 2，沒有假裝執行成功。

兩個快照也驗證不存在的 bus → `unavailable`、沒有執行 probe；未知 probe、越界 deadline 與直接誤用私有 runner 均被拒。沒有對舊核心退回普通 shell 執行。

### 3.3 開發機回歸

- `cargo test --locked --workspace`：233 項通過、0 失敗；這是程式碼回歸，不取代真實桌面驗收。
- `cargo clippy --locked -p ditto-test-host -p ditto-generation --all-targets -- -D warnings`、format、diff check 通過。
- Rust schema export `--check` 與 `pnpm --filter @ditto/protocol check:generated` 通過；既有 G2 Core／Store／協定／confine／packages／Shell／schema 相對 `a88bce8` 無差異。
- `lint-skills --check`：0 error、1 個既有 AGENTS.md 長度警訊；新增 G3 workflow，**GitHub runner 尚未執行**。

## 4. 發現與限制

1. G2 connect broker 不涵蓋未連線 UDP 的 sendto；G3 診斷政策額外禁止建立非 Unix socket，G2 後端原樣保留。不能因為 G2 有 `confined:true` 就把它稱為完整生成隔離。
2. 呼叫端的 private `/tmp` 可能不被 systemd user manager 看見；診斷工作區改用 checkout 內隔離的 artifacts 目錄，且只清自己建立的目錄。
3. 固定模板已按現有 Task 的 `text/done` 欄位驗證；沒有另外創造一份持久資料模型。文字不插值為 QML，未有資料／授權時明示不可用。
4. `ditto-generation-safety` 維持 draft：生產候選政策、完整驗證、能力代理與啟用／回復尚未落地。所有五項出口保持未驗收。

## 5. G4 交接與下一個閘門

先完成 G2 參考機量測，再依當時基底落地 #20→#19／21，接 #23→#24→#25／26→#27→#28；關鍵路徑與工作分解見 plan/05/05。沒有用 G3 commit 回填 G2 證據。

G4 待接：G3 五出口與 AT-26／29 的參考機結果、完整安裝／發行與授權清單、名稱／角色素材權利、四態三次冷登入 PSS、原生首幀／幀時、雙螢幕、基本桌面與 D-38 未完項。VM Agent 暖態超過 150 MiB 的 G2 警訊仍有效；沒有放寬門檻或核定 D-44 hard limit。64 人週維持規劃提案，正式排程依剩餘工作及 owner 人力決策更新。
