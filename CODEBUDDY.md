# Zeno 工程规则

## 跑测试：一律用隔离 scratch path

```bash
swift test --disable-sandbox --scratch-path /tmp/zeno-test-$(date +%H%M)
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

## 改「同名重复行」必须锚定上下文

`.github/workflows/ci.yml` 里第 60 行（macOS 作业）与第 128 行（Linux 作业）文本完全相同，都是 `        run: swift test`。

未锚定的 sed / 字符串替换会同时改掉两处，把 Linux 作业也接上看门狗（那里没有 sample，会失效）。

做法：
1. 替换时带上上下文锚点，例如定位 `- name: 测试` 所在的步骤，或整段多行匹配；
2. 改完用 `git diff --stat` 核对只有 1 行变化；出现 2 处就是改错了，先还原；
3. 不要只靠同一条通道的 stdout 判断改没改——本仓库出现过 exitCode=0 但 stdout 为空的情况，会让人误判「没改成」。验证一律用 `git diff` / `grep -n` 这类独立证据。

## 多 agent 共享 checkout：禁用 reset --soft 与批量暂存

多个 agent 共用一个工作目录时：

- **不要用 `git reset --soft`**：它会把别人未提交的改动一起卷进你的提交，也会把已提交的 commit 静默摘出分支（2026-10-29 因此丢过一次 `003aae3`，commit 对象还在但不在任何分支上，靠提交人自己记着才补回）。
- **`git commit --amend` 只用于「HEAD 就是我刚提交的那个」**：动手前 `git log --oneline -2` 确认父提交是预期值；期间若有别人往分支上加过提交，就不要 amend，改用追加提交——amend 会把对方那个提交一起改写掉，效果与 `reset --soft` 同源，只是入口不同。
- **已 push 的提交一律不 amend**：本地 amend 只是让旧对象悬空，推过之后再 amend 就必须 force-push；多 agent 共用的 checkout 上，force-push 会覆盖别人基于该提交做的工作。
- **不要用 `git add -A` / `git commit -a`**：一律按文件 `git add <path>`，提交前 `git status` 确认暂存清单只含自己的文件。
- **要撤销已提交的改动**：用新提交或 `git revert`；squash 只在最终合回 main 时做一次。
- **推送前**用 `git log --oneline main..HEAD` 对一遍提交清单，确认没有谁的提交被静默摘掉。
