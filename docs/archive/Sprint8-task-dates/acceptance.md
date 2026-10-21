# Sprint 8 验收判据 —— F-14-10 任务起止日期可自定义（检查器日历）

> 2026-10-21 · dev-tester 维护 · 状态：判据表已定稿；可自动化项已落盘并实跑（Tests/AppTests/Sprint8DateAcceptanceTests.swift 共 23 条，结果见 §2「判定方式」列；H-1 / H-2 两条待修复分支合并后复跑）
> 依据（唯一权威，本表不新增需求）：`scope.md`（用户 2026-10-21 三条决策）、`design.md`
> §1 字段语义 / §3 日历交互 / §6 测试矩阵 / §9 lead 裁定（**E1 选 C**：引擎把 `startDate` 作为开始下界）
> 关联缺陷：D-021（`startDate` 不驱动排期）由 E1 方案 C 在 v0.5.0 修复，本表 AC-S8-02 为其回归判据。

## 0. 使用说明

- **判定方式**三种取值：① 自动化用例名（附测试文件）② 人工走查 ③ 归属他人交付（写明文件与负责人）。
- 2026-10-21 已完成回填：core 动作层（`WorkspaceAction.setTaskStart/setTaskFinish`、`ScheduleDateMath`、`CalendarGrid`、
  `TaskInspector.startDate`）合并后落盘 `Tests/AppTests/Sprint8DateAcceptanceTests.swift`（23 条），本表「判定方式」列已把
  「（待补写）」全部替换为**真实用例名 + 实际执行结果**：**通过** = 本次 `swift test` 全量实跑绿；**未覆盖** = 依赖的
  视图/环境未交付或不可自动化，不计为合格；**人工** = §3 不可自动化项。未执行的一律不写「通过」。
- 通用夹具（除特别说明）：`projectStart = 2026-11-02`（周一）、`Calendar` = gregorian；
  自动化用 UTC 固定时区，人工用系统时区。任务 **A**（duration 3 天、无依赖）、任务 **B**（FS 依赖 A、duration 2 天）。
  基线排期：A `[11-02, 11-05)`，B `[11-05, 11-07)`。
- 术语（沿用 `docs/features/02-inspectors-scheduling.md` 术语规约）：
  **开始** = `TaskItem.startDate`（用户意图输入）；**计划开始** = `scheduledStart`（引擎结果）；
  **结束** = `scheduledFinish`（**排他端点**：1 天任务 11-02 起 → 结束 11-07 的相邻日口径见 §1.3）。

## 1. 十二类覆盖矩阵

| # | 类别 | 覆盖内容 | 判据编号 |
|---|---|---|---|
| 1 | 开始字段可编辑 | 写入 / 回显 / 副行 / 清除 | AC-S8-01、03、04 |
| 2 | E1 排期生效 | 设未来开始 → 计划开始与甘特条体前移；早于锚点不回推 | **AC-S8-02** |
| 3 | 结束 → 持续时间 | `durationDays` 换算、`scheduledFinish` 落点、排他口径 | AC-S8-06、07、11 |
| 4 | 非法结束不可达 | 日历置灰 + Store 拒绝 + 无撤销点（双层防线） | **AC-S8-05** |
| 5 | 撤销粒度 | 一步撤销、同字段合并、跨字段不合并 | **AC-S8-09** |
| 6 | 边界 | 里程碑 / 群组 / 无排期 / 无起点 | AC-S8-08、12、16 |
| 7 | 日历交互 | 网格、翻月、键盘、快捷项、跨月选中 | AC-S8-13、14、15 |
| 8 | 视觉与深浅色 | 三态非空白、token 生效、选中/今天可区分 | AC-S8-18 |
| 9 | 无障碍 | label / value / hint / 焦点顺序 / ReduceMotion | AC-S8-19 |
| 10 | 回归 | `dueDate`、画布拖拽、持续时间行、大纲/CLI 口径 | **AC-S8-10**、AC-S8-11、20 |
| 11 | 数据与分层不变 | `.kairo` 版本、无新增字段、KairoCore 改动边界 | AC-S8-20 |
| 12 | 断言改写与全量回归 | 既有断言改写登记、用例数只增不减 | AC-S8-21 |
| 13 | 夏令时口径 | America/New_York 回拨日前后结束落点、finish−start 天数一致 | AC-S8-22 |
| 14 | 陈旧输入（并发 / 撤销） | 弹层打开后排期变化，再提交旧起点 | AC-S8-23 |

## 2. 判据表

| 编号 | 判据 | 触发步骤 | 预期 | 判定方式 |
|---|---|---|---|---|
| AC-S8-01 | 检查器「开始」编辑写入 `startDate`（日粒度归一） | 1) 选中任务 A；2) 点击「开始」行；3) 月历选 2026-11-06 | `TaskItem.startDate == startOfDay(2026-11-06)`（时分秒被丢弃）；行内显示 `2026-11-06`；`InspectorSnapshot.startDate` 同步；仅 1 个撤销点 | 自动化 `startEditWritesStartDateAtStartOfDay`、`startDateWithTimeComponentSchedulesAtStartOfDay`（`Tests/AppTests/Sprint8DateAcceptanceTests.swift`）→ **通过**（写入落 `startOfDay`、检查器回显同步、一次编辑一个撤销点；带时分的意图值排期仍取当日零点）。日历弹层选择与行内显示属视图层（U4 未交付）→ **未覆盖** |
| **AC-S8-02** | **设开始为未来日 → 计划开始与甘特条体前移到该日**（E1 方案 C 核心验收，用调度结果断言） | 1) 夹具项目；2) 记录 A/B 的 `scheduledStart` 与甘特条体 x；3) 对 A 设开始 = 2026-11-06；4) 重算排期并读甘特布局结果；5) 反向用例：把 A 开始改到 2026-10-20（早于 `projectStart`） | 3) 后：A.`scheduledStart == 11-06`、A.`scheduledFinish == 11-09`（duration 3，排他）；B.`scheduledStart == 11-09`（FS 传播，不只看 A 单条）；甘特条体 x 前移量 == 4 天 × 当前日宽（按布局/调度结果断言，**禁止只验 `startDate` 字段回显**）。5) 后：A.`scheduledStart` 仍 == 11-02（下界取 max，显式开始不回拉）；A.`startDate` 仍保存 10-20（意图与结果可不同源） | 自动化 `futureStartDateMovesScheduledStartAndGanttBar`、`startDateEarlierThanAnchorDoesNotPullScheduleBack`（`Sprint8DateAcceptanceTests.swift`）→ **通过**：A 计划开始 11-06 / 结束 11-09、B 计划开始 11-09、条体 x 前移 4 × 日宽（固定视窗后比较）；反向 10-20 时计划开始仍 11-02 且 `startDate` 保留 10-20。引擎层 `ScheduleStartDateBoundTests.*`（`Tests/KairoCoreTests/ScheduleStartDateBoundTests.swift`，dev-coder-engine）由 core 侧声明通过，本表不代其判合格 |
| AC-S8-03 | 「开始」显示意图值，排期差异以副行呈现 | 1) 设 A 开始 = 11-06，此时排期同为 11-06；2) 给 A 加 FS 前驱使 `scheduledStart` 推后到 11-10 | 1) 主值 `2026-11-06`，**无**副行（差异 < 1 天）；2) 主值仍 `2026-11-06`，行下灰字「计划开始 2026-11-10」；原「计划开始/计划结束」两条独立只读行已删除（同一面板无重复日期行） | 归属 U4：`dateFieldRowStatesRenderDistinctly`、`calendarPopoverRendersInLightAndDark`（`Tests/AppTests/Sprint8DateFieldRenderTests.swift`，dev-coder-ui）在合并 s8/ui 后实跑**通过**；副行文案规则（相差 ≥ 1 天才显示「计划开始 …」）以代码核验（`InspectorView.swift:506-510`）为准，**无直接断言**，排版仍待人工确认 |
| AC-S8-04 | 「清除」清空开始且不改变排期 | 对已有 `startDate` 的任务点击「清除」 | `startDate == nil`；行内回到「未设置」占位；`scheduledStart` 不变（项目已设锚点时）；副行消失；1 个撤销点；无提示弹窗 | 部分覆盖：`dateFieldRowStatesRenderDistinctly`（U4）覆盖有值 / 无值 / 禁用三态显示；「清除」提交分支（写 nil、不改排期、1 个撤销点）**无自动化断言**（`allowsClear` 仅由 `quickActionsFollowDesignRules` 间接触达）；Store 侧清空由 `setTaskStartWithNilClearsIntentDate`（dev-coder-core）覆盖 |
| **AC-S8-05** | **结束 ≤ 开始不可达**：日历禁用 + Store 拒绝，且不产生撤销点 | a) 起点 11-06，打开「结束」日历，试图点 11-06 / 11-05 / 11-07；b) 绕过 UI 直接 `dispatch(.setTaskFinish(A, finish: 11-06, start: 11-06))`；c) 同上但 `finish = 11-05` | a) 11-06、11-05 置灰：不可点、不可聚焦，tooltip「结束须晚于开始，至少 1 天」；11-07 可选（最小可选日 == 起点 + 1 天）；b/c) Store 拒绝：`durationDays` 不变、`scheduledFinish` 不变、`alertMessage == "结束日期必须晚于开始日期"`、**撤销栈深度不变（无撤销点）**、无草稿残留 | 自动化 `finishMustBeLaterThanStart`、`finishCalendarDisablesDaysBeforeMinimumFinish`、`finishNotAfterStartIsRejectedWithoutUndo`（`Sprint8DateAcceptanceTests.swift`）→ **通过**：最小可选日 = 起点 + 1 天、`finish <= start` 折算为 nil、Store 拒绝（`alertMessage == 结束日期必须晚于开始日期`、`durationDays` / `scheduledFinish` 不变、一次 undo 回到设开始之前 = **撤销栈未进账**）。日历置灰的**渲染**断言 `finishCalendarBoundaryDaysAreDisabled` **未覆盖**（U4 待交付） |
| AC-S8-06 | 编辑「结束」只改写 `durationDays`，落点为排他端点 | A 起点 11-06、duration 3（结束 11-09）；在「结束」日历选 11-12 | `durationDays == 6`；`scheduledStart` 仍 11-06；`scheduledFinish == 11-12`（== 选中日）；`startDate` 不变；`dueDate` 不变；1 个撤销点 | 自动化 `finishEditRewritesDurationOnlyAndScheduledFinishMatches`（`Sprint8DateAcceptanceTests.swift`）→ **通过**：duration 3 → 6、`scheduledFinish` == 选中日、`startDate` / `dueDate` 不变、一步撤销只回退结束 |
| AC-S8-07 | 排他口径在 UI 上可辨识（不允许用户按含端理解） | 打开「结束」日历；观察预览行与 helper；对照 1 天任务 | 预览行「2026-11-06 – 2026-11-12 · 6 天」；helper「结束日不含当天」；1 天任务起点 11-06 → 结束显示 11-07（不是 11-06）；小数 duration（如 2.5）经本行编辑后变整数天，预览行明示换算 | 换算层 `durationAndFinishStayConsistent`（`Sprint8DateAcceptanceTests.swift`）→ **通过**；预览行 / helper 文案与「1 天任务显示 11-07」的渲染断言 **未覆盖**（U4 未交付），文案人工复核未做 |
| AC-S8-08 | 结束不可清除；里程碑与无起点禁用 | a) 打开普通任务「结束」日历看快捷区；b) 选里程碑；c) 任务无 `startDate` 且项目无排期起点 | a) **无「清除」项**（`allowsClear == false`）；b) 「结束」只读显示当日并禁用，tooltip「里程碑无持续时间」，「持续时间」行同时禁用，不产生写回（`duration` 恒 0）；c) 「结束」禁用，文案「无排期（`Display.unscheduledReason`），无法设置结束」；三者均无写入、无撤销点 | 部分覆盖：`finishCalendarDisablesDaysAtOrBeforeStart`、`subDayDurationFinishIsClampedToMinimum`、`dateFieldRowStatesRenderDistinctly`（U4）覆盖越界置灰、亚日持续时间下限夹取与禁用态渲染 → 实跑**通过**；里程碑「结束只读 + tooltip」、「无排期 unscheduledReason 文案」与「结束无清除项」仍**无直接断言**，待 U4 复核或人工走查 |
| **AC-S8-09** | **一次编辑 = 一步撤销**（合并规则可验证） | a) 提交一次开始编辑后 ⌘Z；b) 500ms 内对同一任务「开始」连点两次后 ⌘Z 一次；c) 先改开始再改结束，⌘Z 两次；d) 画布拖动 A 后立即改「开始」，⌘Z 一次 | a) 完全回到改前（`startDate` 与排期一起回退）；b) 两次合并为**一步**；c) **不合并**（`mergeKey` 含字段名，跨字段永远两步）；d) 只回退检查器这一步，画布拖拽仍在（`task-start-<id>` 与 `canvas-move-<id>` 不互并）；非法写回不占撤销点（见 AC-S8-05） | 自动化 `eachDateEditIsOneUndoStep`、`sameFieldEditsWithin500msMergeIntoOneStep`、`crossFieldEditsDoNotMerge`、`inspectorEditDoesNotMergeWithCanvasMove`（`Sprint8DateAcceptanceTests.swift`）→ **通过**；b 项用同步连续 dispatch（用例内实测两笔间隔 < 500ms 并断言该前提），**未使用 sleep** |
| **AC-S8-10** | **`dueDate` 与既有画布拖拽回归** | a) 新组件下把「截止日期」设为 2026-12-01；b) 清除截止日期；c) 画布拖动 A 条体 +2 天；d) 拖 A 左端改 duration | a) `dueDate == 12-01`，且 `startDate`/`durationDays`/`scheduledFinish` 均不受影响；b) `dueDate == nil`；c) 仍走 `canvasEditSchedule(durationDays: nil)`，`startDate` 改变、撤销 key `canvas-move-`；d) `durationDays` 改变、finish 对齐、key `canvas-resize-`；既有 `moveUpdatesStartDateOnly`、`resizeEndUpdatesDurationOnly`、`resizeStartKeepsFinishDate`、`consecutiveCanvasMovesMergeIntoSingleUndo`、`milestoneMoveViaAction` 全绿 | 自动化 `dueDateEditStillWritesDueDateOnly`（`Sprint8DateAcceptanceTests.swift`）→ **通过**（设 12-01 后 `startDate` / `durationDays` / `scheduledFinish` 均不变，清除回 nil）；既有 `Tests/AppTests/GanttCanvasEditTests.swift` 的 `moveUpdatesStartDateOnly`、`resizeEndUpdatesDurationOnly`、`resizeStartKeepsFinishDate`、`consecutiveCanvasMovesMergeIntoSingleUndo`、`milestoneMoveViaAction` 断言**未改动**，并在本次全量回归中通过 |
| AC-S8-11 | 「结束」与「持续时间」是同字段的两个入口，不允许双源 | a) 把持续时间改为 5；b) 观察「结束」行；c) 再把「结束」改回原值 | a) 结束显示 起点+5；b) 两行始终一致；c) 持续时间同步回改后的天数；任一入口改动后另一行立即刷新 | 自动化 `durationAndFinishStayConsistent`（`Sprint8DateAcceptanceTests.swift`）→ **通过**（duration → finish 与 finish → duration 互为逆运算、终值一致）；`popoverPreviewFollowsCandidateDay`（U4）覆盖预览行随候选日刷新；「持续时间行与结束行同帧刷新」的渲染断言**未覆盖** |
| AC-S8-12 | 群组两行只读 | 选中群组任务 | 「开始」「结束」不可点、不弹层；显示聚合值或占位；渲染画面与只读态一致；UI 不产生任何 dispatch（Store 侧仍保持可写，与既有语义一致，不额外拦截） | 归属 U4：`groupDateRowsRenderAsReadOnly`（`Sprint8DateFieldRenderTests.swift`，dev-coder-ui）→ 合并 s8/ui 后实跑**通过**；Store 侧「群组不拦截写入」由 `setTaskStartOnGroupIsNotBlockedByStore`（`Sprint8TaskDateActionTests.swift`，dev-coder-core）覆盖 |
| AC-S8-13 | 月历网格与月份导航正确 | 打开「开始」日历；向前/后翻 1 个月、跨年（12 月→1 月）、查看 2 月与 31 天月；分别以 `firstWeekday = 周日` / `周一` 两种系统设置验证 | 6 行 × 7 列 = 42 格；首格 = 当月 1 日所在周的周首；非本月日灰显（`textSecondary` × 0.45）但**可点且顺带翻月**；周末文字弱化（无底色块）；今天 1pt `accentStrong` 环；选中实心 `selection` 底；浏览月与选中解耦（翻月不改选中）；重开保留上月视图，仅当外部改动 `value` 才重置 | 自动化 `calendarGridHas42CellsWithFirstWeekdayDrivenStart`、`calendarGridMarksAdjacentMonthDaysAndWeekends`、`calendarGridMonthNavigationCrossesYearBoundary`、`calendarGridRejectsNonexistentFebThirtieth`（`Sprint8DateAcceptanceTests.swift`）→ **通过**（42 格逐日连续、周日 / 周一首两种设置、翻月跨年、非本月 12 格、周末判定、2 月 30 日 → nil）；渲染三态与深浅色归属 U4：`calendarPopoverRendersInLightAndDark`、`selectedAndTodayStatesRenderDifferently`、`calendarDayStyleClassifiesSelectionTodayAndBounds` → 合并后实跑**通过**；「重开保留上月视图」无逻辑层测试（`visibleMonth` 仍在视图内） |
| AC-S8-14 | 键盘可达 | 打开日历：`←`/`→`/`↑`/`↓`、跨月边界、`Return`、`Esc`、`Tab` 循环 | 方向键 ±1 / ±7 天且跨月自动翻 `visibleMonth`；`Return` / `Space` 提交焦点日并关闭；`Esc` 关闭且**不提交**；Tab 顺序按 **lead 裁定（2026-10-21，覆盖 design §3.3 原文）**：上个月 → 下个月 → **网格** → 今天 → 下周一 → +1 周 → 清除（网格为**单一焦点停靠点**：42 格各有无障碍元素，但不做 42 个 Tab 停靠点）；再次点击行 / 点击外部关闭不提交 | 部分自动化：`calendarQuickActionOrderMatchesRuling`（`Tests/AppTests/Sprint8DateAcceptanceTests.swift`）→ **通过**（快捷项声明顺序 = 今天 → 下周一 → +1 周，清除为尾部独立按钮）；方向键 / 跨月翻页 / Return / Esc 的**代码路径**由组件实现覆盖，但物理键盘事件无法离屏派发（§3 N2）；「网格在快捷区之前」与完整 Tab 环仍为**人工走查**（视图声明顺序 header → weekdayHeader → grid → previewRow → quickBar 可静态核对） |
| AC-S8-15 | 快捷项行为与禁用 | 依次点「今天」「下周一」「+1 周」「清除」；在「结束」日历中验证「今天」早于最小可选日的情形 | 「今天」提交今天；「下周一」= 今天即周一时 +7 天，否则下个周一；「+1 周」= `(selection ?? today) + 7`；「清除」仅开始行出现，提交 `nil` 并关闭；任何早于 `minimumDate` 的快捷项禁用（灰显不可点） | 归属 U4：`quickActionsFollowDesignRules`（`Sprint8DateFieldRenderTests.swift`）断言今天 / 下周一（今天即周一 → +7）/ +1 周（以选中值为基准）与越界禁用 → 合并后实跑**通过**；「清除」提交 nil 的路径**未覆盖**（见 AC-S8-04） |
| AC-S8-16 | 无排期与派生命中（R2 已知风险） | a) 构造含环项目，选环上任务；b) 选空群组；c) 项目**未设**开始日期，改最早任务的「开始」 | a/b) 「开始」仍可编辑（写意图），「结束」禁用并给出 `unscheduledReason`；c) 不阻断写入；改后整条时间轴随最早任务平移——**R2 已登记为已知行为**，走查只记录不判缺陷 | 自动化 `taskStartEditWithoutProjectAnchorShiftsTimeline`（`Sprint8DateAcceptanceTests.swift`）→ **通过**（c：写入不阻断；锚点由任务推导，`projectStartDerived == true`，时间轴整体平移按 R2 已知行为记录）；a/b（环上任务、空群组）需构造环数据与视图选择 → **未覆盖**，R2 仍按人工走查 |
| AC-S8-17 | 依赖冲突/时限违例不阻断写入 | 制造 A 的依赖冲突或时限违例，然后编辑 A 的「结束」 | 写入成功；违例区出现既有文案；**不弹新对话框**、不回滚（与 `setDueDate`/`setDuration` 一致） | 自动化 `finishEditDoesNotBlockOnViolations`（`Sprint8DateAcceptanceTests.swift`）→ **通过**：以「项目结束日早于 A 计划结束」制造稳定边界违例，编辑结束后写入成功、`alertMessage == nil`、违例数不变（不弹新对话框、不回滚） |
| AC-S8-18 | 日期行与弹层渲染非空白且状态可区分 | 离屏渲染：「开始」有值 / 无值 / 禁用三态；月历浅色与深色；选中态与今天态 | 全部非空白（`distinctColorCount >= 20`）；三态两两 `differenceRatio > 0`；同一画面深浅色不同；选中/今天两态有可见差异；无字面色（全部走 `DesignTokens`） | 归属 U4：`dateFieldRowStatesRenderDistinctly`（三态非空白 + 两两 differenceRatio > 0）、`calendarPopoverRendersInLightAndDark`（深浅色）、`selectedAndTodayStatesRenderDifferently`（选中 / 今天可区分）—— `Tests/AppTests/Sprint8DateFieldRenderTests.swift`（dev-coder-ui），合并 s8/ui 后实跑**通过**；我不重复补渲染断言 |
| AC-S8-19 | 无障碍语义 | 开启 VoiceOver 走查字段行、网格、快捷区；系统开启「减弱动态效果」 | 字段行 label「开始日期，2026年11月6日」/ 无值时「开始日期，未设置」，hint「打开月历选择日期」，禁用时 hint == `disabledReason`；网格 label「2026 年 11 月月历」，每格含 月日/星期/今天/已选中/不可选；快捷按钮独立可聚焦且 label 用可见文案（清除为「清除开始日期」）；焦点顺序与视觉一致；ReduceMotion 下翻月无过渡动画 | 部分自动化：`dateRowAccessibilityLabelsMatchDesign`、`dayLabelsDescribeTodaySelectionAndBounds`（U4）断言 label / value / hint 文案与每格「月日 / 星期 / 今天 / 已选中 / 不可选」→ 合并后实跑**通过**；VoiceOver 实际播报顺序与 ReduceMotion 仍为**人工**（§3 N3） |
| AC-S8-20 | 数据格式与分层边界不变 | 编辑后保存 `.kairo`，与 v0.4.0 文件对比；审阅改动文件清单 | 格式版本不变、**无新增字段**（复用 `startDate`/`durationDays`/`dueDate`）；`KairoCore` 改动仅 `ScheduleEngine.swift` + `docs/02-architecture.md §7`；`Display.date`（`yyyy/M/d`）未改，大纲列/违例文案格式不变；CLI `tasks` 与大纲「结束」列口径不变；`DesignTokens.swift` 零改动 | 既有 `FormatUpgradeTests`、`FormatMigrationTests` 在本次全量回归中 **通过**；改动面：`s8/test` 自身只新增测试文件与 docs，合并 `s8/ui` 带入 `Apps/macos/Sources/Workspace/Inspector/DateFieldRow.swift`、`InspectorView.swift`、`Display.swift` 与 `Tests/AppTests/Sprint8DateFieldRenderTests.swift`；`Sources/KairoCore` 仍仅 `ScheduleEngine.swift`（S8 引擎修复）；`DesignTokens.swift` 零改动、`Display.date` 格式未改 |
| AC-S8-21 | 断言改写登记 + 全量回归只增不减 | 跑全量 `swift test`；审阅 `Tests/**` 的 diff | 全量通过；用例数 ≥ Sprint 7 收尾基线（基线数以 lead 记录为准，本表不臆测具体数字）；凡断言被改写的用例（尤其既有「`startDate` 不驱动排期」类）在任务记录中列出**测试名 + 理由**，禁止静默删除断言（design §9.1）；`ScheduleAnchorEngineTests.engineDerivesAnchorFromEarliestTaskStart` 在 E1-C 下仍应通过（派生锚点 == 最早 `startDate`，下界不变） | **最终门禁（lead 实跑 2026-10-21；合并 s8/engine 210d4f9 + s8/core 0f2c139 + s8/ui e289e7b + s8/test 136e5e0）**：`swift test` **669 用例 / 69 套件全部通过**（基线 558 → 669，只增不减；日志 `docs/archive/Sprint8-task-dates/logs/gate-*.log`）；`tools/gate-core.sh` 与 `tools/gate-ui.sh` 通过；`swift build -c release -Xswiftc -warnings-as-errors` 通过。`Tests/**` 只新增文件，无既有断言被改写或删除（审查以 `git diff --numstat fb8e75e..HEAD -- Tests/` 核实，全部为新增行）；`ScheduleAnchorEngineTests.engineDerivesAnchorFromEarliestTaskStart` 在 E1-C 下仍通过 |
| AC-S8-22 | 夏令时下「结束」落点（跨层日期口径一致） | 1) 时区 America/New_York；2) 起点 2025-11-01（11-02 回拨）；3) duration 3 与 5 分别看「结束」显示值与 `scheduledFinish`；4) 核对 finish − start 的日历天数 | 结束显示值与 `scheduledFinish` 均 == 日历整日相加结果（当地 11-04 / 11-06 零点，**不得少一天**）；`dayOffset(finish − start) == duration`；换算层与引擎结论一致 | 自动化 `dstTransitionKeepsFinishOnCalendarDay`（`Sprint8DateAcceptanceTests.swift`）→ **通过**（2026-10-21 复跑，H-1 修复 `210d4f9` 合并后）：America/New_York 起点 2025-11-01、duration 3/5，`scheduledFinish` 落当地 11-04 / 11-06 零点，`finish − start == duration` 天；引擎按日历日推进，换算层与引擎一致（`ScheduleDaylightSavingTests` 5 例同时覆盖回拨/春令/依赖 lag/宽延/时限）。修复前 4 处失败的记录保留于审查 H-1 与缺陷登记 |
| AC-S8-23 | 陈旧起点提交必须拒绝（不得静默折算持续时间） | 1) 打开「结束」弹层（视图记住起点 11-02）；2) 打开期间排期变化（画布拖拽 / 撤销重做 / ALAP 重算使起点变 11-06）；3) 仍按旧起点看到的月历选 11-10 提交 | Store 拒绝：`alertMessage == "排期已变化，请重新选择结束日期"`；`durationDays` / `scheduledFinish` 不变；**不占撤销点**（一次 undo 只回退期间那次排期变化） | 自动化 `staleStartFinishIsRejectedWithoutUndo`（`Sprint8DateAcceptanceTests.swift`）→ **通过**（2026-10-21 复跑，H-2 修复 `0f2c139` 合并后）：`alertMessage` 为「排期已变化，请重新选择结束日期」，`durationDays` 与 `scheduledFinish` 不变，撤销栈深度不变（观测缝 `undoDepthForTesting`）。修复前 5 处失败的记录保留于审查 H-2 与缺陷登记 |

## 3. 不可自动化项（沿用 D-015 体例登记，不计入漏测）

| # | 项 | 原因 | 兜底 |
|---|---|---|---|
| N1 | 真实 popover 系统动画与边缘翻转 | 依赖窗口服务器与系统动画 | 人工走查（AC-S8-14） |
| N2 | 物理键盘事件派发（方向键/Return/Esc/Tab） | `ImageRenderer` 离屏渲染不派发事件 | 人工走查 + 逻辑层纯函数测试 |
| N3 | VoiceOver 实际播报内容与顺序 | 需要真实辅助技术栈 | 人工走查（AC-S8-19） |
| N4 | 系统 `firstWeekday` 变更下的真实渲染 | 依赖用户系统设置 | C8 双设置纯逻辑覆盖 + 人工切换设置 |

## 4. 交付前置与缺口

- **2026-10-21 更新**：core 动作层已合并（`WorkspaceAction.setTaskStart` / `setTaskFinish`、`ScheduleDateMath`、
  `CalendarGrid`、`TaskInspector.startDate`），`Tests/AppTests/Sprint8DateAcceptanceTests.swift` 已落盘 **23 条**用例，
  覆盖 AC-S8-01/02/05/06/07/08/09/10/11/13/14（快捷项顺序）/16/17/22/23 的可自动化判据；
  本表原先标注待补写的用例名已全部替换为真实用例名与执行结果。
- **UI 已合并（s8/ui → 6e9eadf / e289e7b，2026-10-21 合入本分支）**：检查器「开始」「结束」行、日历弹层与
  `DateFieldRow` 已落地；U4 的 11 条渲染 / 无障碍用例（`Tests/AppTests/Sprint8DateFieldRenderTests.swift`）在合并后实跑通过，
  AC-S8-03/08/12/13/15/18/19 的渲染类判据改为归属 U4 引用（见「判定方式」列），未直接断言的子项已逐条写明。
- **H-1 / H-2 已合并并复跑**：AC-S8-22（夏令时落点）与 AC-S8-23（陈旧起点）在修复分支合并后转为**通过**（证据见「判定方式」列）；修复前的失败记录保留在审查报告 H-1/H-2 与缺陷登记，不删除历史。
- **未自动化项**：真机 popover 动画/边缘翻转、物理键盘事件与焦点环、VoiceOver 播报、系统 firstWeekday 真机渲染、R2 时间轴平移观感 —— 均为人工走查项，本表不填「通过」。
- AC-S8-14 的 Tab 顺序已按 **lead 裁定（2026-10-21）** 更新；「网格在快捷区之前」与完整 Tab 环仍为人工走查（§3 N2）。
- C7/C8/C9/U4 的用例由 dev-coder-core / dev-coder-ui 交付；本表引用其用例名并以**本分支实跑结果**记录，判据的实现责任仍归属各自负责人（谁实现谁负责），dev-tester 不代其修改断言。
- 发现生产代码缺陷 → 按 `docs/defects.md` IEEE 829 最小集登记，附 `文件:行号` 与判据编号；测试自身缺陷由本表维护者直接修正。
