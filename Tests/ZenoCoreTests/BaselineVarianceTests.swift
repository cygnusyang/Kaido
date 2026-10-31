import Foundation
import Testing

@testable import ZenoCore

// MARK: - 夹具

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private let newYork: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}()

private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int, calendar: Calendar = utc) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth))!
}

private func scheduled(_ id: UUID, start: Date, finish: Date, calendar: Calendar = utc) -> ScheduledTask {
    ScheduledTask(
        taskID: id,
        durationDays: Double(CalendarDayMath.dayOffset(from: start, to: finish, calendar: calendar)),
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

private func entry(
    _ id: UUID,
    start: Date,
    finish: Date,
    progress: Double = 0,
    isMilestone: Bool = false
) -> BaselineEntry {
    BaselineEntry(taskID: id, start: start, finish: finish, progress: progress, isMilestone: isMilestone)
}

private func baseline(_ entries: [BaselineEntry], at createdAt: Date = day(2026, 10, 25)) -> Baseline {
    Baseline(name: "基线 1 · 2026-10-25", createdAt: createdAt, anchor: day(2026, 10, 20), entries: entries)
}

private func task(
    title: String = "任务",
    kind: TaskKind = .task,
    status: TaskStatus = .pending,
    progress: Double = 0,
    actualStart: Date? = nil,
    completedAt: Date? = nil
) -> TaskItem {
    TaskItem(
        title: title,
        status: status,
        kind: kind,
        progress: progress,
        completedAt: completedAt,
        actualStart: actualStart
    )
}

// MARK: - 判据 3：符号「后者 − 基线」，正 = 晚，空 = nil

@Test func planFinishVarianceIsPositiveWhenLater() {
    let id = UUID()
    var item = task()
    item.id = id
    let base = baseline([entry(id, start: day(2026, 11, 2), finish: day(2026, 11, 5))])
    let schedules = [id: scheduled(id, start: day(2026, 11, 2), finish: day(2026, 11, 8))]

    let report = BaselineEngine.variance(
        baseline: base, tasks: [item], schedules: schedules, now: day(2026, 10, 25), calendar: utc
    )

    let variance = report.tasks[id]
    #expect(variance?.planFinishVariance == 3)
    #expect(variance?.planStartVariance == 0)
}

@Test func planFinishVarianceIsNegativeWhenEarly() {
    let id = UUID()
    var item = task()
    item.id = id
    let base = baseline([entry(id, start: day(2026, 11, 2), finish: day(2026, 11, 5))])
    let schedules = [id: scheduled(id, start: day(2026, 11, 1), finish: day(2026, 11, 4))]

    let report = BaselineEngine.variance(
        baseline: base, tasks: [item], schedules: schedules, now: day(2026, 10, 25), calendar: utc
    )

    #expect(report.tasks[id]?.planFinishVariance == -1)
    #expect(report.tasks[id]?.planStartVariance == -1)
}

@Test func planVarianceIsNilWhenNoCurrentPrediction() {
    let id = UUID()
    var item = task()
    item.id = id
    let base = baseline([entry(id, start: day(2026, 11, 2), finish: day(2026, 11, 5))])

    // 排期表为空 = 当前无预测；不得回落成 0。
    let report = BaselineEngine.variance(
        baseline: base, tasks: [item], schedules: [:], now: day(2026, 10, 25), calendar: utc
    )

    let variance = report.tasks[id]
    #expect(variance?.planFinishVariance == nil)
    #expect(variance?.planStartVariance == nil)
    #expect(variance?.baselineStart == day(2026, 11, 2))
    #expect(variance?.baselineFinish == day(2026, 11, 5))
}

// MARK: - 判据 5：actual 缺失 → 实际偏差 nil，逾期有值；完成后 overdue 变 nil

@Test func actualVarianceIsNilButOverdueReportedWhenNotStarted() {
    let id = UUID()
    var item = task()
    item.id = id
    let base = baseline([entry(id, start: day(2026, 11, 2), finish: day(2026, 11, 5))])
    let schedules = [id: scheduled(id, start: day(2026, 11, 2), finish: day(2026, 11, 8))]

    let report = BaselineEngine.variance(
        baseline: base, tasks: [item], schedules: schedules, now: day(2026, 11, 10), calendar: utc
    )

    let variance = report.tasks[id]
    // 不拿 plan 冒充 actual：planFinishVariance 有值，实际偏差必须为 nil。
    #expect(variance?.planFinishVariance == 3)
    #expect(variance?.actualStartVariance == nil)
    #expect(variance?.actualFinishVariance == nil)
    #expect(variance?.overdueDays == 5)
    #expect(variance?.isForecast == true)
    #expect(report.predictedTaskCount == 1)
    #expect(report.overdueOpenCount == 1)
}

@Test func completedTaskReportsActualVarianceAndNoOverdue() {
    let id = UUID()
    var item = task(status: .done, progress: 1, actualStart: day(2026, 11, 3), completedAt: day(2026, 11, 9))
    item.id = id
    let base = baseline([entry(id, start: day(2026, 11, 2), finish: day(2026, 11, 5))])
    let schedules = [id: scheduled(id, start: day(2026, 11, 2), finish: day(2026, 11, 8))]

    let report = BaselineEngine.variance(
        baseline: base, tasks: [item], schedules: schedules, now: day(2026, 11, 20), calendar: utc
    )

    let variance = report.tasks[id]
    #expect(variance?.actualStartVariance == 1)
    #expect(variance?.actualFinishVariance == 4)
    #expect(variance?.overdueDays == nil)
    #expect(variance?.isForecast == false)
    #expect(report.lateTaskCount == 1)
    #expect(report.overdueOpenCount == 0)
    #expect(report.predictedTaskCount == 0)
}

@Test func actualFinishWithoutActualStartKeepsStartVarianceNil() {
    // 07 §3：pending → done 直跳不补实际开始，偏差侧也不得臆造。
    let id = UUID()
    var item = task(status: .done, progress: 1, completedAt: day(2026, 11, 6))
    item.id = id
    let base = baseline([entry(id, start: day(2026, 11, 2), finish: day(2026, 11, 5))])

    let report = BaselineEngine.variance(
        baseline: base, tasks: [item], schedules: [:], now: day(2026, 11, 20), calendar: utc
    )

    #expect(report.tasks[id]?.actualStartVariance == nil)
    #expect(report.tasks[id]?.actualFinishVariance == 1)
}

// MARK: - 判据 4：跨 DST 不漂移（America/New_York 2026-03-08 拨快）

@Test func varianceAcrossSpringForwardKeepsDayCount() {
    let id = UUID()
    var item = task()
    item.id = id
    // 基线结束 03-07，当前计划结束 03-08：本地只差 23 小时，秒除会得 0 天。
    let base = baseline([entry(id, start: day(2026, 3, 5, calendar: newYork), finish: day(2026, 3, 7, calendar: newYork))])
    let schedules = [id: scheduled(
        id,
        start: day(2026, 3, 5, calendar: newYork),
        finish: day(2026, 3, 8, calendar: newYork),
        calendar: newYork
    )]

    let report = BaselineEngine.variance(
        baseline: base,
        tasks: [item],
        schedules: schedules,
        now: day(2026, 3, 1, calendar: newYork),
        calendar: newYork
    )

    #expect(report.tasks[id]?.planFinishVariance == 1)
}

// MARK: - 判据 8：孤儿

@Test func deletedTaskBecomesOrphanAndLeavesProjectVariance() {
    let keptID = UUID()
    let deletedID = UUID()
    var kept = task(title: "保留")
    kept.id = keptID
    let base = baseline([
        entry(keptID, start: day(2026, 11, 2), finish: day(2026, 11, 5)),
        entry(deletedID, start: day(2026, 11, 2), finish: day(2026, 12, 20)),
    ])
    let schedules = [keptID: scheduled(keptID, start: day(2026, 11, 2), finish: day(2026, 11, 8))]

    let report = BaselineEngine.variance(
        baseline: base, tasks: [kept], schedules: schedules, now: day(2026, 10, 25), calendar: utc
    )

    #expect(report.orphans.map(\.taskID) == [deletedID])
    // 已删除任务不进偏差表（只在 orphans），否则大纲会凭空多行。
    #expect(report.tasks[deletedID] == nil)
    // 孤儿不参与项目偏差：最晚基线结束仍取保留任务的 11-05。
    #expect(report.projectFinishVariance == 3)
    #expect(report.tasksWithoutBaseline == 0)
}

// MARK: - 判据 7：基线后新增

@Test func taskAddedAfterBaselineHasNoVarianceButIsCounted() {
    let baselinedID = UUID()
    let addedID = UUID()
    var baselined = task(title: "已有基线")
    baselined.id = baselinedID
    var added = task(title: "基线后新增")
    added.id = addedID
    let base = baseline([entry(baselinedID, start: day(2026, 11, 2), finish: day(2026, 11, 5))])
    let schedules = [
        baselinedID: scheduled(baselinedID, start: day(2026, 11, 2), finish: day(2026, 11, 5)),
        addedID: scheduled(addedID, start: day(2026, 11, 9), finish: day(2026, 11, 12)),
    ]

    let report = BaselineEngine.variance(
        baseline: base, tasks: [baselined, added], schedules: schedules, now: day(2026, 10, 25), calendar: utc
    )

    // 基线后新增：条目存在但 hasBaseline == false、偏差全为 nil（不是「准时 0」）。
    let addedVariance = report.variance(for: addedID)
    #expect(addedVariance?.hasBaseline == false)
    #expect(addedVariance?.baselineStart == nil)
    #expect(addedVariance?.planFinishVariance == nil)
    #expect(report.tasksWithoutBaseline == 1)
    // 新增任务的时间不参与项目结束偏差。
    #expect(report.projectFinishVariance == 0)
}

// MARK: - 判据 9：群组走自身条目

@Test func groupVarianceUsesItsOwnEntryNotChildrenSum() {
    let groupID = UUID()
    let childAID = UUID()
    let childBID = UUID()
    var group = task(title: "群组", kind: .group)
    group.id = groupID
    var childA = task(title: "子 A")
    childA.id = childAID
    var childB = task(title: "子 B")
    childB.id = childBID
    let base = baseline([
        entry(childAID, start: day(2026, 11, 2), finish: day(2026, 11, 5)),
        entry(childBID, start: day(2026, 11, 5), finish: day(2026, 11, 6)),
        entry(groupID, start: day(2026, 11, 2), finish: day(2026, 11, 10)),
    ])
    let schedules = [
        childAID: scheduled(childAID, start: day(2026, 11, 2), finish: day(2026, 11, 5)),
        childBID: scheduled(childBID, start: day(2026, 11, 5), finish: day(2026, 11, 6)),
        groupID: scheduled(groupID, start: day(2026, 11, 2), finish: day(2026, 11, 11)),
    ]

    let report = BaselineEngine.variance(
        baseline: base,
        tasks: [group, childA, childB],
        schedules: schedules,
        now: day(2026, 10, 25),
        calendar: utc
    )

    #expect(report.tasks[groupID]?.planFinishVariance == 1)
    #expect(report.tasks[childAID]?.planFinishVariance == 0)
    #expect(report.projectFinishVariance == 1)
}

// MARK: - 【Zeno 扩展】工期偏差

@Test func durationVarianceComparesBothSidesDuration() {
    let id = UUID()
    var item = task()
    item.id = id
    // 基线 3 天（11-02 → 11-05），当前 7 天（11-02 → 11-09）。
    let base = baseline([entry(id, start: day(2026, 11, 2), finish: day(2026, 11, 5))])
    let schedules = [id: scheduled(id, start: day(2026, 11, 2), finish: day(2026, 11, 9))]

    let report = BaselineEngine.variance(
        baseline: base, tasks: [item], schedules: schedules, now: day(2026, 10, 25), calendar: utc
    )

    #expect(report.tasks[id]?.durationVariance == 4)
}

// MARK: - 快照

@Test func snapshotSkipsUnscheduledTasksAndRecordsProgress() throws {
    let scheduledID = UUID()
    let unscheduledID = UUID()
    let milestoneID = UUID()
    var normalTask = task(title: "已排期", progress: 0.4)
    normalTask.id = scheduledID
    var unscheduled = task(title: "未排期")
    unscheduled.id = unscheduledID
    var milestone = task(title: "里程碑", kind: .milestone)
    milestone.id = milestoneID
    let schedules = [
        scheduledID: scheduled(scheduledID, start: day(2026, 11, 2), finish: day(2026, 11, 5)),
        milestoneID: scheduled(milestoneID, start: day(2026, 11, 6), finish: day(2026, 11, 6)),
    ]

    let snapshot = BaselineEngine.snapshot(
        tasks: [normalTask, unscheduled, milestone],
        schedules: schedules,
        name: "基线 1 · 2026-10-25",
        anchor: day(2026, 10, 20),
        now: day(2026, 10, 25)
    )

    #expect(snapshot.entries.map(\.taskID) == [scheduledID, milestoneID])
    #expect(snapshot.entries[0].progress == 0.4)
    #expect(snapshot.entries[0].isMilestone == false)
    #expect(snapshot.entries[1].isMilestone)
    #expect(snapshot.entries[1].start == snapshot.entries[1].finish)
    #expect(snapshot.createdAt == day(2026, 10, 25))
    #expect(snapshot.anchor == day(2026, 10, 20))
}

@Test func scheduleIndexExcludesUnschedulableTasks() {
    let okID = UUID()
    let cycleID = UUID()
    let result = ScheduleResult(
        tasks: [
            scheduled(okID, start: day(2026, 11, 2), finish: day(2026, 11, 3)),
            scheduled(cycleID, start: day(2026, 11, 2), finish: day(2026, 11, 3)),
        ],
        cycleTaskIDs: [cycleID],
        unscheduledTaskIDs: [cycleID]
    )

    let index = BaselineEngine.scheduleIndex(from: result)

    #expect(Set(index.keys) == [okID])
}

// MARK: - 判据 6：偏差必须带基线标识

@Test func reportCarriesBaselineIdentity() {
    let base = baseline([], at: day(2026, 10, 25))

    let report = BaselineEngine.variance(
        baseline: base, tasks: [], schedules: [:], now: day(2026, 10, 25), calendar: utc
    )

    #expect(report.baselineID == base.id)
    #expect(report.baselineName == base.name)
    #expect(report.baselineCreatedAt == base.createdAt)
    #expect(report.projectFinishVariance == nil)
}

// MARK: - 默认名

@Test func defaultNameCarriesIndexAndSnapshotDate() {
    let name = BaselineEngine.defaultName(index: 3, date: day(2026, 10, 25), calendar: utc)

    #expect(name == "基线 3 · 2026-10-25")
}
