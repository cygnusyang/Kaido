import Foundation
import Testing
import ZenoCore
@testable import ZenoMacApp

/// 状态选择规则（D-037）：转「已取消」必须先填原因，两个入口共用同一判据。
@MainActor
@Suite("状态选择动作（大纲 / 检查器共用）")
struct OutlineStatusActionTests {

    @Test func cancelledFromAnyOtherStatePromptsForReason() {
        for current in [TaskStatus.pending, .inProgress, .done, .blocked] {
            #expect(
                OutlineStatusAction.forSelection(.cancelled, current: current) == .promptCancelReason,
                "从 \(current.rawValue) 转取消必须弹原因层"
            )
        }
    }

    @Test func selectingCancelledAgainDoesNotPrompt() {
        #expect(OutlineStatusAction.forSelection(.cancelled, current: .cancelled) == .apply(.cancelled))
    }

    @Test func otherStatusesApplyDirectly() {
        for status in [TaskStatus.pending, .inProgress, .done, .blocked] {
            #expect(OutlineStatusAction.forSelection(status, current: .cancelled) == .apply(status))
            #expect(OutlineStatusAction.forSelection(status, current: .pending) == .apply(status))
        }
    }

    /// 行内取消走的是 `cancelTask`（带原因），不是 `setStatus`：后者不落原因、会被会话拒绝。
    @Test func cancellingFromOutlineStoresReason() throws {
        let suite = "zeno.tests.outline-cancel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let store = WorkspaceStore(
            defaults: defaults,
            seedsDemoData: true,
            projectLoader: { try ZenoFile.read(from: $0) }
        )
        let taskID = try #require(store.snapshot.outline.rows.first?.id)

        store.dispatch(.cancelTask(taskID, reason: "  预算砍掉  "))
        let row = try #require(store.snapshot.outline.rows.first { $0.id == taskID })
        #expect(row.status == .cancelled)

        // 原因经检查器快照读出（store.session 为 private，不为了测试放公开口）。
        store.dispatch(.select(taskID))
        guard case .task(let inspector) = store.snapshot.inspector.content else {
            Issue.record("期望任务检查器快照")
            return
        }
        #expect(inspector.cancelReason == "预算砍掉", "原因需去首尾空白后落库")
    }
}
