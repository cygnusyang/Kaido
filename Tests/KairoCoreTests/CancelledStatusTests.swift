import Foundation
import Testing
@testable import KairoCore
@testable import KairoCommands

// 已取消终态（v0.16 B1）：`cancelled` 是「决定不做」的终点，不是 blocked 的变体。
// 语义契约：
// 1) 模型：status 增 `cancelled`，新键 `cancelReason`（缺键 → nil，格式版本不变）；
// 2) 命令层：转 cancelled 必须给非空原因，离开 cancelled 清原因，转 cancelled 清实际结束；
// 3) 派生：排期 / 违例 / 关键路径 / 进度分母一律不含 cancelled。

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d))!
}

private let d0 = day(2026, 11, 2) // 2026-11-02 周一
private let now = day(2026, 10, 18)

private func newSession() throws -> KairoSession {
    let session = KairoSession()
    try session.createProject(title: "已取消终态项目")
    return session
}

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

private func task(
    _ title: String,
    id: UUID? = nil,
    status: TaskStatus = .pending,
    duration: Double? = nil,
    progress: Double = 0,
    effort: Double? = nil,
    parentID: UUID? = nil,
    kind: TaskKind = .task,
    deps: [TaskDependency] = [],
    constraint: SchedulingConstraint? = nil,
    dueDate: Date? = nil
) -> TaskItem {
    TaskItem(
        id: id ?? UUID(),
        title: title,
        dueDate: dueDate,
        status: status,
        kind: kind,
        parentID: parentID,
        effortHours: effort,
        durationDays: duration,
        dependencies: deps,
        progress: progress,
        constraint: constraint
    )
}

// MARK: - 模型层

struct CancelledTaskModelTests {
    /// rawValue 落在磁盘与接口契约上：写 "cancelled"，且新用例追加在末尾（CaseIterable 顺序即 UI 顺序）。
    @Test func cancelledRawValueIsStableAndAppendedLast() {
        #expect(TaskStatus(rawValue: "cancelled") == .cancelled)
        #expect(TaskStatus.allCases.last == .cancelled)
        #expect(TaskStatus.allCases.map(\.rawValue) == [
            "pending", "in_progress", "done", "blocked", "cancelled",
        ])
    }

    /// 原因字段：默认 nil、按 camelCase 键落盘、往返精确还原。
    @Test func cancelReasonDefaultsToNilAndRoundTrips() throws {
        let plain = TaskItem(title: "普通任务")
        #expect(plain.cancelReason == nil)

        let cancelled = TaskItem(title: "砍掉的任务", status: .cancelled, cancelReason: "需求取消")
        #expect(cancelled.cancelReason == "需求取消")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(decoding: try encoder.encode(cancelled), as: UTF8.self)
        #expect(json.contains("\"cancelReason\""))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TaskItem.self, from: try encoder.encode(cancelled))
        #expect(decoded.cancelReason == "需求取消")
        #expect(decoded.status == .cancelled)

        // nil 不落盘（不写空键，旧读者看到的仍是旧形状）。
        let plainJSON = String(decoding: try encoder.encode(plain), as: UTF8.self)
        #expect(!plainJSON.contains("\"cancelReason\""))
    }

    /// 旧 .kairo（无 cancelReason 键）解码为 nil，不报错（ADR-011 前向兼容）。
    @Test func legacyPayloadWithoutCancelReasonDecodesAsNil() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","title":"旧任务","notes":"","priority":"normal","status":"blocked","tags":[],"kind":"task","dependencies":[],"progress":0,"schedulingPolicy":"asap","assignments":[]}
        """
        let task = try JSONDecoder().decode(TaskItem.self, from: Data(legacy.utf8))
        #expect(task.cancelReason == nil)
        #expect(task.status == .blocked)
    }

    /// 新字段参与 Equatable/Hashable：原因不同即不同任务。
    @Test func cancelReasonParticipatesInEquatable() {
        var first = TaskItem(title: "任务", status: .cancelled)
        let second = TaskItem(id: first.id, title: "任务", status: .cancelled)
        first.cancelReason = "甲方砍需求"
        #expect(first != second)
        #expect(Set([first, second]).count == 2)
    }
}

// MARK: - 命令层：状态回写

struct CancelledStatusSessionTests {
    /// 无原因 / 全空白原因都拒绝，且任务不被修改（不写库）。
    @Test func cancellingWithoutReasonIsRejectedAndLeavesTaskUntouched() throws {
        let session = try newSession()
        let id = try session.addTask(title: "要砍的任务")

        let missing = sessionError { _ = try session.statusUpdate(id: id, status: .cancelled, now: d0) }
        #expect(missing?.reason == .cancelReasonRequired)
        #expect(missing?.code == .invalidArgument)

        for blank in ["", "   ", "\n\t"] {
            let error = sessionError {
                _ = try session.statusUpdate(id: id, status: .cancelled, cancelReason: blank, now: d0)
            }
            #expect(error?.reason == .cancelReasonRequired, "空白原因必须拒绝：\(blank.debugDescription)")
        }

        let stored = try #require(try session.listTasks().first { $0.id == id })
        #expect(stored.status == .pending)
        #expect(stored.cancelReason == nil)
    }

    /// 原因按去空白后存库；取消是终态，不记实际结束、不动进度。
    @Test func cancellingStoresTrimmedReason() throws {
        let session = try newSession()
        let id = try session.addTask(title: "要砍的任务")
        _ = try session.statusUpdate(id: id, progress: 0.3, now: d0)

        let cancelled = try session.statusUpdate(
            id: id, status: .cancelled, cancelReason: "  需求取消 \n", now: d0
        )
        #expect(cancelled.status == .cancelled)
        #expect(cancelled.cancelReason == "需求取消")
        #expect(cancelled.completedAt == nil)
        #expect(cancelled.progress == 0.3, "取消不把进度抹平")
    }

    /// pending → cancelled → pending：原因不残留。
    @Test func revertingFromCancelledClearsReason() throws {
        let session = try newSession()
        let id = try session.addTask(title: "先砍后恢复")

        _ = try session.statusUpdate(id: id, status: .cancelled, cancelReason: "先放着", now: d0)
        let reverted = try session.statusUpdate(id: id, status: .pending, now: d0)
        #expect(reverted.status == .pending)
        #expect(reverted.cancelReason == nil)
    }

    /// done → cancelled：清空实际结束（没做完就不该有完成时刻）。
    @Test func doneToCancelledClearsCompletedAt() throws {
        let session = try newSession()
        let id = try session.addTask(title: "先完成后砍")

        let done = try session.statusUpdate(id: id, status: .done, now: d0)
        #expect(done.completedAt == d0)

        let cancelled = try session.statusUpdate(
            id: id, status: .cancelled, cancelReason: "做完又不要了", now: now
        )
        #expect(cancelled.completedAt == nil)
        #expect(cancelled.cancelReason == "做完又不要了")
    }

    /// cancelled → inProgress / done / blocked 都清原因（原因只属于 cancelled 状态）。
    @Test func everyExitFromCancelledClearsReason() throws {
        for target in [TaskStatus.inProgress, .done, .blocked, .pending] {
            let session = try newSession()
            let id = try session.addTask(title: "退出取消：\(target.rawValue)")
            _ = try session.statusUpdate(id: id, status: .cancelled, cancelReason: "一次性", now: d0)

            let moved = try session.statusUpdate(id: id, status: target, now: d0)
            #expect(moved.status == target)
            #expect(moved.cancelReason == nil, "离开 cancelled 必须清原因：\(target.rawValue)")
        }
    }

    /// 取消的任务忽略进度回写：终态不会被 progress=1 悄悄变成 done。
    @Test func cancelledTaskIgnoresProgressWriteBack() throws {
        let session = try newSession()
        let id = try session.addTask(title: "已取消")
        _ = try session.statusUpdate(id: id, status: .cancelled, cancelReason: "不做了", now: d0)

        let after = try session.statusUpdate(id: id, progress: 1, now: d0)
        #expect(after.status == .cancelled)
        #expect(after.cancelReason == "不做了")
        #expect(after.completedAt == nil)
    }

    /// 新建任务不能直接是已取消（终态只能由回写进入，否则原因必然缺失）。
    @Test func addTaskCannotBeBornCancelled() throws {
        let session = try newSession()
        let error = sessionError { _ = try session.addTask(title: "新任务", status: .cancelled) }
        #expect(error?.reason == .cancelReasonRequired)
        #expect(try session.listTasks().isEmpty)
    }

    /// 补丁路径同样受约束：没有原因的补丁被整体拒绝（不留半改记录）。
    @Test func taskPatchCannotCancelWithoutReason() throws {
        let session = try newSession()
        let id = try session.addTask(title: "补丁取消")

        var patch = TaskPatch()
        patch.title = "改名"
        patch.status = .cancelled
        let error = sessionError { _ = try session.updateTask(id: id, patch: patch) }
        #expect(error?.reason == .cancelReasonRequired)

        let stored = try #require(try session.listTasks().first { $0.id == id })
        #expect(stored.title == "补丁取消", "整条补丁被拒，标题也不得写入")
        #expect(stored.status == .pending)

        var allowed = TaskPatch()
        allowed.status = .cancelled
        allowed.cancelReason = "补丁原因"
        let cancelled = try session.updateTask(id: id, patch: allowed)
        #expect(cancelled.cancelReason == "补丁原因")
    }

    /// 批量回写带原因成功、缺原因逐条失败且不中断其余条目。
    @Test func statusBatchCarriesReasonPerEntry() throws {
        let session = try newSession()
        let cancelledID = try session.addTask(title: "批量取消")
        let pendingID = try session.addTask(title: "批量待办")

        let result = try session.statusBatch([
            .init(taskID: cancelledID, status: .cancelled, cancelReason: "批量原因"),
            .init(taskID: pendingID, status: .cancelled),
        ])

        #expect(result.succeeded == 1)
        #expect(result.failed == 1)
        let stored = try #require(try session.listTasks().first { $0.id == cancelledID })
        #expect(stored.cancelReason == "批量原因")
    }
}

// MARK: - 排期 / 违例 / 关键路径

struct CancelledScheduleTests {
    /// 取消的任务没有排期条目：不出甘特条、不被当成「无法排期」。
    @Test func cancelledTaskHasNoScheduleEntry() {
        let active = task("在做", duration: 2)
        let dropped = task("砍掉", status: .cancelled, duration: 5)
        let result = ScheduleEngine.compute(tasks: [active, dropped], projectStart: d0, calendar: utc)

        #expect(result.scheduled(dropped.id) == nil)
        #expect(!result.hasSchedule(for: dropped.id))
        #expect(result.tasks.map(\.taskID) == [active.id])
        #expect(!result.unscheduledTaskIDs.contains(dropped.id))
    }

    /// 取消的前驱不再卡住后继：后继从项目锚点起排，而不是等一个不做的任务。
    @Test func cancelledPredecessorDoesNotDelaySuccessor() throws {
        let dropped = task("砍掉的前驱", status: .cancelled, duration: 5)
        let successor = task(
            "后继", duration: 2, deps: [TaskDependency(predecessorID: dropped.id, type: .fs)]
        )
        let result = ScheduleEngine.compute(tasks: [dropped, successor], projectStart: d0, calendar: utc)

        let scheduled = try #require(result.scheduled(successor.id))
        #expect(scheduled.earliestStart == d0)
        #expect(scheduled.scheduledFinish == day(2026, 11, 4))
    }

    /// 群组窗口聚合忽略已取消的子任务。
    @Test func groupWindowIgnoresCancelledChildren() throws {
        let group = task("阶段", kind: .group)
        let active = task("保留", duration: 3, parentID: group.id)
        let dropped = task("砍掉", status: .cancelled, duration: 10, parentID: group.id)
        let result = ScheduleEngine.compute(
            tasks: [group, active, dropped], projectStart: d0, calendar: utc
        )

        let window = try #require(result.scheduled(group.id))
        #expect(window.scheduledStart == d0)
        #expect(window.scheduledFinish == day(2026, 11, 5))
        #expect(window.durationDays == 3)
    }

    /// 关键路径不参与：取消的任务既不在排期里，也就不在重要路径明细里。
    @Test func criticalPathExcludesCancelled() {
        let active = task("在做", duration: 2)
        let dropped = task("砍掉", status: .cancelled, duration: 5)
        let result = ScheduleEngine.compute(tasks: [active, dropped], projectStart: d0, calendar: utc)

        let entries = CriticalPathEngine.compute(result: result)
        #expect(entries.map(\.taskID) == [active.id])
    }

    /// 取消的任务不报违例：即便它越过项目结束、且时限装不下持续时间。
    @Test func violationsIgnoreCancelled() {
        let dropped = task(
            "砍掉", status: .cancelled, duration: 10,
            constraint: .endNoLaterThan(day(2026, 11, 1))
        )
        let active = task("在做", duration: 2)
        let result = ScheduleEngine.compute(
            tasks: [active, dropped], projectStart: d0, projectEnd: day(2026, 11, 5), calendar: utc
        )
        let violations = ViolationEngine.check(result: result, tasks: [active, dropped])

        #expect(!violations.contains { $0.taskID == dropped.id })
    }
}

// MARK: - 进度分母与群组聚合

struct CancelledProgressTests {
    /// 项目摘要：取消的叶子不进进度与健康分母，也不算逾期。
    @Test func summaryExcludesCancelledFromDenominator() {
        let done = task("已完成", status: .done, progress: 1, effort: 1)
        let dropped = task("已取消", status: .cancelled, progress: 0, effort: 1, dueDate: day(2026, 10, 1))
        let pending = task("待办", effort: 1)

        let summary = ProjectSummary(
            tasks: [done, dropped, pending], schedule: nil, violations: [], now: now, calendar: utc
        )

        // 分母只剩 已完成 + 待办 → 1/2；取消项不进分母。
        #expect(abs(summary.totalProgress - 0.5) < 0.0001)
        #expect(summary.incompleteLeafCount == 1)
        #expect(summary.overdueCount == 0, "已取消不算逾期")
        #expect(summary.missingDueDateCount == 1)
        #expect(summary.criticalPathCount == 0)
    }

    /// 逾期口径：cancelled 一律不算逾期（与 done 同档）。
    @Test func isOverdueIsFalseForCancelled() {
        let dropped = task("已取消", status: .cancelled, dueDate: day(2026, 10, 1))
        #expect(!ProjectSummary.isOverdue(
            dropped, plannedFinish: day(2026, 10, 1), now: now, calendar: utc
        ))
    }

    /// 大纲群组：取消的子任务不占权重，也不拖住群组完成态。
    @Test func outlineGroupIgnoresCancelledLeaf() {
        let group = task("阶段", kind: .group)
        let done = task("做完", status: .done, progress: 1, parentID: group.id)
        let dropped = task("砍掉", status: .cancelled, parentID: group.id)

        let tree = OutlineTree(tasks: [group, done, dropped], calendar: utc)
        let row = tree.rows.first { $0.id == group.id }
        #expect(row?.aggregateProgress == 1)
        #expect(row?.aggregateStatus == .done)
    }

    /// 命令层群组完成度：取消的叶子不进加权分母。
    @Test func sessionGroupProgressIgnoresCancelledLeaf() throws {
        let session = try newSession()
        let groupID = try session.addTask(title: "阶段", kind: .group)
        let doneID = try session.addTask(title: "做完", parentID: groupID, effortHours: 1)
        let droppedID = try session.addTask(title: "砍掉", parentID: groupID, effortHours: 1)

        _ = try session.statusUpdate(id: doneID, status: .done, now: d0)
        _ = try session.statusUpdate(id: droppedID, status: .cancelled, cancelReason: "不做了", now: d0)

        #expect(try session.groupProgress(id: groupID) == 1)
    }
}
