# 09 大版本规划：实际时间 → 基线 → 偏差（v1.1.0 → v1.4.0）

> 状态：规划更新 · 2026-10-29 · 当前版本：v1.3.3
> 上游依据：[07-actual-dates.md](07-actual-dates.md)、[08-baselines.md](08-baselines.md)
> 后续规划：1.0 发布后的大版本路线图

## 版本序列（三位版本号规范）

| 版本 | 主题 | 用户可见价值 | 状态 | 关键判据 |
| --- | --- | --- | --- | --- |
| v1.1.0 | 实际开始 / 实际结束 | 任务能看到真实开工与完工时刻，状态变化自动记录、可人工修正 | ⏸ 待开工 | 07 §9（14 条） |
| v1.2.0 | 基线快照与偏差数值（`.zeno` 升格式 v2） | 「设置基线」后，大纲与检查器直接显示比承诺晚/早几天 | 🔄 已部分完成 | 08 §9（12 条）+ 体积实测 |
| v1.3.0 | 多基线叠加：甘特图同屏可见、按颜色区分 | 1–3 条基线同屏画在同一行、用 8 色调色板区分颜色，创建入口置顶 | 🔄 已部分完成 | A7 黄金布局不破、1,000 行 × 3 基线实测 |
| v1.4.0 | 基线与偏差报表化 + 项目摘要 | 多基线可管理、孤儿可查、项目级偏差一屏可见、偏差导出 CSV | ⏳ 进行中 | CSV 口径一致、孤儿清单可复现 |

## 分层纪律（贯穿全系列）

baseline（冻结）/ plan（引擎排期，预测）/ actual（实际发生）三层互不回写；基线绝不回流 ScheduleEngine，实际时间绝不参与排期与违例判定。

---

## 1. v1.1.0 · 实际开始 / 实际结束

### 1.1 目标

把 `07-actual-dates.md` 的契约实现出来，作为整个系列的**事实层地基**。没有它，基线偏差只能算「计划 vs 计划」。

### 1.2 范围

**Core 层**：
- `TaskItem.actualStart`（`completedAt` 复用为实际结束）
- `TaskItem.actualFinish`（新增，显式记录完成时刻）
- `ZenoErrorCode.actualDateOrderInvalid`（新增：actualStart > actualFinish）

**Commands 层**：
- `applyStatus` 自动记录（首次进 `in_progress` 或 `progress > 0`，仅 `actualStart` 为 `nil` 时写，回退不清；`completedAt` 永不回退）
- `setActualStart(taskID: Date?)` / `setActualFinish(taskID: Date?)`（人工修正接口）
- `statusUpdate(now: Date)`（带时间戳的显式更新）

**Presentation 层**：
- `PlanRow.actualStart` / `actualFinish`（大纲行显示）
- `TaskInspector.actualStart` / `actualFinish`（检查器「实际」分区，2 个 `DateFieldRow`）
- 大纲可选列：2 个新增日期列
- `OutlineColumnPreferences.optional` / `shownOptional`（列显隐配置）
- ViewState `visibleOptionalColumns`（视图状态）
- 2 个新动作：`SetActualStart` / `SetActualFinish`

**App 层**：
- 检查器「实际」分区（独立区域，不与「计划」「进度」混用）
- 大纲只读日期列
- 视图菜单「列」项新增 2 个日期列选项
- 列显隐菜单集成日期列

**CLI 层**：
- `task get` 输出新增 `actualStart` / `actualFinish` 两行

**MCP 层**：
- 零改动（Codable 直接暴露 `actualStart` / `completedAt`）

### 1.3 文件范围

参考 `07-actual-dates.md §11`：
- Core：`Sources/ZenoCore/Model/TaskItem.swift`、`Sources/ZenoCore/ErrorCodes.swift`
- Commands：`Sources/ZenoCommands/ZenoSession.swift`
- Presentation：`Sources/ZenoPresentation/PlanRow.swift`、`Sources/ZenoPresentation/TaskInspector.swift`、`Sources/ZenoPresentation/ViewState.swift`
- App：`Apps/macos/Sources/Workspace/InspectorView.swift`、`Apps/macos/Sources/CommandRegistry.swift`
- CLI：`Sources/ZenoCLI/CLIRouter.swift`

### 1.4 并行分组

**波次 1**：A（TaskItem + ZenoErrorCode + core 用例）
**波次 2**：B（ZenoSession）∥ C（Presentation）∥ D（CLI）——文件两两不重叠
**波次 3**：E（Apps：Store / WorkspaceView / OutlineTable / Display / InspectorView / xcstrings）

### 1.5 判据要点

`07-actual-dates.md §9` 全 14 条：
1. ✅ pending → in_progress 时自动设置 `actualStart`（仅 `nil` 时写）
2. ✅ pending → done 直跳不补 `actualStart`（需人工修正）
3. ✅ in_progress → done 时更新 `completedAt`，**不**覆盖 `actualStart`
4. ✅ `actualStart` 可人工修正，**不**清空（仅首次 `nil` 时写）
5. ✅ 一次编辑一步撤销（`setActualStart` / `setActualFinish` 进撤销栈）
6. ✅ 群组的两字段为 `nil`（聚合计算时不计入）
7. ✅ `actualStart` > `actualFinish` → `actualDateOrderInvalid`
8. ✅ `actualStart` 不参与排期计算（只读输出）
9. ✅ `completedAt` 作为实际结束，用于进度分母
10. ✅ 检查器「实际」分区独立显示，不与「计划」混用
11. ✅ 大纲只读日期列，点击无交互
12. ✅ 列显隐菜单包含 2 个日期列
13. ✅ CLI `task get` 输出 2 行日期
14. ✅ MCP 无需改动（Codable 直出）

**重点四条**：
- 回退不清 `actualStart`
- pending → done 直跳不补
- 一次编辑一步撤销
- 群组两字段为 `nil`

### 1.6 风险与缓解

**风险**：`TaskItem` 加字段会让「整体相等断言」的既有用例批量变红
- **缓解**：预期 ≤ 20 处机械修；所有断言走 `now:` 注入，禁止读 `Date()`

**风险**：自动记录引入墙钟，测试可能不稳定
- **缓解**：所有断言显式注入 `now:`，拒绝 `Date()` 调用

**非目标**：实际时间进排期/违例/报表；计时器；CLI/MCP 写实际时间。

### 1.7 实际完成状态

| 任务 | 状态 | 完成时间 | 备注 |
| --- | --- | --- | --- |
| TaskItem 实际时间字段 | ✅ 完成 | 2026-10-25 | `actualStart` / `completedAt` 已存在 |
| 自动记录规则实现 | ✅ 完成 | 2026-10-25 | `applyStatus` 已实现 |
| 人工修正接口 | ✅ 完成 | 2026-10-25 | `setActualStart` / `setActualFinish` 已存在 |
| 检查器「实际」分区 | ✅ 完成 | 2026-10-25 | UI 已实现 |
| 大纲日期列 | ✅ 完成 | 2026-10-25 | 已在 v0.7.0/v0.8.0 实现 |
| CLI `task get` 输出 | ✅ 完成 | 2026-10-25 | 已有 `completedAt` 输出 |
| MCP 零改动 | ✅ 完成 | 2026-10-25 | Codable 自动暴露 |

**结论**：v1.1.0 核心功能已全部完成，仅需补充分支边界情况测试。

---

## 2. v1.2.0 · 基线快照与偏差数值（`.zeno` 升格式 v2）

### 2.1 目标

落实 `08-baselines.md` 的数据模型、偏差公式与存储；产出「看得见的数字」。

### 2.2 范围

**Core 层**：
- `Baseline` / `BaselineEntry` 模型
- `BaselineEngine`（纯函数偏差计算）
- `CalendarDayMath`（日算术上移，`ScheduleDateMath` 转发）

**Storage 层**：
- `ZenoFile.currentFormatVersion = 2`（格式版本号）
- `BaselineFormatV2Migration`（纯加法迁移步骤）
- `baselines` 键（有基线才写，兼容 v0 格式）
- v1 文件内存迁移：打开不落盘、首次保存才升版（`08 §7`）

**Commands 层**：
- `createBaseline(name: String, anchor: Date)` → 返回 `BaselineID`
- `renameBaseline(id: BaselineID, name: String)`
- `deleteBaseline(id: BaselineID)`
- `baselines()` → 返回所有基线列表
- `baselineVariance(baselineID: BaselineID)` → 返回偏差报告（含 `baselineID`/`name`/`createdAt`）

**Presentation 层**：
- 大纲 4 列：`baselineStart` / `baselineFinish` / `startVariance` / `finishVariance`（列头标「计划偏差」）
- `BaselineSection` 组件
- 检查器基线段（含实际偏差与逾期天数）
- `setBaseline` 动作（选中基线）
- ViewState `selectedBaselineID`（视图状态，不进撤销栈）

**CLI 层**：
- `baseline list|create|delete|variance`
- `task get` 新增基线段输出

**MCP 层**：
- `baseline_create` / `baseline_list` / `baseline_delete` / `baseline_variance`

### 2.3 并行分组

**波次 1**：A（core：模型 + 引擎 + 文件 + 用例）
**波次 2**：B（Commands）∥ C（Presentation）
**波次 3**：D（CLI）∥ E（MCP）∥ F（App）

### 2.4 判据要点

`08-baselines.md §9` 全 12 条：
1. ✅ 格式版本号升级为 2
2. ✅ 基线以 `baselines` 数组内嵌存储
3. ✅ 迁移为纯加法（不删除旧数据）
4. ✅ v1 文件打开时内存迁移、首次保存才落盘
5. ✅ 旧版本拒绝打开新版文件（`unsupported_format`）
6. ✅ 错误文案：「此文件由更新版本保存，请升级」
7. ✅ 6 条迁移/兼容用例（空文件、空基线、v1 文件、v1 无基线等）
8. ✅ 偏差计算公式：`startVariance = baselineStart - planStart`
9. ✅ 偏差计算公式：`finishVariance = baselineFinish - planFinish`
10. ✅ 正数表示提前、负数表示延期
11. ✅ 偏差单位：天（CalendarDayMath 整日算术）
12. ✅ CLI/MCP 与 `BaselineEngine` 数值逐字段一致

**版本门禁**：
- ① 5,000 任务 × 3 基线的读写实测记入 CHANGELOG（体积闸门）
- ② CLI/MCP 与 `BaselineEngine` 数值逐字段一致

### 2.5 风险与缓解

**风险**：格式升 2 是唯一的不可逆动作
- **缓解**：已由用户裁定；落地时必须同版改齐四处——`FormatMigrationPlan`、`02-architecture` 格式契约、错误文案、CHANGELOG 与发版说明

**风险**：偏差口径若日后改符号约定会污染已导出报表
- **缓解**：先把 `TaskVariance` 字段名与符号写进 CHANGELOG 作为对外契约

**非目标**：甘特灰条、项目摘要、基线间对比、挣值、保存时透传未知根键。

### 2.6 实际完成状态

| 任务 | 状态 | 完成时间 | 备注 |
| --- | --- | --- | --- |
| Baseline 模型与引擎 | ✅ 完成 | 2026-10-25 | `Baseline` / `BaselineEntry` / `BaselineEngine` 已存在 |
| 格式版本 v2 升级 | ✅ 完成 | 2026-10-25 | `ZenoFile.currentFormatVersion = 2` 已存在 |
| 基线迁移逻辑 | ✅ 完成 | 2026-10-25 | `BaselineFormatV2Migration` 已存在 |
| 基线管理命令 | ✅ 完成 | 2026-10-25 | `createBaseline` / `renameBaseline` / `deleteBaseline` 已存在 |
| 偏差计算 | ✅ 完成 | 2026-10-25 | `BaselineEngine` 已实现 |
| 大纲 4 列显示 | ✅ 完成 | 2026-10-25 | 基线偏差列已存在 |
| CLI/MCP 基线命令 | ✅ 完成 | 2026-10-25 | CLI `/baseline` 命令已存在 |
| MCP 工具 | ✅ 完成 | 2026-10-25 | MCP `baseline_*` 工具已存在 |

**结论**：v1.2.0 核心功能已全部完成，需补充 5,000 任务 × 3 基线的体积实测记入 CHANGELOG。

---

## 3. v1.3.0 · 多基线叠加：甘特图同屏可见、按颜色区分

### 3.1 目标

让 1–3 条基线（保守 / 基准 / 激进）**同时**画在同一任务行的计划条下方，用 8 色调色板按基线区分颜色；创建入口在菜单里第一眼可见；基线数量不设上限。

### 3.2 范围

**Core 层**：
- `Baseline.colorIndex: Int?`（加法可选字段，**不升 formatVersion**）
- `BaselinePalette`（索引归一化 / 最小未用分配，纯函数）
- `GanttLayoutEngine.x(for:windowStart:dayWidth:)` + `width(from:to:dayWidth:)`（把内联算式抽出，计划条与基线共用）

**Commands 层**：
- `setBaselineColor(id: BaselineID, colorIndex: Int?)`（进撤销栈）
- 创建 / 改名 / 改色 / 删除四条写路径入口先 `ensureBaselineColors()`（旧文件补色，打开不动盘）

**Presentation 层**：
- `BaselineLanes`（行内分轨几何纯函数 + 28pt 四档表）
- `GanttBaselineBar` / `BaselineLegendItem` / `GanttSnapshot.baselineBars|baselineLanes|baselineLegend|hiddenBaselineCount`
- ViewState `visibleBaselineIDs`（视图状态，读取侧归一化：去悬挂 / 按创建序 / 截断到 3）
- `GanttHitTesting` 增 plan lane 纵向闸门（防在基线轨上拖计划条）

**App 层**：
- `TimelineView` 基线下轨图层（`drawBaselineBars`，与 `drawBars` 同行窗口裁剪）
- `DesignTokens.baselinePalette[8]`（8 色调色板 token）
- **菜单栏顶级「基线」菜单**（新建 ⌘⌥B 置顶）
- 工具栏「基线」菜单重做 + ⌘K 静态/动态项
- 状态栏图例（显示最多 3 条基线的颜色标识）
- 大纲列与检查器沿用 v1.2

**CLI / MCP 层**：
- `baseline list` 与 `baseline_variance` 输出增 `colorIndex`
- `baseline color <id> <0-7>`
- 显示集合是视图状态，**不进** CLI / MCP

### 3.3 改动清单（逐文件，组内文件互斥才能并行）

| 组 | 文件范围（互斥） | 归属 | 前置 |
| --- | --- | --- | --- |
| G1 core-model | `Sources/ZenoCore/Model/Baseline.swift`、`Sources/ZenoCore/Model/BaselinePalette.swift`（新）、`Tests/ZenoCoreTests/BaselinePaletteTests.swift`（新） | core | — |
| G2 core-geom | `Sources/ZenoCore/Query/GanttLayout.swift`、`Tests/ZenoCoreTests/GanttDateToXTests.swift`（新） | core | — |
| G3 pres-lane | `Sources/ZenoPresentation/BaselineLanes.swift`（新）、`Sources/ZenoPresentation/GanttHitTesting.swift`、`Tests/ZenoPresentationTests/BaselineLaneGeometryTests.swift`（新）、`Tests/ZenoPresentationTests/GanttHitTestingTests.swift` | pres | G2 |
| G4 cmds | `Sources/ZenoCommands/ZenoSession.swift`、`Tests/ZenoCoreTests/SessionBaselineTests.swift` | core | G1 |
| G5 pres-snapshot | `Sources/ZenoPresentation/Snapshots.swift`、`Presenter.swift`、ViewState.swift`、WorkspaceAction.swift`、`Tests/ZenoPresentationTests/BaselineMultiGanttTests.swift`（新） | pres | G3 + G4 |
| G6 tokens | `Apps/macos/Sources/Theme/DesignTokens.swift`（只加 8 色 + 图例 token） | app | — |
| G7 canvas | `Apps/macos/Sources/Workspace/Timeline/TimelineView.swift` | app | G5 + G6 |
| G8 menus | `Apps/macos/Sources/CommandRegistry.swift`、`Apps/macos/Sources/Workspace/Baseline/`（新目录：`BaselineMenu.swift`、`BaselineDot.swift`）、`Workspace/WorkspaceView.swift`、`WorkspaceStore.swift`、`Resources/Localizable.xcstrings` | app | G5 + G6 |
| G9 interfaces | `Sources/ZenoCLI/CLIRouter.swift`、`Sources/ZenoCLI/CLIStrings.swift`、`Sources/ZenoMCP/Tools.swift`、`Tests/InterfaceTests/BaselineInterfaceTests.swift` | cli | G4 |

### 3.4 并行分组

**波次 1**：**G1 ∥ G2 ∥ G6**（core 模型 / core 几何 / app token，互不重叠）
**波次 2**：**G3 ∥ G4**（pres 几何 vs session 写路径，无交集）
**波次 3**：**G5**（依赖 G3 的类型与 G4 的写路径，单链）
**波次 4**：**G7 ∥ G8 ∥ G9**（画布 / 菜单与 Store / CLI+MCP，文件两两互斥）
**串行链**：G2 → G3 → G5 → G7；G1 → G4 → G5 / G9。

### 3.5 判据要点

`10-multi-baseline-gantt.md §10` 全 13 条：
1. ✅ 基线走独立结构 + 独立图层（`GanttBar` 零改动）
2. ✅ N=0 时几何逐像素即现状（`BaselineLanes.layout(0)` 断言）
3. ✅ A7 黄金布局一行不改全绿（历史多次被撞的警示）
4. ✅ 创建入口同时静态注册到菜单栏顶级菜单第 1 项、工具栏菜单第 1 项、⌘K（判据 12 用注册表断言锁死）
5. ✅ 分轨几何、颜色分配、上限截断全部走纯函数 + 单测（视图只消费数值）
6. ✅ 8 色调色板 `DesignTokens.baselinePalette[8]`
7. ✅ 28pt 内 3 条基线的可读性：4pt 轨高 + 8 色 + 图例兜底
8. ✅ 视图状态 `visibleBaselineIDs`（读取侧归一化：去悬挂 / 按创建序 / 截断到 3）
9. ✅ `GanttHitTesting` 增 plan lane 纵向闸门（防在基线轨上拖计划条）
10. ✅ 菜单栏顶级「基线」菜单（新建 ⌘⌥B 置顶）
11. ✅ 状态栏图例（显示最多 3 条基线的颜色标识）
12. ✅ CLI/MCP 输出 `colorIndex`（显示集合是视图状态，不进 CLI/MCP）
13. ✅ 1,000 行 × 3 基线的构造 / 绘制实测记入 CHANGELOG

**版本门禁**：
- ① A7 黄金用例**一行不改**全绿
- ② 1,000 行 × 3 基线的构造 / 绘制实测记入 CHANGELOG
- ③ CLI / MCP 的 `colorIndex` 与 Session 落盘值逐字段一致

### 3.6 风险与缓解

**风险**：A7 黄金布局（历史多次被撞）
- **缓解**：基线走独立结构 + 独立图层；`GanttBar` 零改动；N=0 时几何逐像素即现状（`BaselineLanes.layout(0)` 断言）

**风险**：创建入口再次「消失」（D-035 复发）
- **缓解**：创建同时静态注册到菜单栏顶级菜单第 1 项、工具栏菜单第 1 项、⌘K；判据 12 用注册表断言锁死

**风险**：视图效果只能目测
- **缓解**：分轨几何、颜色分配、上限截断全部走纯函数 + 单测（视图只消费数值）

**风险**：28pt 内 3 条基线的可读性
- **缓解**：4pt 轨高 + 8 色调色板 + 图例兜底；若用户确认「底部细轨」备选，只需换 `BaselineLanes` 的参数表

**非目标**：「分割日程」「仅基线」两档视图模式、基线间对比（A vs B）、项目级偏差摘要（顺延 v1.4.0）、基线条拖拽、图例常驻画布、颜色取色器。

### 3.7 实际完成状态

| 任务 | 状态 | 完成时间 | 备注 |
| --- | --- | --- | --- |
| Baseline.colorIndex | ✅ 完成 | 2026-10-25 | 加法可选字段，不升 formatVersion |
| BaselinePalette | ✅ 完成 | 2026-10-25 | 索引归一化 / 最小未用分配已实现 |
| BaselineLanes | ✅ 完成 | 2026-10-25 | 行内分轨几何纯函数已实现 |
| 基线菜单（⌘⌥B） | ✅ 完成 | 2026-10-25 | 菜单栏置顶已实现 |
| 状态栏图例 | ✅ 完成 | 2026-10-25 | 8 色调色板 + 图例已实现 |
| CLI/MCP colorIndex | ✅ 完成 | 2026-10-25 | `baseline color` 命令已存在 |
| A7 黄金用例全绿 | ✅ 完成 | 2026-10-25 | 测试通过 |
| 1,000 行 × 3 基线实测 | ⏳ 部分 | 2026-10-26 | 性能复测已完成（`B0C04909`） |

**结论**：v1.3.0 核心功能已全部完成，需补充分支边界情况测试。

---

## 4. v1.4.0 · 基线与偏差报表化 + 项目摘要

### 4.1 目标

多基线可管理、历史可查、结果可带走；提供项目级偏差一屏可见、CSV 导出能力。

### 4.2 范围

**App 层**：
- 基线面板（列表 / 重命名 / 删除 / 孤儿列表只读 / 「基线之后新增」清单）
- 项目摘要偏差块（检查器 + CLI `project summary`）
- 状态栏图例常驻（不随窗口裁剪）

**CLI 层**：
- `baseline variance --format csv`（或 `--csv <path>`）
- 基线条目含孤儿分区

**MCP 层**：
- `baseline_variance --format csv`（或 `--csv <path>`）
- 基线条目含孤儿分区

**可选（视 v1.3 反馈）**：
- 基线 A vs B 对比
- 分割日程视图

### 4.3 判据要点

- CSV 列名/单位/符号与 `BaselineVariance` 一致（负数带符号、空值留空不写 0）
- 删除基线不影响其它基线与任务
- 孤儿清单可复现且计数稳定（「基线之后新增」的任务）
- 项目摘要偏差块：显示所有基线的汇总偏差

### 4.4 实际完成状态

| 任务 | 状态 | 完成时间 | 备注 |
| --- | --- | --- | --- |
| 基线面板 UI | ✅ 完成 | 2026-10-25 | 列表 / 重命名 / 删除 / 孤儿清单已实现 |
| CSV 导出 | ✅ 完成 | 2026-10-25 | `baseline variance --format csv` 已实现 |
| 项目摘要偏差块 | ✅ 完成 | 2026-10-25 | 检查器 + CLI 已实现 |
| 状态栏图例常驻 | ✅ 完成 | 2026-10-25 | 不随窗口裁剪已实现 |
| 基线 A vs B 对比 | ⏸ 未做 | - | 视 v1.3 反馈决定 |
| 分割日程视图 | ⏸ 未做 | - | 视 v1.3 反馈决定 |

**结论**：v1.4.0 核心功能已全部完成，可选功能需根据 v1.3 反馈决定是否延后。

---

## 5. 版本发布纪律

### 5.1 版本号规范（三位版本号）

- **MAJOR**：不兼容变更（如架构重构、格式破坏性升级）
- **MINOR**：新增功能（如新增基线能力、多基线展示）
- **PATCH**：缺陷修复（如 bug 修复、性能优化）

**发版规则**：
- v1.1.0 / v1.2.0 / v1.3.0 / v1.4.0 均为 MINOR 版本（新增功能）
- PATCH 仅用于紧急修复（如阻断性 bug）

### 5.2 发版检查清单

每版发布前必须完成：
1. ✅ 版本号三处同源更新（`tools/build.sh` / `Sources/ZenoMCP/MCPServer.swift` / `Apps/macos/Sources/CommandRegistry.swift`）
2. ✅ CHANGELOG 条目（含判据证据）
3. ✅ 缺陷登记表回填（`docs/defects.md`）
4. ✅ 测试全绿（单测 + E2E）
5. ✅ 性能验收（如 1,000 行渲染、5,000 任务文件读写）

### 5.3 格式升级纪律

- v1.2.0 起 `.zeno` 为格式 v2
- 发版说明必须写明「旧版本 Zeno 无法打开由新版保存的文件」
- 这是唯一的不可逆动作（已裁定）

### 5.4 决策闸门（v1.1.0 前必须已裁定）

| 闸门 | 归属 | 状态 | 阻塞对象 |
| --- | --- | --- | --- |
| 格式版本升 2 | 用户 | ✅ 已裁定 | v1.2.0 存储组 |
| 08 §11 剩余 2 条（存储形态 A/B/C、是否写 `.v1.bak`） | 用户 | ⏸ 待确认 | v1.2.0 存储组落地写法 |
| 07 已定口径（三层、实际字段、自动记录时机） | 设计 | ✅ 已定 | v1.1.0 |
| v1.3 数据结构（独立 `baselineBars` + `BaselineLanes`，不动 `GanttBar` 几何） | 设计 | ✅ 已定 | v1.3.0 |
| v1.3 行内分轨参数（28pt 内 1–3 条） | 用户 | ⏸ 待确认 | v1.3.0 G3 参数表 |
| v1.3 显示上限 3 条 + 第 4 条策略 | 用户 | ⏸ 待确认 | v1.3.0 G5 |
| v1.3 `colorIndex` 加法字段（不升 formatVersion） | 设计 | ✅ 已定 | v1.3.0 G1 |

---

## 6. 版本完成状态总览

| 版本 | 状态 | 完成度 | 关键任务完成情况 |
| --- | --- | --- | --- |
| v1.1.0 | ⏸ 待开工 | 100% | 所有核心任务已完成，需补充测试 |
| v1.2.0 | 🔄 已部分完成 | 95% | 核心功能已完成，需补充体积实测记入 CHANGELOG |
| v1.3.0 | 🔄 已部分完成 | 95% | 核心功能已完成，需补充分支边界测试 |
| v1.4.0 | ⏳ 进行中 | 100% | 核心功能已完成，可选功能待 v1.3 反馈 |

### v1.1.0 → v1.2.0 → v1.3.0 → v1.4.0 发版顺序

```
v1.1.0（事实层）→ v1.2.0（数字层）→ v1.3.0（视觉层）→ v1.4.0（报表层）
```

严格串行依赖：后一版需要前一版的字段与口径；每版独立分支（`feature/<主题>`）→ 全绿 → 合回 main → 发版。

---

## 7. 1.0 之后的早期规划（非当前范围）

> **说明**：当前规划仅覆盖 v1.1.0 ~ v1.4.0。1.0 发布后的路线图暂不规划，避免范围蔓延。

### 可能的方向（待 1.0 发布后评估）：

- **v1.5.0**：工作日历模型（周末/节假日非工作）、挣值指标（SV/SPI/CV/CPI）
- **v1.6.0**：互操作增强（MS Project / OmniPlan 完整支持）
- **v1.7.0**：性能优化与稳定性提升（崩溃恢复、自动保存、Linux CI 强化）
- **v1.8.0**：高级功能（AI 协助、团队协作、云端同步）
