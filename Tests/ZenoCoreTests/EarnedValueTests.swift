import Foundation
import Testing
@testable import ZenoCore

// EVM 计算口径（17-evm-status-date §4）：PV / EV / SV / SPI。
// 纪律：时刻一律由字面日期构造，不读墙钟（`now` 注入）；期望值写死，不用被测函数现算。
// 夹具固定 2026-10-05（周一）起始的五天工作周。

// MARK: - 夹具

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int, hour: Int = 0) -> Date {
    utc.date(from: DateComponents(year: year, month: month, day: dayOfMonth, hour: hour))!
}

/// 2026-10-05 是周一：一周 = 5, 6, 7, 8, 9（周一至周五）。
private func fiveDayWeek(hoursPerDay: Double = 8) -> WorkCalendar {
    WorkCalendar(workingWeekdays: WorkCalendar.mondayToFriday, hoursPerDay: hoursPerDay)
}

private func scheduled(
    _ taskID: UUID,
    start: Date,
    finish: Date,
    durationDays: Double = 0
) -> ScheduledTask {
    ScheduledTask(
        taskID: taskID,
        durationDays: durationDays,
        earliestStart: start,
        earliestFinish: finish,
        latestStart: start,
        latestFinish: finish,
        scheduledStart: start,
        scheduledFinish: finish,
        totalSlackDays: 0,
        freeSlackDays: 0
    )
}

private func close(_ actual: Double, _ expected: Double) -> Bool {
    abs(actual - expected) < 1e-9
}

/// 一条 40 小时、跨 5 个工作日的任务（10-05 → 10-12，右端开区间）。
private func fiveDayTask(
    _ id: UUID = UUID(),
    effort: Double? = 40,
    progress: Double = 0,
    completedAt: Date? = nil
) -> TaskItem {
    TaskItem(
        id: id,
        title: "任务",
        effortHours: effort,
        durationDays: 5,
        progress: progress,
        completedAt: completedAt
    )
}

private func report(
    tasks: [TaskItem],
    schedule: [ScheduledTask],
    statusDate: Date?,
    unscheduled: [UUID] = [],
    week: WorkCalendar? = nil,
    now: Date = day(2026, 10, 7)
) -> EarnedValueReport {
    EarnedValueEngine.report(
        schedule: ScheduleResult(tasks: schedule, unscheduledTaskIDs: unscheduled),
        tasks: tasks,
        statusDate: statusDate,
        workCalendar: week ?? fiveDayWeek(),
        calendar: utc,
        now: now
    )
}

// MARK: - 数据日期（可复现性）

struct EarnedValueStatusDateTests {
    @Test func nilStatusDateEqualsExplicitTodayAtStartOfDay() {
        let task = fiveDayTask()
        let schedule = [scheduled(task.id, start: day(2026, 10, 5), finish: day(2026, 10, 12), durationDays: 5)]

        let today = report(tasks: [task], schedule: schedule, statusDate: nil, now: day(2026, 10, 7, hour: 15))
        let explicit = report(tasks: [task], schedule: schedule, statusDate: day(2026, 10, 7))

        #expect(today.statusDate == day(2026, 10, 7))
        #expect(explicit.statusDate == day(2026, 10, 7))
        #expect(today.isStatusDateFixed == false)
        #expect(explicit.isStatusDateFixed == true)
        #expect(close(today.plannedValue, explicit.plannedValue))
        #expect(close(today.earnedValue, explicit.earnedValue))
        #expect(close(today.scheduleVariance, explicit.scheduleVariance))
        #expect(today.tasks == explicit.tasks)
    }

    @Test func fixedStatusDateIsReproducibleRegardlessOfWallClock() {
        let task = fiveDayTask(progress: 0.5)
        let schedule = [scheduled(task.id, start: day(2026, 10, 5), finish: day(2026, 10, 12), durationDays: 5)]
        let fixed = day(2026, 10, 7)

        let first = report(tasks: [task], schedule: schedule, statusDate: fixed, now: day(2026, 10, 7))
        let second = report(tasks: [task], schedule: schedule, statusDate: fixed, now: day(2026, 11, 20))

        // 数据日期一固定，墙钟与报告内容彻底脱钩：同一天算两次必须逐字段相同。
        #expect(first == second)
        #expect(close(first.plannedValue, 16))
        #expect(close(first.earnedValue, 20))
    }
}

// MARK: - PV

struct EarnedValuePlannedValueTests {
    @Test func plannedValueAdvancesByWorkingDaysOnFiveDayWeek() {
        let task = fiveDayTask()
        let schedule = [scheduled(task.id, start: day(2026, 10, 5), finish: day(2026, 10, 12), durationDays: 5)]

        // 10-05 周一 → 10-12 下周一 = 5 个工作日；10-07 是第 3 天开始，已过 2 个工作日 → 2/5。
        let wednesday = report(tasks: [task], schedule: schedule, statusDate: day(2026, 10, 7))
        #expect(close(wednesday.plannedValue, 16))
        // 若按日历天插值会得到 40 × 2/7 ≈ 11.43：周末不该推快 PV。
        #expect(!close(wednesday.plannedValue, 40 * 2 / 7))

        let thursday = report(tasks: [task], schedule: schedule, statusDate: day(2026, 10, 8))
        #expect(close(thursday.plannedValue, 24))

        let friday = report(tasks: [task], schedule: schedule, statusDate: day(2026, 10, 9))
        #expect(close(friday.plannedValue, 32))
    }

    @Test func plannedValueIsZeroBeforeStartAndFullAfterFinish() {
        let task = fiveDayTask()
        let schedule = [scheduled(task.id, start: day(2026, 10, 5), finish: day(2026, 10, 12), durationDays: 5)]

        let before = report(tasks: [task], schedule: schedule, statusDate: day(2026, 9, 30))
        #expect(close(before.plannedValue, 0))

        let after = report(tasks: [task], schedule: schedule, statusDate: day(2026, 10, 20))
        #expect(close(after.plannedValue, 40))
    }

    @Test func milestoneIsBinaryNotInterpolated() {
        let milestone = TaskItem(title: "里程碑", kind: .milestone, effortHours: 8)
        let schedule = [scheduled(milestone.id, start: day(2026, 10, 5), finish: day(2026, 10, 5))]

        let onDay = report(tasks: [milestone], schedule: schedule, statusDate: day(2026, 10, 5))
        #expect(close(onDay.plannedValue, 8))

        let dayBefore = report(tasks: [milestone], schedule: schedule, statusDate: day(2026, 10, 4))
        #expect(close(dayBefore.plannedValue, 0))
        #expect(dayBefore.schedulePerformanceIndex == nil)
    }
}

// MARK: - EV（effectiveProgress 的三条规则）

struct EarnedValueEarnedValueTests {
    @Test func unfinishedTaskIsCreditedByProgress() {
        let task = fiveDayTask(progress: 0.25)
        let schedule = [scheduled(task.id, start: day(2026, 10, 5), finish: day(2026, 10, 12), durationDays: 5)]

        let result = report(tasks: [task], schedule: schedule, statusDate: day(2026, 10, 7))

        #expect(close(result.earnedValue, 10))
        #expect(close(result.plannedValue, 16))
        #expect(close(result.scheduleVariance, -6))
        #expect(result.tasks.first.map { close($0.effectiveProgress, 0.25) } == true)
    }

    @Test func actualFinishBeforeStatusDateForcesFullCreditIgnoringProgress() {
        let task = fiveDayTask(progress: 0.6, completedAt: day(2026, 10, 6))
        let schedule = [scheduled(task.id, start: day(2026, 10, 5), finish: day(2026, 10, 12), durationDays: 5)]

        let result = report(tasks: [task], schedule: schedule, statusDate: day(2026, 10, 7))

        // 已完成就是 100%：进度字段填了 0.6 也不打折。
        #expect(close(result.earnedValue, 40))
        #expect(result.tasks.first.map { close($0.effectiveProgress, 1) } == true)
        #expect(close(result.schedulePerformanceIndex ?? .nan, 2.5))
    }

    @Test func actualFinishAfterStatusDateIsNotCounted() {
        let task = fiveDayTask(progress: 1, completedAt: day(2026, 10, 9))
        let schedule = [scheduled(task.id, start: day(2026, 10, 5), finish: day(2026, 10, 12), durationDays: 5)]

        // 追溯 10-07 这个历史时点：之后（10-09）才完成的工作不得计入，哪怕现在 progress = 1。
        let result = report(tasks: [task], schedule: schedule, statusDate: day(2026, 10, 7))

        #expect(close(result.earnedValue, 0))
        #expect(result.tasks.first.map { close($0.effectiveProgress, 0) } == true)
        #expect(close(result.plannedValue, 16))
    }

    @Test func completionOnStatusDateCountsAsDone() {
        let task = fiveDayTask(progress: 0, completedAt: day(2026, 10, 7, hour: 18))
        let schedule = [scheduled(task.id, start: day(2026, 10, 5), finish: day(2026, 10, 12), durationDays: 5)]

        // 数据日期是当日 00:00：当天傍晚完成按「整日」比较仍算已完成，不因时分被踢出。
        let result = report(tasks: [task], schedule: schedule, statusDate: day(2026, 10, 7))

        #expect(close(result.earnedValue, 40))
    }

    @Test func milestoneEarnedValueIsBinary() {
        let milestone = TaskItem(
            title: "里程碑",
            kind: .milestone,
            effortHours: 8,
            completedAt: day(2026, 10, 5)
        )
        let schedule = [scheduled(milestone.id, start: day(2026, 10, 5), finish: day(2026, 10, 5))]

        let onDay = report(tasks: [milestone], schedule: schedule, statusDate: day(2026, 10, 5))
        #expect(close(onDay.earnedValue, 8))
        #expect(close(onDay.scheduleVariance, 0))

        let dayBefore = report(tasks: [milestone], schedule: schedule, statusDate: day(2026, 10, 4))
        #expect(close(dayBefore.earnedValue, 0))
    }
}

// MARK: - 汇总（SV / SPI）与参与范围

struct EarnedValueAggregateTests {
    @Test func cancelledTasksStayOutOfBothSides() {
        let active = fiveDayTask(progress: 0.5)
        var cancelled = fiveDayTask(effort: 100, progress: 1)
        cancelled.status = .cancelled
        cancelled.cancelReason = "决定不做"
        let schedule = [
            scheduled(active.id, start: day(2026, 10, 5), finish: day(2026, 10, 12), durationDays: 5),
            scheduled(cancelled.id, start: day(2026, 10, 5), finish: day(2026, 10, 12), durationDays: 5),
        ]

        let result = report(tasks: [active, cancelled], schedule: schedule, statusDate: day(2026, 10, 7))

        // 取消的任务既不进分子也不进分母：若它计入，PV 会是 16 + 40 = 56。
        #expect(result.tasks.count == 1)
        #expect(result.excludedTaskCount == 1)
        #expect(close(result.plannedValue, 16))
        #expect(close(result.earnedValue, 20))
        #expect(result.task(cancelled.id) == nil)
    }

    @Test func nothingDueYetGivesNilSPIAndZeroSV() {
        let first = fiveDayTask(progress: 0)
        let second = fiveDayTask(progress: 0)
        let schedule = [
            scheduled(first.id, start: day(2026, 10, 5), finish: day(2026, 10, 12), durationDays: 5),
            scheduled(second.id, start: day(2026, 10, 5), finish: day(2026, 10, 12), durationDays: 5),
        ]

        let result = report(tasks: [first, second], schedule: schedule, statusDate: day(2026, 10, 1))

        #expect(close(result.plannedValue, 0))
        #expect(close(result.earnedValue, 0))
        #expect(close(result.scheduleVariance, 0))
        // ΣPV = 0 时比值无定义：nil，而不是 0 或 ∞。
        #expect(result.schedulePerformanceIndex == nil)
    }

    @Test func spiEqualsOneWhenProgressMatchesPlan() {
        let task = fiveDayTask(progress: 1)
        let schedule = [scheduled(task.id, start: day(2026, 10, 5), finish: day(2026, 10, 12), durationDays: 5)]

        let result = report(tasks: [task], schedule: schedule, statusDate: day(2026, 10, 20))

        #expect(close(result.plannedValue, 40))
        #expect(close(result.earnedValue, 40))
        #expect(close(result.schedulePerformanceIndex ?? .nan, 1))
    }

    @Test func emptyProjectProducesEmptyReport() {
        let result = report(tasks: [], schedule: [], statusDate: day(2026, 10, 7))

        #expect(result.tasks.isEmpty)
        #expect(result.excludedTaskCount == 0)
        #expect(close(result.plannedValue, 0))
        #expect(close(result.earnedValue, 0))
        #expect(close(result.scheduleVariance, 0))
        #expect(result.schedulePerformanceIndex == nil)
    }

    @Test func groupsAreNotCountedTwice() {
        let group = TaskItem(title: "阶段", kind: .group, effortHours: 40, durationDays: 5)
        let child = TaskItem(
            title: "子任务",
            parentID: group.id,
            effortHours: 40,
            durationDays: 5
        )
        let schedule = [
            scheduled(group.id, start: day(2026, 10, 5), finish: day(2026, 10, 12), durationDays: 5),
            scheduled(child.id, start: day(2026, 10, 5), finish: day(2026, 10, 12), durationDays: 5),
        ]

        let result = report(tasks: [group, child], schedule: schedule, statusDate: day(2026, 10, 7))

        // 群组的时间窗来自子树聚合：把它的投入也算一遍会把 PV 翻倍（32 而不是 16）。
        #expect(result.tasks.map(\.taskID) == [child.id])
        #expect(result.excludedTaskCount == 1)
        #expect(close(result.plannedValue, 16))
    }

    @Test func unscheduledTasksAreExcluded() {
        let task = fiveDayTask()
        let schedule = [scheduled(task.id, start: day(2026, 10, 5), finish: day(2026, 10, 12), durationDays: 5)]

        let result = report(
            tasks: [task],
            schedule: schedule,
            statusDate: day(2026, 10, 7),
            unscheduled: [task.id]
        )

        #expect(result.tasks.isEmpty)
        #expect(result.excludedTaskCount == 1)
        #expect(result.schedulePerformanceIndex == nil)
    }
}

// MARK: - 投入兜底

struct EarnedValueEffortTests {
    @Test func missingEffortFallsBackToDurationTimesHoursPerDay() {
        let task = TaskItem(title: "未填投入", durationDays: 3)
        let schedule = [scheduled(task.id, start: day(2026, 10, 5), finish: day(2026, 10, 8), durationDays: 3)]

        let result = report(tasks: [task], schedule: schedule, statusDate: day(2026, 10, 8))

        // 3 个工作日 × 8 小时/日 = 24。
        #expect(close(result.plannedValue, 24))
        #expect(result.tasks.first?.isEffortEstimated == true)
        #expect(result.estimatedEffortTaskIDs == [task.id])
    }

    @Test func explicitEffortIsNotMarkedAsEstimated() {
        let task = fiveDayTask()
        let schedule = [scheduled(task.id, start: day(2026, 10, 5), finish: day(2026, 10, 12), durationDays: 5)]

        let result = report(tasks: [task], schedule: schedule, statusDate: day(2026, 10, 7))

        #expect(result.tasks.first?.isEffortEstimated == false)
        #expect(result.estimatedEffortTaskIDs.isEmpty)
    }

    @Test func zeroDurationTaskWithoutEffortWeighsNothing() {
        let milestone = TaskItem(title: "无投入里程碑", kind: .milestone)
        let schedule = [scheduled(milestone.id, start: day(2026, 10, 5), finish: day(2026, 10, 5))]

        let result = report(tasks: [milestone], schedule: schedule, statusDate: day(2026, 10, 6))

        // 兜底算出 0 小时不是错误：里程碑本来就不携带工作量，只是不进分子分母。
        #expect(close(result.plannedValue, 0))
        #expect(result.schedulePerformanceIndex == nil)
    }
}
