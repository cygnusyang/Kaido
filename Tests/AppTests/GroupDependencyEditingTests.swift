import Foundation
import Testing
import KairoCommands
import KairoCore
import KairoPresentation
@testable import KairoMacApp

/// 群组依赖可编辑（v0.16 / issue #16）。
///
/// 口径：依赖是群组自己维护的关系，不从子任务汇总，因此群组行的大纲前置列与
/// 检查器 Dependencies 区块都必须可写；日期、持续时间、负责人、进度仍是聚合值，
/// 保持只读。这里的用例锁住「放开了依赖」与「没顺带放开日期」两侧。
@MainActor
@Suite("群组依赖可编辑（v0.16 / issue #16）")
struct GroupDependencyEditingTests {
    /// 每个用例独立偏好域，避免污染开发者真实配置。
    private func makeStore() -> WorkspaceStore {
        let suite = "kairo.apptests.groupdeps.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return WorkspaceStore(defaults: defaults, seedsDemoData: false)
    }

    private func row(_ store: WorkspaceStore, id: UUID) throws -> PlanRow {
        try #require(store.snapshot.outline.rows.first { $0.id == id })
    }

    private func task(_ store: WorkspaceStore, id: UUID) throws -> TaskItem {
        try #require(store.exportProject.tasks.first { $0.id == id })
    }

    /// 一颗最小树：根任务（潜在前驱）+ 群组 + 群组的子任务。
    private struct Fixture {
        let store: WorkspaceStore
        let predecessorID: UUID
        let groupID: UUID
        let childID: UUID
    }

    private func makeFixture() throws -> Fixture {
        let store = makeStore()
        store.dispatch(.createTask(parentID: nil, kind: .task))
        let predecessorID = try #require(store.selection)
        store.dispatch(.createTask(parentID: nil, kind: .group))
        let groupID = try #require(store.selection)
        store.dispatch(.createTask(parentID: groupID, kind: .task))
        let childID = try #require(store.selection)
        return Fixture(
            store: store,
            predecessorID: predecessorID,
            groupID: groupID,
            childID: childID
        )
    }

    // MARK: - ① 大纲前置列

    /// 前置列的可编辑性不随聚合变化：群组行同样是 true。
    @Test func predecessorCellIsEditableOnGroupRows() {
        #expect(OutlineTextCellEditing.isEditable(column: .predecessors, isAggregate: true))
        #expect(OutlineTextCellEditing.isEditable(column: .predecessors, isAggregate: false))
    }

    /// 其余文本列仍按聚合只读：这次只放开依赖，持续时间/负责人不能被顺带放开。
    @Test func otherTextCellsKeepTheirAggregateGuard() {
        for column in [OutlineColumn.duration, .assignee] {
            #expect(!OutlineTextCellEditing.isEditable(column: column, isAggregate: true), "\(column) 在群组行必须只读")
            #expect(OutlineTextCellEditing.isEditable(column: column, isAggregate: false), "\(column) 在叶子行必须可写")
        }
    }

    /// 群组行前置列编辑后落库：提交走与单元格同一条动作（.setPredecessors），
    /// 快照里的 predecessorsText 随之变化——这正是单元格显示的值。
    @Test func groupPredecessorEditLandsInSnapshot() throws {
        let fixture = try makeFixture()
        let before = try row(fixture.store, id: fixture.groupID)
        #expect(before.isAggregate)
        #expect(before.predecessorsText.isEmpty)

        // 用户在前置列输入前驱的大纲编号（单元格 onCommit 的原样入参）。
        fixture.store.dispatch(.setPredecessors(fixture.groupID, "1"))

        let after = try row(fixture.store, id: fixture.groupID)
        #expect(!after.predecessorsText.isEmpty, "群组行前置列写入后快照必须变化")
        let dependencies = try task(fixture.store, id: fixture.groupID).dependencies
        #expect(dependencies.count == 1)
        #expect(dependencies.first?.predecessorID == fixture.predecessorID)
    }

    /// 反向：清空前置（输入为空）同样对群组生效。
    @Test func groupPredecessorEditCanBeCleared() throws {
        let fixture = try makeFixture()
        fixture.store.dispatch(.setPredecessors(fixture.groupID, "1"))
        #expect(try !row(fixture.store, id: fixture.groupID).predecessorsText.isEmpty)

        fixture.store.dispatch(.setPredecessors(fixture.groupID, ""))

        #expect(try row(fixture.store, id: fixture.groupID).predecessorsText.isEmpty)
        #expect(try task(fixture.store, id: fixture.groupID).dependencies.isEmpty)
    }

    // MARK: - ② 检查器 Dependencies 区块

    /// 选择器对群组有候选：自身与后代被排除，其余任务可选。
    @Test func dependencyPickerOffersCandidatesForGroup() throws {
        let fixture = try makeFixture()
        let candidates = fixture.store.predecessorCandidates(for: fixture.groupID)

        #expect(!candidates.isEmpty, "群组必须能打开选择器并选到候选")
        #expect(candidates.contains { $0.id == fixture.predecessorID })
        #expect(!candidates.contains { $0.id == fixture.groupID }, "不得把自己列为前驱")
        #expect(!candidates.contains { $0.id == fixture.childID }, "不得把后代列为前驱（成环）")
    }

    /// 检查器添加依赖（.addDependency）→ 快照更新 + 恰好一个撤销点，一步可撤。
    @Test func groupDependencyAddIsOneUndoStep() throws {
        let fixture = try makeFixture()
        let depthBefore = fixture.store.undoDepthForTesting

        fixture.store.dispatch(.addDependency(
            taskID: fixture.groupID,
            predecessorID: fixture.predecessorID,
            type: .fs,
            lagDays: 0
        ))

        #expect(try task(fixture.store, id: fixture.groupID).dependencies.count == 1)
        #expect(try !row(fixture.store, id: fixture.groupID).predecessorsText.isEmpty)
        #expect(fixture.store.undoDepthForTesting == depthBefore + 1)

        fixture.store.dispatch(.undo)

        #expect(try task(fixture.store, id: fixture.groupID).dependencies.isEmpty)
        #expect(try row(fixture.store, id: fixture.groupID).predecessorsText.isEmpty)
        #expect(fixture.store.undoDepthForTesting == depthBefore)
    }

    /// 检查器移除依赖同样作用于群组（Dependencies 区块的减号按钮）。
    @Test func groupDependencyRemoveWorks() throws {
        let fixture = try makeFixture()
        fixture.store.dispatch(.addDependency(
            taskID: fixture.groupID,
            predecessorID: fixture.predecessorID,
            type: .fs,
            lagDays: 0
        ))
        #expect(try task(fixture.store, id: fixture.groupID).dependencies.count == 1)

        fixture.store.dispatch(.removeDependency(
            taskID: fixture.groupID,
            predecessorID: fixture.predecessorID
        ))

        #expect(try task(fixture.store, id: fixture.groupID).dependencies.isEmpty)
    }

    // MARK: - ③ 日期仍只读（回归守卫）

    /// 群组行的开始/结束仍禁用，原因仍是 .aggregate：依赖放开不等于日期放开。
    /// 检查器的日期行挂同一个 isAggregate 标志（InspectorView 的 isEnabled），
    /// 所以这里同时守住两侧。
    @Test func groupDatesRemainReadOnly() throws {
        let fixture = try makeFixture()
        let groupRow = try row(fixture.store, id: fixture.groupID)

        #expect(groupRow.isAggregate)
        #expect(OutlineDateEditing.availability(column: .start, row: groupRow) == .disabled(reason: .aggregate))
        #expect(OutlineDateEditing.availability(column: .finish, row: groupRow) == .disabled(reason: .aggregate))
        #expect(!OutlineDateEditing.isEnabled(column: .start, row: groupRow))
        #expect(!OutlineDateEditing.isEnabled(column: .finish, row: groupRow))
        #expect(!OutlineDateEditing.canClear(column: .start, row: groupRow))
        // 反证：同一行的依赖列已经可写，说明上面的只读是日期专属，不是整行被禁。
        #expect(OutlineTextCellEditing.isEditable(column: .predecessors, isAggregate: groupRow.isAggregate))
    }

    /// 叶子行的前置列行为与放开前一致：可编辑、可落库（不允许因本次改动回退）。
    @Test func leafPredecessorEditingIsUnchanged() throws {
        let fixture = try makeFixture()

        #expect(OutlineTextCellEditing.isEditable(column: .predecessors, isAggregate: false))
        #expect(OutlineDateEditing.isEnabled(column: .start, row: try row(fixture.store, id: fixture.childID)))

        fixture.store.dispatch(.setPredecessors(fixture.childID, "1"))

        #expect(try task(fixture.store, id: fixture.childID).dependencies.count == 1)
    }
}
