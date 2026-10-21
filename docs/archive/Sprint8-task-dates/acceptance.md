# Sprint 8 验收判据 —— F-14-10 任务起止日期可自定义（检查器日历）

> 2026-10-21 · dev-tester 维护 · 状态：判据表已定稿；可自动化项已落盘并实跑（Tests/AppTests/Sprint8DateAcceptanceTests.swift 共 20 条，结果见 §2「判定方式」列）
> 依据（唯一权威，本表不新增需求）：`scope.md`（用户 2026-10-21 三条决策）、`design.md`
> §1 字段语义 / §3 日历交互 / §6 测试矩阵 / §9 lead 裁定（**E1 选 C**：引擎把 `startDate` 作为开始下界）
> 关联缺陷：D-021（`startDate` 不驱动排期）由 E1 方案 C 在 v0.5.0 修复，本表 AC-S8-02 为其回归判据。

## 0. 使用说明

- **判定方式**三种取值：① 自动化用例名（附测试文件）② 人工走查 ③ 归属他人交付（写明文件与负责人）。
- 2026-10-21 已完成回填：core 动作层（`WorkspaceAction.setTaskStart/setTaskFinish`、`ScheduleDateMath`、`CalendarGrid`、
  `TaskInspector.startDate`）合并后落盘 `Tests/AppTests/Sprint8DateAcceptanceTests.swift`，本表「判定方式」列已把
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

## 2. 判据表

| 编号 | 判据 | 触发步骤 | 预期 | 判定方式 |
|---|---|---|---|---|
| AC-S8-01 | 检查器「开始」编辑写入 `startDate`（日粒度归一） | 1) 选中任务 A；2) 点击「开始」行；3) 月历选 2026-11-06 | `TaskItem.startDate == startOfDay(2026-11-06)`（时分秒被丢弃）；行内显示 `2026-11-06`；`InspectorSnapshot.startDate` 同步；仅 1 个撤销点 | 自动化 `startEditWritesStartDateAtStartOfDay`、`startDateWithTimeComponentSchedulesAtStartOfDay`（`Tests/AppTests/Sprint8DateAcceptanceTests.swift`）→ **通过**（写入落 `startOfDay`、检查器回显同步、一次编辑一个撤销点；带时分的意图值排期仍取当日零点）。日历弹层选择与行内显示属视图层（U4 未交付）→ **未覆盖** |
| **AC-S8-02** | **设开始为未来日 → 计划开始与甘特条体前移到该日**（E1 方案 C 核心验收，用调度结果断言） | 1) 夹具项目；2) 记录 A/B 的 `scheduledStart` 与甘特条体 x；3) 对 A 设开始 = 2026-11-06；4) 重算排期并读甘特布局结果；5) 反向用例：把 A 开始改到 2026-10-20（早于 `projectStart`） | 3) 后：A.`scheduledStart == 11-06`、A.`scheduledFinish == 11-09`（duration 3，排他）；B.`scheduledStart == 11-09`（FS 传播，不只看 A 单条）；甘特条体 x 前移量 == 4 天 × 当前日宽（按布局/调度结果断言，**禁止只验 `startDate` 字段回显**）。5) 后：A.`scheduledStart` 仍 == 11-02（下界取 max，显式开始不回拉）；A.`startDate` 仍保存 10-20（意图与结果可不同源） | 自动化 `futureStartDateMovesScheduledStartAndGanttBar`、`startDateEarlierThanAnchorDoesNotPullScheduleBack`（`Sprint8DateAcceptanceTests.swift`）→ **通过**：A 计划开始 11-06 / 结束 11-09、B 计划开始 11-09、条体 x 前移 4 × 日宽（固定视窗后比较）；反向 10-20 时计划开始仍 11-02 且 `startDate` 保留 10-20。引擎层 `ScheduleStartDateBoundTests.*`（`Tests/KairoCoreTests/ScheduleStartDateBoundTests.swift`，dev-coder-engine）由 core 侧声明通过，本表不代其判合格 |
| AC-S8-03 | 「开始」显示意图值，排期差异以副行呈现 | 1) 设 A 开始 = 11-06，此时排期同为 11-06；2) 给 A 加 FS 前驱使 `scheduledStart` 推后到 11-10 | 1) 主值 `2026-11-06`，**无**副行（差异 < 1 天）；2) 主值仍 `2026-11-06`，行下灰字「计划开始 2026-11-10」；原「计划开始/计划结束」两条独立只读行已删除（同一面板无重复日期行） | **未覆盖**：副行渲染尚未交付（`Apps/macos/Sources/Workspace/Inspector/InspectorView.swift:250-251` 仍是「计划开始 / 计划结束」两条独立只读行）；待 dev-coder-ui（U4）交付后补 `startRowShowsIntentValueWithPlannedSubline` 并回填 |
| AC-S8-04 | 「清除」清空开始且不改变排期 | 对已有 `startDate` 的任务点击「清除」 | `startDate == nil`；行内回到「未设置」占位；`scheduledStart` 不变（项目已设锚点时）；副行消失；1 个撤销点；无提示弹窗 | **未覆盖**（清除入口与占位文案属检查器视图，U4 未交付）；Store 侧清空分支由 `setTaskStartWithNilClearsIntentDate`（`Tests/AppTests/Sprint8TaskDateActionTests.swift`，dev-coder-core）覆盖，本表不代其判合格 |
| **AC-S8-05** | **结束 ≤ 开始不可达**：日历禁用 + Store 拒绝，且不产生撤销点 | a) 起点 11-06，打开「结束」日历，试图点 11-06 / 11-05 / 11-07；b) 绕过 UI 直接 `dispatch(.setTaskFinish(A, finish: 11-06, start: 11-06))`；c) 同上但 `finish = 11-05` | a) 11-06、11-05 置灰：不可点、不可聚焦，tooltip「结束须晚于开始，至少 1 天」；11-07 可选（最小可选日 == 起点 + 1 天）；b/c) Store 拒绝：`durationDays` 不变、`scheduledFinish` 不变、`alertMessage == "结束日期必须晚于开始日期"`、**撤销栈深度不变（无撤销点）**、无草稿残留 | 自动化 `finishMustBeLaterThanStart`、`finishCalendarDisablesDaysBeforeMinimumFinish`、`finishNotAfterStartIsRejectedWithoutUndo`（`Sprint8DateAcceptanceTests.swift`）→ **通过**：最小可选日 = 起点 + 1 天、`finish <= start` 折算为 nil、Store 拒绝（`alertMessage == 结束日期必须晚于开始日期`、`durationDays` / `scheduledFinish` 不变、一次 undo 回到设开始之前 = **撤销栈未进账**）。日历置灰的**渲染**断言 `finishCalendarBoundaryDaysAreDisabled` **未覆盖**（U4 待交付） |
| AC-S8-06 | 编辑「结束」只改写 `durationDays`，落点为排他端点 | A 起点 11-06、duration 3（结束 11-09）；在「结束」日历选 11-12 | `durationDays == 6`；`scheduledStart` 仍 11-06；`scheduledFinish == 11-12`（== 选中日）；`startDate` 不变；`dueDate` 不变；1 个撤销点 | 自动化 `finishEditRewritesDurationOnlyAndScheduledFinishMatches`（`Sprint8DateAcceptanceTests.swift`）→ **通过**：duration 3 → 6、`scheduledFinish` == 选中日、`startDate` / `dueDate` 不变、一步撤销只回退结束 |
| AC-S8-07 | 排他口径在 UI 上可辨识（不允许用户按含端理解） | 打开「结束」日历；观察预览行与 helper；对照 1 天任务 | 预览行「2026-11-06 – 2026-11-12 · 6 天」；helper「结束日不含当天」；1 天任务起点 11-06 → 结束显示 11-07（不是 11-06）；小数 duration（如 2.5）经本行编辑后变整数天，预览行明示换算 | 换算层 `durationAndFinishStayConsistent`（`Sprint8DateAcceptanceTests.swift`）→ **通过**；预览行 / helper 文案与「1 天任务显示 11-07」的渲染断言 **未覆盖**（U4 未交付），文案人工复核未做 |
| AC-S8-08 | 结束不可清除；里程碑与无起点禁用 | a) 打开普通任务「结束」日历看快捷区；b) 选里程碑；c) 任务无 `startDate` 且项目无排期起点 | a) **无「清除」项**（`allowsClear == false`）；b) 「结束」只读显示当日并禁用，tooltip「里程碑无持续时间」，「持续时间」行同时禁用，不产生写回（`duration` 恒 0）；c) 「结束」禁用，文案「无排期（`Display.unscheduledReason`），无法设置结束」；三者均无写入、无撤销点 | 部分覆盖：里程碑最小可选日 = 当日由 `finishMustBeLaterThanStart` 断言 → **通过**；「结束不可清除」（`allowsClear == false`）、里程碑「结束 / 持续时间」禁用态、无起点禁用文案均属视图层 → **未覆盖**（U4 待交付） |
| **AC-S8-09** | **一次编辑 = 一步撤销**（合并规则可验证） | a) 提交一次开始编辑后 ⌘Z；b) 500ms 内对同一任务「开始」连点两次后 ⌘Z 一次；c) 先改开始再改结束，⌘Z 两次；d) 画布拖动 A 后立即改「开始」，⌘Z 一次 | a) 完全回到改前（`startDate` 与排期一起回退）；b) 两次合并为**一步**；c) **不合并**（`mergeKey` 含字段名，跨字段永远两步）；d) 只回退检查器这一步，画布拖拽仍在（`task-start-<id>` 与 `canvas-move-<id>` 不互并）；非法写回不占撤销点（见 AC-S8-05） | 自动化 `eachDateEditIsOneUndoStep`、`sameFieldEditsWithin500msMergeIntoOneStep`、`crossFieldEditsDoNotMerge`、`inspectorEditDoesNotMergeWithCanvasMove`（`Sprint8DateAcceptanceTests.swift`）→ **通过**；b 项用同步连续 dispatch（用例内实测两笔间隔 < 500ms 并断言该前提），**未使用 sleep** |
| **AC-S8-10** | **`dueDate` 与既有画布拖拽回归** | a) 新组件下把「截止日期」设为 2026-12-01；b) 清除截止日期；c) 画布拖动 A 条体 +2 天；d) 拖 A 左端改 duration | a) `dueDate == 12-01`，且 `startDate`/`durationDays`/`scheduledFinish` 均不受影响；b) `dueDate == nil`；c) 仍走 `canvasEditSchedule(durationDays: nil)`，`startDate` 改变、撤销 key `canvas-move-`；d) `durationDays` 改变、finish 对齐、key `canvas-resize-`；既有 `moveUpdatesStartDateOnly`、`resizeEndUpdatesDurationOnly`、`resizeStartKeepsFinishDate`、`consecutiveCanvasMovesMergeIntoSingleUndo`、`milestoneMoveViaAction` 全绿 | 自动化 `dueDateEditStillWritesDueDateOnly`（`Sprint8DateAcceptanceTests.swift`）→ **通过**（设 12-01 后 `startDate` / `durationDays` / `scheduledFinish` 均不变，清除回 nil）；既有 `Tests/AppTests/GanttCanvasEditTests.swift` 的 `moveUpdatesStartDateOnly`、`resizeEndUpdatesDurationOnly`、`resizeStartKeepsFinishDate`、`consecutiveCanvasMovesMergeIntoSingleUndo`、`milestoneMoveViaAction` 断言**未改动**，并在本次全量回归中通过 |
| AC-S8-11 | 「结束」与「持续时间」是同字段的两个入口，不允许双源 | a) 把持续时间改为 5；b) 观察「结束」行；c) 再把「结束」改回原值 | a) 结束显示 起点+5；b) 两行始终一致；c) 持续时间同步回改后的天数；任一入口改动后另一行立即刷新 | 自动化 `durationAndFinishStayConsistent`（`Sprint8DateAcceptanceTests.swift`）→ **通过**（duration → finish 与 finish → duration 互为逆运算、终值一致）；「两行同时刷新」属视图渲染 → **未覆盖**（U4 未交付） |
| AC-S8-12 | 群组两行只读 | 选中群组任务 | 「开始」「结束」不可点、不弹层；显示聚合值或占位；渲染画面与只读态一致；UI 不产生任何 dispatch（Store 侧仍保持可写，与既有语义一致，不额外拦截） | **未覆盖**（群组行只读弹层与禁用态属检查器视图，U4 未交付）；Store 侧「群组不拦截写入」由 `setTaskStartOnGroupIsNotBlockedByStore`（`Tests/AppTests/Sprint8TaskDateActionTests.swift`，dev-coder-core）覆盖 |
| AC-S8-13 | 月历网格与月份导航正确 | 打开「开始」日历；向前/后翻 1 个月、跨年（12 月→1 月）、查看 2 月与 31 天月；分别以 `firstWeekday = 周日` / `周一` 两种系统设置验证 | 6 行 × 7 列 = 42 格；首格 = 当月 1 日所在周的周首；非本月日灰显（`textSecondary` × 0.45）但**可点且顺带翻月**；周末文字弱化（无底色块）；今天 1pt `accentStrong` 环；选中实心 `selection` 底；浏览月与选中解耦（翻月不改选中）；重开保留上月视图，仅当外部改动 `value` 才重置 | 自动化 `calendarGridHas42CellsWithFirstWeekdayDrivenStart`、`calendarGridMarksAdjacentMonthDaysAndWeekends`、`calendarGridMonthNavigationCrossesYearBoundary`、`calendarGridRejectsNonexistentFebThirtieth`（`Sprint8DateAcceptanceTests.swift`）→ **通过**：42 格且逐日连续、周日 / 周一首两种设置首格分别为 11-01 / 10-26、12 月与跨年翻月、非本月日照常输出（12 格）、周末判定、2 月 30 日返回 nil。三态渲染 `calendarPopoverRendersDistinctStates` **未覆盖**（U4 未交付） |
| AC-S8-14 | 键盘可达 | 打开日历：`←`/`→`/`↑`/`↓`、跨月边界、`Return`、`Esc`、`Tab` 循环 | 方向键 ±1 / ±7 天且跨月自动翻 `visibleMonth`；`Return`/`Space` 提交焦点日并关闭；`Esc` 关闭且**不提交**；`Tab` 顺序 上个月 → 下个月 → 今天 → 下周一 → +1 周 → 清除 → 网格；再次点击行/点击外部关闭不提交 | **人工**（不变）：popover 系统动画与物理键盘事件不可离屏自动化（§3 N1/N2）；`visibleMonth` / `focusedDay` 目前仍是视图内状态，未抽为纯函数，故无可补的自动化用例 |
| AC-S8-15 | 快捷项行为与禁用 | 依次点「今天」「下周一」「+1 周」「清除」；在「结束」日历中验证「今天」早于最小可选日的情形 | 「今天」提交今天；「下周一」= 今天即周一时 +7 天，否则下个周一；「+1 周」= `(selection ?? today) + 7`；「清除」仅开始行出现，提交 `nil` 并关闭；任何早于 `minimumDate` 的快捷项禁用（灰显不可点） | **未覆盖 / 人工**：快捷项取值与禁用规则当前在视图层实现，未抽为纯函数；仅 `CalendarMonthGrid.date(year:month:day:)` 的越界拒绝由 `calendarGridRejectsNonexistentFebThirtieth` 覆盖，不构成对「今天 / 下周一 / +1 周 / 清除」的验收 |
| AC-S8-16 | 无排期与派生命中（R2 已知风险） | a) 构造含环项目，选环上任务；b) 选空群组；c) 项目**未设**开始日期，改最早任务的「开始」 | a/b) 「开始」仍可编辑（写意图），「结束」禁用并给出 `unscheduledReason`；c) 不阻断写入；改后整条时间轴随最早任务平移——**R2 已登记为已知行为**，走查只记录不判缺陷 | 自动化 `taskStartEditWithoutProjectAnchorShiftsTimeline`（`Sprint8DateAcceptanceTests.swift`）→ **通过**（c：写入不阻断；锚点由任务推导，`projectStartDerived == true`，时间轴整体平移按 R2 已知行为记录）；a/b（环上任务、空群组）需构造环数据与视图选择 → **未覆盖**，R2 仍按人工走查 |
| AC-S8-17 | 依赖冲突/时限违例不阻断写入 | 制造 A 的依赖冲突或时限违例，然后编辑 A 的「结束」 | 写入成功；违例区出现既有文案；**不弹新对话框**、不回滚（与 `setDueDate`/`setDuration` 一致） | 自动化 `finishEditDoesNotBlockOnViolations`（`Sprint8DateAcceptanceTests.swift`）→ **通过**：以「项目结束日早于 A 计划结束」制造稳定边界违例，编辑结束后写入成功、`alertMessage == nil`、违例数不变（不弹新对话框、不回滚） |
| AC-S8-18 | 日期行与弹层渲染非空白且状态可区分 | 离屏渲染：「开始」有值 / 无值 / 禁用三态；月历浅色与深色；选中态与今天态 | 全部非空白（`distinctColorCount >= 20`）；三态两两 `differenceRatio > 0`；同一画面深浅色不同；选中/今天两态有可见差异；无字面色（全部走 `DesignTokens`） | **未覆盖**：离屏渲染断言属 U4（`Sprint8DateFieldRenderTests` 未落盘）；本次无任何渲染断言，不以「构建通过」充当覆盖 |
| AC-S8-19 | 无障碍语义 | 开启 VoiceOver 走查字段行、网格、快捷区；系统开启「减弱动态效果」 | 字段行 label「开始日期，2026年11月6日」/ 无值时「开始日期，未设置」，hint「打开月历选择日期」，禁用时 hint == `disabledReason`；网格 label「2026 年 11 月月历」，每格含 月日/星期/今天/已选中/不可选；快捷按钮独立可聚焦且 label 用可见文案（清除为「清除开始日期」）；焦点顺序与视觉一致；ReduceMotion 下翻月无过渡动画 | **人工**（不变）：VoiceOver 实际播报与 ReduceMotion 需真实辅助技术栈（§3 N3） |
| AC-S8-20 | 数据格式与分层边界不变 | 编辑后保存 `.kairo`，与 v0.4.0 文件对比；审阅改动文件清单 | 格式版本不变、**无新增字段**（复用 `startDate`/`durationDays`/`dueDate`）；`KairoCore` 改动仅 `ScheduleEngine.swift` + `docs/02-architecture.md §7`；`Display.date`（`yyyy/M/d`）未改，大纲列/违例文案格式不变；CLI `tasks` 与大纲「结束」列口径不变；`DesignTokens.swift` 零改动 | 既有 `FormatUpgradeTests`、`FormatMigrationTests` 在本次全量回归中 **通过**；改动面核对：本次仅新增 `Tests/AppTests/Sprint8DateAcceptanceTests.swift` 与 docs，`Sources/**`、`Apps/**`、`Tests/**` 既有文件零改动（见任务记录 `git diff --stat`），`DesignTokens.swift` 与 `Display.date` 未触碰 |
| AC-S8-21 | 断言改写登记 + 全量回归只增不减 | 跑全量 `swift test`；审阅 `Tests/**` 的 diff | 全量通过；用例数 ≥ Sprint 7 收尾基线（基线数以 lead 记录为准，本表不臆测具体数字）；凡断言被改写的用例（尤其既有「`startDate` 不驱动排期」类）在任务记录中列出**测试名 + 理由**，禁止静默删除断言（design §9.1）；`ScheduleAnchorEngineTests.engineDerivesAnchorFromEarliestTaskStart` 在 E1-C 下仍应通过（派生锚点 == 最早 `startDate`，下界不变） | 全量 `swift test` → **通过**：**647 用例 / 67 套件**（基线 627 + 本文件新增 20，2026-10-21 实跑）；`Tests/**` 本次只**新增**文件，无既有断言被改写或删除（无静默删断言）；`ScheduleAnchorEngineTests.engineDerivesAnchorFromEarliestTaskStart` 在 E1-C 下仍通过 |

## 3. 不可自动化项（沿用 D-015 体例登记，不计入漏测）

| # | 项 | 原因 | 兜底 |
|---|---|---|---|
| N1 | 真实 popover 系统动画与边缘翻转 | 依赖窗口服务器与系统动画 | 人工走查（AC-S8-14） |
| N2 | 物理键盘事件派发（方向键/Return/Esc/Tab） | `ImageRenderer` 离屏渲染不派发事件 | 人工走查 + 逻辑层纯函数测试 |
| N3 | VoiceOver 实际播报内容与顺序 | 需要真实辅助技术栈 | 人工走查（AC-S8-19） |
| N4 | 系统 `firstWeekday` 变更下的真实渲染 | 依赖用户系统设置 | C8 双设置纯逻辑覆盖 + 人工切换设置 |

## 4. 交付前置与缺口

- **2026-10-21 更新**：core 动作层已合并（`WorkspaceAction.setTaskStart` / `setTaskFinish`、`ScheduleDateMath`、
  `CalendarGrid`、`TaskInspector.startDate`），`Tests/AppTests/Sprint8DateAcceptanceTests.swift` 已落盘 **20 条**用例，
  覆盖 AC-S8-01/02/05/06/07/08/09/10/11/13/16/17 的可自动化判据；本表原先标注待补写的用例名已全部替换为真实用例名与执行结果。
- **仍缺 UI 交付**：检查器「开始」/「结束」行、日历弹层、副行与清除入口尚未实现（`InspectorView` 仍渲染
  「计划开始 / 计划结束」只读行），故 AC-S8-03/04/07（文案）/08（禁用态）/11（两行同步）/12/18/19 的渲染类判据为**未覆盖**。
- 未覆盖项归属：AC-S8-03/04/07/08/11/12/18 待 dev-coder-ui（U4）交付后由 dev-tester 补写渲染断言；
  AC-S8-14/15/19 属人工走查或待逻辑抽为纯函数后补自动化（§3 N1/N2/N3）。
- C7/C8/C9/U4 的用例由 dev-coder-core / dev-coder-ui 交付，本表只引用其用例名，不代其声明通过。
- 发现生产代码缺陷 → 按 `docs/defects.md` IEEE 829 最小集登记，附 `文件:行号` 与判据编号；测试自身缺陷由本表维护者直接修正。
