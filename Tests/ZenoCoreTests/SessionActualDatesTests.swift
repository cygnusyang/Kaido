import Foundation
import Testing
@testable import ZenoCommands
@testable import ZenoCore

// 实际开始 / 实际结束的自动记录与人工修正（v0.12 / docs/features/07-actual-dates.md §3 §4 §9）。
// 所有时刻由 now: 参数注入，用例不读墙钟。

/// 夹具时刻：t0 < t1 < t2，差值固定，便于断言「首次为准」。
private let t0 = Date(timeIntervalSince1970: 1_760_000_000)
private let t1 = Date(timeIntervalSince1970: 1_760_003_600)
private let t2 = Date(timeIntervalSince1970: 1_760_007_200)

private func newSession() throws -> ZenoSession {
    let session = ZenoSession()
    try session.createProject(title: "实际时间项目")
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

struct SessionActualDatesTests {
    // MARK: - 判据 1：首次进入 in_progress 记录，重复回写不覆盖

    @Test func enteringInProgressRecordsActualStartOnce() throws {
        let session = try newSession()
        let id = try session.addTask(title: "开工任务")

        let first = try session.statusUpdate(id: id, status: .inProgress, now: t0)
        #expect(first.actualStart == t0)
        #expect(first.completedAt == nil)
        #expect(first.status == .inProgress)

        let second = try session.statusUpdate(id: id, status: .inProgress, now: t1)
        #expect(second.actualStart == t0)
    }

    // MARK: - 判据 2：进度 > 0 记录实际开始，但不改状态

    @Test func progressAboveZeroRecordsActualStartWithoutStatusChange() throws {
        let session = try newSession()
        let id = try session.addTask(title: "部分完成任务")

        let task = try session.statusUpdate(id: id, progress: 0.4, now: t0)
        #expect(task.actualStart == t0)
        #expect(task.status == .pending)
        #expect(task.completedAt == nil)
    }

    /// 进度 0 不算开工：显式回写 0 不产生实际开始。
    @Test func zeroProgressDoesNotRecordActualStart() throws {
        let session = try newSession()
        let id = try session.addTask(title: "未开工任务")

        let task = try session.statusUpdate(id: id, progress: 0, now: t0)
        #expect(task.actualStart == nil)
    }

    // MARK: - 判据 3 / 5：done 记完成时间；离开 done 清完成时间但保留实际开始

    @Test func doneRecordsCompletedAtAndLeavingDoneKeepsActualStart() throws {
        let session = try newSession()
        let id = try session.addTask(title: "先开工后完成")

        _ = try session.statusUpdate(id: id, status: .inProgress, now: t0)
        let done = try session.statusUpdate(id: id, status: .done, now: t1)
        #expect(done.completedAt == t1)
        #expect(done.progress == 1)
        #expect(done.actualStart == t0)

        let reopened = try session.statusUpdate(id: id, status: .inProgress, now: t2)
        #expect(reopened.completedAt == nil)
        #expect(reopened.actualStart == t0)
    }

    /// 判据 5：回退到 pending 不清空实际开始（已发生的开工是历史事实）。
    @Test func revertingToPendingKeepsActualStart() throws {
        let session = try newSession()
        let id = try session.addTask(title: "回退任务")

        _ = try session.statusUpdate(id: id, status: .inProgress, now: t0)
        let reverted = try session.statusUpdate(id: id, status: .pending, now: t1)
        #expect(reverted.status == .pending)
        #expect(reverted.actualStart == t0)
    }

    // MARK: - 判据 4：progress 达 1 等同 done

    @Test func fullProgressRecordsCompletedAtAndDone() throws {
        let session = try newSession()
        let id = try session.addTask(title: "一次性完成")

        let task = try session.statusUpdate(id: id, progress: 1, now: t0)
        #expect(task.status == .done)
        #expect(task.progress == 1)
        #expect(task.completedAt == t0)
        // 直跳完成不臆造开工时刻。
        #expect(task.actualStart == nil)
    }

    // MARK: - 判据 6：pending → done 直跳不补实际开始

    @Test func pendingToDoneDoesNotBackfillActualStart() throws {
        let session = try newSession()
        let id = try session.addTask(title: "直跳完成")

        let task = try session.statusUpdate(id: id, status: .done, now: t0)
        #expect(task.status == .done)
        #expect(task.completedAt == t0)
        #expect(task.actualStart == nil)
    }

    // MARK: - 判据 7：setActualStart 手工写入与清除

    @Test func setActualStartOnPendingTaskStartsIt() throws {
        let session = try newSession()
        let id = try session.addTask(title: "待开工任务")

        let started = try session.setActualStart(id: id, date: t0)
        #expect(started.actualStart == t0)
        #expect(started.status == .inProgress)
        #expect(started.completedAt == nil)
    }

    @Test func clearActualStartKeepsStatus() throws {
        let session = try newSession()
        let id = try session.addTask(title: "清空开工时间")
        _ = try session.statusUpdate(id: id, status: .inProgress, now: t0)

        let cleared = try session.setActualStart(id: id, date: nil)
        #expect(cleared.actualStart == nil)
        #expect(cleared.status == .inProgress)
    }

    /// 补录历史不改状态：done / blocked 任务写入实际开始后仍保持原状态。
    @Test func setActualStartOnDoneOrBlockedTaskKeepsStatus() throws {
        let session = try newSession()
        let doneID = try session.addTask(title: "已完成任务")
        _ = try session.statusUpdate(id: doneID, status: .done, now: t1)

        // 补录的开工时刻必须早于实际结束（顺序校验同时覆盖人工写入）。
        let done = try session.setActualStart(id: doneID, date: t0)
        #expect(done.status == .done)
        #expect(done.actualStart == t0)
        #expect(done.completedAt == t1)

        let blockedID = try session.addTask(title: "受阻任务")
        _ = try session.statusUpdate(id: blockedID, status: .blocked, now: t0)

        let blocked = try session.setActualStart(id: blockedID, date: t1)
        #expect(blocked.status == .blocked)
        #expect(blocked.actualStart == t1)
    }

    /// 清除后再次进入 in_progress 会重新自动记录（人工清除不设锁）。
    @Test func actualStartIsReRecordedAfterManualClear() throws {
        let session = try newSession()
        let id = try session.addTask(title: "重新开工")
        _ = try session.statusUpdate(id: id, status: .inProgress, now: t0)
        _ = try session.setActualStart(id: id, date: nil)

        let resumed = try session.statusUpdate(id: id, status: .inProgress, now: t1)
        #expect(resumed.actualStart == t1)
    }

    // MARK: - 判据 8：setActualFinish 手工写入与清除

    @Test func setActualFinishCompletesTask() throws {
        let session = try newSession()
        let id = try session.addTask(title: "人工完成")
        _ = try session.statusUpdate(id: id, status: .inProgress, now: t0)

        let finished = try session.setActualFinish(id: id, date: t1)
        #expect(finished.completedAt == t1)
        #expect(finished.status == .done)
        #expect(finished.progress == 1)
    }

    @Test func clearActualFinishKeepsDoneStatus() throws {
        let session = try newSession()
        let id = try session.addTask(title: "清空完成时间")
        _ = try session.statusUpdate(id: id, status: .done, now: t0)

        let cleared = try session.setActualFinish(id: id, date: nil)
        #expect(cleared.completedAt == nil)
        #expect(cleared.status == .done)
        #expect(cleared.progress == 1)
    }

    // MARK: - 判据 9：顺序非法拒绝且不写库

    @Test func finishBeforeStartIsRejectedWithoutMutation() throws {
        let session = try newSession()
        let id = try session.addTask(title: "顺序非法")

        _ = try session.setActualStart(id: id, date: t1)
        let error = sessionError { _ = try session.setActualFinish(id: id, date: t0) }
        #expect(error?.code == .invalidArgument)
        #expect(error?.reason == .actualDateOrderInvalid)
        #expect(error?.taskID == id)

        let unchanged = try session.getTask(id: id)
        #expect(unchanged.completedAt == nil)
        #expect(unchanged.actualStart == t1)
        #expect(unchanged.status == .inProgress)
    }

    @Test func startAfterFinishIsRejectedWithoutMutation() throws {
        let session = try newSession()
        let id = try session.addTask(title: "顺序非法")
        _ = try session.statusUpdate(id: id, status: .done, now: t0)

        let error = sessionError { _ = try session.setActualStart(id: id, date: t2) }
        #expect(error?.reason == .actualDateOrderInvalid)

        let unchanged = try session.getTask(id: id)
        #expect(unchanged.actualStart == nil)
        #expect(unchanged.completedAt == t0)
        #expect(unchanged.status == .done)
    }

    /// 同一时刻（开始 == 结束）合法：零时长任务不该被顺序校验拦住。
    @Test func equalStartAndFinishIsAllowed() throws {
        let session = try newSession()
        let id = try session.addTask(title: "零时长")

        _ = try session.setActualStart(id: id, date: t0)
        let finished = try session.setActualFinish(id: id, date: t0)
        #expect(finished.actualStart == t0)
        #expect(finished.completedAt == t0)
        #expect(finished.status == .done)
    }

    // MARK: - 判据 14 的补丁路径：状态统一回写入口同样自动记录

    @Test func patchStatusUsesSameWritePath() throws {
        let session = try newSession()
        let id = try session.addTask(title: "补丁开工")
        var patch = TaskPatch()
        patch.status = .inProgress

        let task = try session.updateTask(id: id, patch: patch)
        #expect(task.actualStart != nil)
    }

    @Test func missingTaskIsRejectedByActualDateWrites() throws {
        let session = try newSession()
        let missing = UUID()

        #expect(sessionError { _ = try session.setActualStart(id: missing, date: t0) }?.reason == .taskNotFound)
        #expect(sessionError { _ = try session.setActualFinish(id: missing, date: t0) }?.reason == .taskNotFound)
    }
}
