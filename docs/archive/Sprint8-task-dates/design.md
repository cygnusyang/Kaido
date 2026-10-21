# Sprint 8 设计稿 —— F-14-10 任务起止日期可自定义（检查器日历）

> 2026-10-21 · 状态：待评审（含 3 条需 lead 裁定项，见 §7）
> 依据：`docs/archive/Sprint8-task-dates/scope.md`（用户 2026-10-21 确认的三条决策）、
> `docs/design/ui-redesign.md` §6.1 检查器、`docs/features/02-inspectors-scheduling.md` F-22-04
> 发版目标：v0.5.0（feature 级）

## 0. 结论先行

1. **字段映射**：「开始」= `TaskItem.startDate`（用户意图，可清除）；「结束」= 计划结束
   `scheduledFinish`（排他端点，**不可清除**，编辑后改写 `durationDays`）；`dueDate` 语义一字不改。
2. **写回零引擎改动**：本 Sprint 只动表现层（`KairoPresentation`）与应用层（`WorkspaceStore` + 检查器视图），
   `KairoCore` 零改动，`.kairo` 格式版本不变、无新增字段。
3. **结束 → 持续时间的唯一换算**：`duration = dayOffset(scheduledStart → 选中日)`，日粒度整数天，下限 1 天；
   日历把 `start + 1 天` 之前的日子直接置灰（非法输入不可达），Store 再校验一次（负路径）。
4. **两个 coder 的文件范围完全互斥**（§5）：core 独占 `Sources/KairoPresentation/**` + `WorkspaceStore.swift`，
   ui 独占 `Workspace/Inspector/**` + `Display.swift`。唯一串行门禁是「接口壳先落地」（§5.2 Phase A）。
5. **必须先看的风险**：`ScheduleEngine` 目前**不消费**每任务的 `startDate`（只用作无项目开始日期时的全局锚点），
   因此本 Sprint 上线后编辑「开始」**不会移动画布条体**。这是 v0.4.0 遗留缺陷（画布拖条同病），
   需 lead 裁定是否在本版一并修（§7 E1）。设计已把改动点收敛到 Store 内一个函数，两种裁定都可落地。

## 1. 范围与裁定

### 1.1 字段映射表（权威）

| 检查器行 | 显示值 | 编辑写回 | 可清除 | 禁用条件 | 与既有列的关系 |
|---|---|---|---|---|---|
| **开始** | `TaskInspector.startDate`（本次新增快照字段） | `TaskPatch.startDate = .set/.clear` | ✅ | 群组（`isAggregate`） | 大纲「开始」列是**排期结果**，与本行不同源，见 §1.2 |
| **结束** | `scheduledFinish`；无排期时回退 `startDate + durationDays` | `TaskPatch.durationDays = .set(finish − scheduledStart)` | ❌ | 群组；里程碑；无起点（`scheduledStart == nil && startDate == nil`） | 与大纲「结束」列、画布条尾**同源同口径** |
| 持续时间 | `durationDays` | `TaskPatch.durationDays`（既有 `setDuration`） | ✅（既有） | 群组；**里程碑（新增）** | 与「结束」写同一字段，互为逆运算 |
| 投入 / 宽延 | 只读 | — | — | — | 不变 |
| 截止日期 | `dueDate` | `TaskPatch.dueDate`（既有 `setDueDate`） | ✅ | — | **语义不改**，仍只用于风险提示 |

「开始」行保留只读「计划开始」的可见性：当 `scheduledStart` 与 `startDate` 相差 ≥ 1 天时，行下显示副行灰字
「计划开始 2025-11-05」。原两条只读行「计划开始／计划结束」删除（其值已并入上表两行的主值/副行），
避免同一面板出现重复日期行。

### 1.2 为什么两行不同源（术语裁定）

术语规约（`02-inspectors-scheduling.md` 开头）已区分「开始＝用户输入」与「计划开始＝排期结果」。
本设计严格沿用：检查器「开始」是**意图输入口**，「结束」是**排期输出口**——因为结束的写回恒为「改写持续时间」，
它必须锚定一个真实起点才有定义；锚定排期起点（`scheduledStart`）可保证「我选的日期 = 面板显示的日期」。
锚定意图起点（`startDate`）在依赖推后场景下会让用户选了 11-06 却看到 11-09，属不可接受。

> **需 lead 裁定 E2**：若裁定「结束」改按含端（用户直觉：结束 11-02 = 覆盖 11-02 全天）显示，
> 需同步大纲结束列、画布条尾标签、CLI `tasks` 输出三处口径，范围扩到 `KairoCore/Query` 与 `KairoCLI`。

### 1.3 finish 排他端点（沿用既有口径，明确写死）

引擎口径：`finish = start + duration`，条体覆盖 `[start, finish)`。故 1 天任务 `start=11-02` →
`finish=11-03`，条体只覆盖 11-02 当天。

日历上「结束」字段的**选中日就是 finish 本身**，不是最后覆盖日。为了让这一点不被误读：

- 弹层底部预览行固定显示「`开始日 – 结束日` · N 天」，如「11-02 – 11-03 · 1 天」；
- 结束字段的 `helper` 在打开弹层时显示「结束日不含当天」；
- 结束日历的**最小可选日 = 起点 + 1 天**（排他），选不到 `≤ 起点` 的日子 —— 零长度输入在 UI 层不可达。

里程碑：`duration = 0` → `finish == start`，结束行只读显示该日并禁用（tooltip「里程碑无持续时间」）。

### 1.4 换算公式与取整/夹取规则

```
durationDays = Double(dayOffset(from: startOfDay(start), to: startOfDay(finish)))
```

| 规则 | 口径 |
|---|---|
| 粒度 | 日粒度整数天；选中日先 `startOfDay` 归一（丢弃时分秒），再整日相减 |
| 时区/日历 | `Calendar.current`（`WorkspaceStore` 用 gregorian + 当前时区；换算只涉及日界线，二者在常规环境等价）。日粒度按日历整日相减，**不用 `86_400` 秒除**（避免夏令时差 1 天） |
| 下限 | 1 天。`finish ≤ start` → `durationDays(start:finish:)` 返回 `nil`，Store 拒绝写入 |
| 上限 | 无（日历年可导航；不设 `maximumDate`） |
| 取整 | 无二次取整（整日相减天然整数）。既有小数 duration（如 2.5）经本行编辑后变整数天——弹层预览行明确显示「2.5 天 → 3 天」 |
| 里程碑 | `duration` 恒 0；结束行禁用，不产生写回 |
| 群组 | 两行均只读（沿用「群组字段由子任务聚合，只读」） |
| `start` 取值 | `scheduledStart ?? startDate`；两者皆 nil → 结束行禁用 |

### 1.5 边界处置与文案口径

| 场景 | 检测点 | 处置 | 文案 |
|---|---|---|---|
| 无排期（环 / 空群组） | `hasSchedule == false` | 「开始」仍可编辑（写意图）；「结束」禁用 | 「无排期（`Display.unscheduledReason`），无法设置结束」 |
| 结束 ≤ 开始 | 日历 `minimumDate = start + 1d` | 该日置灰不可点 | tooltip「结束须晚于开始，至少 1 天」 |
| 非法写回（越权/陈旧快照） | Store `durationDays(start:finish:) == nil` | 拒绝写入、不产生撤销点 | 弹窗「结束日期必须晚于开始日期」 |
| 用户清空开始 | 弹层「清除」 | `startDate = .clear` | 无提示（字段回到「未设置」占位） |
| 用户清空结束 | — | **不提供**（结束不可清除） | — |
| 开始晚于计划结束 | ~~视图比较~~ **E1-C 后不可达**（引擎保证 `scheduledStart ≥ startDate` 且 `scheduledFinish ≥ scheduledStart`） | 不呈现；该分支已于审查 M-5 删除 | — |
| 依赖冲突 / 约束违例 | 既有 `ViolationEngine` 输出 | **不阻断写入**（与 `setDueDate`/`setDuration` 一致） | 违例区既有文案，不新增 |
| 项目未设开始日期 | 引擎 `ScheduleAnchor.derived == true` | 不阻断；文档登记为回归风险 R2（改最早任务开始会平移整条时间轴） | 本版不加 UI 提示 |
| 清除开始后 | `startDate = nil` | 副行「计划开始」随之消失（排期不变） | — |

## 2. 冻结接口

### 2.1 WorkspaceAction 新增两个 case

```swift
// Sources/KairoPresentation/WorkspaceAction.swift —— 任务编辑区

/// 「开始」字段：写 `startDate`（用户意图锚点，与画布拖条同一字段）。`nil` = 清除。
case setTaskStart(UUID, Date?)

/// 「结束」字段：`finish` 为排他端点；`start` 为本次换算采用的排期起点
/// （视图传 `scheduledStart ?? startDate`，不自行做除法）。Store 折算后只写 `durationDays`。
case setTaskFinish(UUID, finish: Date, start: Date)
```

签名理由：把「结束 → 持续时间」的换算放在 Store + 纯函数，视图只搬运日期；
同时 `start` 随 action 显式传入，使 Store 不依赖检查器快照（`WorkspaceStore` 不持有 `InspectorSnapshot`，已核实）。

### 2.2 WorkspaceStore 路由与撤销粒度

```swift
case .setTaskStart(let id, let date):
    update(id: id, mergeKey: "task-start-\(id)") {
        var patch = TaskPatch()
        patch.startDate = date.map(FieldPatch.set) ?? .clear
        try self.session.updateTask(id: id, patch: patch)
    }

case .setTaskFinish(let id, let finish, let start):
    guard let duration = ScheduleDateMath.durationDays(start: start, finish: finish) else {
        alertMessage = "结束日期必须晚于开始日期"     // 不 pushUndo、不写库
        return
    }
    update(id: id, mergeKey: "task-finish-\(id)") {
        var patch = TaskPatch()
        patch.durationDays = .set(duration)
        try self.session.updateTask(id: id, patch: patch)
    }
```

- **一次编辑 = 一步撤销**：每次提交各产生一个撤销点；同字段 500ms 内连点按既有 `pushUndo` 规则合并（`WorkspaceStore.swift:658-676`，无需改动）。
- 非法路径在 `update` 之前返回 → 无撤销点、无草稿残留。
- `mergeKey` 与画布拖拽的 `canvas-move-*` / `canvas-resize-*` 不共用，避免检查器编辑与拖拽互相合并。
- **裁定点若变成 E1 方案 C**（引擎消费 `startDate`）：只在 `setTaskStart` 分支内追加一行 `patch.constraint = ...`（或不做），
  视图与纯函数零改动。

### 2.3 KairoPresentation 新增纯日期工具（新文件，仅依赖 Foundation）

`Sources/KairoPresentation/ScheduleDateMath.swift`：

```swift
public enum ScheduleDateMath {
    /// 归一为当天零点（`calendar.startOfDay`）。
    public static func startOfDay(_ date: Date, calendar: Calendar = .current) -> Date

    /// 两个日期相差的整日数（先各自归一到零点；可为负）。
    public static func dayOffset(from: Date, to: Date, calendar: Calendar = .current) -> Int

    /// 排他端点 → 持续时间天数。`finish <= start` 返回 nil（非法）；否则 `Double(dayOffset)`（≥ 1）。
    public static func durationDays(start: Date, finish: Date, calendar: Calendar = .current) -> Double?

    /// 持续时间 → 排他端点：`start + duration` 天。`duration <= 0` 时返回 `startOfDay(start)`。
    public static func finish(start: Date, durationDays: Double, calendar: Calendar = .current) -> Date

    /// 日历最小可选结束日：普通任务 `start + 1 天`；里程碑 `start`（不可编辑，调用方禁用）。
    public static func minimumFinish(start: Date, kind: TaskKind, calendar: Calendar = .current) -> Date
}
```

`Sources/KairoPresentation/CalendarGrid.swift`（6×7 网格模型，视图只渲染、不自算日历）：

```swift
public struct CalendarMonthGrid: Equatable, Sendable {
    public static let rows = 6
    public static let columns = 7

    public let firstDay: Date          // 当月 1 日（零点）
    public let days: [Date]            // 42 项，从网格首日（当月 1 日所在周的周首）起
    public let calendar: Calendar

    public func isInMonth(_ day: Date) -> Bool
    public func isWeekend(_ day: Date) -> Bool
    public func isSameDay(_ lhs: Date, _ rhs: Date) -> Bool
    public func month(offsetBy months: Int) -> CalendarMonthGrid
    public func date(year: Int, month: Int, day: Int) -> Date?   // 快捷项「今天 / 下周一」定位
}

public enum CalendarGrid {
    /// 含该日的月份网格；`firstWeekday` 跟随 `calendar.firstWeekday`（用户系统设置）。
    public static func month(containing date: Date, calendar: Calendar = .current) -> CalendarMonthGrid
}
```

约束：这两个文件**不得 import SwiftUI / AppKit**（保持 KairoPresentation 的纯数据层性质，可进 `KairoPresentationTests`）。

### 2.4 TaskInspector 快照新增一个字段

`Sources/KairoPresentation/InspectorSnapshots.swift`：`public var startDate: Date?`，`public init` 末尾追加带默认值
`startDate: Date? = nil`（源码兼容，所有既有调用点无需改）。`Presenter.makeTaskInspector` 传 `task.startDate`（群组传 `nil`）。

### 2.5 视图组件对 store 的唯一依赖面

`Apps/macos/Sources/Workspace/Inspector/DateFieldRow.swift` 中两个新组件**不持有 `WorkspaceStore`**：

```swift
struct DateFieldRow: View {
    let label: String
    let value: Date?                 // 主值，行内渲染 YYYY-MM-DD
    let placeholder: String          // value == nil 时的占位（如「未设置」）
    let helper: String?              // 副行灰字（如「计划开始 2025-11-05」）
    let isEnabled: Bool
    let disabledReason: String?      // 禁用 tooltip
    let minimumDate: Date?           // 含；结束行传 start + 1 天
    let maximumDate: Date?           // nil = 不限
    let allowsClear: Bool
    let quickActions: [DateQuickAction]
    let onCommit: (Date?) -> Void    // nil 只可能来自「清除」（allowsClear 为真时）
}

enum DateQuickAction: CaseIterable { case today, nextMonday, plusWeek }
```

唯一接线点：`TaskInspectorContent`（既有 `InspectorView.swift`）把 `onCommit` 接成
`store.dispatch(.setTaskStart(...))` / `store.dispatch(.setTaskFinish(...))`。
→ core 侧改动（action 签名、纯函数）与 ui 侧（组件、渲染）可独立编译验证。

### 2.6 依赖方向（不变）

```
Apps/macos  (InspectorView → DateFieldRow → CalendarPopover)
   │  只读 TaskInspector 快照 + dispatch WorkspaceAction
   ▼
KairoPresentation (WorkspaceAction · ScheduleDateMath · CalendarGrid · TaskInspector)
   │
   ▼
KairoCore (ScheduleEngine · TaskItem)   ← 本 Sprint 零改动
```

无新增跨层引用；`KairoCore` 不感知 UI 概念。**分层违规自查：通过**。

## 3. 日历 Popover 组件规格

### 3.1 结构与尺寸

```
┌─────────────────────────────┐  236 × 300，圆角 8，边框 separator 0.5pt
│ ‹     2025 年 11 月      ›  │  头部 30pt（左/右 20×20 点击区）
│ 一  二  三  四  五  六  日  │  星期表头 18pt（一周起始跟随系统）
│ 27  28  29  30  31   1   2  │  6 行 × 30pt，单元格 30×30
│  3   4   5   6   7   8   9  │
│ ...                         │
│ 11-02 – 11-05 · 4 天        │  预览行 18pt
│ [今天] [下周一] [+1 周] [清除]│  快捷区 30pt
└─────────────────────────────┘
```

- 弹性：宽度不随检查器宽度变化（检查器 280–420，236 固定可容纳）；
- 锚点：`.popover(attachmentAnchor: .rect(.bounds), arrowEdge: .bottom)`，附着在字段行的整行命中区；
  屏幕边缘由系统翻转，不自算；
- 弹出层级：仅当字段可用（`isEnabled`）时可开；禁用行点击不弹层，悬停显示 tooltip。

### 3.2 状态

| 状态 | 定义 | 呈现 |
|---|---|---|
| 今天 | `isSameDay(day, today)` | 1pt `accentStrong` 描边圆环；文字 `accentStrong` |
| 选中 | `isSameDay(day, selection)` | 实心 `selection` 圆角 6 底；文字 `textPrimary` |
| 非本月 | `!isInMonth(day)` | 灰显 `textSecondary` × 0.45；**可点**（点了顺带翻月） |
| 周末 | `isWeekend(day)` | 文字降为 `textSecondary`（不做色块，避免与今天环冲突） |
| 越界 | `day < minimumDate` 或 `> maximumDate` | 禁用：`textSecondary` × 0.3，不可点、不可聚焦 |
| 键盘焦点 | 方向键移动 | `accentBase` 1.5pt 内描 + `focusRingOuter` 外描 |
| 浏览月 | 本地 `@State visibleMonth` | 与选中解耦：翻月不改变选中 |

**重复打开保留上月视图**：`visibleMonth` 存于 `DateFieldRow`（视图生命周期内保留）；
仅当 `value` 相对上次提交发生了外部变化（撤销、画布拖拽、其他窗口编辑）时，重开重置到 `value` 所在月；
`value == nil` 时重置到今天所在月。**该状态不写入 `WorkspaceViewState` / 偏好**，重启回落。

### 3.3 交互

| 触发 | 行为 |
|---|---|
| 点击字段行 | 打开弹层（焦点落在选中日；无选中落今天） |
| 再次点击字段行 / 点击外部 | 关闭，不提交 |
| 点击某日 | 立即提交并关闭（结束行提交 `start = 当前排期起点`） |
| `←`/`→`/`↑`/`↓` | 焦点日移动 ±1 天 / ±7 天；跨月自动把 `visibleMonth` 翻过去 |
| `Return` / `Space` | 提交焦点日 |
| `Esc` | 关闭，不提交（`.onExitCommand`） |
| `Tab` | 依次循环「上个月 → 下个月 → 网格 → 今天 → 下周一 → +1 周 → 清除」（按视觉顺序，与 §3.4 一致；网格作为单一焦点停靠点，42 格不产生 42 个 Tab 停靠点）。**lead 裁定 2026-10-21**：§3.3 原文与 §3.4/AC-S8-14 冲突，以本条为准 |
| 快捷「今天」 | 提交今天（若早于 `minimumDate` 则该项禁用） |
| 快捷「下周一」 | 提交下一个周一（今天即周一时为 +7 天）；早于 `minimumDate` 则禁用 |
| 快捷「+1 周」 | 提交 `(selection ?? today) + 7 天` |
| 快捷「清除」 | 仅 `allowsClear` 时出现，提交 `nil` 并关闭 |

### 3.4 无障碍

- 字段行：`accessibilityElement(children: .combine)`；
  label「开始日期，2025年11月2日」（无值 →「开始日期，未设置」）；hint「打开月历选择日期」；
  `accessibilityValue` 同 label 的日期部分；禁用时 hint 为 `disabledReason`。
- 网格：`accessibilityElement(children: .contain)`，label「2025 年 11 月月历」；每格 label
  「11 月 2 日，星期日，今天，已选中」/「10 月 27 日，不在本月」；禁用格加「不可选」+ `accessibilityHint` 说明原因。
- 快捷区按钮各自独立可聚焦，label 用可见文案（「今天」「下周一」「+1 周」「清除开始日期」）。
- 焦点顺序：头部导航 → 网格 → 快捷区（视觉顺序与 tab 顺序一致）。
- 减弱动态效果（`accessibilityReduceMotion`）：翻月不做过渡动画。

### 3.5 深浅色 token 映射（全部复用现有 token，禁止字面色）

| 元素 | DesignTokens 属性 | 备注 |
|---|---|---|
| 弹层背景 | `surfaceElevated` | 与检查器 `surfaceBase` 形成层次 |
| 弹层边框 | `separator` | 0.5pt |
| 月份标题 | `textPrimary`（`bodyFontSize`, semibold） | — |
| 月份导航箭头 | `textSecondary` | hover 底 `hoverOverlay` |
| 星期表头 | `textSecondary`（`captionFontSize`） | — |
| 本月平日文字 | `textPrimary` | — |
| 本月周末文字 | `textSecondary` | 周末弱化 |
| 非本月文字 | `textSecondary` × 0.45 | 可点，翻月 |
| 今天描边 | `accentStrong`（1pt） | — |
| 今天文字 | `accentStrong` | 选中时由选中态覆盖 |
| 选中底 | `selection` | — |
| 选中文字 | `DesignTokens.semanticText(.textPrimary, isSelected: true)` | 沿用 §2.9 规则 |
| 悬停底 | `hoverOverlay` | — |
| 禁用文字 | `textSecondary` × 0.3 | 越界日 |
| 键盘焦点环 | `accentBase` 1.5pt + `focusRingOuter` | — |
| 预览行 | `textSecondary`（`captionFontSize`） | — |
| 快捷按钮文字 | `accentStrong` | 禁用时 `textSecondary` |
| 清除按钮 | `textSecondary` | 与既有 `OptionalDateRow` 的 `xmark.circle` 一致 |

**不新增 token**：`DesignTokens.swift` 本 Sprint 零改动（见 §5 文件清单），避免与其它并行工作冲突。

## 4. 组件替换范围

- 新增 `DateFieldRow`（日历版）后，**删除** `InspectorView.swift` 内的私有 `OptionalDateRow`，三处调用改用新组件：
  任务页「截止日期」、项目页「开始 / 结束」。理由：同面板内不允许出现两套日期控件（原生 `DatePicker` 与月历）。
  三处的 `onChange` 闭包与 dispatch 目标**一字不改**（`setDueDate` / `setProjectStart` / `setProjectEnd`）。
- 行内日期格式统一为 `YYYY-MM-DD`（新增 `Display.isoDate(_:)`），**不改** `Display.date`（`yyyy/M/d`），
  以免影响大纲列、违例文案等既有输出。

## 5. 并行改动清单（文件互斥）

### 5.1 归属

**dev-coder-core**（`Sources/` + `WorkspaceStore`）

| # | 文件 | 改动 |
|---|---|---|
| C1 | `Sources/KairoPresentation/WorkspaceAction.swift` | 新增 `setTaskStart`、`setTaskFinish`（§2.1 精确签名） |
| C2 | `Sources/KairoPresentation/ScheduleDateMath.swift` | **新建**（§2.3） |
| C3 | `Sources/KairoPresentation/CalendarGrid.swift` | **新建**（§2.3） |
| C4 | `Sources/KairoPresentation/InspectorSnapshots.swift` | `TaskInspector.startDate`（默认 nil） |
| C5 | `Sources/KairoPresentation/Presenter.swift` | `makeTaskInspector` 传 `task.startDate` |
| C6 | `Apps/macos/Sources/WorkspaceStore.swift` | dispatch 两个分支（§2.2，含非法拒绝） |
| C7 | `Tests/KairoPresentationTests/ScheduleDateMathTests.swift` | **新建** |
| C8 | `Tests/KairoPresentationTests/CalendarGridTests.swift` | **新建** |
| C9 | `Tests/AppTests/Sprint8TaskDateActionTests.swift` | **新建**（store 路由 / 撤销 / 拒绝） |

**dev-coder-ui**（`Apps/macos/Sources/Workspace/Inspector` + `Display`）

| # | 文件 | 改动 |
|---|---|---|
| U1 | `Apps/macos/Sources/Workspace/Inspector/DateFieldRow.swift` | **新建**：`DateFieldRow` + `CalendarPopover` + 快捷区（§3） |
| U2 | `Apps/macos/Sources/Workspace/Inspector/InspectorView.swift` | 排期区接线（开始/结束/持续时间/截止）；删 `OptionalDateRow`；项目页三处改用新组件 |
| U3 | `Apps/macos/Sources/Workspace/Display.swift` | 新增 `isoDate` / `monthTitle` / `weekdaySymbols` / `dayLabel` |
| U4 | `Tests/AppTests/Sprint8DateFieldRenderTests.swift` | **新建**（离屏渲染 + 禁用态/深色） |

> 互斥核对：core 的 C1–C9 与 ui 的 U1–U4 **无交集文件**。`Display.swift` 归 ui（core 不碰）；
> `WorkspaceStore.swift` 归 core（ui 不碰）。

### 5.2 依赖顺序与门禁

```
Phase A（串行，core 独占，短）   C1 → C2/C3 → C4/C5 → C6
        ▲ 门禁：全树可编译（新 case 已在 store 分支消费），UI 方可编译验证
Phase B（并行）
        core: C7/C8/C9   ∥   ui: U1 → U2/U3 → U4
Phase C（联调，串行）
        J1 字段接线后手动/渲染验证；J2 全量回归
```

- ui 可在 Phase A 期间**先写** `DateFieldRow.swift` 的静态部分（按 §2.3 冻结签名），Phase A 落地即可编译；
  但**不得**提前改 `InspectorView.swift`（会引用不存在的 action case，打断全树编译）。
- 联调点 J1：`TaskInspector.startDate` 就绪后，UI 才能渲染「开始」主值（此前恒为 `nil` → 显示占位）。
- 联调点 J2：`minimumDate` 必须由 UI 计算（`ScheduleDateMath.minimumFinish`），Store 不做二次夹取——
  避免两边各夹一次导致「选了 11-05 落库成 11-06」。

## 6. 测试矩阵

| 层 | 用例 | 归宿 |
|---|---|---|
| 纯函数 | `durationDays`：1 天 / N 天 / finish<start→nil / finish==start→nil / 跨月跨年 / 带时分秒输入归一 | KairoPresentationTests（C7） |
| 纯函数 | `finish`：整数天 / 小数 2.5 天 / duration 0 / 负值回落 startOfDay | C7 |
| 纯函数 | `dayOffset` 跨夏令时（同一时区前后调整两个月）仍为整日数 | C7 |
| 纯函数 | `minimumFinish`：任务 +1 天、里程碑 = 起点 | C7 |
| 网格 | 42 格、首格为当月 1 日所在周周首、`firstWeekday` = 周日/周一两种设置、2 月/31 天月、跨年翻月、`isInMonth`/`isWeekend` | KairoPresentationTests（C8） |
| Store | `setTaskStart`：写入 / 清除 / 群组不拦截（由 UI 禁用，Store 保持可写） | AppTests（C9） |
| Store | `setTaskFinish`：改写 duration 且 startDate 不变；`finish ≤ start` → alert + 数据不变 + 无撤销点 | C9 |
| Store | 撤销：一次提交 = 一步；同字段 500ms 内两笔合并为一步；与 `canvas-move-` 不互相合并 | C9 |
| Store | 结束编辑后 `scheduledFinish == 选中日`（无依赖、projectStart 已设的场景） | C9 |
| 渲染 | 字段行有值/无值/禁用三态画面不同且非空白（`distinctColorCount ≥ 20`） | AppTests（U4） |
| 渲染 | 月历弹层浅色 / 深色渲染非空白；选中态与今天态画面有差异 | U4 |
| 渲染 | 群组任务页：开始/结束两行不出现可点击样式（画面与只读态一致） | U4 |
| 负路径 | 非法写回不弹崩溃（alert 路径）；越界日不可点（由 `minimumDate` 单测覆盖，渲染只判非空白） | C7/C9/U4 |
| 回归 | 全量 `swift test` 只增不减；画布拖拽用例（`GanttCanvasEditTests`）全绿 | 全量 |

残余不可自动化项（沿用 D-015 体例登记）：真实 popover 系统动画、物理键盘事件派发、VoiceOver 实际播报。

## 7. 需 lead 裁定项（不自行改决策）

### E1（阻塞价值）`startDate` 不驱动排期 → 编辑「开始」不移动条体

**事实**：`ScheduleEngine.forwardPass` 只取 `max(锚点, 时限下界)`，**从不消费任务的 `startDate`**
（`ScheduleAnchor` 仅在项目未设开始日期时用全体 `startDate` 的最小值做全局锚点）。
演示数据设了 `projectStart`（`SeedData.swift:122`），故 v0.4.0 画布拖条改期在当前实现下**不会移动被拖的条体**——
这是既有缺陷（登记建议 D-021），不是本 Sprint 引入。

**影响**：本设计按 scope 决策 1 写 `startDate`，则「开始」可存、可回显、可导出，但画布无反应；用户很可能判定功能无效。

**备选**

| 方案 | 做法 | 代价 | 风险 |
|---|---|---|---|
| A（本稿基线） | 只写 `startDate` | 零 | 功能观感无效（除「无项目开始日期的项目」外） |
| B | 写 `startDate` + `constraint = .startNoEarlierThan(date)` | Store 一个函数，视图零改动 | 语义混用；清除开始需清 constraint（会丢用户原时限）；画布拖条仍不改 constraint → 拖拽被时限钉死；`ViolationEngine` 会为带依赖任务抛 `constraint_is_dependency` 噪声 |
| C（推荐） | 引擎 `forwardPass` 把显式 `startDate` 作为开始下界 | `Sources/KairoCore/Schedule/ScheduleEngine.swift` 一处 + 全量基线重算 | **不可逆观感**：所有既有项目里被 0.4.0 拖拽写入却从未生效的 `startDate` 会突然生效，任务集体跳位；需发版说明 + 可能需一次「按排期结果回写意图」迁移工具 |

**建议**：若 v0.5.0 目标包含「用户能真正改开始日期」，选 C 并单独排一个「迁移与告知」子任务；
若本版只交付输入路径，选 A 并在界面副行明确「计划开始」与意图的差异，同时把 C 立为下版主线。
**我不自行决定**——见 E1 看板记录。

### E2 finish 排他端点的显示直觉

本稿按 scope 与既有口径：结束字段显示 `scheduledFinish`（1 天任务 11-02 开始 → 显示 11-03）。
若裁定改为「含端显示」（用户直觉：结束 = 任务最后一天），改动点为
`ScheduleDateMath.finish` 使用点 + 大纲「结束」列 + 画布条尾标签 + CLI，跨 3 个模块，范围显著扩大。
**建议**：本版保持排他 + 预览行与 helper 文案消歧（§1.3），不扩范围。

### E3 「清除」的作用范围

scope 写「支持清除」，本稿裁定：**开始可清除，结束不可清除**（有排期的任务必有结束，删除结束等于删持续时间，
语义上属「清除持续时间」而非「清除结束」，两者混用会产生空排期）。截止日期仍可清除（既有）。
**建议**：维持本裁定；若用户坚持要能被清除结束，等价于清除 `durationDays`，需另定文案「清除持续时间」。

## 8. 回归风险

| # | 风险 | 预案 |
|---|---|---|
| R1 | 撤销粒度被 500ms 合并「吃掉」 | 只合并同字段同任务；跨字段永远两步（mergeKey 含字段名） |
| R2 | 项目未设开始日期时，改/清最早任务的 `startDate` 会平移整条时间轴（`ScheduleAnchor` 行为） | 文档登记；本版不加提示，验收走查覆盖 |
| R3 | 用户把「开始」当成「让任务这天开工」→ E1 的观感问题 | 副行「计划开始」常显差异；文案「实际排期仍按依赖与项目开始计算」 |
| R4 | 组件替换波及 `dueDate` / 项目起止 | 三处 `onChange` 闭包与 dispatch 不变；渲染用例覆盖三行 |
| R5 | 里程碑/群组误写入 | UI 禁用 + Store 侧保持可写（与既有一致）；渲染用例断言禁用态 |
| R6 | 弹层打开即触发重算拖慢检查器 | 打开不 dispatch，仅选定提交；排期缓存（D-014）已生效 |
| R7 | 日期格式不统一（`yyyy/M/d` vs `YYYY-MM-DD`） | 新增 `Display.isoDate`，仅新组件使用；不改 `Display.date` |
| R8 | 时区/夏令时导致天数差 1 | 全部走 `Calendar` 归一整日相减，不用 `86_400` 秒除（与引擎的 `addDays` 口径不同处已注明，仅换算层用日历） |

## 9. lead 裁定（2026-10-21 · 用户确认）

| 裁定项 | 结论 | 落地范围 |
|---|---|---|
| E1（startDate 是否驱动排期） | **选 C**：引擎把显式 `startDate` 作为「开始不早于」下界 | 新增 `Sources/KairoCore/Schedule/ScheduleEngine.swift` 改动（归 dev-coder-engine）；画布拖条同时修复；登记 D-021；发版说明登记「既有 startDate 生效导致条体位移」的观感变化 |
| E2（finish 排他显示） | **维持排他**（结束字段显示 finish；预览行 + helper 文案消歧），不扩范围到大纲/画布/CLI | 无额外改动 |
| E3（清除范围） | **维持**：开始可清除、结束不可清除、截止日期仍可清除 | 无额外改动 |

### 9.1 E1 引擎改造的冻结口径

- 作用对象：叶子任务与里程碑（`kind != .group`）；群组仍由子任务聚合，忽略群组自身 `startDate`。
- 取值：`startOfDay(task.startDate)`（日粒度归一）。
- 下界合并：`start = max(项目锚点, 归一后的 startDate, 时限下界, 相关性推出的下界)`；环上任务同样适用。
- 后向传播（latest/slack）不变；`schedulingPolicy` 仍是 ASAP/ALAP 选择，但不突破 startDate 下界。
- 既有测试若断言「startDate 不驱动排期」，属规格变更，需改写并在任务记录中列出测试名与理由（不得静默删除断言）。
- 文档同步：`docs/02-architecture.md` §7「日期语义」条目改口径（startDate = 用户意图 + 排期下界）；`docs/03-roadmap.md` 只由 lead 在发版段更新。
- 迁移/告知：不写数据迁移工具；发版说明 + CHANGELOG「已知观感变化」如实登记：v0.4.0 曾写入但未生效的 `startDate` 在 v0.5.0 起会生效，相关任务可能位移。


### 9.2 审查裁定（2026-10-21）

- **M-1（ALAP/负宽延）**：后向传播**不**夹 `startDate` 下界（保持 §9.1 口径）；当用户设置晚于项目窗口的开始日时，`latest < earliest` 会产生「任务无法安排」错误级违例——语义上成立（该项目窗口内确实排不下），仅文案未点明原因。**本版不改引擎语义**，登记缺陷顺延 v0.5.1 处理文案与宽延展示。
- **M-5**：`startLaterThanPlan` 死分支删除（见 §1.5 修订）。
- **M-8**：渲染区分度门槛收紧到 `differenceRatio > 0.002`（与深浅色 0.3 口径分离，防 D-009 式弱断言）。
