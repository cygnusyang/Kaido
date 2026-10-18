import Foundation
import Testing
@testable import KairoCore

// 调度引擎纯函数测试（ADR-007 / US-E2-01 / US-E2-02）。
// 日期间算统一用 UTC 午夜；引擎以自然日（24h）为最小单位（US-E2-04 之前的工作周简化）。

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d))!
}

private let d0 = day(2026, 11, 2) // 2026-11-02 周一

private func task(
    _ title: String,
    id: UUID? = nil,
    duration: Double? = nil,
    deps: [TaskDependency] = [],
    policy: SchedulingPolicy = .asap,
    constraint: SchedulingConstraint? = nil,
    kind: TaskKind = .task
) -> TaskItem {
    TaskItem(
        id: id ?? UUID(),
        title: title,
        kind: kind,
        durationDays: duration,
        dependencies: deps,
        constraint: constraint,
        schedulingPolicy: policy
    )
}

private func compute(_ tasks: [TaskItem], start: Date? = d0, end: Date? = nil) -> ScheduleResult {
    ScheduleEngine.compute(tasks: tasks, projectStart: start, projectEnd: end, calendar: utc)
}

// MARK: - FS / FF / SS / SF 四型相关性（含正负前导时间）

struct DependencyPropagationTests {
    @Test func finishToStartBasic() throws {
        let a = task("A", duration: 3)
        let b = task("B", duration: 2, deps: [TaskDependency(predecessorID: a.id, type: .fs)])
        let result = compute([a, b])
        let sb = try #require(result.scheduled(b.id))
        // B 的开始不早于 A 的结束（FS）。
        #expect(sb.earliestStart == day(2026, 11, 5))
        #expect(sb.earliestFinish == day(2026, 11, 7))
    }

    @Test func finishToStartWithPositiveLag() throws {
        let a = task("A", duration: 3)
        let b = task("B", duration: 2, deps: [TaskDependency(predecessorID: a.id, type: .fs, lagDays: 2)])
        let result = compute([a, b])
        let sb = try #require(result.scheduled(b.id))
        // B 开始 ≥ A 结束 + 2 天 = D0+5（2026-11-07）。
        #expect(sb.earliestStart == day(2026, 11, 7))
    }

    @Test func finishToStartWithNegativeLag() throws {
        let a = task("A", duration: 3)
        let b = task("B", duration: 2, deps: [TaskDependency(predecessorID: a.id, type: .fs, lagDays: -1)])
        let result = compute([a, b])
        let sb = try #require(result.scheduled(b.id))
        // B 开始 ≥ A 结束 - 1 天 = D0+2（允许重叠）。
        #expect(sb.earliestStart == day(2026, 11, 4))
    }

    @Test func startToStartBasic() throws {
        let a = task("A", duration: 3)
        let b = task("B", duration: 2, deps: [TaskDependency(predecessorID: a.id, type: .ss)])
        let result = compute([a, b])
        let sb = try #require(result.scheduled(b.id))
        // B 开始 ≥ A 开始。
        #expect(sb.earliestStart == d0)
        #expect(sb.earliestFinish == day(2026, 11, 4))
    }

    @Test func startToStartWithLag() throws {
        let a = task("A", duration: 3)
        let b = task("B", duration: 2, deps: [TaskDependency(predecessorID: a.id, type: .ss, lagDays: 1)])
        let result = compute([a, b])
        let sb = try #require(result.scheduled(b.id))
        // B 开始 ≥ A 开始 + 1 天。
        #expect(sb.earliestStart == day(2026, 11, 3))
    }

    @Test func finishToFinishBasic() throws {
        let a = task("A", duration: 3)
        let b = task("B", duration: 2, deps: [TaskDependency(predecessorID: a.id, type: .ff)])
        let result = compute([a, b])
        let sb = try #require(result.scheduled(b.id))
        // B 结束 ≥ A 结束 = D0+3 → B 开始 ≥ D0+1。
        #expect(sb.earliestStart == day(2026, 11, 3))
        #expect(sb.earliestFinish == day(2026, 11, 5))
    }

    @Test func finishToFinishWithLag() throws {
        let a = task("A", duration: 3)
        let b = task("B", duration: 2, deps: [TaskDependency(predecessorID: a.id, type: .ff, lagDays: 1)])
        let result = compute([a, b])
        let sb = try #require(result.scheduled(b.id))
        // B 结束 ≥ A 结束 + 1 = D0+4 → B 开始 ≥ D0+2。
        #expect(sb.earliestStart == day(2026, 11, 4))
        #expect(sb.earliestFinish == day(2026, 11, 6))
    }

    @Test func startToFinishBasic() throws {
        let a = task("A", duration: 3, constraint: .startNoEarlierThan(day(2026, 11, 9)))
        let b = task("B", duration: 2, deps: [TaskDependency(predecessorID: a.id, type: .sf)])
        let result = compute([a, b])
        let sa = try #require(result.scheduled(a.id))
        let sb = try #require(result.scheduled(b.id))
        // A 开始 D0+7（时限抬升）；SF：B 结束 ≥ A 开始 → B 开始 ≥ A 开始 − 2 = D0+5。
        #expect(sa.earliestStart == day(2026, 11, 9))
        #expect(sb.earliestStart == day(2026, 11, 7))
        #expect(sb.earliestFinish >= sa.earliestStart)
    }

    @Test func startToFinishWithLag() throws {
        let a = task("A", duration: 3, constraint: .startNoEarlierThan(day(2026, 11, 9)))
        let b = task("B", duration: 2, deps: [TaskDependency(predecessorID: a.id, type: .sf, lagDays: 2)])
        let result = compute([a, b])
        let sb = try #require(result.scheduled(b.id))
        // B 结束 ≥ A 开始 + 2 = D0+9 → B 开始 ≥ D0+7。
        #expect(sb.earliestStart == day(2026, 11, 9))
        #expect(sb.earliestFinish == day(2026, 11, 11))
    }
}

// MARK: - ASAP / ALAP

struct PolicyTests {
    @Test func asapTaskSchedulesAtEarliest() throws {
        let c = task("C", duration: 2, policy: .asap)
        let result = compute([c], end: day(2026, 11, 10))
        let sc = try #require(result.scheduled(c.id))
        #expect(sc.scheduledStart == d0)
        #expect(sc.scheduledFinish == day(2026, 11, 4))
    }

    @Test func alapTaskSchedulesAtLatestBoundedByProjectEnd() throws {
        let c = task("C", duration: 2, policy: .alap)
        let result = compute([c], end: day(2026, 11, 10))
        let sc = try #require(result.scheduled(c.id))
        // ALAP：以项目结束为界取最晚 → 结束 = 项目结束（2026-11-10），开始 = D0+6（2026-11-08）。
        #expect(sc.scheduledStart == day(2026, 11, 8))
        #expect(sc.scheduledFinish == day(2026, 11, 10))
        #expect(sc.totalSlackDays == 6)
    }

    @Test func alapTaskInChainPushedToLatest() throws {
        let a = task("A", duration: 2)
        let b = task("B", duration: 2)
        let c = task("C", duration: 2, policy: .alap)
        // C 无前驱；项目结束固定后 ALAP 尽量靠后。
        let result = compute([a, b, c], end: day(2026, 11, 10))
        let sc = try #require(result.scheduled(c.id))
        let sa = try #require(result.scheduled(a.id))
        #expect(sc.scheduledStart == day(2026, 11, 8))
        #expect(sa.scheduledStart == d0)
    }
}

// MARK: - 持续时间与默认值

struct DurationTests {
    @Test func missingDurationDefaultsToOneDay() throws {
        let t = task("T")
        let result = compute([t])
        let s = try #require(result.scheduled(t.id))
        #expect(s.durationDays == 1)
        #expect(s.earliestFinish == day(2026, 11, 3))
    }

    @Test func milestoneHasZeroDuration() throws {
        let m = task("M", kind: .milestone)
        let result = compute([m])
        let s = try #require(result.scheduled(m.id))
        #expect(s.durationDays == 0)
        #expect(s.scheduledStart == s.scheduledFinish)
    }

    @Test func projectStartBoundsEarliestStart() throws {
        let t = task("T", duration: 2)
        let result = compute([t], start: day(2026, 11, 16))
        let s = try #require(result.scheduled(t.id))
        #expect(s.earliestStart == day(2026, 11, 16))
    }

    @Test func startNoEarlierThanConstraintRaisesEarliestStart() throws {
        let t = task("T", duration: 2, constraint: .startNoEarlierThan(day(2026, 11, 20)))
        let result = compute([t])
        let s = try #require(result.scheduled(t.id))
        #expect(s.earliestStart == day(2026, 11, 20))
    }
}

// MARK: - 环检测（F-30-08）

struct CycleDetectionTests {
    @Test func twoTaskCycleFlagsBoth() {
        let aID = UUID()
        let bID = UUID()
        let b = task("B", id: bID, deps: [TaskDependency(predecessorID: aID)])
        // 构造 A→B→A 环：A 依赖 B（用同一 id 闭合）。
        let aClosed = task("A", id: aID, deps: [TaskDependency(predecessorID: bID)])
        let result = compute([aClosed, b])
        #expect(result.cycleTaskIDs.contains(aID))
        #expect(result.cycleTaskIDs.contains(bID))
        #expect(result.cycleTaskIDs.count == 2)
    }

    @Test func threeCycleExcludesFreeTask() {
        let aID = UUID()
        let bID = UUID()
        let cID = UUID()
        let b = task("B", id: bID, deps: [TaskDependency(predecessorID: aID)])
        let c = task("C", id: cID, deps: [TaskDependency(predecessorID: bID)])
        let aClosed = task("A", id: aID, deps: [TaskDependency(predecessorID: cID)])
        let free = task("自由任务")
        let result = compute([aClosed, b, c, free])
        #expect(Set(result.cycleTaskIDs) == Set([aID, bID, cID]))
        #expect(!result.cycleTaskIDs.contains(free.id))
    }
}

// MARK: - 宽延（US-E2-03 输入：引擎直接输出）

struct SlackTests {
    @Test func totalAndFreeSlackOnTightChain() throws {
        let a = task("A", duration: 2)
        let b = task("B", duration: 2, deps: [TaskDependency(predecessorID: a.id, type: .fs)])
        let result = compute([a, b], end: day(2026, 11, 16))
        let sa = try #require(result.scheduled(a.id))
        // A 最早开始 D0；最晚开始 = 项目结束 − B − A = D0+10 → 总宽延 10 天。
        // 自由宽延 = 0（一推迟即拖累 B 的最早开始）。
        #expect(sa.totalSlackDays == 10)
        #expect(sa.freeSlackDays == 0)
        // 无后继任务的自由宽延等于总宽延。
        let sb = try #require(result.scheduled(b.id))
        #expect(sb.freeSlackDays == sb.totalSlackDays)
    }
}
