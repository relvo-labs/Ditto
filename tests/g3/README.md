# G3 開發驗證

| 命令 | 檢查範圍 | 證據限制 |
| --- | --- | --- |
| `bash tests/g3/run.sh` | Rust 描述／完整性、Qt lint、固定模板 QtTest | 固定可信模板、明示測試資料；沒有生成管線或桌面驗收 |
| `python3 tests/g3/host/rejection.py` | 無 bus、未知命令、非法 deadline、私有 runner 拒絕 | 不執行超限程式 |
| `bash tools/dev-vm/run-g3.sh` | 還原閒置 VM、同步、建置、上述檢查及 OS 故障矩陣 | D-25 開發 VM；不登出目前的實體工作階段 |
| `DITTO_VM_SNAPSHOT=ditto-base DITTO_G3_EXPECT_OLD_ABI=1 bash tools/dev-vm/run-g3.sh` | 在 ABI <6 的舊核心驗證 partial／不執行 | 完整候選執行矩陣仍未執行 |
| `bash tests/g3/host/run.sh` | 實際 cgroup／Landlock／seccomp／失敗與清理 | VM 先跑；參考機出口時需另加真桌面 PID／revision |

OS driver 保存每個 probe 原始 JSON、stderr 與 summary 到 `artifacts/g3/`；VM runner 收集到 `artifacts/g3-vm/`。缺環境退出 2，不能算成全部通過。超限測試先讀回 512 MiB、1 CPU、64 tasks、零 swap 與 deadline，缺一不執行；只使用固定診斷程式。完整矩陣含十項：files、network、signals、spawn、spoof、memory、busy、timeout、orphan、cancel。

目前沒有真實模型生成、正式 artifact、五關管線、Core 啟用交易、資料 schema 回退、工作池第三項排隊或參考機出口證據。這些依 [plan/05](../../plan/05/README.md) 與 issue #19～#33 繼續追蹤，不以本套件取代。
