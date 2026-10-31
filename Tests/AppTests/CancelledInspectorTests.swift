import Foundation
import Testing
import ZenoCommands
import ZenoCore
import ZenoPresentation
@testable import ZenoMacApp

/// v0.16 D：检查器的「已取消」状态选择与取消原因（应用适配层 + 视图口径）。
///
/// 口径与 core 同源：转入 `cancelled` 必须给非空白原因，空白请求在 Store 层就被
/// 拦下（不写库、不留撤销步）；原因属于该终态，离开即清空。
@MainActor
@Suite("已取消状态（检查器）")
struct CancelledInspectorTests {
    private func makeStore() -> WorkspaceStore {
        let suite = "zeno.apptests.cancelled.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let store = WorkspaceStore(
            defaults: defaults,
            seedsDemoData: true,
            projectLoader: { try ZenoFile.read(from: $0) }
        )
        // 启动窗口是 [今天, 今天+7)：示例里结束在昨天的任务不画条。
        // 本套用例拿 hasGanttBar 当正反判据——没有条时「!hasGanttBar」会必然成立（假绿），
        // 因此显式进入 fit 还原"全部内容可见"的前提，正反两边才有判别力。
        store.dispatch(.setFitZoom(true))
        return store
    }

    private func task(_ store: WorkspaceStore, _ title: String) throws -> TaskItem {
        try #require(store.exportProject.tasks.first { $0.title == title })
    }

    /// 选中任务后取检查器任务页快照；不是任务页返回 nil（由 `#require` 报错）。
    private func inspectorTask(_ store: WorkspaceStore, id: UUID) -> TaskInspector? {
        store.dispatch(.select(id))
        guard case .task(let inspector) = store.snapshot.inspector.content else { return nil }
        return inspector
    }

    private func hasGanttBar(_ store: WorkspaceStore, id: UUID) -> Bool {
        store.snapshot.gantt.bars.contains { $0.taskID == id }
    }

    // MARK: - 原因口径

    /// 空白（含换行/制表符）视作没填；首尾空白在提交前归一掉。
    @Test func cancelReasonInputTrimsAndRejectsBlank() {
        #expect(CancelReasonInput.normalized("   ") == nil)
        #expect(CancelReasonInput.normalized("\n\t ") == nil)
        #expect(CancelReasonInput.normalized("") == nil)
        #expect(CancelReasonInput.normalized("  预算砍掉  ") == "预算砍掉")
    }

    /// 已取消必须能从检查器的状态列表里选到（列表按 `allCases` 生成）。
    @Test func cancelledStatusIsSelectableAndLocalized() {
        #expect(TaskStatus.allCases.contains(.cancelled))
        let title = Display.statusTitle(.cancelled)
        #expect(!title.isEmpty)
        #expect(title != "outline.status.cancelled")
    }

    // MARK: - 空白原因

    /// 空白原因：状态不变、无取消原因、给出提示、不产生撤销步。
    @Test func blankReasonKeepsStatusAndAlerts() throws {
        let store = makeStore()
        let target = try task(store, "实现搜索后端")
        let initialStatus = target.status
        let undoDepth = store.undoDepthForTesting

        store.dispatch(.cancelTask(target.id, reason: "   "))

        let unchanged = try task(store, "实现搜索后端")
        #expect(unchanged.status == initialStatus)
        #expect(unchanged.cancelReason == nil)
        #expect(store.alertMessage != nil)
        #expect(store.undoDepthForTesting == undoDepth)
        #expect(hasGanttBar(store, id: target.id))
    }

    // MARK: - 带原因取消

    /// 带原因取消：快照状态与原因正确、检查器多出原因、甘特不再有该任务条。
    @Test func cancelWithReasonStoresReasonAndDropsGanttBar() throws {
        let store = makeStore()
        let target = try task(store, "实现搜索后端")

        store.dispatch(.cancelTask(target.id, reason: "  预算砍掉，本期不做  "))

        let cancelled = try task(store, "实现搜索后端")
        #expect(cancelled.status == .cancelled)
        #expect(cancelled.cancelReason == "预算砍掉，本期不做")
        #expect(store.alertMessage == nil)

        let inspector = try #require(inspectorTask(store, id: target.id))
        #expect(inspector.status == .cancelled)
        #expect(inspector.cancelReason == "预算砍掉，本期不做")
        #expect(!hasGanttBar(store, id: target.id))
    }

    // MARK: - 恢复待办

    /// 恢复为待办：状态回 pending、原因清空、重新进排期。
    @Test func restoreToPendingClearsReason() throws {
        let store = makeStore()
        let target = try task(store, "实现搜索后端")
        store.dispatch(.cancelTask(target.id, reason: "范围收缩，移到下一版"))
        #expect(try task(store, "实现搜索后端").status == .cancelled)

        store.dispatch(.setStatus(target.id, .pending))

        let restored = try task(store, "实现搜索后端")
        #expect(restored.status == .pending)
        #expect(restored.cancelReason == nil)
        #expect(hasGanttBar(store, id: target.id))
        let inspector = try #require(inspectorTask(store, id: target.id))
        #expect(inspector.cancelReason == nil)
    }

    // MARK: - 撤销

    /// 取消进撤销栈：撤销一次即回到取消前的状态与原因。
    @Test func undoRestoresCancelledTask() throws {
        let store = makeStore()
        let target = try task(store, "实现搜索后端")
        let initialStatus = target.status
        store.dispatch(.cancelTask(target.id, reason: "预算砍掉"))
        #expect(try task(store, "实现搜索后端").status == .cancelled)

        store.dispatch(.undo)

        let reverted = try task(store, "实现搜索后端")
        #expect(reverted.status == initialStatus)
        #expect(reverted.cancelReason == nil)
    }
}
