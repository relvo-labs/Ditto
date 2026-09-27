# D-32 hostd 的候選策略（策略 A／B）

| 欄位 | 內容 |
| --- | --- |
| 決策日期 | 2026-09-27（判準寫入）；試作結果見「依據」 |
| 狀態 | **提案**，待 Host 核定；核定前 hostd 預設採策略 A（plan/03/03 §4.2 第 1 條） |
| 決策者 | Host |
| 關聯 | [plan/03/03 §4.2](../../../plan/03/03-host-and-cordis.md#42-候選策略d-32)、[docs/contracts/host-protocol.md §4.1](../../../docs/contracts/host-protocol.md#41-候選策略d-32)、D-37 |

## 問題

Cordis 的 isolate realm 內的服務對主 realm 不可見，也沒有「把 isolate 實例升格到主 realm」的操作（plan/03/03 §4.2、F-4）。所以候選與現役並存、commit 時交棒，只有兩條路：

- **策略 A `isolate_rebuild`**：prepare 在 isolate 子 realm 掛載候選並跑健康檢查，現役不動；commit 時舊實例交接並 dispose、候選 dispose、在主 realm 以相同設定重建、第二次健康檢查。
- **策略 B `in_place`**：prepare 只做靜態檢查；commit 時舊實例交接並 dispose，在主 realm 掛載新實例，再健康檢查。失敗靠重掛舊實例回復，中間有服務空窗。

## 預先承諾的判準

以下判準在試作**之前**寫入（2026-09-27），抄自 plan/03/03 §4.2，**試作後不得調整**：

1. 預設採用策略 A。
2. 策略 A 須同時滿足：
   - ① L-03、L-04、L-08 以策略 A 通過（正例與故障注入負例都要通過，plan/03/06 §3）；
   - ② Cordis 服務插件替換的 `prepared`→`committed` p95 ≤2 秒（100 次，參考機或開發 VM 先估）；
   - ③ 100 次無故障注入的替換中，「候選健康而重建後不健康」的次數為 0。
3. 任一條不成立 → 採用策略 B，並在 `docs/contracts/host-protocol.md` 與使用者可見的結果中如實說明服務空窗；**不得**把策略 B 的空窗描述成即時替換。
4. 兩個策略不混用：同一版本的 hostd 只有一種交易語意。

量測定義（同樣在試作前固定）：

- 「`prepared`→`committed`」在 hostd 端量：`participant.commit` 收到請求到回應送出的時間（`TransactionLayer` 的 `commitMs`）。這是 hostd 的份額，不含 Core 的狀態寫入與 readback；Core 端的 NFR-04 量測（Core 寫入 `operations` 的時間戳）另由 G1-QA-06 在參考機做，**不以本數字代替**。
- 「Cordis 服務插件替換」：一個提供 Cordis 服務並註冊一項能力的插件，以新版本（不同設定）替換，有一個 inject 它的消費者；每次替換都走 prepare → commit。
- 「候選健康而重建後不健康」：`TransactionLayer.stats.candidateHealthyRebuildUnhealthy`，即候選通過健康檢查、但 commit 時主 realm 重建的實例未通過 settle／健康檢查／註冊的次數。

## 依據

以下全部是**開發證據**：2026-09-27 在開發機（AMD Ryzen 9 7945HX、Node 22.23.2）上，以 `createTestHost()` 的程序內假 Core，或以打包後的 hostd 測試建置（`dist/ditto-hostd-fault.mjs`）經 Unix socket 接假 Core 量得。**不是參考機出口證據**，也不代替 G1-QA-06 在參考機以 Core 時間戳量的 NFR-04。原始數字在 `artifacts/g1-dev/`（不進版控）：`d32-trial-*.json`、`d32-trial-process-*.json`、`lifecycle-isolate_rebuild.json`、`lifecycle-in_place.json`。重跑：`DITTO_D32_TRIAL=1 pnpm --filter @ditto/host-runtime exec vitest run tests/trial`。

| 判準 | 策略 A 的結果 | 成立？ |
| --- | --- | --- |
| ① L-03、L-04、L-08 以策略 A 通過（含負例） | `packages/host-runtime/tests/lifecycle/` 13 項全數通過（L-01 2、L-02 3、L-03 2、L-04 2、L-08 4），同批 unit／pinning 合計 65 項通過、0 項失敗 | 成立 |
| ② 服務插件替換 `prepared`→`committed` p95 ≤2 秒，100 次 | 程序內（服務提供者＋消費者）：p50 0.82 ms、p95 1.52 ms、最大 2.10 ms。真 hostd 程序經 socket、以 fake Core 送出 `participant.commit` 到收到回應計：夾具插件 p95 1.22 ms；`ditto.svc.tasks`（檔案授予、fs.watch、資料區、受控交接）p50 1.21 ms、p95 1.68 ms、最大 2.11 ms。同日三次重跑的 p95 落在 1.27～1.52 ms（程序內）與 1.60～1.75 ms（tasks）之間，本格取最後一次的數字 | 成立（差三個數量級；夾具插件沒有真實 I/O，參考機數字必須另量） |
| ③ 100 次無故障替換中「候選健康而重建後不健康」為 0 | 程序內 100 次：0 次；程序層級 200 次（夾具與 tasks 各 100）：commit 失敗 0 次、回讀不符 0 次 | 成立 |

同一批測試以策略 B 也全部通過，p95 相近（程序內 0.92 ms；tasks 1.58 ms）。這**不是**選 B 的理由：判準是「A 不成立才換 B」。另外兩點試作中才看清楚、判準沒有涵蓋的事實，如實記下：

- **策略 A 在 commit 時也有服務空窗。** 舊實例 dispose 之後、主 realm 重建實例通過健康檢查之前，該能力沒有租約。量到的空窗（交易層內部計時 `timings().gaps`，不在協定回應中：Rust 的 `ItemReport` 不接受多餘欄位）程序內 p50 0.72 ms、p95 1.17 ms。A 與 B 的差別在於「大多數失敗在 prepare 就被擋下、現役不受影響」，不是「沒有空窗」。建議契約 owner 在 host-protocol.md §4.1 的 A 列也寫出這個空窗（本工作流未改契約文件）。
- **策略 A 下，清理永不完成的插件無法啟用。** commit 必須先 dispose 候選；候選的清理逾時 → 該 entry 以 `candidate_cleanup_timeout` 失敗並標為故障，現役（若有）不受影響。策略 B 下同一個插件可以啟用，但之後永遠無法被替換或移除。L-08 的負例兩種情況都測了。
- 策略 B 的 L-03 負例是空的：B 在 commit 前不掛載任何東西，沒有「候選」可以強行取得資源。

**依預先承諾的判準，選擇策略 A（`isolate_rebuild`）。** 核定前 hostd 預設即為 A；`in_place` 的程式碼只在測試建置可經 `DITTO_HOST_STRATEGY` 選用（試作用），正式建置無此開關。

## 考慮過但沒選的方案

- **兩個策略都保留，依插件選擇**：違反判準第 4 條；測試矩陣倍增，而且使用者看到的「替換」會有兩種可靠性等級。
- **修改 vendored Cordis，加上 isolate 升格**：會新增一項 Ditto 修改集，而且要改 `ReflectService` 的服務儲存語意；每次同步上游都要重新套用。`ditto-upstream-port` 要求先證明薄轉接不行，這裡沒有這個證明。

## 影響

- `host.hello.strategy` 回報 `isolate_rebuild`；host-protocol.md §4.1 維持 A 為預設。建議補上「A 在 commit 時也有短暫空窗」與「清理永不完成的插件在 A 下無法啟用」兩句，由契約 owner 決定。
- 核定後：刪除 `in_place` 或保留為測試夾具，由 Host 決定；無論哪一種，正式建置都只有一種交易語意（判準第 4 條）。
- 參考機上的 NFR-04（Cordis 服務替換 30 次，Core 時間戳）仍須在 G1-QA-06 量測，本紀錄的開發數字不得寫進出口證據。
- 核定時回寫 `milestones/01/05 §2` 的 D-32 列（本工作流不改 `milestones/`）。
