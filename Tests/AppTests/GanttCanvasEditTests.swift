import Foundation
import Testing
import KaidoCore
import KaidoCommands
import KaidoPresentation
@testable import KaidoMacApp

// F-14-09 Store 路由测试：canvasEditSchedule 三语义（move/resize 右端/resize 左端）、
// 撤销合并（长拖拽多笔节流提交并成一步）、依赖建/删复用与环拒绝。

@MainActor
@Suite("F-14-09 画布直接编辑")
struct GanttCanvasEditTests {
    private func makeStore() -> WorkspaceStore {
        let suite = "kaido.f1409.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return WorkspaceStore(defaults: defaults, seedsDemoData: true)
    }

    private func makeDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return Calendar.current.date(from: components)!
    }

    private func task(_ store: WorkspaceStore, _ id: UUID) throws -> TaskItem {
        try #require(store.exportProject.tasks.first { $0.id == id })
    }

    private func draggableTask(_ store: WorkspaceStore) throws -> TaskItem {
        try #require(store.exportProject.tasks.first { $0.kind == .task })
    }

    // MARK: - move：只改 startDate，duration 不变

    @Test func moveUpdatesStartDateOnly() throws {
        let store = makeStore()
        let original = try draggableTask(store)
        let target = makeDate(2025, 6, 2)

        store.dispatch(.canvasEditSchedule(original.id, startDate: target, durationDays: nil))

        let updated = try task(store, original.id)
        #expect(updated.startDate == target)
        #expect(updated.durationDays == original.durationDays, "拖条改期不改持续时间")
    }

    // MARK: - resize 右端：只改 duration，start 不变

    @Test func resizeEndUpdatesDurationOnly() throws {
        let store = makeStore()
        let original = try draggableTask(store)

        store.dispatch(.canvasEditSchedule(original.id, startDate: nil, durationDays: 9))

        let updated = try task(store, original.id)
        #expect(updated.durationDays == 9)
        #expect(updated.startDate == original.startDate, "拖右端不改开始日期")
    }

    // MARK: - resize 左端：start 与 duration 同变，end 不变

    @Test func resizeStartKeepsFinishDate() throws {
        let store = makeStore()
        let original = try draggableTask(store)
        // 演示数据任务可能无显式 duration：先固定为 5 天（与画布拖拽解耦的前置）。
        store.dispatch(.setDuration(original.id, 5))
        let originalStart = try #require(original.startDate)
        let originalDuration = try #require(task(store, original.id).durationDays)
        let originalFinish = originalStart.addingTimeInterval(originalDuration * 86_400)
        let newStart = originalStart.addingTimeInterval(2 * 86_400)

        store.dispatch(.canvasEditSchedule(
            original.id, startDate: newStart, durationDays: originalDuration - 2
        ))

        let updated = try task(store, original.id)
        #expect(updated.startDate == newStart)
        #expect(updated.durationDays == originalDuration - 2)
        let updatedFinish = updated.startDate!.addingTimeInterval((try #require(updated.durationDays)) * 86_400)
        #expect(updatedFinish == originalFinish, "拖左端结束日期不变")
    }

    // MARK: - 撤销合并：连续两笔 move 并为一步

    @Test func consecutiveCanvasMovesMergeIntoSingleUndo() throws {
        let store = makeStore()
        let original = try draggableTask(store)
        let first = makeDate(2025, 6, 2)
        let second = makeDate(2025, 6, 5)

        store.dispatch(.canvasEditSchedule(original.id, startDate: first, durationDays: nil))
        store.dispatch(.canvasEditSchedule(original.id, startDate: second, durationDays: nil))
        #expect(try task(store, original.id).startDate == second)

        // 同 mergeKey 在 500ms 内合并：一次 undo 回到原始 startDate。
        store.dispatch(.undo)
        #expect(try task(store, original.id).startDate == original.startDate)
    }

    // MARK: - 依赖：复用 add/removeDependency，环拒绝

    @Test func canvasDependencyCommitAndRemove() throws {
        let store = makeStore()
        let tasks = store.exportProject.tasks
        let a = try #require(tasks.first { $0.kind == .task })
        let b = try #require(tasks.drop(while: { $0.id == a.id }).first { $0.kind == .task })

        // 从 a 尾端拖到 b：a 是 b 的前驱。
        store.dispatch(.addDependency(
            taskID: b.id, predecessorID: a.id, type: .fs, lagDays: 0
        ))
        #expect(try task(store, b.id).dependencies.contains { $0.predecessorID == a.id })

        // 点选线按 Delete：removeDependency。
        store.dispatch(.removeDependency(taskID: b.id, predecessorID: a.id))
        #expect(!(try task(store, b.id).dependencies.contains { $0.predecessorID == a.id }))
    }

    @Test func cycleDependencyIsRejectedWithoutSideEffect() throws {
        let store = makeStore()
        let tasks = store.exportProject.tasks
        let a = try #require(tasks.first { $0.kind == .task })
        let b = try #require(tasks.drop(while: { $0.id == a.id }).first { $0.kind == .task })

        store.dispatch(.addDependency(
            taskID: b.id, predecessorID: a.id, type: .fs, lagDays: 0
        ))
        // 反向建线成环：拒绝，b 的依赖不变。
        store.dispatch(.addDependency(
            taskID: a.id, predecessorID: b.id, type: .fs, lagDays: 0
        ))
        #expect(!(try task(store, a.id).dependencies.contains { $0.predecessorID == b.id }))
    }

    // MARK: - 里程碑（演示数据无里程碑，经动作创建）

    @Test func milestoneMoveViaAction() throws {
        let store = makeStore()
        store.dispatch(.createTask(parentID: nil, kind: .milestone))
        let milestone = try #require(store.exportProject.tasks.first { $0.kind == .milestone })
        let target = makeDate(2025, 7, 1)

        store.dispatch(.canvasEditSchedule(milestone.id, startDate: target, durationDays: nil))
        #expect(try task(store, milestone.id).startDate == target)
    }
}
