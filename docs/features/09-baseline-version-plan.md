# 09 大版本规划：实际时间 → 基线 → 偏差（v0.12 → v0.15）

> 状态：规划稿（dev-architect）· 2026-10-25 · 上游：[07-actual-dates.md](07-actual-dates.md)、[08-baselines.md](08-baselines.md)
> 当前版本：v0.11.0（CHANGELOG）。本规划共 4 个可独立发版的 MINOR 版本，每版都带用户可见价值，可单独回滚。

## 0. 总览

| 版本 | 主题 | 用户可见价值 | 依赖 | 主要风险 |
| --- | --- | --- | --- | --- |
| v0.12.0 | 实际开始 / 实际结束（落实 07） | 任务能看到「真的什么时候开工、什么时候完的」，并自动记录 | 无 | TaskItem 扩字段引发既有相等断言批量红 |
| v0.13.0 | 基线快照 + 偏差数值（含 `.kairo` 格式升 v2） | 拍一次基线，大纲/检查器直接看到「比承诺晚几天」 | v0.12 | 格式升版不可逆：旧版本从此打不开新文件 |
| v0.14.0 | 基线可视化 + 项目摘要 | 甘特上灰条 vs 计划条一眼对照，项目级偏差一屏看完 | v0.13 | 碰 A7 黄金基线布局 |
| v0.15.0 | 基线与偏差报表化 | 多基线管理、孤儿可查、偏差导出 CSV | v0.14 | 报表口径与对等性 |

分层纪律（贯穿四版）：baseline（冻结）/ plan（引擎 `scheduledStart/Finish`，预测）/ actual（`actualStart` + `completedAt`，事实）三层互不回写；
基线绝不回流 `ScheduleEngine`，实际时间也绝不参与排期与违例判定。

## 1. v0.12.0 · 实际开始 / 实际结束

**目标**：把 07 的契约实现出来，作为整个大版本的**事实层地基**。没有它，基线偏差只能算「计划 vs 计划」。

**范围**

- Core：`TaskItem.actualStart`（`completedAt` 复用为实际结束）、`KairoErrorCode.actualDateOrderInvalid`。
- Commands：`applyStatus` 自动记录（首次进 in_progress / progress > 0，仅 `nil` 时写，回退不清）、`setActualStart` / `setActualFinish`、`statusUpdate(now:)`。
- Presentation：`PlanRow.actualStart/actualFinish`、`TaskInspector.actualStart`、大纲可选列 2 个、`OutlineColumnPreferences.optional` + `shownOptional`、ViewState `visibleOptionalColumns`、2 个新动作。
- App：检查器「实际」分区（2 个 `DateFieldRow`）、大纲只读日期列、列显隐菜单。
- CLI：`task get` 两行输出。MCP：零改动（Codable 直出）。

**文件范围**：见 07 §11。

**并行分组**

- 波次 1：A（TaskItem + KairoErrorCode + core 用例）
- 波次 2：B（KairoSession）∥ C（Presentation）∥ D（CLI）——文件两两不重叠
- 波次 3：E（Apps：Store / WorkspaceView / OutlineTable / Display / InspectorView / xcstrings）

**判据要点**：07 §9 全 14 条；重点四条——回退不清 `actualStart`、pending → done 直跳不补、一次编辑一步撤销、群组两字段为 `nil`。

**风险与缓解**：`TaskItem` 加字段会让「整体相等断言」的既有用例批量变红（预期 ≤ 20 处机械修）；自动记录引入墙钟 → 所有断言走 `now:` 注入，禁止读 `Date()`。

**非目标**：实际时间进排期/违例/报表；计时器；CLI/MCP 写实际时间。

## 2. v0.13.0 · 基线快照与偏差数值

**目标**：落实 08 的数据模型、偏差公式与存储；产出「看得见的数字」。

**范围**

- Core：`Baseline` / `BaselineEntry`、`BaselineEngine`（纯函数偏差）、`CalendarDayMath`（日算术上移，`ScheduleDateMath` 转发）。
- Storage：`KairoFile.currentFormatVersion = 2` + `BaselineFormatV2Migration`（纯加法的迁移步骤）+ `baselines` 键（有基线才写）；v1 文件内存迁移、打开不落盘、首次保存才升版（08 §7）。同版更新 `02-architecture` 格式契约、错误文案与发版说明。
- Commands：`createBaseline / renameBaseline / deleteBaseline / baselines / baselineVariance`（偏差报告带 `baselineID/name/createdAt`）。
- Presentation：大纲 4 列（baselineStart / baselineFinish / startVariance / finishVariance，列头标「计划偏差」）、`BaselineSection`、检查器基线段（含实际偏差与逾期天数）、`setBaseline` 动作、ViewState `selectedBaselineID`（视图状态，不进撤销栈）。
- CLI：`baseline list|create|delete|variance` + `task get` 基线段。
- MCP：`baseline_create / baseline_list / baseline_delete / baseline_variance`。

**并行分组**

- 波次 1：A（core：模型 + 引擎 + 文件 + 用例）
- 波次 2：B（Commands）∥ C（Presentation）
- 波次 3：D（CLI）∥ E（MCP）∥ F（App）

**判据要点**：08 §9 全 12 条（含 §7.6 的六条迁移/兼容用例）；另加两条门禁——① 5,000 任务 × 3 基线的读写实测记入 CHANGELOG（体积闸门）；② CLI/MCP 与 `BaselineEngine` 数值逐字段一致。

**风险与缓解**：格式升 2 是**本规划唯一的不可逆动作**（已由用户裁定），落地时必须同版改齐四处——`FormatMigrationPlan`、`02-architecture` 格式契约、错误文案（「此文件由更新版本保存，请升级」）、CHANGELOG 与发版说明；偏差口径若日后改符号约定会污染已导出报表 → 先把 `TaskVariance` 字段名与符号写进 CHANGELOG 作为对外契约。

**非目标**：甘特灰条、项目摘要、基线间对比、挣值、保存时透传未知根键。

## 3. v0.14.0 · 基线可视化 + 项目摘要

**目标**：把 v0.13 的数字画出来，并给项目级偏差一屏结论。
甘特对比模式先定义四档 `GanttBaselineMode`（仅实际 / 仅基线 / 双日程 / 分割），**本版只实现「双日程（基线灰条在下）」**，其余两档不出现在菜单里（不放死按钮）。

**范围**

- Presentation：独立 `baselineBars: [GanttBaselineBar]`（**不改 `GanttBar` 既有几何**）、`GanttSnapshot.baselineMode: GanttBaselineMode`、项目摘要 `ProjectInspector` 增偏差字段（结束偏差 / 晚完成数 / 逾期数 / 无基线数 / 已删除数 / 预测项数）。
- App：`TimelineView` 灰条图层（新增 `DesignTokens.baselineBar` token）、视图菜单「基线对比：双日程」（另两档不出现）、项目检查器 Summary 行。
- CLI：`project summary` 增偏差块（与检查器同源字符串）。

**并行分组**

- 波次 1：G1（Presentation 几何：`GanttLayout` 纯函数算基线 x/width + 用例）
- 波次 2：G2（App 渲染 + 菜单 + token）∥ G3（项目摘要：Presentation 快照 + InspectorView + CLI 文案）——文件不重叠

**判据要点**

1. 灰条几何由纯函数计算并有断言（`baselineX/Width` 与基线条目日期换算一致），不靠目测。
2. 模式切换不改变行索引、不改变既有 bars 几何（**A7 黄金基线用例必须原样通过**，只允许新增图层）。
3. 无基线 / 基线后新增任务：不画灰条、不报错、不占位留空陷阱。
4. 1,000 行灰条渲染不掉帧（沿用既有性能用例口径）。

**风险**：A7 黄金基线是既有布局基准（历史多次被撞）；缓解——灰条走独立数据结构与独立图层，禁止改 `GanttBar.x/width` 的既有语义。

**非目标**：「仅基线」「分割日程（上下半并排）」两档——枚举已定义、UI 不暴露，另开版本；资源/成本维度的基线。

## 4. v0.15.0 · 基线与偏差报表化

**目标**：多基线可管理、历史可查、结果可带走。

**范围**

- App：基线面板（列表 / 重命名 / 删除 / 孤儿列表只读 / 「基线之后新增」清单）。
- CLI/MCP：`baseline variance --format csv`（或 `--csv <path>`）、基线条目含孤儿分区。
- 可选（视 v0.14 反馈）：基线 A vs B 对比、分割日程视图。

**并行分组**：单链为主——`baseline 面板 UI` 与 `CSV 导出` 文件范围不重叠，可并行；随后一版收口用例与文档。

**判据要点**：CSV 列名/单位/符号与 `BaselineVariance` 一致（负数带符号、空值留空不写 0）；删除基线不影响其它基线与任务；孤儿清单可复现且计数稳定。

**非目标**：挣值/成本（CPI/SPI/CV）、基线云同步、多人变更控制。

## 5. 交付顺序与发版纪律

```
v0.12（事实层） → v0.13（数字层） → v0.14（视觉层） → v0.15（报表层）
```

- 严格串行依赖：后一版需要前一版的字段与口径；每版独立分支（`feature/<主题>`）→ 全绿 → 合回 main → 发版。
- 每版固定三件事：版本号 PATCH/MINOR、CHANGELOG 条目（含判据证据）、缺陷登记表回填。
- v0.13 起 `.kairo` 为格式 v2：发版说明必须写明「旧版本 Kairo 无法打开由新版保存的文件」；这是本规划唯一的不可逆动作（已裁定，非待确认）。

## 6. 决策闸门（开工前必须已裁定）

| 闸门 | 归属 | 状态 | 阻塞对象 |
| --- | --- | --- | --- |
| 格式版本升 2 | 用户 | ✅ 已裁定 | v0.13 存储组 |
| 08 §11 剩余 2 条（存储形态 A/B/C、是否写 `.v1.bak`） | 用户 | 待确认 | v0.13 存储组落地写法 |
| 07 已定口径（三层、实际字段、自动记录时机） | 设计 | ✅ 已定 | v0.12 |
| v0.14 灰条数据结构（独立 `baselineBars`，不动 `GanttBar` 几何） | 设计 | ✅ 已定 | v0.14 G1 |
