import Foundation
import Testing
import KaidoCore
import KaidoPresentation

/// 工作日历进入呈现层（F-22-06 / docs/features/16-work-calendar.md §3）。
///
/// 两条派生都在这里钉住：
/// 1. 甘特非工作带 = 项目日历的「非上班日」补集（无日历 ⇔ 一条不画，默认渲染逐像素不变）；
/// 2. 顺延留痕按任务过滤后进检查器，空数组 ⇒ 视图整段不显示。
///
/// 时间线本身由 `ScheduleEngine.compute(workCalendar:)` 直接算，不经会话：
/// 这条用例只证呈现层派生，不替会话接线背书。
@Suite("工作日历呈现（F-22-06）")
struct WorkCalendarPresentationTests {
    /// 2025-01-06 是周一：以周一为项目起点，周末（1/11 周六、1/12 周日）落在窗口里。
    private let projectStart = makeDate(2025, 1, 6)
    private var now: Date { projectStart }
    private let fiveDayWeek = WorkCalendar(workingWeekdays: WorkCalendar.mondayToFriday)

    // MARK: - 夹具

    private func makeProjectState(
        _ tasks: [TaskItem],
        calendar: WorkCalendar?
    ) -> ProjectState {
        ProjectState(
            metadata: ProjectMetadata(
                title: "日历项目",
                createdAt: makeDate(2025, 1, 1),
                updatedAt: makeDate(2025, 1, 1),
                projectStart: projectStart,
                calendar: calendar
            ),
            tasks: tasks,
            resources: []
        )
    }

    private func computeSchedule(
        _ tasks: [TaskItem],
        calendar: WorkCalendar?
    ) -> ScheduleResult {
        ScheduleEngine.compute(
            tasks: tasks,
            projectStart: projectStart,
            calendar: testCalendar,
            now: now,
            workCalendar: calendar
        )
    }

    /// 非工作带落在哪一天：把带子的 x 折回日期再取 weekday（1 = 周日 … 7 = 周六）。
    private func weekday(ofBandX x: Double, in gantt: GanttSnapshot) -> Int? {
        guard gantt.dayWidth > 0 else { return nil }
        let offset = Int((x / gantt.dayWidth).rounded())
        guard let day = testCalendar.date(byAdding: .day, value: offset, to: gantt.windowStart) else {
            return nil
        }
        return testCalendar.component(.weekday, from: day)
    }

    // MARK: - 甘特铺灰

    @Test func noCalendarLeavesTimelineUnshaded() {
        let tasks = [TaskItem(title: "实现", startDate: projectStart, durationDays: 5)]
        let snapshot = makeSnapshot(
            state: makeProjectState(tasks, calendar: nil),
            schedule: computeSchedule(tasks, calendar: nil),
            now: now
        )
        #expect(snapshot.gantt.bands.isEmpty, "没有日历 ⇒ 不画非工作带（默认渲染不变）")
    }

    @Test func sevenDayCalendarLeavesTimelineUnshadedEvenWithToggleOn() {
        let tasks = [TaskItem(title: "实现", startDate: projectStart, durationDays: 5)]
        var viewState = WorkspaceViewState()
        // 日历存在时以日历为准：全周 7 天的补集是空集，开关也不该把周末补回来。
        viewState.showsNonWorkingDays = true
        let snapshot = makeSnapshot(
            state: makeProjectState(tasks, calendar: WorkCalendar()),
            schedule: computeSchedule(tasks, calendar: WorkCalendar()),
            viewState: viewState,
            now: now
        )
        #expect(snapshot.gantt.bands.isEmpty, "全周 7 天的日历 = 没有非工作日")
    }

    @Test func fiveDayCalendarShadesOnlyWeekend() {
        let tasks = [TaskItem(title: "实现", startDate: projectStart, durationDays: 5)]
        let snapshot = makeSnapshot(
            state: makeProjectState(tasks, calendar: fiveDayWeek),
            schedule: computeSchedule(tasks, calendar: fiveDayWeek),
            now: now
        )
        #expect(!snapshot.gantt.bands.isEmpty, "周一至周五工作 ⇒ 周末应铺灰")
        for band in snapshot.gantt.bands {
            let day = weekday(ofBandX: band.x, in: snapshot.gantt)
            #expect(day == 1 || day == 7, "非工作带只应落在周末，实际 weekday=\(String(describing: day))")
        }
    }

    @Test func customWeekShadesTheDeclaredDaysOff() {
        // 只有周一到周三上班：周四 / 周五 / 周末都该铺灰。
        let calendar = WorkCalendar(workingWeekdays: [2, 3, 4])
        let tasks = [TaskItem(title: "实现", startDate: projectStart, durationDays: 3)]
        let snapshot = makeSnapshot(
            state: makeProjectState(tasks, calendar: calendar),
            schedule: computeSchedule(tasks, calendar: calendar),
            now: now
        )
        let days = Set(snapshot.gantt.bands.compactMap { weekday(ofBandX: $0.x, in: snapshot.gantt) })
        #expect(days == [1, 5, 6, 7], "非工作带应覆盖周四、周五与周末，实际 \(days)")
    }

    // MARK: - 排期随日历变化

    @Test func fiveDayCalendarPushesSuccessorPastWeekend() throws {
        let design = TaskItem(title: "设计", startDate: projectStart, durationDays: 5)
        let build = TaskItem(
            title: "开发",
            durationDays: 1,
            dependencies: [TaskDependency(predecessorID: design.id)]
        )
        let tasks = [design, build]

        let allWeek = computeSchedule(tasks, calendar: nil)
        let fiveDay = computeSchedule(tasks, calendar: fiveDayWeek)

        let startAll = try #require(allWeek.scheduled(build.id)?.scheduledStart)
        let startFive = try #require(fiveDay.scheduled(build.id)?.scheduledStart)
        // 全周：周二 + 5 天 = 周六；5 天工作周：顺延到下一个周一（+2 天）。
        #expect(startAll == makeDate(2025, 1, 11))
        #expect(startFive == makeDate(2025, 1, 13))

        let base = makeSnapshot(
            state: makeProjectState(tasks, calendar: nil),
            schedule: allWeek,
            now: now
        )
        let withCalendar = makeSnapshot(
            state: makeProjectState(tasks, calendar: fiveDayWeek),
            schedule: fiveDay,
            now: now
        )
        let baseBar = try #require(base.gantt.bars.first { $0.taskID == build.id })
        let shiftedBar = try #require(withCalendar.gantt.bars.first { $0.taskID == build.id })
        // 两份快照的日宽可能不同（内容范围变了，档位自适应），因此按「第几天」比较而不是按点。
        let baseOffset = (baseBar.x / base.gantt.dayWidth).rounded()
        let shiftedOffset = (shiftedBar.x / withCalendar.gantt.dayWidth).rounded()
        #expect(baseOffset == 5, "全周：周二起 5 天工期 ⇒ 后继落在窗口第 6 天（周六）")
        #expect(shiftedOffset == 7, "5 天工作周：后继顺延到下一个周一，窗口第 8 天")
        #expect(shiftedOffset - baseOffset == 2, "同一任务条应整体右移两天")
    }

    @Test func holidayExceptionMovesStartToNextWorkingDay() throws {
        let friday = makeDate(2025, 1, 10)
        let calendar = WorkCalendar(
            workingWeekdays: WorkCalendar.mondayToFriday,
            exceptions: [CalendarException(date: friday, isWorking: false, note: "公司假")]
        )
        let task = TaskItem(title: "上线", startDate: friday, durationDays: 1)
        let result = computeSchedule([task], calendar: calendar)

        #expect(result.scheduled(task.id)?.scheduledStart == makeDate(2025, 1, 13))
        let adjustments = result.calendarAdjustments.filter { $0.taskID == task.id }
        #expect(adjustments.count == 1, "输入日期落在例外日应留一条顺延记录")
        #expect(adjustments.first?.requested == friday)
        #expect(adjustments.first?.adjusted == makeDate(2025, 1, 13))
        #expect(adjustments.first?.kind == .nonWorkingDay)
    }

    // MARK: - 顺延留痕

    @Test func rowsKeepOnlyTheRequestedTaskInOrder() {
        let first = UUID()
        let second = UUID()
        let adjustments = [
            // 项目级说明（工作周为空而退化）不属于任何任务。
            CalendarAdjustment(taskID: nil, kind: .invalidWeekdays, requested: now, adjusted: now),
            CalendarAdjustment(
                taskID: first,
                kind: .nonWorkingDay,
                requested: makeDate(2025, 1, 11),
                adjusted: makeDate(2025, 1, 13)
            ),
            CalendarAdjustment(
                taskID: second,
                kind: .nonWorkingDay,
                requested: makeDate(2025, 1, 12),
                adjusted: makeDate(2025, 1, 13)
            ),
            CalendarAdjustment(
                taskID: first,
                kind: .nonWorkingDay,
                requested: makeDate(2025, 1, 4),
                adjusted: makeDate(2025, 1, 6)
            ),
        ]

        let rows = CalendarAdjustmentRow.rows(from: adjustments, taskID: first)
        #expect(rows.count == 2)
        #expect(rows.map(\.requested) == [makeDate(2025, 1, 11), makeDate(2025, 1, 4)])
        #expect(rows.map(\.kind) == [.nonWorkingDay, .nonWorkingDay])
        #expect(Set(rows.map(\.id)).count == 2, "同任务多条留痕的 id 不得相同")
        #expect(CalendarAdjustmentRow.rows(from: adjustments, taskID: UUID()).isEmpty)
    }

    @Test func inspectorShowsAdjustmentsForTheSelectedTask() throws {
        let friday = makeDate(2025, 1, 10)
        let calendar = WorkCalendar(
            workingWeekdays: WorkCalendar.mondayToFriday,
            exceptions: [CalendarException(date: friday, isWorking: false, note: "公司假")]
        )
        let task = TaskItem(title: "上线", startDate: friday, durationDays: 1)
        let tasks = [task]
        var viewState = WorkspaceViewState()
        viewState.selectedTaskID = task.id

        let snapshot = makeSnapshot(
            state: makeProjectState(tasks, calendar: calendar),
            schedule: computeSchedule(tasks, calendar: calendar),
            viewState: viewState,
            now: now
        )
        guard case .task(let inspector) = snapshot.inspector.content else {
            Issue.record("选中任务后检查器应为任务页")
            return
        }
        #expect(inspector.calendarAdjustments.count == 1)
        let row = try #require(inspector.calendarAdjustments.first)
        #expect(row.requested == friday)
        #expect(row.adjusted == makeDate(2025, 1, 13))
    }

    @Test func inspectorOmitsAdjustmentsWhenNothingWasMoved() throws {
        let task = TaskItem(title: "实现", startDate: projectStart, durationDays: 2)
        var viewState = WorkspaceViewState()
        viewState.selectedTaskID = task.id

        let snapshot = makeSnapshot(
            state: makeProjectState([task], calendar: nil),
            schedule: computeSchedule([task], calendar: nil),
            viewState: viewState,
            now: now
        )
        guard case .task(let inspector) = snapshot.inspector.content else {
            Issue.record("选中任务后检查器应为任务页")
            return
        }
        #expect(inspector.calendarAdjustments.isEmpty, "没有顺延就不显示该区块")
    }
}
