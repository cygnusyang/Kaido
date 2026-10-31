import Foundation
import Testing
@testable import ZenoCore

// F-22-06 / 16-work-calendar §4：工期单位从「日历天」改为「工作日」。
//
// 三条红线：
//   D1 默认全周 7 天时工作日 == 日历天，既有排期逐位不变；
//   D2 日历挂在 Project 上是可选加法字段，.zeno 仍为 formatVersion 2；
//   D3 约束 / 开始日期落在非工作日时向后吸附并继续排期，同时留一条记录（不阻断、不静默）。

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d))!
}

// 2026-11-02 周一；11-06 周五；11-07 周六；11-08 周日；11-09 下周一；11-13 下周五。
private let monday = day(2026, 11, 2)
private let friday = day(2026, 11, 6)
private let saturday = day(2026, 11, 7)
private let sunday = day(2026, 11, 8)

private let fiveDayWeek = WorkCalendar(workingWeekdays: WorkCalendar.mondayToFriday)

private func compute(
    _ tasks: [TaskItem],
    start: Date? = monday,
    end: Date? = nil,
    workCalendar: WorkCalendar? = nil
) -> ScheduleResult {
    ScheduleEngine.compute(
        tasks: tasks, projectStart: start, projectEnd: end, calendar: utc, workCalendar: workCalendar
    )
}

struct WorkCalendarTests {
    // MARK: - §4-1 默认 7 天全量不变（D1）

    @Test func defaultSevenDayWeekKeepsLegacyDates() throws {
        let task = TaskItem(title: "T", durationDays: 3)
        let legacy = compute([task])
        let explicitFullWeek = compute([task], workCalendar: WorkCalendar())

        let l = try #require(legacy.scheduled(task.id))
        let e = try #require(explicitFullWeek.scheduled(task.id))

        #expect(l.scheduledStart == monday)
        #expect(l.scheduledFinish == day(2026, 11, 5))
        // 显式写「全周 7 天」与不写日历必须逐字段相等——这是 D1 的唯一保证。
        #expect(e.scheduledStart == l.scheduledStart)
        #expect(e.scheduledFinish == l.scheduledFinish)
        #expect(e.totalSlackDays == l.totalSlackDays)
        #expect(legacy.calendarAdjustments.isEmpty)
        #expect(explicitFullWeek.calendarAdjustments.isEmpty)
    }

    // MARK: - §4-2 5 天周：周五开始、工期 5 天（跨周末）

    @Test func fiveDayWeekTaskSpansWeekend() throws {
        let task = TaskItem(title: "跨周末", startDate: friday, durationDays: 5)

        let s = try #require(compute([task], workCalendar: fiveDayWeek).scheduled(task.id))

        #expect(s.scheduledStart == friday)
        // 5 个工作日 = 周五 + 下周一…下周四（收尾），finish 是半开区间的次日（下周五）。
        #expect(fiveDayWeek.addingWorkDays(4, to: friday, calendar: utc) == day(2026, 11, 12))
        #expect(s.scheduledFinish == day(2026, 11, 13))
        #expect(s.durationDays == 5)
    }

    // MARK: - §4-3 5 天周 FS 链（每跨一次周末整体右移 2 天）

    @Test func fiveDayWeekFSChainShiftsByTwoDaysPerWeekend() throws {
        let a = TaskItem(title: "A", durationDays: 3)
        let b = TaskItem(
            title: "B", durationDays: 3,
            dependencies: [TaskDependency(predecessorID: a.id, type: .fs)]
        )
        let c = TaskItem(
            title: "C", durationDays: 3,
            dependencies: [TaskDependency(predecessorID: b.id, type: .fs)]
        )

        let five = compute([a, b, c], workCalendar: fiveDayWeek)
        let seven = compute([a, b, c])

        let sa = try #require(five.scheduled(a.id))
        let sb = try #require(five.scheduled(b.id))
        let sc = try #require(five.scheduled(c.id))
        let rc = try #require(seven.scheduled(c.id))

        // A：周一 + 3 个工作日 = 周四收尾，finish 为周四之后的下一工作日（周五）。
        #expect(sa.scheduledStart == monday)
        #expect(sa.scheduledFinish == day(2026, 11, 5))
        // B：周五一整天 + 下周一、周二。
        #expect(sb.scheduledStart == day(2026, 11, 5))
        #expect(sb.scheduledFinish == day(2026, 11, 10))
        // C：接在 B 之后，再跨一次周末。
        #expect(sc.scheduledStart == day(2026, 11, 10))
        #expect(sc.scheduledFinish == day(2026, 11, 13))
        // 链尾比 7 天周晚 2 天/次周末：11-11 → 11-13。
        #expect(rc.scheduledFinish == day(2026, 11, 11))
    }

    // MARK: - §4-4 节假日（3 天假期）

    @Test func holidaysPushFinishAndRecordAdjustment() throws {
        let holidays = [
            CalendarException(date: day(2026, 11, 3), isWorking: false, note: "假期"),
            CalendarException(date: day(2026, 11, 4), isWorking: false, note: "假期"),
            CalendarException(date: day(2026, 11, 5), isWorking: false, note: "假期")
        ]
        let calendar = WorkCalendar(exceptions: holidays)

        let crossing = TaskItem(title: "跨假期", durationDays: 5)
        let startingOnHoliday = TaskItem(title: "假日开始", startDate: day(2026, 11, 3), durationDays: 1)

        let result = compute([crossing, startingOnHoliday], workCalendar: calendar)
        let s = try #require(result.scheduled(crossing.id))
        let h = try #require(result.scheduled(startingOnHoliday.id))

        // 7 天周的 5 天任务本该 11-07 结束；假期吃掉 3 天 → 顺延到 11-10（顺延 3 天）。
        #expect(s.scheduledFinish == day(2026, 11, 10))
        // 开始日落在假期 → 吸附到假期后第一个工作日（11-06），不拒绝、不静默。
        #expect(h.scheduledStart == day(2026, 11, 6))

        let adjustments = result.calendarAdjustments
        #expect(adjustments.count == 1)
        let only = try #require(adjustments.first)
        #expect(only.taskID == startingOnHoliday.id)
        #expect(only.kind == .nonWorkingDay)
        #expect(only.requested == day(2026, 11, 3))
        #expect(only.adjusted == day(2026, 11, 6))
    }

    // MARK: - §4-5 调休：周六补班

    @Test func makeUpSaturdayCountsAsWorkingDay() throws {
        let calendar = WorkCalendar(
            workingWeekdays: WorkCalendar.mondayToFriday,
            exceptions: [CalendarException(date: saturday, isWorking: true, note: "调休补班")]
        )
        let task = TaskItem(title: "补班", startDate: friday, durationDays: 2)

        let s = try #require(compute([task], workCalendar: calendar).scheduled(task.id))

        // 周五之后：周六（补班）+ 下周一 = 2 个工作日；没有补班才是下周一 + 下周二。
        #expect(s.scheduledFinish == day(2026, 11, 9))
        #expect(calendar.isWorkingDay(saturday, calendar: utc))
        #expect(fiveDayWeek.isWorkingDay(saturday, calendar: utc) == false)
    }

    // MARK: - §4-6 里程碑落在周六（5 天周）

    @Test func milestoneOnSaturdaySnapsToMonday() throws {
        let milestone = TaskItem(title: "M", startDate: saturday, kind: .milestone)

        let result = compute([milestone], workCalendar: fiveDayWeek)
        let s = try #require(result.scheduled(milestone.id))

        #expect(s.scheduledStart == day(2026, 11, 9))
        #expect(s.scheduledFinish == s.scheduledStart)
        #expect(s.durationDays == 0)
        #expect(result.calendarAdjustments.count == 1)
        #expect(result.calendarAdjustments.first?.adjusted == day(2026, 11, 9))
    }

    // MARK: - §4-7 ALAP + 5 天周

    @Test func alapUsesWorkDaysInFiveDayWeek() throws {
        let projectEnd = day(2026, 11, 13)
        let fits = TaskItem(title: "ALAP", durationDays: 3, schedulingPolicy: .alap)
        let overflow = TaskItem(title: "超长", durationDays: 10, schedulingPolicy: .alap)

        let result = compute([fits, overflow], end: projectEnd, workCalendar: fiveDayWeek)
        let s = try #require(result.scheduled(fits.id))
        let o = try #require(result.scheduled(overflow.id))

        // 最晚结束锚在 11-13（周五），按工作日回推 3 天 → 11-10。
        #expect(s.latestFinish == projectEnd)
        #expect(s.latestStart == day(2026, 11, 10))
        #expect(s.scheduledStart == day(2026, 11, 10))
        #expect(s.scheduledFinish == projectEnd)
        // 10 个工作日回推到项目开始之前：宽延为负，但收尾仍被锚在上界内，不越界、不崩。
        #expect(o.latestStart == day(2026, 10, 30))
        #expect(o.totalSlackDays < 0)
        #expect(o.scheduledFinish == projectEnd)
    }

    // MARK: - §4-8 群组聚合跨非工作日

    @Test func groupWindowAggregatesAcrossNonWorkingDays() throws {
        let group = TaskItem(title: "阶段", kind: .group)
        let first = TaskItem(title: "A", parentID: group.id, durationDays: 3)
        let second = TaskItem(
            title: "B", parentID: group.id, durationDays: 2,
            dependencies: [TaskDependency(predecessorID: first.id, type: .fs)]
        )

        let result = compute([group, first, second], workCalendar: fiveDayWeek)
        let g = try #require(result.scheduled(group.id))

        // 子树最早开始 11-02、最晚结束 11-09；跨度按工作日计 = 11-02…11-06（5 天）。
        #expect(g.scheduledStart == monday)
        #expect(g.scheduledFinish == day(2026, 11, 9))
        #expect(g.durationDays == 5)
    }

    // MARK: - §4-9 存读往返 + 旧文件默认

    @Test func calendarRoundTripsAndOldFileDefaultsToFullWeek() throws {
        let calendar = WorkCalendar(
            workingWeekdays: [2, 3, 4, 5, 6],
            exceptions: [
                CalendarException(date: day(2026, 10, 1), isWorking: false, note: "国庆"),
                CalendarException(date: day(2026, 10, 10), isWorking: true, note: "调休")
            ],
            hoursPerDay: 7.5
        )
        let project = Project(metadata: ProjectMetadata(title: "带日历", projectStart: monday))
        project.calendar = calendar

        let data = try ZenoFile.encode(project: project)
        // 不升格式版本：日历是加法字段，键名照写。
        #expect(String(decoding: data, as: UTF8.self).contains("\"calendar\""))
        #expect(String(decoding: data, as: UTF8.self).contains("\"formatVersion\" : 2"))

        let reloaded = try ZenoFile.decode(from: data)
        #expect(reloaded.calendar == calendar)
        #expect(reloaded.calendar?.exceptions.first?.note == "国庆")

        // 旧文件（没有 calendar 键）读入 = nil，等价全周 7 天。
        let old = Project(metadata: ProjectMetadata(title: "旧文件", projectStart: monday))
        let oldData = try ZenoFile.encode(project: old)
        #expect(String(decoding: oldData, as: UTF8.self).contains("\"calendar\"") == false)
        #expect(try ZenoFile.decode(from: oldData).calendar == nil)
    }

    // MARK: - §4-10 边界：workingWeekdays 为空（脏数据）

    @Test func emptyWorkingWeekdaysFallsBackWithoutHanging() throws {
        let broken = WorkCalendar(workingWeekdays: [])

        // 退化为全周而不是死循环：周日也上班，加减日期等于日历日算术。
        #expect(broken.isDegenerate)
        #expect(broken.effectiveWeekdays == WorkCalendar.allWeekdays)
        #expect(broken.isWorkingDay(sunday, calendar: utc))
        #expect(broken.nextWorkingDay(onOrAfter: sunday, calendar: utc) == sunday)
        #expect(broken.addingWorkDays(3, to: friday, calendar: utc) == day(2026, 11, 9))

        let task = TaskItem(title: "T", durationDays: 3)
        let result = compute([task], workCalendar: broken)
        let s = try #require(result.scheduled(task.id))

        #expect(s.scheduledFinish == day(2026, 11, 5))
        // 退化必须留痕：一条项目级记录说明「日历不可用，已按全周排」。
        #expect(result.calendarAdjustments.count == 1)
        #expect(result.calendarAdjustments.first?.kind == .invalidWeekdays)
        #expect(result.calendarAdjustments.first?.taskID == nil)
    }
}
