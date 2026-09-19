# dittoctl

G0 的診斷 CLI，也是每項能力的第二個消費者——有它，契約才能在沒有圖形環境的情況下測試。

```sh
dittoctl probe handshake                     # 協商結果與目錄 revision
dittoctl probe capabilities                  # 能力目錄，含 availability 與 claimable
dittoctl probe outputs
dittoctl probe workspaces [--activate ID | --get ID]
dittoctl probe windows [--json]
dittoctl probe window <id> [--focus | --move X Y | --resize W H | --state STATE | --close]
dittoctl probe events --for 10s
```

寫操作一律自動回讀並印出比對結果；`--json` 的輸出是 [視窗能力矩陣](../../tests/g0/window-matrix/run.sh) 的資料來源。

token 來自受控啟動器留下的描述子（`DITTO_CORE_TOKEN_FD`）；開發模式才讀 `DITTO_DEV_TOKEN`。

**這不是救援 CLI**：它需要 Core 在跑，而救援模式（REC-03、AT-23）是 G1-PLAT-03／04 的交付物。
