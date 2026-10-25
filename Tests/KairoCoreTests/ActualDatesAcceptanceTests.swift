import Foundation
import Testing

@testable import KairoCore
@testable import KairoCommands

// 实际开始 / 实际结束（v0.12）验收用例
// 依据：docs/features/07-actual-dates.md §9（判据 1-10、14）与 §3/§4 派生边界；
// 用例映射见 docs/features/07-actual-dates-cases.md。
//
// 断言口径（只表达设计语义，不锁实现细节）：
// - 时间一律由调用方注入（判据 14），用例从不读墙钟；
// - 「实际结束」= TaskItem.completedAt（07 §2 命名裁决），断言一律落在 completedAt；
// - 首次记录必须与注入值 == 相等，不接受「非 nil 即可」；
// - 状态回退后 actualStart 是历史事实（保留），completedAt 是完成断言（清除）。
//
// 当前预期为红：actualStart、setActualStart/setActualFinish、statusUpdate(…, now:) 尚未实现，
// 由 dev-coder-core 波次 A/B 实现。转绿判据见 cases 文档「先红后绿」。

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
private let t1 = t0.addingTimeInterval(86_400)
private let t2 = t0.addingTimeInterval(2 * 86_400)

/// 建一个含单任务的会话（判据组的最小前置）。
private func makeSession(taskTitle: String) throws -> (session: KairoSession, id: UUID) {
    let session = KairoSession()
    _ = try session.createProject(title: "实际时间验收")
    let id = try session.addTask(title: taskTitle)
    return (session, id)
}

/// 断言抛出期望的会话错误；不抛错或抛成别的错误类型都判失败。
private func expectSessionError(
    _ code: SessionError.Code,
    _ reason: KairoErrorCode,
    _ body: () throws -> Void
) {
    do {
        try body()
        Issue.record("应抛 SessionError(code: \(code.rawValue), reason: \(reason.rawValue))，实际未抛错")
    } catch let error as SessionError {
        #expect(error.code == code)
        #expect(error.reason == reason)
    } catch {
        Issue.record("应抛 SessionError，实际抛 \(error)")
    }
}

/// v0.11 及以前的任务键集合。新键只允许 actualStart（07 §2 否决 actualFinish 改名/并存）。
private let legacyTaskKeys: Set<String> = [
    "id", "title", "notes", "startDate", "dueDate", "priority", "status", "tags", "assignee",
    "kind", "parentID", "effortHours", "durationDays", "dependencies", "progress",
    "constraint", "schedulingPolicy", "completedAt", "assignments",
]

private func taskObjects(in data: Data) throws -> [[String: Any]] {
    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try #require(root["tasks"] as? [[String: Any]])
}

private func formatVersion(in data: Data) throws -> Int {
    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try #require(root["formatVersion"] as? Int)
}

/// 模拟「旧版本写的文件」：从任务对象里删掉某个新键。
private func removingTaskKey(_ key: String, from data: Data) throws -> Data {
    var root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    var tasks = try #require(root["tasks"] as? [[String: Any]])
    for index in tasks.indices { tasks[index].removeValue(forKey: key) }
    root["tasks"] = tasks
    return try JSONSerialization.data(withJSONObject: root)
}

// MARK: - 自动记录（判据 1-6、14；07 §3）

/// 判据 1 前半 + 判据 14：首次置 in_progress 写入注入的 now，且不产生完成时间。
@Test func firstWritebackToInProgressRecordsActualStart() throws {
    let (session, id) = try makeSession(taskTitle: "首次开工")
    let task = try session.statusUpdate(id: id, status: .inProgress, now: t0)

    #expect(task.status == .inProgress)
    #expect(task.actualStart == t0)
    #expect(task.completedAt == nil)
}

/// 判据 1 后半 / 边界 B-01：再次 .inProgress 不覆盖，值保持首次。
@Test func repeatedInProgressWritebackKeepsFirstActualStart() throws {
    let (session, id) = try makeSession(taskTitle: "重复回写")
    _ = try session.statusUpdate(id: id, status: .inProgress, now: t0)
    let again = try session.statusUpdate(id: id, status: .inProgress, now: t1)

    #expect(again.actualStart == t0)
    #expect(again.status == .inProgress)
}

/// 边界 B-01（进度路径）：进度多次回写同样只记首次。
@Test func repeatedProgressWritebackKeepsFirstActualStart() throws {
    let (session, id) = try makeSession(taskTitle: "进度重复回写")
    _ = try session.statusUpdate(id: id, progress: 0.2, now: t0)
    let later = try session.statusUpdate(id: id, progress: 0.8, now: t1)

    #expect(later.actualStart == t0)
    #expect(later.progress == 0.8)
}

/// 判据 2：进度 > 0 且未满 → 记实际开始，但状态不得隐式跳变。
@Test func progressBelowOneRecordsActualStartWithoutChangingStatus() throws {
    let (session, id) = try makeSession(taskTitle: "进度开工")
    let task = try session.statusUpdate(id: id, progress: 0.4, now: t0)

    #expect(task.actualStart == t0)
    #expect(task.status == .pending)
    #expect(task.progress == 0.4)
}

/// 判定边界（§3 表格「progress > 0」）：进度 0 不算开工，不得写入实际开始。
@Test func zeroProgressWritebackDoesNotRecordActualStart() throws {
    let (session, id) = try makeSession(taskTitle: "进度零")
    let task = try session.statusUpdate(id: id, progress: 0, now: t0)

    #expect(task.actualStart == nil)
    #expect(task.status == .pending)
}

/// 判据 3：置 done 记 completedAt + 进度 1；离开 done 清 completedAt、保留 actualStart。
@Test func markingDoneStampsCompletedAtAndLeavingDoneKeepsActualStart() throws {
    let (session, id) = try makeSession(taskTitle: "完成与回退")
    _ = try session.statusUpdate(id: id, status: .inProgress, now: t0)

    let done = try session.statusUpdate(id: id, status: .done, now: t1)
    #expect(done.completedAt == t1)
    #expect(done.progress == 1)
    #expect(done.actualStart == t0)

    let reopened = try session.statusUpdate(id: id, status: .pending, now: t2)
    #expect(reopened.completedAt == nil)
    #expect(reopened.actualStart == t0)
}

/// 判据 4：进度 1 等同 done（状态、进度、完成时间三者一致）。
@Test func progressOneCompletesTaskLikeDone() throws {
    let (session, id) = try makeSession(taskTitle: "进度满格")
    let task = try session.statusUpdate(id: id, progress: 1, now: t1)

    #expect(task.status == .done)
    #expect(task.progress == 1)
    #expect(task.completedAt == t1)
}

/// 判据 5：in_progress → pending 回退不清空 actualStart。
@Test func rollbackFromInProgressKeepsActualStart() throws {
    let (session, id) = try makeSession(taskTitle: "回退")
    _ = try session.statusUpdate(id: id, status: .inProgress, now: t0)

    let rolledBack = try session.statusUpdate(id: id, status: .pending, now: t1)
    #expect(rolledBack.actualStart == t0)
    #expect(rolledBack.completedAt == nil)
    #expect(rolledBack.status == .pending)
}

/// 判据 6 / 边界 B-02：pending 直跳 done 不补 actualStart（不臆造未观测到的开工时刻）。
@Test func directJumpFromPendingToDoneLeavesActualStartEmpty() throws {
    let (session, id) = try makeSession(taskTitle: "直跳完成")
    let byStatus = try session.statusUpdate(id: id, status: .done, now: t1)
    #expect(byStatus.actualStart == nil)
    #expect(byStatus.completedAt == t1)

    let (progressSession, progressID) = try makeSession(taskTitle: "直跳完成（进度路径）")
    let byProgress = try progressSession.statusUpdate(id: progressID, progress: 1, now: t1)
    #expect(byProgress.actualStart == nil)
}

/// 边界 B-02 补充：blocked 直跳 done 同样不补 actualStart（§3 表格写的是 pending/blocked）。
@Test func directJumpFromBlockedToDoneLeavesActualStartEmpty() throws {
    let (session, id) = try makeSession(taskTitle: "阻塞直跳完成")
    _ = try session.statusUpdate(id: id, status: .blocked, now: t0)

    let done = try session.statusUpdate(id: id, status: .done, now: t1)
    #expect(done.actualStart == nil)
    #expect(done.completedAt == t1)
}

// MARK: - 手工编辑（判据 7-9；07 §4）

/// 判据 7 前半：nil = 清除，且不改状态。
@Test func clearingActualStartKeepsStatus() throws {
    let (session, id) = try makeSession(taskTitle: "清除实际开始")
    _ = try session.statusUpdate(id: id, status: .inProgress, now: t0)

    let cleared = try session.setActualStart(id: id, date: nil)
    #expect(cleared.actualStart == nil)
    #expect(cleared.status == .inProgress)
}

/// 判据 7 中段：对 pending 任务写非 nil → 顺带置 in_progress。
@Test func manualActualStartPromotesPendingTask() throws {
    let (session, id) = try makeSession(taskTitle: "补录开工")
    let task = try session.setActualStart(id: id, date: t0)

    #expect(task.actualStart == t0)
    #expect(task.status == .inProgress)
}

/// 判据 7 后半：对 done / blocked 任务写实际开始不改状态（补录历史不重开任务）。
@Test func manualActualStartDoesNotReopenDoneOrBlockedTask() throws {
    let (doneSession, doneID) = try makeSession(taskTitle: "已完成补录")
    _ = try doneSession.statusUpdate(id: doneID, status: .done, now: t1)
    let backdated = t0
    let done = try doneSession.setActualStart(id: doneID, date: backdated)
    #expect(done.status == .done)
    #expect(done.completedAt == t1)
    #expect(done.actualStart == backdated)

    let (blockedSession, blockedID) = try makeSession(taskTitle: "阻塞补录")
    _ = try blockedSession.statusUpdate(id: blockedID, status: .blocked, now: t1)
    let blocked = try blockedSession.setActualStart(id: blockedID, date: t0)
    #expect(blocked.status == .blocked)
    #expect(blocked.actualStart == t0)
}

/// 判据 8 前半：nil 只清 completedAt，status 保持 done。
@Test func clearingActualFinishOnlyClearsCompletedAt() throws {
    let (session, id) = try makeSession(taskTitle: "清除实际结束")
    _ = try session.statusUpdate(id: id, status: .done, now: t1)

    let cleared = try session.setActualFinish(id: id, date: nil)
    #expect(cleared.completedAt == nil)
    #expect(cleared.status == .done)
}

/// 判据 8 后半：非 nil → done + progress 1 + completedAt 为该值。
@Test func manualActualFinishCompletesTask() throws {
    let (session, id) = try makeSession(taskTitle: "补录完成")
    _ = try session.statusUpdate(id: id, status: .inProgress, now: t0)

    let task = try session.setActualFinish(id: id, date: t1)
    #expect(task.status == .done)
    #expect(task.progress == 1)
    #expect(task.completedAt == t1)
    #expect(task.actualStart == t0)
}

/// 判据 9 方向一：actualStart > actualFinish → invalidArgument + model_actual_date_order_invalid，任务不被修改。
@Test func actualStartAfterActualFinishIsRejectedWithoutMutation() throws {
    let (session, id) = try makeSession(taskTitle: "顺序非法")
    _ = try session.setActualFinish(id: id, date: t1)
    let before = try session.getTask(id: id)

    expectSessionError(.invalidArgument, .actualDateOrderInvalid) {
        _ = try session.setActualStart(id: id, date: t2)
    }

    #expect(try session.getTask(id: id) == before)
}

/// 判据 9 方向二：actualFinish < actualStart → 同一错误码，任务不被修改。
@Test func actualFinishBeforeExistingActualStartIsRejectedWithoutMutation() throws {
    let (session, id) = try makeSession(taskTitle: "顺序非法（结束）")
    _ = try session.setActualStart(id: id, date: t1)
    let before = try session.getTask(id: id)

    expectSessionError(.invalidArgument, .actualDateOrderInvalid) {
        _ = try session.setActualFinish(id: id, date: t0)
    }

    #expect(try session.getTask(id: id) == before)
}

/// 判据 9 边界：相等不算逆序（判据只禁 > / <），同日开工并完工必须允许。
@Test func equalActualDatesAreAccepted() throws {
    let (session, id) = try makeSession(taskTitle: "同日开工完工")

    _ = try session.setActualStart(id: id, date: t0)
    let task = try session.setActualFinish(id: id, date: t0)
    #expect(task.actualStart == t0)
    #expect(task.completedAt == t0)
    #expect(task.status == .done)
}

/// 判据 7/8 共享前置：任务不存在时写实际时间必须报 model_task_not_found（不静默写入）。
@Test func manualActualDatesOnMissingTaskAreRejected() throws {
    let session = KairoSession()
    _ = try session.createProject(title: "空项目")
    let missing = UUID()

    expectSessionError(.taskNotFound, .taskNotFound) {
        _ = try session.setActualStart(id: missing, date: t0)
    }
    expectSessionError(.taskNotFound, .taskNotFound) {
        _ = try session.setActualFinish(id: missing, date: t0)
    }
}

/// 07 §4 末句：人工值与自动值同源 —— 人工写入后自动逻辑不覆盖。
@Test func manualActualStartIsNotOverwrittenByLaterWriteback() throws {
    let (session, id) = try makeSession(taskTitle: "人工优先")
    _ = try session.setActualStart(id: id, date: t0)

    let later = try session.statusUpdate(id: id, status: .inProgress, now: t1)
    #expect(later.actualStart == t0)
}

/// 07 §4 末句（反向）：清除后再进入 in_progress 会重新自动记录。
@Test func clearedActualStartIsRecordedAgainOnNextStart() throws {
    let (session, id) = try makeSession(taskTitle: "清除后重新开工")
    _ = try session.statusUpdate(id: id, status: .inProgress, now: t0)
    _ = try session.setActualStart(id: id, date: nil)
    _ = try session.statusUpdate(id: id, status: .pending, now: t1)

    let restarted = try session.statusUpdate(id: id, status: .inProgress, now: t2)
    #expect(restarted.actualStart == t2)
}

// MARK: - 存储与向后兼容（判据 10；07 §7）

/// 判据 10：旧 .kairo（无 actualStart 键）打开 → 字段 nil、formatVersion 仍为 1。
@Test func legacyFileWithoutActualStartDecodesNilAndKeepsFormatVersion() throws {
    let project = Project()
    project.tasks = [TaskItem(title: "旧任务", actualStart: t0)]
    let current = try KairoFile.encode(project: project)
    #expect(try formatVersion(in: current) == 1)

    let legacy = try removingTaskKey("actualStart", from: current)
    let loaded = try KairoFile.decode(from: legacy)

    #expect(loaded.tasks.first?.actualStart == nil)
    #expect(loaded.tasks.first?.title == "旧任务")
    #expect(KairoFile.currentFormatVersion == 1)
}

/// 判据 10 后半：新文件被旧版本读回 —— 任务对象只多出 actualStart 一个键，且 nil 时不写键。
@Test func encodedTaskAddsOnlyActualStartKey() throws {
    let withActual = Project()
    withActual.tasks = [TaskItem(title: "有实际开始", actualStart: t0)]
    let withKeys = try #require(try taskObjects(in: try KairoFile.encode(project: withActual)).first)
    #expect(Set(withKeys.keys).subtracting(legacyTaskKeys) == ["actualStart"])

    let withoutActual = Project()
    withoutActual.tasks = [TaskItem(title: "无实际开始")]
    let emptyKeys = try #require(try taskObjects(in: try KairoFile.encode(project: withoutActual)).first)
    #expect(emptyKeys["actualStart"] == nil)
}

// MARK: - 非目标守卫（07 §10）

/// 07 §10：实际时间不回灌排期 —— 写实际开始/结束不得移动计划开始与计划结束。
@Test func actualDatesDoNotFeedBackIntoTheSchedule() throws {
    let session = KairoSession()
    _ = try session.createProject(title: "排期不变", projectStart: t0)
    let id = try session.addTask(title: "任务", durationDays: 2)

    let before = try session.computeSchedule()
    _ = try session.setActualStart(id: id, date: t1)
    _ = try session.setActualFinish(id: id, date: t2)
    let after = try session.computeSchedule()

    #expect(after.tasks.map(\.scheduledStart) == before.tasks.map(\.scheduledStart))
    #expect(after.tasks.map(\.scheduledFinish) == before.tasks.map(\.scheduledFinish))
}
