# Kairo 工程规则

## 跑测试：一律用隔离 scratch path

```bash
swift test --disable-sandbox --scratch-path /tmp/kairo-test-$(date +%H%M)
```

**不要**直接跑 `swift test` 共享 `.build`。

**为什么**：`swiftpm-testing-helper` 是常驻子进程，一旦某个用例卡住（历史上出现过管道死锁：先 `waitUntilExit` 再读 `Pipe`，子进程写满 64KB 缓冲双方互等），它不会退出，并**持有 `.build` 锁**。此后所有人（包括并发 agent）的 `swift test` 都会无限排队，表现为「跑了两小时没结果」，实际一次都没开始。

**已发生的代价**：一个 helper 挂了 86 分钟，导致一个编码 agent 空等两个多小时、代码改完却以为在跑测试。

**并发时**：多个 agent 共用同一 checkout 时，除了隔离 scratch path，还要限定 `--filter` 到自己的测试；全量只在收口时跑一次。

## 提交前跑 i18n 门禁

```bash
bash tools/gate-i18n.sh
```

`swift test` **不覆盖**这项。历史上 `v1.2.0` 首发因此失败：一条 `assert` 里的中文文案被拦下——**开发者断言也不允许硬编码中文**，门禁不豁免 `assert`。

## 子进程管道：先读后等，不读就别建

- 读了要 `readDataToEndOfFile()` **再** `waitUntilExit()`
- 不读的话设 `FileHandle.nullDevice`，不要建 `Pipe`

否则子进程输出超过 64KB 缓冲即死锁。
