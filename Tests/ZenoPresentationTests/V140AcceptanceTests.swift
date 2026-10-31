import Foundation
import Testing
import ZenoCore
import ZenoPresentation

// v1.4.0 跨组验收用例（组 A：群组窗口口径统一）。
//
// 这里只钉**用户能看见的口径**：大纲行与甘特条读到的群组起止 = 第一个子任务开始 → 最后一个
// 子任务结束，工期单位与排期结果同源。实现细节（大纲树内部怎么聚合）由组 A 的单测覆盖，
// 本文件不重复；本文件的作用是「换成 5 天工作日历、混进里程碑与被依赖后移的任务之后，
// 口径仍然成立」。
//
// 夹具刻意包含两种会打破「自然日 ∥ 工作日」的子任务：
//   - 里程碑（工期 0）：只贡献时间点，不占跨度；
//   - 依赖后移（FS + lag）：最后一个结束的不一定是最后一个开始的。
//
// 时区固定 UTC：避免用例随本机时区漂移。

private let v140UTC: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func v140Day(_ year: Int, _ month: Int, _ day: Int) -> Date {
    v140UTC.date(from: DateComponents(year: year, month: month, day: day))!
}

private func v140ScheduleEntry(_ schedule: ScheduleResult, _ id: UUID) -> ScheduledTask? {
    schedule.tasks.first { $0.taskID == id }
}

/// 自然日差（口径与「旧实现」一致：只用来做夹具自检，不用来断言产品值）。
private func v140CalendarDays(from start: Date, to finish: Date) -> Double {
    Double(v140UTC.dateComponents(
        [.day], from: v140UTC.startOfDay(for: start), to: v140UTC.startOfDay(for: finish)
    ).day ?? 0)
}

/// 一个群组 + 3 个子任务：常规任务、里程碑、被依赖后移的任务。
///
/// 时间线（默认 7 天日历、项目起点 2026-10-05）：
///   常规任务 3 天                     → 10-05 … 10-08
///   里程碑（依赖常规任务）             → 10-08（零工期，落在常规任务结束那天）
///   后移任务 2 天（依赖常规 + lag 4）  → 10-12 … 10-14（全场最后一个结束）
private struct V140GroupFixture {
    let group: TaskItem
    let first: TaskItem
    let milestone: TaskItem
    let delayed: TaskItem

    init() {
        let group = TaskItem(title: "阶段一", kind: .group)
        let first = TaskItem(
            title: "需求评审", kind: .task, parentID: group.id, durationDays: 3
        )
        let milestone = TaskItem(
            title: "评审通过", kind: .milestone, parentID: group.id, durationDays: 0,
            dependencies: [TaskDependency(predecessorID: first.id)]
        )
        let delayed = TaskItem(
            title: "整改", kind: .task, parentID: group.id, durationDays: 2,
            dependencies: [TaskDependency(predecessorID: first.id, lagDays: 4)]
        )
        self.group = group
        self.first = first
        self.milestone = milestone
        self.delayed = delayed
    }

    var tasks: [TaskItem] { [group, first, milestone, delayed] }
}

struct V140GroupWindowAcceptanceTests {
    /// 验收判据：群组起止 = 第一个子任务开始 → 最后一个子任务结束（大纲行口径）。
    @Test func V140GroupWindowSpansFirstChildStartToLastChildFinish() throws {
        let fixture = V140GroupFixture()
        let projectStart = v140Day(2026, 10, 5)
        let schedule = makeSchedule(fixture.tasks, projectStart: projectStart, now: projectStart)
        var viewState = WorkspaceViewState()
        viewState.expandedTaskIDs = [fixture.group.id]
        let snapshot = makeSnapshot(
            state: makeState(fixture.tasks, projectStart: projectStart),
            schedule: schedule,
            viewState: viewState,
            now: projectStart
        )

        var rows: [UUID: PlanRow] = [:]
        for row in snapshot.outline.rows { rows[row.id] = row }

        let groupRow = try #require(rows[fixture.group.id], "群组行必须出现在大纲里")
        let childRows = [fixture.first, fixture.milestone, fixture.delayed]
            .compactMap { rows[$0.id] }
        #expect(childRows.count == 3, "三个子任务都应展开可见")

        let starts = childRows.compactMap(\.scheduledStart)
        let finishes = childRows.compactMap(\.scheduledFinish)
        let earliestStart = try #require(starts.min(), "子任务必须都有排期")
        let latestFinish = try #require(finishes.max(), "子任务必须都有排期")

        // 夹具自检：里程碑落在常规任务结束那天，后移任务确实被依赖推晚——
        // 否则「取 min/max」与「取第一个/最后一个子任务」区分不出来。
        let firstRow = try #require(rows[fixture.first.id])
        let milestoneRow = try #require(rows[fixture.milestone.id])
        let delayedRow = try #require(rows[fixture.delayed.id])
        #expect(milestoneRow.scheduledStart == firstRow.scheduledFinish, "里程碑应跟在常规任务之后")
        #expect((delayedRow.scheduledStart ?? .distantPast) > (milestoneRow.scheduledStart ?? .distantFuture),
                "后移任务应晚于里程碑开始，夹具才有区分力")

        // 判据本体：群组起止 = 子任务最早开始 / 最晚结束。
        #expect(groupRow.scheduledStart == earliestStart)
        #expect(groupRow.scheduledFinish == latestFinish)
        #expect(groupRow.scheduledStart == firstRow.scheduledStart)
        #expect(groupRow.scheduledFinish == delayedRow.scheduledFinish)
        #expect(groupRow.isAggregate, "群组行必须标为聚合行")
        #expect(groupRow.hasSchedule, "有子任务排期时群组必须视为「有排期」")

        // 窗口必须包住每一个子任务（不能比子任务更窄）。
        for child in childRows {
            let start = try #require(child.scheduledStart)
            let finish = try #require(child.scheduledFinish)
            #expect(start >= (groupRow.scheduledStart ?? .distantFuture))
            #expect(finish <= (groupRow.scheduledFinish ?? .distantPast))
        }
    }

    /// 验收判据：5 天工作日历下，群组工期与排期结果同值（单位分裂回归）。
    ///
    /// 旧实现用「自然日差」算群组工期（大纲树直接做日期差），排期引擎用**工作日**：
    /// 7 天日历下两者恰好相等，一旦日历改成周一至周五（跨周末）就分叉——大纲显示 7 天、
    /// 排期与状态栏显示 5 天，同一行两个数。
    @Test func V140GroupDurationMatchesScheduleOnFiveDayWorkCalendar() throws {
        // 8 个工作日从周一 2026-10-05 开始：中间跨一个周末，
        // 自然日差（10 天左右）严格大于工作日（8 天）——任何一侧口径错都会露馅。
        let group = TaskItem(title: "阶段一", kind: .group)
        let child = TaskItem(title: "实现", kind: .task, parentID: group.id, durationDays: 8)
        let tasks = [group, child]
        let projectStart = v140Day(2026, 10, 5)
        let schedule = ScheduleEngine.compute(
            tasks: tasks,
            projectStart: projectStart,
            calendar: v140UTC,
            now: projectStart,
            workCalendar: WorkCalendar(workingWeekdays: WorkCalendar.mondayToFriday)
        )

        let entry = try #require(v140ScheduleEntry(schedule, group.id), "排期结果必须含群组条目")
        // 夹具自检：区间确实跨了周末，自然日 ≠ 工作日，否则本用例证明不了任何事。
        let calendarDays = v140CalendarDays(from: entry.scheduledStart, to: entry.scheduledFinish)
        #expect(calendarDays > entry.durationDays,
                "夹具必须落在「自然日 ≠ 工作日」的区间，否则单位分裂不会暴露")

        var viewState = WorkspaceViewState()
        viewState.expandedTaskIDs = [group.id]
        let snapshot = makeSnapshot(
            state: makeState(tasks, projectStart: projectStart),
            schedule: schedule,
            viewState: viewState,
            now: projectStart
        )
        let groupRow = try #require(snapshot.outline.rows.first { $0.id == group.id })

        // 判据本体：起止同源、工期同单位。
        #expect(groupRow.scheduledStart == entry.scheduledStart)
        #expect(groupRow.scheduledFinish == entry.scheduledFinish)
        let rowDuration = try #require(groupRow.durationDays, "群组行必须有工期")
        #expect(rowDuration == entry.durationDays,
                "群组工期必须与排期结果同单位（工作日），不能退回自然日差")
        #expect(rowDuration != calendarDays, "群组工期不得再用自然日差")
    }
}

// MARK: - 组 C：窗口外任务提示（D-040 / D-043）

/// 一个含「窗口左侧、跨越窗口、窗口右侧」三类条的固定项目。
///
/// 起点 2026-10-05（day 0），全部任务用 `startDate` 定位（引擎把它当「开始不早于」下界）：
///   A  day 0  … 3    （3 天，整条在窗口左侧）
///   B  day 0  … 12   （12 天，跨过整个窗口）
///   C  day 20 … 22   （2 天，整条在窗口右侧）
///   D  day 30 … 31   （1 天，更靠右）
private struct V140CoverageFixture {
    let tasks: [TaskItem]
    let projectStart: Date

    init() {
        let start = v140Day(2026, 10, 5)
        func shifted(_ days: Int) -> Date {
            v140UTC.date(byAdding: .day, value: days, to: start)!
        }
        tasks = [
            TaskItem(title: "前期调研", startDate: shifted(0), durationDays: 3),
            TaskItem(title: "长周期实现", startDate: shifted(0), durationDays: 12),
            TaskItem(title: "后续验证", startDate: shifted(20), durationDays: 2),
            TaskItem(title: "收尾", startDate: shifted(30), durationDays: 1),
        ]
        projectStart = start
    }

    /// 窗口起点（相对项目起点偏移的天数）。
    func windowStart(daysFromProjectStart days: Int) -> Date {
        v140UTC.date(byAdding: .day, value: days, to: projectStart)!
    }
}

struct V140OffWindowCoverageAcceptanceTests {
    private func snapshotForCoverage(
        fixture: V140CoverageFixture,
        windowStartDay: Int,
        spanDays: Int,
        canvasWidth: Double = 800
    ) -> WorkspaceSnapshot {
        let schedule = makeSchedule(
            fixture.tasks, projectStart: fixture.projectStart, now: fixture.projectStart
        )
        var viewState = WorkspaceViewState(widthMode: .span(days: spanDays, base: .week))
        viewState.windowStart = fixture.windowStart(daysFromProjectStart: windowStartDay)
        return makeSnapshot(
            state: makeState(fixture.tasks, projectStart: fixture.projectStart),
            schedule: schedule,
            viewState: viewState,
            viewport: WorkspaceViewport(canvasWidth: canvasWidth, canvasHeight: 600),
            now: fixture.projectStart
        )
    }

    /// 验收判据：一组条部分在窗口外时，外溢计数与手算一致，且侧别反映两个方向。
    ///
    /// 手算（窗口 = day 10 起 7 天，画布 800pt ⇒ 日宽 800/7 ≈ 114.29）：
    ///   A [day 0,3]    整条在窗口左侧 → 外溢（before）
    ///   B [day 0,12]   跨过窗口       → 窗内
    ///   C [day 20,22]  整条在窗口右侧 → 外溢（after）
    ///   D [day 30,31]  整条在窗口右侧 → 外溢（after）
    /// ⇒ 外溢 3 条、两侧都有 ⇒ side = .both。
    ///
    /// 期望值由**排期结果 + 快照的窗口/日宽**独立推算（日期 → 像素），
    /// 不读 `offWindow` 自己，否则实现怎么算都自洽，用例没有判别力。
    ///
    /// 注意：画布本身只画与窗口相交的条（`GanttLayout` 过滤），所以这里的 3 条
    /// 在 `snapshot.gantt.bars` 里根本不存在——提示是用户能看见它们的唯一渠道，
    /// 这也是本用例用排期而不是用 bars 推算期望值的原因。
    @Test func V140OffWindowCountMatchesHandCountWhenWindowSitsInTheMiddle() throws {
        let fixture = V140CoverageFixture()
        let canvasWidth = 800.0
        let snapshot = snapshotForCoverage(
            fixture: fixture, windowStartDay: 10, spanDays: 7, canvasWidth: canvasWidth
        )
        let gantt = snapshot.gantt
        let schedule = makeSchedule(
            fixture.tasks, projectStart: fixture.projectStart, now: fixture.projectStart
        )

        func projectedX(_ date: Date) -> Double {
            date.timeIntervalSince(gantt.windowStart) / 86_400 * gantt.dayWidth
        }
        func isOffWindow(_ entry: ScheduledTask) -> Bool {
            let startX = projectedX(entry.scheduledStart)
            let endX = projectedX(entry.scheduledFinish)
            // 与窗口有正长度交集才算窗内（端点擦边算窗外，与实现口径一致）。
            return !(endX > 0 && startX < canvasWidth)
        }

        // 夹具自检：先按排期确认「谁在左、谁跨窗口、谁在右」，再谈计数。
        let entries = schedule.tasks.filter { entry in
            fixture.tasks.contains { $0.id == entry.taskID }
        }
        #expect(entries.count == 4, "四条任务都应有排期条目")
        let offLeft = entries.filter { projectedX($0.scheduledFinish) <= 0 }
        let offRight = entries.filter { projectedX($0.scheduledStart) >= canvasWidth }
        let crossing = entries.filter { !isOffWindow($0) }
        #expect(offLeft.count == 1, "A 应整条落在窗口左侧")
        #expect(offRight.count == 2, "C、D 应整条落在窗口右侧")
        #expect(crossing.count == 1, "B 应跨过窗口")

        let expected = entries.filter(isOffWindow).count
        #expect(expected == 3, "手算的外溢条数是 3")
        #expect(gantt.offWindow.offWindowCount == expected, "快照报的外溢条数必须等于手算")
        #expect(gantt.offWindow.side == .both, "左右都有外溢时侧别必须是 both（不能只报一侧）")
    }
    /// 验收判据：全部条在窗口内时计数为 0，且 side 有确定值（不是 Optional nil）。
    @Test func V140AllBarsInsideReportsZeroAndDeterministicSide() throws {
        let fixture = V140CoverageFixture()
        let canvasWidth = 800.0
        // 40 天跨度从项目起点开始，覆盖 day 0…31 的全部条。
        let snapshot = snapshotForCoverage(
            fixture: fixture, windowStartDay: 0, spanDays: 40, canvasWidth: canvasWidth
        )
        let bars = snapshot.gantt.bars
        #expect(bars.count == 4, "四条都在窗内，画布上应四条都画出来")
        for bar in bars {
            #expect(bar.x >= 0 && bar.x + bar.width <= canvasWidth, "本用例要求四条都在窗内")
        }

        #expect(snapshot.gantt.offWindow.offWindowCount == 0)
        // 「有确定值」= 无外溢时仍是一个具体的枚举值（视图靠计数隐藏提示，不靠侧别）。
        #expect(snapshot.gantt.offWindow.side == .both)
    }
}

// MARK: - 组 B：窗口宽度来源单一化（D-041）

/// 验收判据：四种窗口宽度来源的派生值自洽——任一时刻只有一个来源生效，
/// 且落到画布上的日宽就是该来源声称的宽度。
struct V140WindowWidthModeAcceptanceTests {
    private let canvasWidth = 800.0

    private func dayWidth(for mode: WindowWidthMode, tasks: [TaskItem]) -> Double {
        var viewState = WorkspaceViewState(widthMode: mode)
        viewState.windowStart = v140Day(2026, 10, 5)
        let schedule = makeSchedule(tasks, projectStart: v140Day(2026, 10, 5), now: v140Day(2026, 10, 5))
        let snapshot = makeSnapshot(
            state: makeState(tasks, projectStart: v140Day(2026, 10, 5)),
            schedule: schedule,
            viewState: viewState,
            viewport: WorkspaceViewport(canvasWidth: canvasWidth, canvasHeight: 600),
            now: v140Day(2026, 10, 5)
        )
        return snapshot.gantt.dayWidth
    }

    /// 四种模式各自只有一个「正在生效的来源」，其余三项必须为空。
    @Test func V140EachModeHasExactlyOneActiveSource() {
        let modes: [WindowWidthMode] = [
            .preset(.day),
            .fit(.week),
            .custom(dayWidth: 20, base: .week),
            .span(days: 7, base: .week),
        ]
        for mode in modes {
            let activeSources = [
                mode.isFit,
                mode.isSpan,
                mode.customDayWidth != nil,
                !mode.isFit && !mode.isSpan && mode.customDayWidth == nil, // 「纯档位」
            ].filter { $0 }.count
            #expect(activeSources == 1, "模式 \(mode) 必须恰好有一个生效来源")
        }
        // 自定义与跨度不可并存（在构造点断言：枚举让矛盾态不可表示）。
        #expect(WindowWidthMode.custom(dayWidth: 20, base: .week).spanDays == nil)
        #expect(WindowWidthMode.span(days: 7, base: .week).customDayWidth == nil)
        // 由持久化三项还原时，自定义优先于「适合项目」，且永远不会还原出跨度。
        let restored = WindowWidthMode.fromPersisted(zoom: .week, usesFitZoom: true, customDayWidth: 20)
        #expect(restored.customDayWidth == 20)
        #expect(restored.spanDays == nil, "跨度不持久化，还原路径不得造出跨度")
        #expect(restored.isFit == false, "自定义是唯一权威日宽，fit 必须让位")
    }

    /// 派生值落到画布：每种模式的实际日宽与它声称的口径一致。
    @Test func V140DerivedDayWidthMatchesEachMode() {
        let tasks = [TaskItem(title: "实现", durationDays: 3)]
        let presetWidth = dayWidth(for: .preset(.day), tasks: tasks)
        #expect(presetWidth == GanttZoom.day.dayWidth, "档位模式的日宽必须等于档位默认宽度")

        let customWidth = dayWidth(for: .custom(dayWidth: 20, base: .week), tasks: tasks)
        #expect(customWidth == 20, "自定义模式必须原样使用自定义日宽")

        let spanWidth = dayWidth(for: .span(days: 7, base: .week), tasks: tasks)
        #expect(abs(spanWidth - canvasWidth / 7) < 0.001, "跨度模式的日宽 = 画布宽 / 跨度天数")

        let fitWidth = dayWidth(for: .fit(.week), tasks: tasks)
        // 适合项目的日宽 = 画布宽 /（内容天数），且末尾还留一天给零工期对象不越界，
        // 因此严格小于「按内容天数等分」的值，也必然不等于档位默认宽度。
        #expect(fitWidth > 0)
        #expect(fitWidth < canvasWidth / 3, "fit 会在内容末端补一天，不能等于按 3 天等分")
        #expect(fitWidth != GanttZoom.week.dayWidth, "fit 生效时不能退回档位默认宽度")
        #expect(fitWidth != customWidth && fitWidth != spanWidth, "fit 不能被自定义 / 跨度伪装")
    }

    /// 退出路径自洽：清掉自定义 / 退出 fit 都回到基准档位，不会掉进别的模式。
    @Test func V140ExitPathsReturnToBaseZoom() {
        #expect(WindowWidthMode.custom(dayWidth: 30, base: .month).asPreset == .preset(.month))
        #expect(WindowWidthMode.span(days: 14, base: .day).asPreset == .preset(.day))
        #expect(WindowWidthMode.fit(.week).withoutFit == .preset(.week))
        // 平移只该「关掉 fit」，不得把自定义 / 跨度降级成档位（否则日宽会跳变）。
        let custom = WindowWidthMode.custom(dayWidth: 20, base: .week)
        #expect(custom.withoutFit == custom)
        let span = WindowWidthMode.span(days: 7, base: .week)
        #expect(span.withoutFit == span)
    }
}

// MARK: - 组 B：偏好迁移口径（D-045）

/// 验收判据：schema 升级不得重置用户已经存过的窗口偏好；只有「没带 schema」的老数据才整块重置。
///
/// 这里钉的是**迁移决策**（纯函数，本地可跑）；App 层「真的从 UserDefaults 读回并落到
/// 快照」的端到端用例在 AppTests（只能 CI 跑）。
struct V140PreferencesMigrationAcceptanceTests {
    /// v2 数据（上一版真实写出的口径）升级后，自定义日宽必须原样保留、不得跳回 7 天跨度。
    @Test func V140SchemaTwoKeepsCustomDayWidth() {
        let mode = PreferencesMigrationPlan.widthMode(
            zoom: .day,
            usesFitZoom: true,
            customDayWidth: 20,
            schema: 2,
            defaultSpanDays: WorkspaceViewState.defaultWindowSpanDays
        )
        #expect(mode.customDayWidth == 20, "v2 的自定义日宽必须保留")
        #expect(mode.spanDays == nil, "有自定义日宽时不得再注入启动跨度")
        #expect(mode.isFit == false, "自定义是第一权威，fit 让位")
        #expect(PreferencesMigrationPlan.steps(from: 2).isEmpty, "v2 已是可信口径，不产生迁移步骤")
    }

    /// 以后把常量提到 3 / 4 时，v2 用户同样不得被重置（相等门回归的正面证据）。
    @Test func V140FutureSchemaKeepsExistingWindowPreferences() {
        for schema in [3, 4, 10] {
            let withCustom = PreferencesMigrationPlan.widthMode(
                zoom: .week,
                usesFitZoom: false,
                customDayWidth: 20,
                schema: schema,
                defaultSpanDays: WorkspaceViewState.defaultWindowSpanDays
            )
            #expect(withCustom.customDayWidth == 20, "schema=\(schema) 也必须保留自定义日宽")
            #expect(withCustom.spanDays == nil, "schema=\(schema) 不得把自定义改写回跨度")
            #expect(PreferencesMigrationPlan.steps(from: schema).isEmpty)

            // 没存自定义的老用户：启动照常注入跨度，但档位要保留，不是整块回默认。
            let noCustom = PreferencesMigrationPlan.widthMode(
                zoom: .month,
                usesFitZoom: false,
                customDayWidth: nil,
                schema: schema,
                defaultSpanDays: WorkspaceViewState.defaultWindowSpanDays
            )
            #expect(noCustom.spanDays == WorkspaceViewState.defaultWindowSpanDays)
            #expect(noCustom.baseZoom == .month, "档位是用户偏好，升版本不得丢")
        }
    }

    /// 无 schema（= v1）/ schema 1：窗口宽度偏好整块重置为启动口径。
    @Test func V140LegacySchemaResetsWindowWidthPreferences() {
        for schema: Int? in [nil, 1] {
            let mode = PreferencesMigrationPlan.widthMode(
                zoom: .day,
                usesFitZoom: true,
                customDayWidth: 20,
                schema: schema,
                defaultSpanDays: WorkspaceViewState.defaultWindowSpanDays
            )
            #expect(mode.customDayWidth == nil, "老数据的自定义日宽必须清掉（schema=\(String(describing: schema))）")
            #expect(mode.spanDays == WorkspaceViewState.defaultWindowSpanDays, "重置后回到启动跨度")
            #expect(mode.baseZoom == WorkspaceViewState().zoom, "档位一并回默认")
            #expect(PreferencesMigrationPlan.steps(from: schema) == [.resetWindowWidth])
        }
    }
}
