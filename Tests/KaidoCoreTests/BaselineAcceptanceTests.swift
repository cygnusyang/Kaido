import Foundation
import Testing

@testable import KaidoCommands
@testable import KaidoCore

// 基线（v0.13）：快照 / 偏差 / 存储迁移的验收用例。
// 依据 docs/features/08-baselines.md §9（12 条判据）、§4（偏差口径）、§5（孤儿）、§7.6（迁移矩阵）；
// 判据 → 用例映射见 docs/features/08-baselines-cases.md。
//
// 纪律：
// - 所有时刻由参数注入（now: 与字面日期），用例内不读墙钟、不调 Date()。
// - 期望值一律写字面日期，不用被测函数现算（避免 D-009 同源断言）。
// - 排期输入由 ScheduledTask 手工构造，不跑 ScheduleEngine：基线只消费 scheduledStart/Finish，
//   手工构造才能把「基线后漂移」控制成精确的日历日差。

// MARK: - 注入时钟与日历

private let frozenNow = Date(timeIntervalSince1970: 1_763_000_000)

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private var newYork: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}

private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int, in calendar: Calendar = utc) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth))!
}

/// 生产侧（ScheduleEngine、BaselineEngine.defaultName）用「当前时区的公历」归一日期；
/// 命令层断言必须按同一口径取期望值，否则「UTC 零点 vs 本地零点」会被误判成实现缺陷。
private func localDay(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    return calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth))!
}

/// 默认名里的日期段（yyyy-MM-dd，按当前时区渲染）。
private func localDayLabel(_ date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
}

// MARK: - 夹具

private func scheduled(
    _ taskID: UUID,
    start: Date,
    finish: Date,
    durationDays: Double
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

private func scheduleMap(_ entries: [ScheduledTask]) -> [UUID: ScheduledTask] {
    Dictionary(uniqueKeysWithValues: entries.map { ($0.taskID, $0) })
}

private func snapshot(
    _ tasks: [TaskItem],
    _ entries: [ScheduledTask],
    now: Date = frozenNow
) -> Baseline {
    BaselineEngine.snapshot(
        tasks: tasks,
        schedules: scheduleMap(entries),
        name: "基线 1 · 2025-11-03",
        anchor: day(2025, 11, 3),
        now: now
    )
}

/// 捕获 SessionError；非 SessionError 一律按「没抛出对的错」返回 nil，让断言红在该红的地方。
private func sessionError(_ body: () throws -> Void) -> SessionError? {
    do {
        try body()
        return nil
    } catch let error as SessionError {
        return error
    } catch {
        return nil
    }
}

private func newSession() throws -> KaidoSession {
    let session = KaidoSession()
    // 排期锚点按本地日历归一：与 ScheduleEngine 的默认 calendar 同口径。
    try session.createProject(title: "基线项目", projectStart: localDay(2025, 11, 3))
    return session
}

// MARK: - 判据 1 / 3 / 4 / 5 / 6 / 7 / 8 / 9：快照内容与偏差公式

struct BaselineCoreAcceptanceTests {
    // 判据 1：条目数 = 已排期任务数；createdAt 取注入时钟；未排期任务不入条目。
    @Test func snapshotCapturesOnlyScheduledTasks() throws {
        let scheduledTask = TaskItem(title: "已排期", durationDays: 2)
        let partialTask = TaskItem(title: "有进度", durationDays: 1, progress: 0.4)
        let unscheduledTask = TaskItem(title: "未排期", durationDays: 2)

        let baseline = snapshot(
            [scheduledTask, partialTask, unscheduledTask],
            [
                scheduled(scheduledTask.id, start: day(2025, 11, 3), finish: day(2025, 11, 5), durationDays: 2),
                scheduled(partialTask.id, start: day(2025, 11, 3), finish: day(2025, 11, 4), durationDays: 1),
            ]
        )

        #expect(baseline.entries.count == 2)
        #expect(Set(baseline.entries.map(\.taskID)) == [scheduledTask.id, partialTask.id])
        // 没有时间可比较的任务不入表（入表只会制造 0 偏差假象）。
        #expect(!baseline.entries.contains { $0.taskID == unscheduledTask.id })
        #expect(baseline.createdAt == frozenNow)
        #expect(baseline.anchor == day(2025, 11, 3))

        let entry = try #require(baseline.entries.first { $0.taskID == scheduledTask.id })
        #expect(entry.start == day(2025, 11, 3))
        #expect(entry.finish == day(2025, 11, 5))
        #expect(entry.progress == 0)
        #expect(!entry.isMilestone)
        #expect(baseline.entries.first { $0.taskID == partialTask.id }?.progress == 0.4)
    }

    // 判据 1：里程碑零时长（start == finish）并打上 isMilestone。
    @Test func snapshotRecordsMilestoneAsZeroDuration() throws {
        let milestone = TaskItem(title: "里程碑", kind: .milestone, durationDays: 0)
        let baseline = snapshot(
            [milestone],
            [scheduled(milestone.id, start: day(2025, 11, 7), finish: day(2025, 11, 7), durationDays: 0)]
        )
        let entry = try #require(baseline.entries.first)
        #expect(entry.isMilestone)
        #expect(entry.start == entry.finish)
    }

    // 边界：没有任何已排期任务时，快照是空条目列表而不是报错。
    @Test func snapshotWithoutSchedulesHasNoEntries() throws {
        let baseline = snapshot([TaskItem(title: "未排期", durationDays: 2)], [])
        #expect(baseline.entries.isEmpty)
        #expect(baseline.createdAt == frozenNow)
    }

    // 判据 2（core 部分）：Baseline 是值类型，拷贝后改动不回写原快照。
    @Test func baselineHasValueSemantics() throws {
        let task = TaskItem(title: "A", durationDays: 2)
        let original = snapshot(
            [task],
            [scheduled(task.id, start: day(2025, 11, 3), finish: day(2025, 11, 5), durationDays: 2)]
        )

        var copy = original
        copy.name = "被改名的副本"
        copy.entries.removeAll()

        #expect(original.name == "基线 1 · 2025-11-03")
        #expect(original.entries.count == 1)
    }

    // 判据 3：偏差 = 后者 − 基线，单位日历天；正数晚于承诺、负数提前。
    @Test func planVarianceIsSignedCalendarDays() throws {
        let task = TaskItem(title: "A", durationDays: 2)
        let baseline = snapshot(
            [task],
            [scheduled(task.id, start: day(2025, 11, 3), finish: day(2025, 11, 5), durationDays: 2)]
        )

        let lateReport = BaselineEngine.variance(
            baseline: baseline,
            tasks: [task],
            schedules: scheduleMap([
                scheduled(task.id, start: day(2025, 11, 5), finish: day(2025, 11, 8), durationDays: 3)
            ]),
            now: frozenNow,
            calendar: utc
        )
        let late = try #require(lateReport.tasks[task.id])
        #expect(late.planFinishVariance == 3)
        #expect(late.planStartVariance == 2)
        #expect(late.baselineStart == day(2025, 11, 3))
        #expect(late.baselineFinish == day(2025, 11, 5))
        #expect(late.hasBaseline)

        let earlyReport = BaselineEngine.variance(
            baseline: baseline,
            tasks: [task],
            schedules: scheduleMap([
                scheduled(task.id, start: day(2025, 11, 2), finish: day(2025, 11, 4), durationDays: 2)
            ]),
            now: frozenNow,
            calendar: utc
        )
        let early = try #require(earlyReport.tasks[task.id])
        #expect(early.planFinishVariance == -1)
        #expect(early.planStartVariance == -1)
    }

    // 判据 3 / 5：空缺一律 nil，不写 0；未完成且已过期才有 overdueDays。
    @Test func missingLayersStayNilInsteadOfZero() throws {
        let task = TaskItem(title: "计划未变但无实际", durationDays: 2)
        let baseline = snapshot(
            [task],
            [scheduled(task.id, start: day(2025, 11, 3), finish: day(2025, 11, 5), durationDays: 2)]
        )

        let report = BaselineEngine.variance(
            baseline: baseline,
            tasks: [task],
            schedules: scheduleMap([
                scheduled(task.id, start: day(2025, 11, 3), finish: day(2025, 11, 5), durationDays: 2)
            ]),
            now: frozenNow,
            calendar: utc
        )
        let variance = try #require(report.tasks[task.id])

        // 有值且确实为 0 的偏差照写 0（这是合法值，不是"缺值"）。
        #expect(variance.planFinishVariance == 0)
        #expect(variance.planStartVariance == 0)
        // 缺实际层 → nil，不回落成 0，也不拿 plan 冒充 actual。
        #expect(variance.actualStartVariance == nil)
        #expect(variance.actualFinishVariance == nil)
        // 未完成且基线已过期 → 逾期天数有值。
        #expect(variance.overdueDays != nil)
        #expect(report.overdueOpenCount == 1)
        // 计划侧仍在用预测值 → 摘要里必须数得出"含预测项"。
        #expect(report.predictedTaskCount == 1)
    }

    // 判据 5：完成后 overdueDays 为 nil；实际结束偏差按 completedAt 计算。
    @Test func completedTaskDropsOverdueAndCarriesActualVariance() throws {
        var task = TaskItem(title: "已完成", durationDays: 2)
        let baseline = snapshot(
            [task],
            [scheduled(task.id, start: day(2025, 11, 3), finish: day(2025, 11, 5), durationDays: 2)]
        )
        task.status = .done
        task.progress = 1
        task.actualStart = day(2025, 11, 2)
        task.completedAt = day(2025, 11, 8)

        let report = BaselineEngine.variance(
            baseline: baseline,
            tasks: [task],
            schedules: scheduleMap([
                scheduled(task.id, start: day(2025, 11, 3), finish: day(2025, 11, 5), durationDays: 2)
            ]),
            now: frozenNow,
            calendar: utc
        )
        let variance = try #require(report.tasks[task.id])
        #expect(variance.actualStartVariance == -1)   // 11-03 → 11-02
        #expect(variance.actualFinishVariance == 3)   // 11-05 → 11-08
        #expect(variance.overdueDays == nil)
        #expect(report.overdueOpenCount == 0)
    }

    // 判据 4：跨 DST（America/New_York 2025-11-02 回拨）不产生 ±1 天漂移。
    @Test func varianceAcrossDstFallBackHasNoDrift() throws {
        let task = TaskItem(title: "跨 DST", durationDays: 2)
        let baseline = snapshot(
            [task],
            [scheduled(
                task.id,
                start: day(2025, 11, 1, in: newYork),
                finish: day(2025, 11, 2, in: newYork),
                durationDays: 1
            )]
        )

        // 正向跨回拨：11-02 → 11-04 是 2 个日历日。
        let forwardReport = BaselineEngine.variance(
            baseline: baseline,
            tasks: [task],
            schedules: scheduleMap([
                scheduled(
                    task.id,
                    start: day(2025, 11, 2, in: newYork),
                    finish: day(2025, 11, 4, in: newYork),
                    durationDays: 2
                )
            ]),
            now: frozenNow,
            calendar: newYork
        )
        #expect(try #require(forwardReport.tasks[task.id]).planFinishVariance == 2)

        // 反向跨回拨：11-03 → 11-02 是 −1 个日历日（按 86 400 秒折算会算成 0）。
        let backwardBaseline = snapshot(
            [task],
            [scheduled(
                task.id,
                start: day(2025, 11, 1, in: newYork),
                finish: day(2025, 11, 3, in: newYork),
                durationDays: 2
            )]
        )
        let backwardReport = BaselineEngine.variance(
            baseline: backwardBaseline,
            tasks: [task],
            schedules: scheduleMap([
                scheduled(
                    task.id,
                    start: day(2025, 11, 1, in: newYork),
                    finish: day(2025, 11, 2, in: newYork),
                    durationDays: 1
                )
            ]),
            now: frozenNow,
            calendar: newYork
        )
        #expect(try #require(backwardReport.tasks[task.id]).planFinishVariance == -1)
    }

    // 日算术入口（§8）：同日不同时刻按整日算 0；跨 DST 按日历日算。
    @Test func calendarDayMathCountsWholeCalendarDays() throws {
        #expect(CalendarDayMath.dayOffset(from: day(2025, 11, 5), to: day(2025, 11, 8), calendar: utc) == 3)
        #expect(CalendarDayMath.dayOffset(from: day(2025, 11, 5), to: day(2025, 11, 4), calendar: utc) == -1)
        #expect(CalendarDayMath.dayOffset(from: day(2025, 11, 5), to: day(2025, 11, 5), calendar: utc) == 0)
        #expect(
            CalendarDayMath.dayOffset(
                from: day(2025, 11, 5),
                to: day(2025, 11, 5).addingTimeInterval(20 * 3600),
                calendar: utc
            ) == 0
        )
        #expect(
            CalendarDayMath.dayOffset(
                from: day(2025, 11, 3, in: newYork),
                to: day(2025, 11, 2, in: newYork),
                calendar: newYork
            ) == -1
        )
    }

    // 判据 7：基线后新增的任务 hasBaseline == false、偏差为空、计入 tasksWithoutBaseline。
    @Test func taskAddedAfterBaselineIsFlaggedWithoutVariance() throws {
        let existing = TaskItem(title: "基线内", durationDays: 2)
        let added = TaskItem(title: "基线后新增", durationDays: 2)
        let baseline = snapshot(
            [existing],
            [scheduled(existing.id, start: day(2025, 11, 3), finish: day(2025, 11, 5), durationDays: 2)]
        )

        let report = BaselineEngine.variance(
            baseline: baseline,
            tasks: [existing, added],
            schedules: scheduleMap([
                scheduled(existing.id, start: day(2025, 11, 4), finish: day(2025, 11, 6), durationDays: 2),
                scheduled(added.id, start: day(2025, 11, 3), finish: day(2025, 11, 9), durationDays: 6),
            ]),
            now: frozenNow,
            calendar: utc
        )

        let addedVariance = try #require(report.tasks[added.id])
        #expect(!addedVariance.hasBaseline)
        #expect(addedVariance.baselineStart == nil)
        #expect(addedVariance.baselineFinish == nil)
        #expect(addedVariance.planStartVariance == nil)
        #expect(addedVariance.planFinishVariance == nil)
        #expect(report.tasksWithoutBaseline == 1)
        // 不计入项目偏差：只按有基线条目的任务算（11-06 − 11-05 = 1）。
        #expect(report.projectFinishVariance == 1)
    }

    // 判据 8：任务删除后条目进 orphans，不合成任务行，项目偏差不含它。
    @Test func deletedTaskBecomesOrphanAndLeavesProjectVarianceIntact() throws {
        let kept = TaskItem(title: "保留", durationDays: 2)
        let removed = TaskItem(title: "已删除", durationDays: 4)
        let baseline = snapshot(
            [kept, removed],
            [
                scheduled(kept.id, start: day(2025, 11, 3), finish: day(2025, 11, 5), durationDays: 2),
                scheduled(removed.id, start: day(2025, 11, 3), finish: day(2025, 11, 7), durationDays: 4),
            ]
        )

        let report = BaselineEngine.variance(
            baseline: baseline,
            tasks: [kept],
            schedules: scheduleMap([
                scheduled(kept.id, start: day(2025, 11, 4), finish: day(2025, 11, 6), durationDays: 2)
            ]),
            now: frozenNow,
            calendar: utc
        )

        #expect(report.orphans.map(\.taskID) == [removed.id])
        // 孤儿条目仍可读出承诺起止（面板可展开只读）。
        let orphan = try #require(report.orphans.first)
        #expect(orphan.start == day(2025, 11, 3))
        #expect(orphan.finish == day(2025, 11, 7))
        // 任务已不存在 → 不合成任务行。
        #expect(report.tasks[removed.id] == nil)
        // 最晚 P.finish(11-06) − 最晚 B.finish(11-05) = 1；孤儿不参与。
        #expect(report.projectFinishVariance == 1)
    }

    // 判据 9：群组偏差取自身条目（聚合值），不等于子任务偏差之和。
    @Test func groupVarianceUsesOwnEntryNotChildrenSum() throws {
        let group = TaskItem(title: "阶段", kind: .group)
        let child1 = TaskItem(title: "子 1", parentID: group.id, durationDays: 2)
        let child2 = TaskItem(title: "子 2", parentID: group.id, durationDays: 2)
        let tasks = [group, child1, child2]

        let baseline = snapshot(
            tasks,
            [
                scheduled(group.id, start: day(2025, 11, 3), finish: day(2025, 11, 7), durationDays: 4),
                scheduled(child1.id, start: day(2025, 11, 3), finish: day(2025, 11, 5), durationDays: 2),
                scheduled(child2.id, start: day(2025, 11, 5), finish: day(2025, 11, 7), durationDays: 2),
            ]
        )
        let report = BaselineEngine.variance(
            baseline: baseline,
            tasks: tasks,
            schedules: scheduleMap([
                scheduled(group.id, start: day(2025, 11, 5), finish: day(2025, 11, 9), durationDays: 4),
                scheduled(child1.id, start: day(2025, 11, 5), finish: day(2025, 11, 7), durationDays: 2),
                scheduled(child2.id, start: day(2025, 11, 7), finish: day(2025, 11, 9), durationDays: 2),
            ]),
            now: frozenNow,
            calendar: utc
        )

        let groupVariance = try #require(report.tasks[group.id])
        let child1Variance = try #require(report.tasks[child1.id])
        let child2Variance = try #require(report.tasks[child2.id])

        #expect(groupVariance.planFinishVariance == 2)
        #expect(child1Variance.planFinishVariance == 2)
        #expect(child2Variance.planFinishVariance == 2)
        // 自身条目口径：不是子任务偏差求和（2 ≠ 4）。
        let childrenSum = (child1Variance.planFinishVariance ?? 0) + (child2Variance.planFinishVariance ?? 0)
        #expect(groupVariance.planFinishVariance != childrenSum)
    }

    // 判据 6（core 部分）：报告必须携带 baselineID / name / createdAt。
    @Test func reportCarriesBaselineIdentity() throws {
        let task = TaskItem(title: "A", durationDays: 2)
        let baseline = snapshot(
            [task],
            [scheduled(task.id, start: day(2025, 11, 3), finish: day(2025, 11, 5), durationDays: 2)]
        )
        let report = BaselineEngine.variance(
            baseline: baseline,
            tasks: [task],
            schedules: scheduleMap([
                scheduled(task.id, start: day(2025, 11, 3), finish: day(2025, 11, 5), durationDays: 2)
            ]),
            now: frozenNow,
            calendar: utc
        )
        #expect(report.baselineID == baseline.id)
        #expect(report.baselineName == baseline.name)
        #expect(report.baselineCreatedAt == baseline.createdAt)
    }

    // 纯函数：同样的输入重复调用结果完全相同（不掺墙钟、不掺外部状态）。
    @Test func varianceIsPureAndDeterministic() throws {
        let task = TaskItem(title: "A", durationDays: 2)
        let baseline = snapshot(
            [task],
            [scheduled(task.id, start: day(2025, 11, 3), finish: day(2025, 11, 5), durationDays: 2)]
        )
        let schedules = scheduleMap([
            scheduled(task.id, start: day(2025, 11, 4), finish: day(2025, 11, 6), durationDays: 2)
        ])

        let first = BaselineEngine.variance(
            baseline: baseline, tasks: [task], schedules: schedules, now: frozenNow, calendar: utc
        )
        let second = BaselineEngine.variance(
            baseline: baseline, tasks: [task], schedules: schedules, now: frozenNow, calendar: utc
        )
        #expect(first == second)
    }
}

// MARK: - 判据 11：格式版本、迁移与兼容矩阵

private let projectID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
private let taskAID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
private let orphanTaskID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
private let baselineOneID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
private let baselineTwoID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!

// 夹具里的 ISO8601 时刻（字面值，解码按 JSONDecoder.iso8601）。
private let november3 = Date(timeIntervalSince1970: 1_762_128_000)  // 2025-11-03T00:00:00Z
private let november5 = Date(timeIntervalSince1970: 1_762_300_800)  // 2025-11-05T00:00:00Z

/// v1 夹具：无 baselines 键（§7.6 第 1 条）。
private func v1Document(includeResources: Bool = true) -> Data {
    let resources = includeResources ? "\"resources\": []," : ""
    let json = """
    {
      "formatVersion": 1,
      "project": {
        "id": "\(projectID.uuidString)",
        "title": "旧版项目",
        "createdAt": "2025-11-03T00:00:00Z",
        "updatedAt": "2025-11-03T00:00:00Z"
      },
      "tasks": [
        { "id": "\(taskAID.uuidString)", "title": "任务 A", "durationDays": 2, "progress": 0.5 }
      ],
      \(resources)
      "unknownRootKey": { "kept": true }
    }
    """
    return Data(json.utf8)
}

/// v2 夹具：2 条基线（第 2 条条目为空、无 anchor）+ 1 条孤儿条目（§7.6 第 3 条）。
private func v2Document(withBaselines: Bool = true) -> Data {
    let baselines = withBaselines ? """
      "baselines": [
        {
          "id": "\(baselineOneID.uuidString)",
          "name": "基线 1 · 2025-11-03",
          "createdAt": "2025-11-03T00:00:00Z",
          "anchor": "2025-11-03T00:00:00Z",
          "entries": [
            {
              "taskID": "\(taskAID.uuidString)",
              "start": "2025-11-03T00:00:00Z",
              "finish": "2025-11-05T00:00:00Z",
              "progress": 0.5,
              "isMilestone": false
            },
            {
              "taskID": "\(orphanTaskID.uuidString)",
              "start": "2025-11-03T00:00:00Z",
              "finish": "2025-11-07T00:00:00Z",
              "progress": 0,
              "isMilestone": false
            }
          ]
        },
        {
          "id": "\(baselineTwoID.uuidString)",
          "name": "基线 2 · 2025-11-10",
          "createdAt": "2025-11-10T00:00:00Z",
          "entries": []
        }
      ],
    """ : ""
    let json = """
    {
      "formatVersion": 2,
      "project": {
        "id": "\(projectID.uuidString)",
        "title": "新版项目",
        "createdAt": "2025-11-03T00:00:00Z",
        "updatedAt": "2025-11-10T00:00:00Z"
      },
      "tasks": [
        { "id": "\(taskAID.uuidString)", "title": "任务 A", "durationDays": 2, "progress": 0.5 }
      ],
      "resources": [],
    \(baselines)
      "unknownRootKey": { "kept": true }
    }
    """
    return Data(json.utf8)
}

private func writeTemporaryFile(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("baseline-\(UUID().uuidString).kaido")
    try data.write(to: url, options: .atomic)
    return url
}

private func rootObject(of data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

struct BaselineStorageAcceptanceTests {
    // §7.1：当前格式版本升到 2，迁移步骤登记在 toVersion 2。
    @Test func currentFormatVersionIsTwo() throws {
        #expect(KaidoFile.currentFormatVersion == 2)
        #expect(BaselineFormatV2Migration().toVersion == 2)
    }

    // §7.6 第 1 条：v1 打开 → sourceFormatVersion == 1、baselines 空、needsFormatUpgrade 为 true。
    @Test func v1FileOpensWithEmptyBaselinesAndNeedsUpgrade() throws {
        let decoded = try KaidoFile.read(from: v1Document())
        #expect(decoded.sourceFormatVersion == 1)
        #expect(decoded.project.baselines.isEmpty)

        let url = try writeTemporaryFile(v1Document())
        defer { try? FileManager.default.removeItem(at: url) }
        let session = KaidoSession()
        try session.openProject(at: url)
        #expect(session.sourceFormatVersion == 1)
        #expect(session.needsFormatUpgrade)
        // 打开不落盘（§7.3）：磁盘仍是 v1 原文。
        #expect(try Data(contentsOf: url) == v1Document())
    }

    // §7.6 第 2 条：v1 → 保存 = v2 且无 baselines 键（省略策略），读回逐字段相等。
    @Test func savingProjectWithoutBaselinesOmitsBaselinesKey() throws {
        let project = try KaidoFile.decode(from: v1Document())
        let encoded = try KaidoFile.encode(project: project)
        let root = try rootObject(of: encoded)

        #expect(root["formatVersion"] as? Int == 2)
        #expect(root["baselines"] == nil)

        let reread = try KaidoFile.read(from: encoded)
        #expect(reread.sourceFormatVersion == 2)
        #expect(reread.project.baselines.isEmpty)
        #expect(reread.project.metadata == project.metadata)
        #expect(reread.project.tasks == project.tasks)
        #expect(reread.project.resources == project.resources)
    }

    // §7.6 第 3 条：v2（2 基线 + 1 孤儿）读 → 写 → 读，基线逐字段相等。
    @Test func v2BaselinesSurviveRoundTrip() throws {
        let decoded = try KaidoFile.read(from: v2Document())
        #expect(decoded.sourceFormatVersion == 2)
        #expect(decoded.project.baselines.count == 2)

        let first = try #require(decoded.project.baselines.first)
        #expect(first.id == baselineOneID)
        #expect(first.name == "基线 1 · 2025-11-03")
        #expect(first.createdAt == november3)
        #expect(first.anchor == november3)
        #expect(first.entries.count == 2)
        #expect(first.entries.contains { $0.taskID == orphanTaskID })
        let second = try #require(decoded.project.baselines.last)
        #expect(second.id == baselineTwoID)
        #expect(second.entries.isEmpty)
        // anchor 是可选字段：夹具没写 → nil，不是 1970。
        #expect(second.anchor == nil)

        let encoded = try KaidoFile.encode(project: decoded.project)
        let reread = try KaidoFile.read(from: encoded)
        #expect(reread.project.baselines == decoded.project.baselines)
        #expect(reread.project.baselines.count == 2)
        let entry = try #require(reread.project.baselines.first?.entries.first)
        #expect(entry.taskID == taskAID)
        #expect(entry.finish == november5)
        #expect(entry.progress == 0.5)
        #expect(!entry.isMilestone)
    }

    // §3 / §6：条目只有 5 个字段；多存标题或工期就是"体积与语义蔓延"的重演。
    @Test func baselineEntryEncodingKeepsContractKeys() throws {
        let decoded = try KaidoFile.read(from: v2Document())
        let encoded = try KaidoFile.encode(project: decoded.project)
        let root = try rootObject(of: encoded)
        let baselines = try #require(root["baselines"] as? [[String: Any]])
        #expect(baselines.count == 2)
        let entries = try #require(baselines.first?["entries"] as? [[String: Any]])
        #expect(entries.count == 2)
        let entry = try #require(entries.first)
        #expect(Set(entry.keys) == ["taskID", "start", "finish", "progress", "isMilestone"])
    }

    // §7.6 第 4 条：未来版本 → unsupportedFormatVersion(3)，磁盘文件未被修改。
    @Test func futureFormatVersionIsRejectedWithoutTouchingDisk() throws {
        var root = try rootObject(of: v2Document())
        root["formatVersion"] = 3
        let futureData = try JSONSerialization.data(withJSONObject: root)
        let url = try writeTemporaryFile(futureData)
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try Data(contentsOf: url)

        #expect(throws: KaidoFileError.unsupportedFormatVersion(3)) {
            _ = try KaidoFile.read(from: url)
        }
        #expect(try Data(contentsOf: url) == before)
    }

    // §7.6 第 5 条 + 口径说明：迁移层只碰 formatVersion，未知根键原样保留。
    @Test func v2MigrationOnlyBumpsVersionAndKeepsUnknownRootKeys() throws {
        var document = FormatDocument(root: [
            "formatVersion": 1,
            "project": ["id": projectID.uuidString],
            "tasks": [],
            "futureThing": ["nested": 1],
        ])
        try BaselineFormatV2Migration().migrate(&document)

        #expect(document.formatVersion == 2)
        #expect(document.root["futureThing"] != nil)
        #expect(document.root["project"] != nil)
        #expect(document.root["tasks"] != nil)

        // 标准计划里必须挂上 1 → 2 这一步（缺了它所有 v1 文件都打不开）。
        var throughPlan = FormatDocument(root: [
            "formatVersion": 1,
            "project": ["id": projectID.uuidString],
            "tasks": [],
        ])
        try FormatMigrationPlan.standard.migrate(from: 1, to: 2, document: &throughPlan)
        #expect(throughPlan.formatVersion == 2)
    }

    // §7.6 第 6 条：v1 同时缺 resources 与 baselines → 不报错，均回落默认值。
    @Test func v1MissingResourcesAndBaselinesFallBackToDefaults() throws {
        let project = try KaidoFile.decode(from: v1Document(includeResources: false))
        #expect(project.resources.isEmpty)
        #expect(project.baselines.isEmpty)
        #expect(project.tasks.count == 1)
    }

    // §7.4：旧客户端（支持 1）打开 v2 → 明确拒开；有无基线都是同一个错误码。
    @Test func oldClientRejectsV2File() throws {
        let withBaselines = try KaidoFile.encode(project: KaidoFile.decode(from: v2Document()))
        let withoutBaselines = try KaidoFile.encode(project: KaidoFile.decode(from: v2Document(withBaselines: false)))

        #expect(throws: KaidoFileError.unsupportedFormatVersion(2)) {
            _ = try KaidoFile.read(from: withBaselines, targetVersion: 1, plan: FormatMigrationPlan())
        }
        #expect(throws: KaidoFileError.unsupportedFormatVersion(2)) {
            _ = try KaidoFile.read(from: withoutBaselines, targetVersion: 1, plan: FormatMigrationPlan())
        }
    }
}

// MARK: - 判据 1 / 2 / 6 / 7 / 8：命令层（唯一写入口）

struct BaselineCommandsAcceptanceTests {
    // 判据 1：默认名含日期与序号；createdAt 取注入时钟；条目数 = 已排期任务数。
    @Test func createBaselineUsesInjectedClockAndDefaultName() throws {
        let session = try newSession()
        _ = try session.addTask(title: "A", durationDays: 2)
        _ = try session.addTask(title: "B", durationDays: 3)

        let first = try session.createBaseline(now: frozenNow)
        #expect(first.createdAt == frozenNow)
        #expect(first.entries.count == 2)
        #expect(first.name.hasPrefix("基线 1"))
        #expect(first.name.contains(localDayLabel(frozenNow)))
        #expect(first.anchor == localDay(2025, 11, 3))

        // 同一天再拍一份：序号必须区分，名字不得重复。
        let second = try session.createBaseline(now: frozenNow.addingTimeInterval(3600))
        #expect(second.name.hasPrefix("基线 2"))
        #expect(second.name != first.name)
        #expect(try session.baselines().map(\.id) == [first.id, second.id])
    }

    // 判据 2：改任务不会改动已拍的基线（快照不可变）。
    @Test func editingTasksDoesNotMutateExistingBaseline() throws {
        let session = try newSession()
        let taskID = try session.addTask(title: "A", durationDays: 2)
        let baseline = try session.createBaseline(now: frozenNow)

        try session.updateTask(id: taskID, durationDays: 6)
        _ = try session.statusUpdate(id: taskID, status: .inProgress, now: frozenNow)

        let reread = try #require(try session.baselines().first)
        #expect(reread == baseline)
        #expect(reread.entries.first?.finish == localDay(2025, 11, 5))
    }

    // 判据 2：rename 只改名字。
    @Test func renameOnlyChangesName() throws {
        let session = try newSession()
        _ = try session.addTask(title: "A", durationDays: 2)
        let baseline = try session.createBaseline(now: frozenNow)

        let renamed = try session.renameBaseline(id: baseline.id, name: "承诺 V1")
        #expect(renamed.id == baseline.id)
        #expect(renamed.name == "承诺 V1")
        #expect(renamed.createdAt == baseline.createdAt)
        #expect(renamed.entries == baseline.entries)
        #expect(try session.baselines() == [renamed])
    }

    // 判据 2：删除基线不动其它基线，也不动任务。
    @Test func deleteBaselineLeavesOthersAndTasksIntact() throws {
        let session = try newSession()
        _ = try session.addTask(title: "A", durationDays: 2)
        let first = try session.createBaseline(now: frozenNow)
        let second = try session.createBaseline(now: frozenNow.addingTimeInterval(86_400))
        let tasksBefore = try session.listTasks()

        try session.deleteBaseline(id: first.id)

        #expect(try session.baselines() == [second])
        #expect(try session.listTasks() == tasksBefore)
    }

    // 判据 2：再拍一份是新增而不是覆盖。
    @Test func secondSnapshotAddsNewBaseline() throws {
        let session = try newSession()
        let taskID = try session.addTask(title: "A", durationDays: 2)
        let first = try session.createBaseline(now: frozenNow)
        try session.updateTask(id: taskID, durationDays: 6)
        let second = try session.createBaseline(now: frozenNow.addingTimeInterval(86_400))

        #expect(first.id != second.id)
        #expect(first.entries != second.entries)
        #expect(try session.baselines().count == 2)
        // 第一份仍是旧承诺，没有被第二次快照覆盖。
        #expect(try session.baselines().first == first)
    }

    // 判据 6：报告带基线标识；baselineID 省略 = 最新。
    @Test func varianceDefaultsToLatestBaselineAndCarriesIdentity() throws {
        let session = try newSession()
        _ = try session.addTask(title: "A", durationDays: 2)
        let first = try session.createBaseline(now: frozenNow)
        let second = try session.createBaseline(now: frozenNow.addingTimeInterval(86_400))

        let latest = try session.baselineVariance(now: frozenNow)
        #expect(latest.baselineID == second.id)
        #expect(latest.baselineName == second.name)
        #expect(latest.baselineCreatedAt == second.createdAt)

        let explicit = try session.baselineVariance(baselineID: first.id, now: frozenNow)
        #expect(explicit.baselineID == first.id)
        #expect(explicit.baselineName == first.name)
        #expect(explicit.baselineCreatedAt == first.createdAt)
    }

    // 判据 10（数据侧）：多基线切换互不影响，反复查询不改任何一份报告。
    @Test func switchingBaselinesDoesNotAffectEachOther() throws {
        let session = try newSession()
        let taskID = try session.addTask(title: "A", durationDays: 2)
        let first = try session.createBaseline(now: frozenNow)
        try session.updateTask(id: taskID, durationDays: 5)
        let second = try session.createBaseline(now: frozenNow.addingTimeInterval(86_400))

        let firstReport = try session.baselineVariance(baselineID: first.id, now: frozenNow)
        let secondReport = try session.baselineVariance(baselineID: second.id, now: frozenNow)

        #expect(firstReport.tasks[taskID]?.planFinishVariance == 3)
        #expect(secondReport.tasks[taskID]?.planFinishVariance == 0)
        #expect(try session.baselineVariance(baselineID: second.id, now: frozenNow) == secondReport)
        #expect(try session.baselineVariance(baselineID: first.id, now: frozenNow) == firstReport)
        #expect(try session.baselines() == [first, second])
    }

    // 判据 7 / 8：基线后新增与已删除任务在命令层都可见，且条目不被查询动作清掉。
    @Test func addedAndDeletedTasksStayVisibleFromCommands() throws {
        let session = try newSession()
        let kept = try session.addTask(title: "保留", durationDays: 2)
        let removed = try session.addTask(title: "将被删除", durationDays: 2)
        let baseline = try session.createBaseline(now: frozenNow)

        let added = try session.addTask(title: "基线后新增", durationDays: 2)
        _ = try session.deleteTask(id: removed)

        let report = try session.baselineVariance(baselineID: baseline.id, now: frozenNow)
        #expect(report.tasks[kept]?.hasBaseline == true)
        #expect(report.tasks[removed] == nil)
        #expect(report.orphans.map(\.taskID) == [removed])
        #expect(report.tasksWithoutBaseline == 1)
        #expect(report.tasks[added]?.hasBaseline == false)
        // 基线自身不被查询动作清理：条目仍为 2 条。
        #expect(try session.baselines().first?.entries.count == 2)
    }

    // 判据 2（撤销栈）：createBaseline 进撤销栈，restore 后基线与任务一起回滚。
    @Test func createBaselineIsUndoable() throws {
        let session = try newSession()
        _ = try session.addTask(title: "A", durationDays: 2)
        let before = try session.snapshot()

        _ = try session.createBaseline(now: frozenNow)
        #expect(try session.baselines().count == 1)

        try session.restore(before)
        #expect(try session.baselines().isEmpty)
        #expect(try session.listTasks().count == 1)
    }

    // 负路径：未知基线 ID 一律报错且不改状态。
    // 错误码与 CLI/MCP 出口钉成同一粗码 + 细码（08 未规定，由 B-12 对等性用例与 CLI 稳定码
    // model_baseline_not_found 共同定案）：commands 层不 pin 的话，改了细码只有 CLI 会红。
    @Test func baselineOperationsRejectUnknownIdentifiers() throws {
        let session = try newSession()
        _ = try session.addTask(title: "A", durationDays: 2)
        let baseline = try session.createBaseline(now: frozenNow)
        let unknown = UUID()

        for error in [
            sessionError { _ = try session.renameBaseline(id: unknown, name: "不存在") },
            sessionError { try session.deleteBaseline(id: unknown) },
            sessionError { _ = try session.baselineVariance(baselineID: unknown, now: frozenNow) },
        ] {
            let thrown = try #require(error)
            #expect(thrown.code == .invalidArgument)
            #expect(thrown.reason == .baselineNotFound)
        }

        #expect(try session.baselines() == [baseline])
        #expect(try session.listTasks().count == 1)
    }

    // 负路径：空基线名被拒（reason model_baseline_name_empty），不产生基线。
    @Test func blankBaselineNameIsRejected() throws {
        let session = try newSession()
        _ = try session.addTask(title: "A", durationDays: 2)

        let thrown = try #require(sessionError { try session.createBaseline(name: "   ", now: frozenNow) })
        #expect(thrown.code == .invalidArgument)
        #expect(thrown.reason == .baselineNameEmpty)
        #expect(try session.baselines().isEmpty)
    }

    // 负路径：未打开项目时基线接口一律报错（不静默返回空数组）。
    @Test func baselineOperationsRequireOpenProject() throws {
        let session = KaidoSession()

        #expect(throws: SessionError.self) { try session.createBaseline(now: frozenNow) }
        #expect(throws: SessionError.self) { try session.baselines() }
        #expect(throws: SessionError.self) { try session.baselineVariance(now: frozenNow) }
        #expect(throws: SessionError.self) { try session.renameBaseline(id: UUID(), name: "x") }
        #expect(throws: SessionError.self) { try session.deleteBaseline(id: UUID()) }
    }

    // §7.3：打开 v1 后首次保存才升版；保存后 needsFormatUpgrade 转 false 且无 baselines 键。
    @Test func openingV1ThenSavingUpgradesToV2() throws {
        let url = try writeTemporaryFile(v1Document())
        defer { try? FileManager.default.removeItem(at: url) }
        let session = KaidoSession()
        try session.openProject(at: url)
        #expect(session.needsFormatUpgrade)

        try session.saveProject()

        #expect(!session.needsFormatUpgrade)
        let saved = try Data(contentsOf: url)
        let root = try rootObject(of: saved)
        #expect(root["formatVersion"] as? Int == 2)
        #expect(root["baselines"] == nil)
        #expect(try KaidoFile.read(from: saved).sourceFormatVersion == 2)
    }

    // §7.3：打开 v2 文件 → sourceFormatVersion 2、needsFormatUpgrade 为 false、基线可读。
    @Test func openingV2FileNeedsNoUpgrade() throws {
        let url = try writeTemporaryFile(v2Document())
        defer { try? FileManager.default.removeItem(at: url) }
        let session = KaidoSession()
        try session.openProject(at: url)

        #expect(session.sourceFormatVersion == 2)
        #expect(!session.needsFormatUpgrade)
        #expect(try session.baselines().count == 2)
    }
}
