# Sprint 10 设计稿 —— F-14-19 大纲日期列可编辑（开始 / 结束 + 日历弹层）

> 2026-10-22 · 状态：待评审
> 用户需求原文：① 在左边的开始和结束日期都需要可以编辑；② 采用日历组件的方式，让用户可以快速选择某一天；③ 由 dev-team 设计测试用例并开发实现；④ 新增一个版本（v0.7.0）。
> 复用基础：F-14-10（v0.5.0）检查器日期行 `DateFieldRow` + 月历弹层 `CalendarPopover`（两组件均不持有 store，纯值 + 闭包注入）。

## 1. 现状

- 大纲列 `start` / `finish` 只读：`OutlineTable.swift:173-176` → `dateCell(_:)`（:199-207）纯 `Text`。
- 列宽 78pt、行高 28pt、单元格 `.clipped()`（`OutlineTable.swift:112`、`DesignTokens.swift:11`）⇒ **不能内联展开日历**，必须 popover。
- 列降级：`outlineWidth < 376` 不显示 `start`、`< 454` 不显示 `finish`（`Snapshots.swift:36-50`）——列不存在即无入口，不需要额外处理。
- 写回动作已冻结（v0.5.0）：`setTaskStart(UUID, Date?)`（写意图 `startDate`，nil=清除）、`setTaskFinish(UUID, finish:start:)`（写 `durationDays`，排他端点，带陈旧起点与"结束须晚于开始"二次校验）；撤销键 `task-start-*` / `task-finish-*`，已有 18 例覆盖。

## 2. 语义裁定（关键）

| 列 | 显示 | 编辑写回 | 禁用 |
|---|---|---|---|
| 开始 | `scheduledStart`（排期结果，保持现状，与画布对齐） | `startDate` 意图值（`.setTaskStart`），可「清除」 | 群组（聚合只读） |
| 结束 | `scheduledFinish`（排期排他端点） | `durationDays`（`.setTaskFinish`，start 传当前排期起点） | 群组 / 里程碑 / 无排期 |

- **「开始列显示排期、编辑意图」的口径差异照旧**（F-14-10 design.md:28 已明示）：用户选 10/1 但排期因依赖推到 10/5 时，列里显示 10/5。UI 用 `.help("设置为最早开始日期；依赖可能使排期后移")` 说明，不引入提示弹窗。
- 结束列最小可选日 = `ScheduleDateMath.minimumFinish(start: scheduledStart, kind:)`（普通任务起点次日；里程碑禁用）。
- 结束列不提供「清除」（持续时间不可为空），开始列提供清除（回落为自动排期）。

## 3. 架构

### 3.1 可测策略（KaidoPresentation 新文件 `OutlineDateEditing.swift`）

```swift
public enum OutlineDateEditing {
    public static func isEnabled(column: OutlineColumn, row: PlanRow) -> Bool
    public static func disabledReason(column: OutlineColumn, row: PlanRow) -> String?
    public static func minimumDate(column: OutlineColumn, row: PlanRow, calendar: Calendar = .current) -> Date?
}
```

视图只查策略，不写规则 —— 群组/里程碑/无排期三类禁用与最小日全部可在纯函数测试里锁定。

### 3.2 视图（`OutlineTable.swift` 内新增 `private struct OutlineDateCell`）

- 外观与现 `dateCell` 一致（`Display.date`、`monospacedDigit`、逾期色、选中色）。
- 点击 → 先 `store.dispatch(.select(row.id))`（保持行选中同步），再开 popover。
- popover：`attachmentAnchor: .rect(.bounds)`、`arrowEdge: .bottom`，内容为现成 `CalendarPopover`（不改造）；
  选中值传列当前显示值；开始列 `allowsClear: true`、quickActions 全部；结束列 `allowsClear: false`、minimumDate 由策略给出。
- 禁用态：灰字 + `.help(原因)`，点击无弹层（不静默无反应）。
- 状态：单元格内 `@State isPresented` + `@State visibleMonth`（翻月不改值、重开保留），独立于标题编辑的 `editingTaskID`，不复用其焦点。

### 3.3 行接线

`cell(_:)` 的 `.start` / `.finish` 分支替换为 `OutlineDateCell(...)`；提交分别 dispatch `setTaskStart` / `setTaskFinish`（store 层零改动，撤销粒度天然正确）。

## 4. 测试计划（dev-tester 产出）

| 层 | 用例 |
|---|---|
| 策略纯函数 | start：普通/群组；finish：普通/群组/里程碑/无排期；minimumDate：普通=起点次日、里程碑=起点、无起点=nil；跨 DST 日历下仍为整天 |
| Store 集成 | 已有 `Sprint8TaskDateActionTests` 覆盖写回；补一条「大纲路径与检查器路径同源」断言（同一动作、同一撤销键） |
| 渲染 | `OutlineDateCell` 为 private，不单独渲染；由既有 GUI 离屏用例保证大纲整体不回归 |
| 回归 | A7 基线、全量绿 |

## 5. 风险

| # | 风险 | 预案 |
|---|---|---|
| R1 | 单元格点击与整行 tap / 拖拽重排手势竞争 | 单元格内 tap 手势（内层优先），并主动 dispatch select 保持选中同步；拖拽仍需从非日期区域起手 |
| R2 | 结束提交命中「排期已变化」校验（快照起点与 Store 判定不一致） | 传 `row.scheduledStart`（同一快照源）；若命中，Store 既有提示文案已覆盖 |
| R3 | 亚日持续时间导致结束格「已选中但不可选」 | 显示值沿用 `DateFieldValueMath.clampedFinish` 口径（与检查器一致） |
| R4 | 窄窗列消失后用户找不到入口 | 检查器「开始/结束」行仍在（F-14-10），文档说明两处同源 |
