import Foundation
import Testing
import KairoCore
import KairoCommands
import KairoPresentation
@testable import KairoMacApp

// F-14-10 Store 路由：setTaskStart 写意图起点 / setTaskFinish 折算持续时间、
// 非法结束日期拒绝（无撤销点、无数据变更）、一次编辑一步撤销、与画布拖拽互不合并。

@MainActor
@Suite("F-14-10 任务起止日期动作")
struct Sprint8TaskDateActionTests {
    private func makeStore() -> WorkspaceStore {
        let suite = "kairo.f1410.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return WorkspaceStore(defaults: defaults, seedsDemoData: true)
    }

    private func makeDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        guard let date = Calendar.current.date(from: components) else {
            fatalError("测试日期构造失败：\(year)-\(month)-\(day)")
        }
        return date
    }

    private func task(_ store: WorkspaceStore, _ title: String) throws -> TaskItem {
        try #require(store.exportProject.tasks.first { $0.title == title })
    }

    private func task(_ store: WorkspaceStore, _ id: UUID) throws -> TaskItem {
        try #require(store.exportProject.tasks.first { $0.id == id })
    }

    private func row(_ store: WorkspaceStore, _ id: UUID) throws -> PlanRow {
        try #require(store.snapshot.outline.rows.first { $0.id == id })
    }

    /// 演示数据中无前置、无显式 startDate 的任务：排期起点 = 项目开始日。
    private func plainTask(_ store: WorkspaceStore) throws -> TaskItem {
        let candidate = try task(store, "整理用户反馈")
        #expect(candidate.dependencies.isEmpty)
        #expect(candidate.startDate == nil)
        return candidate
    }

    // MARK: - setTaskStart

    @Test func setTaskStartWritesIntentDate() throws {
        let store = makeStore()
        let original = try plainTask(store)
        let target = makeDate(2025, 11, 2)

        store.dispatch(.setTaskStart(original.id, target))

        let updated = try task(store, original.id)
        #expect(updated.startDate == target)
        #expect(updated.durationDays == original.durationDays, "改开始不改持续时间")
    }

    @Test func setTaskStartWithNilClearsIntentDate() throws {
        let store = makeStore()
        let backend = try #require(store.exportProject.tasks.first { $0.startDate != nil })

        store.dispatch(.setTaskStart(backend.id, nil))

        #expect(try task(store, backend.id).startDate == nil)
    }

    @Test func setTaskStartDoesNotTouchDueDate() throws {
        let store = makeStore()
        let original = try plainTask(store)

        store.dispatch(.setTaskStart(original.id, makeDate(2025, 11, 2)))

        #expect(try task(store, original.id).dueDate == original.dueDate)
    }

    /// 群组由 UI 禁用编辑，Store 侧保持可写（与既有 setDueDate / setDuration 一致）。
    @Test func setTaskStartOnGroupIsNotBlockedByStore() throws {
        let store = makeStore()
        store.dispatch(.createTask(parentID: nil, kind: .group))
        let groupID = try #require(store.selection)
        let target = makeDate(2025, 11, 2)

        store.dispatch(.setTaskStart(groupID, target))

        #expect(try task(store, groupID).startDate == target)
        #expect(store.alertMessage == nil)
    }

    // MARK: - setTaskFinish

    @Test func setTaskFinishRewritesDurationAndKeepsStartDate() throws {
        let store = makeStore()
        let backend = try task(store, "实现搜索后端")
        let start = try #require(backend.startDate)
        let startOfDay = ScheduleDateMath.startOfDay(start)
        let finish = try #require(Calendar.current.date(byAdding: .day, value: 5, to: startOfDay))

        store.dispatch(.setTaskFinish(backend.id, finish: finish, start: start))

        let updated = try task(store, backend.id)
        #expect(updated.durationDays == 5)
        #expect(updated.startDate == backend.startDate, "结束只折算持续时间，不动开始意图")
    }

    @Test func setTaskFinishMakesScheduledFinishMatchSelectedDay() throws {
        let store = makeStore()
        let original = try plainTask(store)
        let scheduledStart = try #require(try row(store, original.id).scheduledStart)
        let finish = try #require(Calendar.current.date(byAdding: .day, value: 5, to: scheduledStart))

        store.dispatch(.setTaskFinish(original.id, finish: finish, start: scheduledStart))

        #expect(try row(store, original.id).scheduledFinish == finish)
    }

    @Test func setTaskFinishRejectsFinishEqualToStart() throws {
        let store = makeStore()
        let original = try plainTask(store)
        let scheduledStart = try #require(try row(store, original.id).scheduledStart)
        let originalDuration = original.durationDays

        store.dispatch(.setTaskFinish(original.id, finish: scheduledStart, start: scheduledStart))

        #expect(store.alertMessage == "结束日期必须晚于开始日期")
        #expect(try task(store, original.id).durationDays == originalDuration)
    }

    @Test func setTaskFinishRejectsFinishEarlierThanStart() throws {
        let store = makeStore()
        let original = try plainTask(store)
        let scheduledStart = try #require(try row(store, original.id).scheduledStart)
        let earlier = try #require(Calendar.current.date(byAdding: .day, value: -2, to: scheduledStart))
        let originalDuration = original.durationDays

        store.dispatch(.setTaskFinish(original.id, finish: earlier, start: scheduledStart))

        #expect(store.alertMessage == "结束日期必须晚于开始日期")
        #expect(try task(store, original.id).durationDays == originalDuration)
    }

    /// 非法路径在 update 之前返回：不产生撤销点，一次 undo 应撤掉上一笔合法改动。
    @Test func rejectedFinishDoesNotPushUndoPoint() throws {
        let store = makeStore()
        let original = try plainTask(store)
        let originalStartDate = original.startDate
        let scheduledStart = try #require(try row(store, original.id).scheduledStart)
        let target = makeDate(2025, 11, 2)

        store.dispatch(.setTaskStart(original.id, target))
        #expect(try task(store, original.id).startDate == target)

        store.dispatch(.setTaskFinish(original.id, finish: scheduledStart, start: scheduledStart))
        #expect(store.alertMessage != nil)

        store.dispatch(.undo)
        #expect(try task(store, original.id).startDate == originalStartDate)
    }

    @Test func rejectedFinishLeavesNoDraftOrNotice() throws {
        let store = makeStore()
        let original = try plainTask(store)
        let scheduledStart = try #require(try row(store, original.id).scheduledStart)

        store.dispatch(.setTaskFinish(original.id, finish: scheduledStart, start: scheduledStart))

        #expect(store.alertMessage == "结束日期必须晚于开始日期")
        #expect(store.notice == nil)
    }

    // MARK: - 撤销粒度

    @Test func eachTaskStartEditIsOneUndoStep() throws {
        let store = makeStore()
        let original = try plainTask(store)
        let first = makeDate(2025, 11, 2)
        let second = makeDate(2025, 11, 9)

        store.dispatch(.setTaskStart(original.id, first))
        store.dispatch(.setTaskStart(original.id, second))
        #expect(try task(store, original.id).startDate == second)

        // 同字段 500ms 内两笔合并为一步（既有 pushUndo 合并规则）。
        store.dispatch(.undo)
        #expect(try task(store, original.id).startDate == original.startDate)
    }

    @Test func taskStartAndFinishEditsAreSeparateUndoSteps() throws {
        let store = makeStore()
        let original = try plainTask(store)
        let target = makeDate(2025, 11, 2)

        store.dispatch(.setTaskStart(original.id, target))
        let scheduledStart = try #require(try row(store, original.id).scheduledStart)
        let finish = try #require(Calendar.current.date(byAdding: .day, value: 4, to: scheduledStart))
        store.dispatch(.setTaskFinish(original.id, finish: finish, start: scheduledStart))

        store.dispatch(.undo)
        #expect(try task(store, original.id).startDate == target, "第一步撤销只回退结束")
        #expect(try task(store, original.id).durationDays == original.durationDays)

        store.dispatch(.undo)
        #expect(try task(store, original.id).startDate == original.startDate, "第二步撤销回退开始")
    }

    @Test func taskStartEditDoesNotMergeWithCanvasMove() throws {
        let store = makeStore()
        let original = try plainTask(store)
        let target = makeDate(2025, 11, 2)
        let canvasTarget = makeDate(2025, 12, 1)

        store.dispatch(.setTaskStart(original.id, target))
        store.dispatch(.canvasEditSchedule(original.id, startDate: canvasTarget, durationDays: nil))
        #expect(try task(store, original.id).startDate == canvasTarget)

        store.dispatch(.undo)
        #expect(try task(store, original.id).startDate == target, "检查器编辑与画布拖拽各自一步")
    }

    // MARK: - 快照透出

    @Test func inspectorSnapshotCarriesStartDate() throws {
        let store = makeStore()
        let backend = try task(store, "实现搜索后端")

        store.dispatch(.select(backend.id))

        guard case .task(let inspector) = store.snapshot.inspector.content else {
            Issue.record("选中任务后检查器应显示任务页")
            return
        }
        #expect(inspector.startDate == backend.startDate)
    }

    @Test func inspectorSnapshotCarriesNilStartDateForGroup() throws {
        let store = makeStore()
        store.dispatch(.createTask(parentID: nil, kind: .group))
        let groupID = try #require(store.selection)
        store.dispatch(.createTask(parentID: groupID, kind: .task))
        store.dispatch(.select(groupID))

        guard case .task(let inspector) = store.snapshot.inspector.content else {
            Issue.record("选中群组后检查器应显示任务页")
            return
        }
        #expect(inspector.kind == .group)
        #expect(inspector.startDate == nil)
    }
}
