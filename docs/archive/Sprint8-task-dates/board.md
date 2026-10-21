# Sprint 8 任务板（v0.5.0 · 任务起止日期可自定义）—— 已收口

> 2026-10-21 · lead 维护。**协作机制缺口（如实记录）**：本会话共享任务工具在子智能体沙箱内不可用（`TaskGet/TaskUpdate/TaskList` 报 not defined，任务板条目丢失/被重建），故以本文件为权威状态源；成员按聊天消息回报，lead 逐项核对代码与测试证据。

| ID | 任务 | Owner | 状态 | 证据 |
|---|---|---|---|---|
| S8-SCOPE | 范围与三条决策（用户确认） | lead | done | scope.md（含 E1=C 补充裁定） |
| S8-DESIGN | 方案设计 + 规格回写 | dev-architect | done | design.md（§9 裁定、§9.2 审查裁定）；ui-redesign §6.1；features/02 F-22-04 |
| S8-ENGINE | 引擎消费 startDate（D-021）+ DST 日历日算术 | dev-coder-engine / -2 | done | 0d30589 · c07d6e2 · 210d4f9；ScheduleStartDateBoundTests 10 例、ScheduleDaylightSavingTests 5 例 |
| S8-CORE | 动作层 + 日期工具 + 陈旧起点校验/归一 | dev-coder-core / -2 | done | 03d1c9b · 0f2c139；ScheduleDateMathTests 22、CalendarGridTests 22、Sprint8TaskDateActionTests 18 |
| S8-UI | 检查器日期字段 + 日历弹层 + 审查项修复 | dev-coder-ui | done | 6e9eadf · e289e7b；Sprint8DateFieldRenderTests 11 |
| S8-AC | 验收判据 AC-S8-01…23 + 验收用例 20 条 | dev-tester | done | acceptance.md（回填实跑结果）；Sprint8DateAcceptanceTests 20 |
| S8-REVIEW | 发版前审查 | dev-reviewer | done（3 HIGH 已修复复跑） | docs/reviews/Sprint8-task-dates-review.md：0 C / 3 H / 8 M / 6 L |
| S8-GATE | 全量回归 + 缺陷登记/核销 | dev-tester + lead | done | 669 / 69 suites 全绿；gate-core/gate-ui/release 构建通过；logs/gate-*.log |
| S8-RELEASE | CHANGELOG / 版本号 / roadmap / 缺陷统计 | lead | done | CHANGELOG v0.5.0；tools/build.sh + CommandRegistry 0.5.0；roadmap §5；defects D-021 核销 + D-022…024 顺延 |

## 分支与合并

- 基线：`fb8e75e`（tag v0.4.0）→ 功能分支 `feature/task-date-editing`
- coder worktree：`Kairo-wt-engine`(s8/engine) · `Kairo-wt-core`(s8/core) · `Kairo-wt-ui`(s8/ui) · `Kairo-wt-test`(s8/test)
- 合并顺序：engine → core → ui → test，均在 `feature/task-date-editing` 上 --no-ff 合并；**未合 main、未 push**（main 落后 41 个提交，含 v0.2–v0.4 未合入，需用户批准后另行处理）。

## 缺陷

- **D-021**（高/高）v0.4.0 startDate 不驱动排期 → 本版核销（0d30589 + c07d6e2），核销测试 5 条。
- **D-022 / D-023 / D-024**（中/中/低）→ 顺延 v0.5.1，均非阻断，处置已写入 defects.md。
