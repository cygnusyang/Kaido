# 09 大版本规划：实际时间 → 基线 → 偏差（v0.12 → v0.15）

> 状态：规划稿（dev-architect）· 2026-10-25 · 上游：[07-actual-dates.md](07-actual-dates.md)、[08-baselines.md](08-baselines.md)
> 当前版本：v0.11.0（CHANGELOG）。本规划共 4 个可独立发版的 MINOR 版本，每版都带用户可见价值，可单独回滚。

## 0. 总览

| 版本 | 主题 | 用户可见价值 | 依赖 | 主要风险 |
| --- | --- | --- | --- | --- |
| v0.12.0 | 实际开始 / 实际结束（落实 07） | 任务能看到「真的什么时候开工、什么时候完的」，并自动记录 | 无 | TaskItem 扩字段引发既有相等断言批量红 |
| v0.13.0 | 基线快照 + 偏差数值（含 `.kairo` 格式升 v2） | 拍一次基线，大纲/检查器直接看到「比承诺晚几天」 | v0.12 | 格式升版不可逆：旧版本从此打不开新文件 |
| v0.14.0 | **多基线叠加**（重写，取代「单基线灰条」） | 1–3 条基线同屏画在同一行、按颜色区分，创建入口一眼可见 | v0.13 | 碰 A7 黄金布局；28pt 内 3 条的可读性 |
| v0.15.0 | 基线与偏差报表化 + 项目摘要 | 基线面板管理、孤儿可查、项目级偏差一屏、导出 CSV | v0.14 | 报表口径与对等性 |

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

## 3. v0.14.0 · 多基线叠加：甘特图同屏可见、按颜色区分

> **重写（2026-10-25）**：原方案「单基线灰条 + 四档 `GanttBaselineMode`」已被**用户否决**——需求是「可创建很多个基线，甘特图同一行同时显示、用不同颜色区分」。
> 新方案全文见 **[10-multi-baseline-gantt.md](10-multi-baseline-gantt.md)**；本节只保留版本范围、并行分组与版本级判据。原「项目摘要」内容顺延到 v0.15。

**目标**：让 1–3 条基线（保守 / 基准 / 激进）**同时**画在同一任务行的计划条下方，用 8 色调色板按基线区分颜色；创建入口在菜单里第一眼可见；基线数量不设上限。

**范围**

- Core：`Baseline.colorIndex: Int?`（加法可选字段，**不升 formatVersion**）、`BaselinePalette`（索引归一化 / 最小未用分配，纯函数）、`GanttLayoutEngine.x(for:windowStart:dayWidth:)` + `width(from:to:dayWidth:)`（把内联算式抽出，计划条与基线共用，杜绝第二份实现）。
- Commands：`setBaselineColor(id:colorIndex:)`（进撤销栈）；创建 / 改名 / 改色 / 删除四条写路径入口先 `ensureBaselineColors()`（旧文件补色，打开不动盘）。
- Presentation：`BaselineLanes`（行内分轨几何纯函数 + 28pt 四档表）、`GanttBaselineBar` / `BaselineLegendItem` / `GanttSnapshot.baselineBars|baselineLanes|baselineLegend|hiddenBaselineCount`、`ViewState.visibleBaselineIDs` + 读取侧归一化（去悬挂 / 按创建序 / 截断到 3）、`GanttHitTesting` 增 plan lane 纵向闸门（防在基线轨上拖计划条）。
- App：`TimelineView` 基线下轨图层（`drawBaselineBars`，与 `drawBars` 同行窗口裁剪）、`DesignTokens.baselinePalette[8]`、**菜单栏顶级「基线」菜单**（新建 ⌘⌥B 置顶）+ 工具栏「基线」菜单重做 + ⌘K 静态/动态项、状态栏图例、大纲列与检查器沿用 v0.13。
- CLI / MCP：`baseline list` 与 `baseline_variance` 输出增 `colorIndex`；`baseline color <id> <0-7>`。显示集合是视图状态，**不进** CLI / MCP。

**改动清单（逐文件，组内文件互斥才能并行）**

| 组 | 文件范围（互斥） | 归属 | 前置 |
| --- | --- | --- | --- |
| G1 core-model | `Sources/KairoCore/Model/Baseline.swift`、`Sources/KairoCore/Model/BaselinePalette.swift`（新）、`Tests/KairoCoreTests/BaselinePaletteTests.swift`（新） | core | — |
| G2 core-geom | `Sources/KairoCore/Query/GanttLayout.swift`、`Tests/KairoCoreTests/GanttDateToXTests.swift`（新） | core | — |
| G3 pres-lane | `Sources/KairoPresentation/BaselineLanes.swift`（新）、`Sources/KairoPresentation/GanttHitTesting.swift`、`Tests/KairoPresentationTests/BaselineLaneGeometryTests.swift`（新）、`Tests/KairoPresentationTests/GanttHitTestingTests.swift` | pres | G2 |
| G4 cmds | `Sources/KairoCommands/KairoSession.swift`、`Tests/KairoCoreTests/SessionBaselineTests.swift` | core | G1 |
| G5 pres-snapshot | `Sources/KairoPresentation/Snapshots.swift`、`Presenter.swift`、`ViewState.swift`、`WorkspaceAction.swift`、`Tests/KairoPresentationTests/BaselineMultiGanttTests.swift`（新） | pres | G3 + G4 |
| G6 tokens | `Apps/macos/Sources/Theme/DesignTokens.swift`（只加 8 色 + 图例 token） | app | — |
| G7 canvas | `Apps/macos/Sources/Workspace/Timeline/TimelineView.swift` | app | G5 + G6 |
| G8 menus | `Apps/macos/Sources/CommandRegistry.swift`、`Apps/macos/Sources/Workspace/Baseline/`（新目录：`BaselineMenu.swift`、`BaselineDot.swift`）、`Workspace/WorkspaceView.swift`、`WorkspaceStore.swift`、`Resources/Localizable.xcstrings` | app | G5 + G6 |
| G9 interfaces | `Sources/KairoCLI/CLIRouter.swift`、`Sources/KairoCLI/CLIStrings.swift`、`Sources/KairoMCP/Tools.swift`、`Tests/InterfaceTests/BaselineInterfaceTests.swift` | cli | G4 |

**并行分组（只有文件范围两两不重叠才并行）**

- 波次 1：**G1 ∥ G2 ∥ G6**（core 模型 / core 几何 / app token，互不重叠）
- 波次 2：**G3 ∥ G4**（pres 几何 vs session 写路径，无交集）
- 波次 3：**G5**（依赖 G3 的类型与 G4 的写路径，单链）
- 波次 4：**G7 ∥ G8 ∥ G9**（画布 / 菜单与 Store / CLI+MCP，文件两两互斥）
- 串行链（不得并行）：G2 → G3 → G5 → G7；G1 → G4 → G5 / G9。

**版本级判据**：10 §10 全 13 条；版本门禁另加——① A7 黄金用例**一行不改**全绿；② 1,000 行 × 3 基线的构造 / 绘制实测记入 CHANGELOG；③ CLI / MCP 的 `colorIndex` 与 Session 落盘值逐字段一致。

**风险与缓解**

- **A7 黄金布局（历史多次被撞）**：基线走独立结构 + 独立图层；`GanttBar` 零改动；N=0 时几何逐像素即现状（`BaselineLanes.layout(0)` 断言）。
- **创建入口再次「消失」**（D-035 复发）：创建同时静态注册到菜单栏顶级菜单第 1 项、工具栏菜单第 1 项、⌘K；判据 12 用注册表断言锁死，不靠肉眼验收。
- **视图效果只能目测**：分轨几何、颜色分配、上限截断全部走纯函数 + 单测，视图只消费数值。
- **28pt 内 3 条基线的可读性**：以 4pt 轨高 + 8 色调色板 + 图例兜底；若用户确认「底部细轨」备选，只需换 `BaselineLanes` 的参数表，其余组不动（这是把几何抽成纯函数的主要收益）。

**非目标**：「分割日程」「仅基线」两档视图模式、基线间对比（A vs B）、项目级偏差摘要（顺延 v0.15）、基线条拖拽、图例常驻画布、颜色取色器。

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
| v0.14 数据结构（独立 `baselineBars` + `BaselineLanes`，不动 `GanttBar` 几何） | 设计 | ✅ 已定 | v0.14 G3 / G5 |
| v0.14 行内分轨参数（28pt 内 1–3 条） | 用户 | 待确认（10 §12-1） | v0.14 G3 参数表 |
| v0.14 显示上限 3 条 + 第 4 条策略 | 用户 | 待确认（10 §12-2） | v0.14 G5 |
| v0.14 `colorIndex` 加法字段（不升 formatVersion） | 设计 | ✅ 已定 | v0.14 G1 |
