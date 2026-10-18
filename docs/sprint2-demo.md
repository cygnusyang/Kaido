# Sprint 2 验收 Demo——排期计算与状态回写闭环

> 日期：2026-10-18 · 执行环境：macOS（本地时区 UTC+8，日期渲染以本地午夜为锚，ISO 输出为 UTC 时刻）
> 对应 Roadmap：Sprint 2「调度引擎 + 状态回写闭环」（[03-roadmap.md](03-roadmap.md)）
> 验收口径：全程无人点界面，Claude Code 经 MCP 与 CLI 各复现一次「建 WBS → 排期 → 违例 → 回写 → 群组聚合」。

## 1. 目标

验证 Sprint 2 交付物在真实执行中的行为：

- 调度引擎纯函数（US-E2-01/02）：FS/FF/SS/SF 相关性传播 + 时限 + ASAP/ALAP；
- 违例引擎基础集（US-E2-05）：环、时限冲突、超项目范围；
- 重要路径与宽延（US-E2-03）；
- 状态回写与群组完成度聚合（US-E3-01/02）；
- 资源模型与投入换算（US-E1-05）。

## 2. MCP 管道

经 `kairo-mcp`（stdio JSON-RPC）逐请求调用，工具清单含 Sprint 2 新增
`schedule_compute` / `schedule_critical_path` / `violations_list` / `status_update`。

### 2.1 建 WBS（含一条故意时限冲突）

```json
project_create  {"title":"演示项目"}
task_add        {"title":"Sprint2交付群组","kind":"group"}
task_add        {"title":"规格评审","parentID":"<群组>","durationDays":2}
task_add        {"title":"实现","parentID":"<群组>","durationDays":3}
task_add        {"title":"验收","parentID":"<群组>","durationDays":1}
task_add        {"title":"发布准备","durationDays":2}
task_add        {"title":"发布截止","durationDays":2,"constraint":"startNoLaterThan:2026-11-10T00:00:00Z"}
```

`发布截止` 被故意设为「开始不晚于 2026-11-10」且持续 2 天，而项目结束 2026-11-08
——时限窗口容不下任务持续时间，构成一条预期违例。

### 2.2 排期计算

```
schedule_compute  {"projectStart":"2026-11-02T00:00:00Z","projectEnd":"2026-11-08T00:00:00Z"}
```

执行摘录（日期为 UTC 时刻，本地时区 UTC+8 午夜即当日 16:00Z）：

```
9911EA14  2026-11-01T16:00:00Z → 2026-11-02T16:00:00Z（1 天）
E0F94B29  2026-11-01T16:00:00Z → 2026-11-03T16:00:00Z（2 天）规格评审
359050BE  2026-11-01T16:00:00Z → 2026-11-04T16:00:00Z（3 天）实现
9125A2E8  2026-11-01T16:00:00Z → 2026-11-02T16:00:00Z（1 天）验收
687EDB34  2026-11-01T16:00:00Z → 2026-11-03T16:00:00Z（2 天）发布准备
6E44FF2D  2026-11-01T16:00:00Z → 2026-11-03T16:00:00Z（2 天）发布截止
```

### 2.3 违例列表

```
violations_list  {}
```

执行摘录——`发布截止` 的时限窗口冲突被报告：

```
[error] constraint_is_dependency：任务「发布截止」的「开始不晚于」时限与相关性链冲突：窗口无法容纳任务持续时间
```

### 2.4 逐任务回写与群组聚合

```
status_update  {"taskID":"<规格评审>","status":"done"}
status_update  {"taskID":"<实现>","status":"done"}
status_update  {"taskID":"<验收>","status":"done"}
status_update  {"taskID":"<发布截止>","status":"done"}
status_update  {"taskID":"<发布准备>","progress":0.5}
```

执行摘录（规格评审/实现/验收/发布截止均记录完成时间）：

```
规格评审: status=done progress=1 completedAt=有
实现:     status=done progress=1 completedAt=有
验收:     status=done progress=1 completedAt=有
发布截止: status=done progress=1 completedAt=有
```

群组完成度聚合（只读查询群组）：

```
status_update  {"taskID":"<群组>"}
群组聚合 groupProgress=1
```

规格评审/实现/验收全部完成 → 群组完成度 100%，符合 US-E3-02 的投入加权聚合。

## 3. CLI 复现同一序列

`kairo` 命令逐条执行，行为与 MCP 对等（US-E5-02）。

### 3.1 建 WBS（CLI 用 `--dep` 建立 FS 链，时限冲突同款）

```bash
kairo project create 演示项目 --file demo.kairo
kairo task add Sprint2交付群组 --kind group --file demo.kairo
kairo task add 规格评审 --parent <群组> --duration 2 --file demo.kairo
kairo task add 实现 --parent <群组> --duration 3 --dep <规格评审>:fs --file demo.kairo
kairo task add 验收 --parent <群组> --duration 1 --dep <实现>:fs --file demo.kairo
kairo task add 发布准备 --duration 2 --file demo.kairo
kairo task add 发布截止 --duration 1 --dep <实现>:fs \
  --constraint startNoLaterThan:2026-11-04T00:00:00Z --file demo.kairo
```

### 3.2 排期、违例与重要路径

```bash
kairo schedule compute --start 2026-11-02T00:00:00Z --end 2026-11-13T00:00:00Z --file demo.kairo
kairo violations --file demo.kairo
kairo schedule path --file demo.kairo
```

执行摘录：

```
== 排期计算 ==
已计算排期：6 个任务
  CA261717 规格评审  2026-11-01T16:00:00Z → 2026-11-03T16:00:00Z（2 天，ASAP）
  EA94A18D 实现      2026-11-03T16:00:00Z → 2026-11-06T16:00:00Z（3 天，ASAP）
  B656CFA9 发布截止  2026-11-06T16:00:00Z → 2026-11-07T16:00:00Z（1 天，ASAP）

== 违例列表 ==
违例：1 条
  [错误] constraint_is_dependency：任务「发布截止」的「开始不晚于」时限与相关性链冲突：窗口无法容纳任务持续时间

== 重要路径 ==
重要路径：4 个任务（宽延限制 0 天）
  规格评审 *  总宽延 0 天 / 自由宽延 0 天
  实现     *  总宽延 0 天 / 自由宽延 0 天
  验收     *  总宽延 0 天 / 自由宽延 0 天
  发布截止 *  总宽延 0 天 / 自由宽延 0 天
```

重要路径覆盖规格评审 → 实现 → 验收 → 发布截止链路，均总宽延 0；并行任务有正宽延。

### 3.3 状态回写与群组聚合

```bash
kairo status update <规格评审> --status done --file demo.kairo
kairo status update <实现> --status done --file demo.kairo
kairo status update <验收> --status done --file demo.kairo
kairo status update <发布截止> --status done --file demo.kairo
kairo status update <发布准备> --progress 0.5 --file demo.kairo
kairo status update <群组> --file demo.kairo   # 只读查询聚合
```

执行摘录：

```
已回写：CA261717 规格评审（已完成，进度 100%）  完成度聚合：100%
已回写：EA94A18D 实现（已完成，进度 100%）    完成度聚合：100%
已回写：F8BABE8F 发布准备（待办，进度 50%）   完成度聚合：50%
已回写：2B2873C0 Sprint2交付群组（待办，进度 0%）完成度聚合：100%
```

### 3.4 资源

```bash
kairo resource add 李工 --type person --units 1 --efficiency 0.9 --file demo.kairo
kairo resource list --file demo.kairo
```

执行摘录：

```
已添加资源：A4024DF5 李工（人员，单位 1，效率 0.9）
A4024DF5 李工（人员，单位 1，效率 0.9）
```

## 4. 观察与说明

- **日期渲染**：引擎以自然日（24h）为最小单位（工作周日历属 US-E2-04，本 Sprint 不做）；
  本机时区 UTC+8 使 ISO 输出显示为当日 16:00Z。跨时区一致性依赖日历参数，属已知口径。
- **违例语义**：单侧时限（开始/结束不早于/不晚于）与相关性链窗口冲突归
  `constraint_is_dependency`；任务同时带开始与结束时限且窗口小于持续时间时归
  `constraint_window_too_narrow`（F-30-03）。本演示为单侧时限场景。
- **群组聚合**：按后代叶子任务的投入加权（无投入叶子按 1 计），群组容器自身不产生投入。
- **零第三方依赖**：全程 `swift build` / `swift test` 与 `tools/gate-core.sh` 通过，
  KairoCore 无 AppKit/SwiftUI/Cocoa import。
