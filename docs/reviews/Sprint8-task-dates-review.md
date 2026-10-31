# Sprint 8 代码审查 —— F-14-10 任务起止日期可自定义（检查器日历）

> 2026-10-21 · 审查者 dev-reviewer · 只审查不修改（未改生产/测试代码，未提交）
> 审查范围：`git diff fb8e75e..HEAD -- Sources/ Apps/ Tests/`（基线 tag v0.4.0 / fb8e75e；HEAD 8f5f4d6）
> 权威依据：`docs/archive/Sprint8-task-dates/scope.md`、`design.md`（§2 冻结接口 / §3 交互 / §9 lead 裁定 E1-C）、`acceptance.md`

## 0. 结论

**打回（有条件）**：无 CRITICAL，3 项 HIGH 需修复或经 lead 书面裁定后方可合并。
引擎下界与写回路径的**设计意图落地正确**（群组/里程碑/环/ALAP 均按设计处理，撤销粒度与非法拒绝符合 §2.2），
但存在一处**可复现的跨层日期口径缺陷**（夏令时下「结束」显示与所选日差一天，实测见 H-1）、
一处**静默改写用户输入的路径**（陈旧起点折算持续时间，H-2），以及**文档交付面缺失**（D-021 未登记 + 规格更新未提交，H-3）。

| 级别 | 条数 | 摘要 |
|---|---|---|
| CRITICAL | 0 | — |
| HIGH | 3 | H-1 夏令时 finish 漂移；H-2 陈旧 start 静默折算；H-3 文档交付面（D-021 / CHANGELOG / 规格未提交） |
| MEDIUM | 8 | ALAP 下界与后向传播分叉、预览行不随候选日、组件硬编码「结束」语义、亚日持续时间、死警示分支、归一不在 Store、epoch 哨兵、渲染断言门槛 |
| LOW | 6 | tooltip 缺失、魔数、预览 N 算法、周一口径、重开月份误判等 |

已执行验证（本机）：

```
swift test                                              → 635 tests / 67 suites 全部通过
swift build -c release -Xswiftc -warnings-as-errors      → Build complete（与 CI 口径一致）
git diff --numstat fb8e75e..HEAD -- Tests/               → 5 个文件全部「只增」，无既有断言被删除/改写
```

## 1. HIGH

### H-1 夏令时下「结束」落点比所选日少一天（跨层日期口径不一致）

- **文件**：`Sources/ZenoCore/Schedule/ScheduleEngine.swift:314`（`scheduledFinish: addDays(selectedStart, duration)`）
  对照 `ScheduleEngine.swift:340-342`（`addDays` = `+ days * 86400`），与 `Sources/ZenoPresentation/ScheduleDateMath.swift:34-57`（日历整日加减）。
- **问题**：S8 新增的换算层用 Calendar 整日相减/相加，而引擎仍用 86 400 秒乘除。`selectedStart` 已被 `startOfDay`
  归一到本地零点，`+ duration * 86400` 一旦跨越夏令时切换就落到前一天 23:00。已实测复现（America/New_York，2025-11-01 起）：

```
duration=3.0  engine=2025-11-03 23:00 -0500   calendar=2025-11-04 00:00 -0500   same=false
duration=5.0  engine=2025-11-05 23:00 -0500   calendar=2025-11-06 00:00 -0500   same=false
```

- **影响**：用户在「结束」日历选 11-04（duration 3），落库 duration 正确，但重新渲染的结束字段显示 2025-11-03
  （`Display.isoDate` 直接格式化时刻）→ **选了 11-04 显示 11-03**，与 AC-S8-06「`scheduledFinish == 选中日`」
  及 AC-S8-07 的 1 天口径直接冲突；同时 `Tests/AppTests/Sprint8TaskDateActionTests.swift:114
  setTaskFinishMakesScheduledFinishMatchSelectedDay` 在 DST 时区会红（本机无 DST 故全绿）。
  设计 R8 只注明「换算层用日历、引擎 addDays 口径不同」，未推演到 finish 漂移这一后果，属**未被裁定覆盖的新缺陷**。
- **建议**：
  1. 引擎侧把 `scheduledFinish` 改为日历加日，或对 `addDays` 结果取 `startOfDay`（`selectedStart` 已归一，只需保证 finish 也是零点）；
  2. 若判定「引擎日期算术整体不动」，则退而求其次：Store 写入前用 `ScheduleDateMath` 双向核对，并在展示层对 `scheduledFinish` 做 `startOfDay` 归一；
  3. 补两条用例：引擎 `ScheduleStartDateBoundTests`（America/New_York 跨 11-01、跨 3 月切换）与 Store 同场景。
- **阻塞理由**：用户可见日期错误 + 直接违反已定稿验收判据；引擎既有「自然日简化」此前不承担 UI 显示契约，现在承担了。

### H-2 `setTaskFinish` 不校验传入 `start` 是否仍是当前排期起点 → 静默按错误起点折算持续时间

- **文件**：`Apps/macos/Sources/WorkspaceStore.swift:552-563`（`case .setTaskFinish`）；
  调用侧 `Apps/macos/Sources/Workspace/Inspector/InspectorView.swift:283-286`（`guard let start = finishStart`）。
- **问题**：设计 §2.1 让视图显式传 `start` 以解耦快照，但 Store 只校验 `finish > start`，
  **从不校验 `start` 与任务当前 `scheduledStart ?? startDate` 是否一致**。视图渲染到点击之间若排期变化
  （撤销/重做、画布拖拽、ALAP 重算、外部文件 `reloadExternal` 合并），`start` 即为陈旧值：
  `duration = finish − 旧起点`，落库后 `scheduledFinish = 新起点 + duration ≠ 用户所选日`，**无告警、占用一个撤销点**。
  这正是任务书点名要查的「静默改用户输入」路径。
- **影响**：AC-S8-06 落点断言在并发/撤销场景下失效；用户会认为字段「没记住我选的日期」；
  AC-S8-05 声称的「双层防线」第二层只防 `finish ≤ start`，不防起点漂移。
- **建议**：Store 分支在 `update` 之前取值复核（`session.scheduleOrCompute()` 或 `session.project?.tasksByID[id]` 已有现成 API）：

```swift
// 建议语义（伪代码）
let current = 当前排期起点(for: id)          // scheduledStart ?? startDate
guard let current, ScheduleDateMath.dayOffset(from: current, to: start) == 0 else {
    alertMessage = "排期已变化，请重新选择结束日期"
    return                                  // 不 pushUndo
}
```

  或直接忽略传入的 `start`、以当前起点重算（把 `start` 降级为 hint）。补一条「陈旧 start 被拒绝/对齐」用例。

### H-3 文档交付面缺失：D-021 未登记、规格更新未提交、CHANGELOG 无 v0.5.0 观感变化

- **文件**：`docs/defects.md`（无 D-021 行，仅 archive 文档提到「建议登记」）；
  `CHANGELOG.md`（最新段仍是 v0.4.0）；`docs/design/ui-redesign.md` 与 `docs/features/02-inspectors-scheduling.md`
  （`git status` 显示 ` M`，**改动只在工作树，未进任何提交**）。
- **问题**：设计 §9.1 明确要求「登记 D-021」「发版说明 + CHANGELOG 如实登记 v0.4.0 曾写入但未生效的 `startDate`
  在 v0.5.0 起生效、相关任务可能位移」；acceptance §0 以 D-021 作为 AC-S8-02 的缺陷关联。当前三项均缺；
  且规格同步若按 HEAD 合并会整体丢失（工作树改动不随 PR 走）。
- **影响**：E1-C 是本 Sprint **唯一影响存量数据观感的改动**（所有项目里被 0.4.0 拖拽写入的 `startDate` 会突然生效、
  任务集体跳位），无 CHANGELOG/发版说明 = 用户侧无告知；D-021 无登记 → 后续回归无从追溯，
  违反 `docs/defects.md` 的 IEEE 829 最小集约定与 AC-S8-20/21 的交付面要求。
- **建议**：① defects.md 补 D-021（严重度/优先级、发现于 S8 设计阶段、修复版本 v0.5.0、
  修复证据 = `ScheduleEngine.swift:196-215,296-318,351-358` + `ScheduleStartDateBoundTests` 用例清单）；
  ② CHANGELOG 增 v0.5.0 段并单列「已知观感变化」；③ 提交两份 `docs/` 改动（或明确由谁在哪个 PR 提交）。

## 2. MEDIUM

### M-1 ALAP/下界与后向传播分叉：负宽延噪声 + `scheduledFinish > latestFinish`

- **文件**：`Sources/ZenoCore/Schedule/ScheduleEngine.swift:296-318`（`selectedStart` 收敛），后向传播 `:246-275` 未消费下界。
- **问题**：选定值被夹到 `startDate` 下界，而 `latestStart/latestFinish/totalSlack` 仍是未夹取结果。
  `Tests/ZenoCoreTests/ScheduleStartDateBoundTests.swift:144 alapTaskNeverStartsBeforeStartDate` 固化了该形态：
  `latestStart = 11-04`、`scheduledStart = 11-20`、`scheduledFinish = 11-21`（> `latestFinish` 11-05）。
  当 `totalSlack < 0` 时 `ViolationEngine.negativeSlackViolations` 抛「任务无法安排：最晚开始早于最早开始」
  （`Sources/ZenoCore/Schedule/ViolationEngine.swift:135-143`）。
- **影响**：用户只是给任务设了个晚于项目结束的开始日，却收到错误级违例，且文案归因于依赖而非其输入；
  `ScheduledTask` 内部出现 `latest < earliest` 的自相矛盾，宽延/画布读数可能对不上。
  E1 把该矛盾的触发面从「时限下界」扩大到「任何显式开始日」。
- **建议**：需 lead 裁定 —— (a) 接受并改违例文案（提示「开始日期晚于项目/时限上界」）；
  或 (b) 后向传播同步夹取 `l.start = max(l.start, bound)`（会改写设计 §9.1「后向传播不变」）。
  无论选哪个，补一条断言固定 `totalSlack` 与该违例的关系。

### M-2 弹层预览行不随焦点日/候选日变化

- **文件**：`Apps/macos/Sources/Workspace/Inspector/DateFieldRow.swift:112`（`preview: preview?(value)` 在打开瞬间求值成 `String`）；`DateFieldRow.swift:428-436`（`previewRow` 只渲染常量）。
- **问题**：`preview` 闭包签名是 `(Date?) -> String?`，但调用方把当时的 `value` 填进去后固化为 `String`；
  方向键移动焦点、悬停其它日时预览行不变。设计 §3.1/§3.2 的意图是「预览候选区间」，AC-S8-07 只校验打开时的文案，
  故当前实现能过判据但达不到交互意图。
- **影响**：按方向键移动焦点时看到的仍是旧区间天数，容易误判排他口径（正是 AC-S8-07 要消除的误解）。
- **建议**：把 `preview` 求值下移到 `CalendarPopover` 内部，用 `focusedDay ?? selection` 每帧计算。

### M-3 组件把「结束」语义硬编码进通用日期行

- **文件**：`DateFieldRow.swift:179-180`（`disabledDayHint`）、`:233`（`boundaryTooltip`）、`:434-436`（`cellHint` 兜底）。
- **问题**：只要 `minimumDate` 或 `maximumDate` 非空就播报「结束须晚于开始，至少 1 天」。该组件同时用于
  「截止日期」「项目开始」「项目结束」（`InspectorView.swift:303-309, 575-589`），一旦这些字段带 `maximumDate`
  （例如项目结束不得早于项目开始）就会给出与字段无关的错误解释。
- **影响**：当前无可达错误播报（这些行不传 bounds），属错误抽象定时炸弹；且「今天早于最小可选日」这类真实场景也缺字段级文案。
- **建议**：把越界文案参数化（`boundaryHint: String?`）由调用方给，组件内不留「结束」字样。

### M-4 亚日（<1 天）持续时间下，结束行的值落在自己的最小可选日之前

- **文件**：`InspectorView.swift:472-483`（`finishValue` / `finishMinimumDate`）。
- **问题**：`durationDays` 可为 0.5（`ScheduleEngine.duration(of:)` 接受任意 `> 0`，投入换算也产生小数）。
  `scheduledFinish = start + 0.5 天` → `finishValue` 显示当天，而 `minimumDate = start + 1 天` →
  该格「已选中但不可选」，预览显示「同一天 · 0 天」。
- **影响**：字段显示一个「存在但不可选」的值，用户无法通过日历复现，且无提示；AC-S8-07 只覆盖 2.5 天。
- **建议**：`finishValue` 取 `max(scheduledFinish, finishMinimumDate)`，或 duration < 1 时给 helper 说明；补 0.5 天用例。

### M-5 `startLaterThanPlan` 警示在 E1 之后不可达（死分支）

- **文件**：`InspectorView.swift:263-272`（渲染）、`:502-506`（判定）。
- **问题**：E1-C 保证 `scheduledStart ≥ startDate` 且 `scheduledFinish = scheduledStart + duration ≥ scheduledStart`，
  故 `startDate > scheduledFinish` 恒假。设计 §1.5 写这条警示时是 E1 方案 A 的语境，裁定 C 之后未同步。
- **影响**：不会误报，但过期文案会误导后续维护者，且该判据实际无法被走查到（AC-S8-03/§1.5）。
- **建议**：删除分支并在设计 §1.5 标注「E1-C 下不可达（由 max 下界保证）」；若想保留提示，改为「计划开始 ≠ 开始」的副行（`plannedStartHelper` 已存在）。

### M-6 `startDate` 的日粒度归一不在 Store/会话层

- **文件**：`WorkspaceStore.swift:545-550`；`Sources/ZenoCommands/ZenoSession.swift:393`（`Self.apply(patch.startDate, to: &task.startDate)` 原样写入）。
- **问题**：AC-S8-01 要求「写入 startOfDay」，但归一只发生在视图（`CalendarPopover.pick`）。任何绕过该视图的入口
  （画布拖拽、将来的 CLI/内联编辑、测试）都会把带时分秒的值原样落库；引擎虽会归一，但文件里存的是脏值。
- **影响**：当前无可见故障（画布路径也归了），属单源缺失；新增入口即出现「同一字段两种精度」。
- **建议**：在 `setTaskStart`（或会话层 startDate 应用点）统一归一，把系统日历作为唯一口径来源；视图归一不作为唯一防线。

### M-7 `startDateLowerBound` 以 1970-01-01 作「无下界」哨兵

- **文件**：`ScheduleEngine.swift:348-358`。
- **问题**：返回 `Date(timeIntervalSince1970: 0)` 表示「无下界」（与既有 `constraintStartLowerBound` 同写法），
  但该值不是 `startOfDay` 归一结果（负时区下是前一天 19:00），语义上与 `dayZero` 混用，
  且 `max(base, …, sentinel)` 依赖「项目不早于 1970」的隐式前提。
- **影响**：无现实故障，但这是新代码里唯一需要读源码才能确认「它是哨兵不是日期」的地方。
- **建议**：改 `Date.distantPast`（或返回 `Date?` 并在调用点 `if let`），保留一行注释。

### M-8 渲染断言的区分度门槛过低

- **文件**：`Tests/AppTests/Sprint8DateFieldRenderTests.swift:157-159, 168-186, 236-240`（多处 `differenceRatio(from:) > 0`）。
- **问题**：`> 0` 只要一个像素不同即通过（抗锯齿噪声也满足），与 AC-S8-18「三态两两可区分」意图相比过松；
  同文件深浅色用了 `> 0.3` 的合理门槛，前后不一致。
- **影响**：禁用态若退化为「文字颜色微变」仍可能通过；重演 D-009（恒真/弱断言）教训。
- **建议**：三态断言改 `> 0.002`，并对禁用态补 `CalendarDayStyle.isSelectable` 的纯逻辑断言（可复用 `finishCalendarDisablesDaysAtOrBeforeStart`）。

## 3. LOW

| # | 文件:行 | 问题 | 建议 |
|---|---|---|---|
| L-1 | `DateFieldRow.swift:88-100` | 禁用行只有副行文案，缺设计 §3.1 要求的「悬停 tooltip」 | 给命中区加 `.help(disabledReason)` |
| L-2 | `DateFieldRow.swift:505-528` | `moveFocus` 用 `steps < 62` 魔数限制跳格 | 提为具名常量并注释（42 格 + 余量） |
| L-3 | `InspectorView.swift:517-526` | 「2.5 天 → N 天」的 N 由**当前值**算，与候选日无关 | 随 M-2 一并改 |
| L-4 | `DateFieldRow.swift:24-31` | 「下周一」硬编码 `weekday == 2`；与「周末弱化」在水周日/非周末体系下口径不一 | 用 `nextDate(after:matching:)` 或注明仅支持默认周末 |
| L-5 | `DateFieldRow.swift:149-155` | 提交被 Store 拒绝后 `knownValue` 已是新值而 `value` 仍旧值，重开被判「外部改动」而重置月份 | 可接受；建议只用 `value` 变化驱动重置 |
| L-6 | `InspectorView.swift:508-515` | 开始行预览用 `durationDays ?? 1`，投入驱动持续时间的任务预览天数不准 | 用 `scheduledFinish` 差值或暴露引擎 duration |

## 4. 测试缺口（按 acceptance.md 编号，不含已覆盖项）

| 判据 | 缺口 | 建议 |
|---|---|---|
| **AC-S8-02** | 引擎层已覆盖（9 例）；**App 层「甘特条体 x 前移 4 天」无自动化**（`futureStartDateMovesScheduledStartAndGanttBar` 待补写） | 落盘时按判据「禁止只验 startDate 回显」实现，用布局结果断言 |
| AC-S8-03 | `plannedStartHelper`（副行「计划开始」）零断言，且是 private 视图计算属性不可测 | 下沉为 ZenoPresentation 纯函数后补 3 例（相等/差 1 天/无排期） |
| AC-S8-05 b/c | 已有（`setTaskFinishRejectsFinishEqualToStart` / `…EarlierThanStart` / `rejectedFinishDoesNotPushUndoPoint`）；**缺「撤销栈深度不变」直接断言**（现为间接证明） | 暴露只读撤销栈深度或断言 `canUndo` 语义 |
| AC-S8-08 b/c | 里程碑/无起点的禁用与文案无自动化；`finishDisabledReason` 为 private 计算属性，只能人工 | 抽出纯函数（kind/isAggregate/finishStart → reason）补 4 例 |
| AC-S8-09 a | 单笔编辑=一步撤销仅被 `rejectedFinishDoesNotPushUndoPoint` 间接覆盖；`eachTaskStartEditIsOneUndoStep`（:181）实测的是**合并**，与用例名不符 | 增一条只 dispatch 一次的用例，并把 :181 更名 `sameFieldEditsWithin500msMergeIntoOneStep` |
| AC-S8-11 | 「持续时间 ↔ 结束」双入口一致性无断言（只有「结束→duration」单向） | 补 `setDuration` 后结束行刷新断言（需先下沉 M-4 的纯函数） |
| AC-S8-16 | 无排期/环上任务「开始仍可编辑、结束禁用」无断言 | 用环夹具补 1 例 |
| AC-S8-17 | 违例不阻断写入无断言 | 构造 `constraint_window_too_narrow` 夹具补 1 例，或按判据如实登记人工 |
| — | **DST 场景全缺**：5 个新测试文件全部使用 Shanghai/UTC 或 `Calendar.current` | 见 H-1，至少补 America/New_York 引擎与 Store 各一例 |
| — | `DateFieldRow` 的 `visibleMonth` 保留策略（§3.2「仅外部改动才重置」）无逻辑层测试 | 状态在视图内，可接受；要测需抽出 `DateFieldRowState` |

**无恒真断言**：抽查 4 个测试文件，期望值均为字面日期（`day(2026,…)`）而非「用被测函数现算」，不构成 D-009 式自证；
`setTaskFinishMakesScheduledFinishMatchSelectedDay`（:114）为跨引擎断言，区分度有效（只是受 H-1 影响会随主机时区变红）。

## 5. 未验证项（不可自动化 / 需真机）

1. **真实 popover**：系统动画、屏幕边缘翻转、点外部关闭不提交（N1）。
2. **物理键盘**：方向键 ±1/±7 与跨月翻页、Return/Space 提交、Esc 不提交、Tab 循环（N2）。
   另注：设计 §3.3 的 Tab 顺序（上个月→下个月→**网格**→今天…）与 AC-S8-14（上个月→下个月→**今天**…→清除→网格）**互相矛盾**；
   实现按视图声明顺序（导航 → 网格 → 快捷区）自然排列，走查前需 lead 先统一口径，否则该项无法判定。
3. **VoiceOver**：字段行/网格/快捷区实际播报与焦点顺序（N3）。label/hint 已按 §3.4 给出，但
   `accessibilityElement(children: .combine)` + `onTapGesture`（非 Button）能否被 VO「激活」打开弹层需实测。
4. **系统 `firstWeekday` 切换后的真实渲染**（N4；纯逻辑已有双设置覆盖）。
5. **R2**：项目未设开始日期时改/清最早任务的「开始」会平移整条时间轴 —— 须人工走查确认「可接受」。
6. **R5 反向**：Store 对群组/里程碑保持可写是刻意的（`setTaskStartOnGroupIsNotBlockedByStore`），
   需确认没有第二入口（菜单/快捷键/CLI）能在 UI 禁用之外触达。

## 6. 正面确认清单（已核对通过）

- **引擎作用面**：下界只作用于 `kind != .group`（`ScheduleEngine.swift:351-358`），群组/里程碑/环/ALAP 四条路径各有用例
  （`groupStartDateIsIgnored` / `milestoneStartDateActsAsBound` / `cycleTaskStartDateDoesNotCrash` / `alapTaskNeverStartsBeforeStartDate`），未误伤；
  `start = max(锚点, 时限, startDate, 相关性)` 顺序正确，早于锚点不回拉（`startDateBeforeProjectAnchorDoesNotPullScheduleEarlier`）。
- **finish 恒等于 start + duration**：`scheduledTasks` 统一由 `selectedStart` 派生（`:314`），消除了 ALAP 走 `l.finish` 的口径分叉；
  ASAP 未回归（`asapTaskSelectionKeepsStartDateBound`）。
- **写回路径**：`task-start-*` / `task-finish-*` 与 `canvas-move-*` / `canvas-resize-*` 互不合并（用例 :209）；
  非法区间在 `update` 之前 return，无撤销点/无草稿（:160-186）；`mergeKey` 含字段名，跨字段两步（:194）。
- **UI 禁用条件**：开始=仅群组；结束=群组→里程碑→无起点（与 §1.5 顺序一致）；持续时间对里程碑新增禁用（`InspectorView.swift:295`）。
- **换算单源**：视图不做除法，`duration = dayOffset` 只在 `ScheduleDateMath`；新增 UI/换算层 `86_400` 0 处（仅引擎既有 `addDays`，见 H-1）。
- **token 单源**：`DateFieldRow.swift` 全文无字面色（`Color(…)`/`.black`/`.white`/`NSColor`/`ColorLiteral` 均 0 命中），
  越界/非本月 0.3/0.45 与 §3.5 一致，选中走 `semanticText(_:isSelected:)`；`DesignTokens.swift` 零改动。
- **分层**：`ScheduleDateMath`/`CalendarGrid` 仅 import Foundation（+模型类型），无 SwiftUI/AppKit；
  `ZenoCore` 改动仅 `ScheduleEngine.swift` + 文档；`.zeno` 无新增字段（`Format*` 用例全绿）。
- **回归**：635/635 通过（含 `GanttCanvasEditTests`），`Tests/` diff 全为新增文件（无断言被改写，AC-S8-21 满足）。
- **安全清单**：本改动无网络、无凭据、无路径拼接、无外部输入解析（日期来自系统日历控件）→ **N/A**；
  未发现越权写入路径（写操作仍全部经 `ZenoSession`，无直接 FileManager 调用）。

## 7. 复审门槛（建议）

1. H-1 修复并有 DST 用例（引擎 + Store）；
2. H-2 补 `start` 一致性校验与用例；
3. H-3 补齐 defects.md / CHANGELOG / 提交规格改动；
4. M-1 由 lead 就「后向传播是否同步夹取」给出书面裁定（阻塞 AC-S8-02 的语义解释，不阻塞编译）；
5. 其余 MEDIUM/LOW 可登记下 Sprint 技术债，但 M-3 / M-5 建议随本次一并清掉（均几行量级）。
