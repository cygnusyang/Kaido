# 缺陷登记

Sprint 2 回顾行动项 A6：自 Sprint 3 起登记缺陷，供回顾计算缺陷逃逸率。

## 规则

- 来源分三类：**开发自检**（编码时发现）、**测试**（单测/契约测试发现）、**验收 Demo**（演示或人工验收发现）。
- 缺陷逃逸率 = 验收 Demo 发现的缺陷数 ÷ 本 Sprint 总缺陷数。
- 编译失败、类型检查超时等构建期问题不登记为本表缺陷，记入回顾的工程问题。

## 登记表

| 编号 | 日期 | Sprint | 来源 | 描述 | 状态 |
|---|---|---|---|---|---|
| D-001 | 2026-10-18 | 3 | 开发自检 | ⌘F 在查找栏已打开时不再聚焦输入框（只处理了「打开」状态变化） | 已修复：加 `findFocusToken`，每次 ⌘F 递增触发聚焦 |
| D-002 | 2026-10-18 | 3 | 测试 | 首页演示数据未设项目时间线，排期从 1970 纪元起算：甘特显示 1970 年日期，验收 Demo §4 用「昨天」设置时限无法触发违例 | 已修复：`SeedData` 设 `projectStart`/`projectEnd`，`ProjectStore` 载入时应用；新增 `SeedDataTests` 与 `AppTests` 覆盖 |
| D-003 | 2026-10-18 | 3 | 开发自检 | 除演示项目外，未设项目时间线的项目（如新建空项目）仍从 1970 纪元起算排期，甘特显示 1970 年日期 | 已修复（2026-10-19 核销）：`ScheduleAnchor.derive` 按最早任务推导起点并标记 `projectStartDerived`；`ScheduleAnchorEngineTests` / `ScheduleAnchorTests` / `storeSeedsNoTasksByDefault` 覆盖；随 ADR-013 重设计交付 |
| D-004 | 2026-10-19 | 4 | 测试 | assignee 传纯空白（如 " "）会存为空格值而非清空；应 trim 后空则置 nil（上版 dev-reviewer LOW-3 顺延项） | 已修复（2026-10-20 核销）：`KairoSession.normalizedAssignee` 统一处理 addTask / 兼容 updateTask / patch `.set` 三条写路径；`TaskPatchTests` 三个用例覆盖；全量 `swift test` 354 个用例通过 |
| D-005 | 2026-10-20 | 5 | 测试 | 全量门禁偶发 `swiftpm-testing-helper` signal 13（SIGPIPE）：`captureStdout` 直接重定向进程 fd 1，并行用例捕获窗口重叠时后者继承前者管道写端，读端关闭后写入即崩溃，CI 发版会被中断 | 已修复（2026-10-20 核销）：文件级 `stdoutCaptureLock` 串行化 dup2→body→恢复→关闭全程（提交 e58c200）；修复后连续 10 次全量 413/43 通过、无 signal 13 |
| D-006 | 2026-10-20 | 5 | 验收 Demo | 计划 tab 大纲与甘特纵向错位：Outline 每行 28pt 后又渲染占布局空间的 `Divider`（实际节距 ≈29pt），而 Timeline 内容高/命中换算/任务条全部按 28pt 节距计算，偏移随行号线性累积（约第 28 行错开一整行），画布点击后左侧高亮「指错行」 | 已修复（2026-10-20 核销）：`OutlineTable.swift` 删除行间 Divider，改为 28pt 行内底部 overlay 自绘 1pt 分隔线（提交 fd3b248）；新增 `OutlineAlignmentTests` 离屏量测 40 行总高 == 40×28 回归断言（旧代码实测 1160 vs 期望 1120 先红后绿）；独立验证全量 AppTests 99/99、KairoCoreTests 234/234 通过。过程报告归档 `docs/archive/D-006-gantt-outline-misalignment/` |
