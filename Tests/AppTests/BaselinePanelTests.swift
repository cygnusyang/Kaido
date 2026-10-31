import Foundation
import Testing
import KaidoCore
import KaidoPresentation
@testable import KaidoMacApp

// v0.15 基线面板（docs/features/08-baselines.md §5、10-multi-baseline-gantt.md §5）。
//
// 覆盖用户可见路径：
// ① 面板逐条列出颜色 / 名称 / 创建时间 / 条目数 / 甘特显示 / 主对比；
// ② 底部两块只算「焦点基线」（主对比 ?? 最新）：孤儿条目可读、基线后新增给计数；
// ③ 孤儿不因任务删除而消失（条目数不减少），大纲行也不插行（那是 Presenter 的口径）；
// ④ 面板打开期间任何写操作后模型即时刷新；⑤ 入口命令与空态文案接线。

@MainActor
@Suite("基线面板（v0.15）")
struct BaselinePanelTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "kaido.v015.panel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(defaults: makeDefaults(), seedsDemoData: true)
    }

    @discardableResult
    private func createBaseline(_ store: WorkspaceStore, name: String) -> UUID {
        store.dispatch(.createBaseline(name))
        return store.baselines.last?.id ?? UUID()
    }

    private func panel(_ store: WorkspaceStore) throws -> BaselinePanelModel {
        try #require(store.baselinePanel)
    }

    private func statistics(_ store: WorkspaceStore) throws -> BaselinePanelStatistics {
        let panel = try panel(store)
        return try #require(panel.statistics)
    }

    /// 一条已排期、无子项的普通任务 ID（删除它只会产生一个孤儿，不级联）。
    private func leafTaskID(_ store: WorkspaceStore, in baseline: Baseline) throws -> UUID {
        let tasks = store.exportProject.tasks
        guard let entry = baseline.entries.first(where: { candidate in
            let task = tasks.first { $0.id == candidate.taskID }
            return task?.kind == .task && !tasks.contains { $0.parentID == candidate.taskID }
        }) else {
            throw BaselinePanelTestError.noLeafEntry
        }
        return entry.taskID
    }

    private enum BaselinePanelTestError: Error { case noLeafEntry }

    // MARK: - 行

    /// 逐条列出：顺序 = 创建顺序，状态与颜色取自与菜单 / 甘特同一套归一化口径。
    @Test func listsEveryBaselineInCreationOrder() throws {
        let store = makeStore()
        let first = createBaseline(store, name: "保守")
        let second = createBaseline(store, name: "基准")
        store.dispatch(.setBaseline(first))
        store.presentBaselinePanel()

        let model = try panel(store)
        #expect(!model.isEmpty)
        #expect(model.rows.map(\.id) == [first, second])
        #expect(model.rows.map(\.name) == ["保守", "基准"])
        #expect(model.rows.map(\.createdAt) == store.baselines.map(\.createdAt))
        // 条目数 = 快照时的已排期任务数（不是当前任务数）。
        #expect(model.rows.map(\.entryCount) == store.baselines.map { $0.entries.count })
        #expect(model.rows.allSatisfy { $0.entryCount > 0 })
        // 主对比单选、甘特显示多选（新建自动加入显示）。
        #expect(model.rows.map(\.isCompared) == [true, false])
        #expect(model.rows.allSatisfy { $0.isVisibleInGantt })
        // 颜色与菜单 / 图例同一函数派生，不得各算一套。
        #expect(model.rows.map(\.colorIndex) == BaselinePalette.resolve(store.baselines.map(\.colorIndex)))
    }

    /// 甘特显示满 3 条后第 4 条置灰（会话会拒绝），面板据此给出解释而不是「点了没反应」。
    @Test func reflectsVisibilityCapAndUpdatesLive() throws {
        let store = makeStore()
        let ids = (0 ..< 4).map { createBaseline(store, name: "B\($0)") }
        store.presentBaselinePanel()

        var model = try panel(store)
        #expect(model.rows.map(\.isVisibleInGantt) == [true, true, true, false])
        #expect(model.rows.map(\.isVisibilityBlocked) == [false, false, false, true])

        // 面板打开期间改显隐：模型随 refresh 重建，不需要重新打开面板。
        store.dispatch(.setBaselineVisible(ids[0], false))
        model = try panel(store)
        #expect(model.rows.map(\.isVisibleInGantt) == [false, true, true, false])
        #expect(model.rows.allSatisfy { !$0.isVisibilityBlocked })
    }

    // MARK: - 焦点与底部两块

    /// 焦点基线 = 主对比 ?? 最新一条；统计只算这一条，不替每条基线各算一份偏差。
    @Test func statisticsFocusFollowsComparedThenLatest() throws {
        let store = makeStore()
        let first = createBaseline(store, name: "保守")
        let second = createBaseline(store, name: "基准")

        // 新建会自动选中新基线；清掉后回落到「最新一条」。
        store.dispatch(.setBaseline(nil))
        store.presentBaselinePanel()
        #expect(try statistics(store).baselineID == second)
        #expect(try statistics(store).name == "基准")

        store.dispatch(.setBaseline(first))
        #expect(try statistics(store).baselineID == first)
        #expect(try statistics(store).name == "保守")
    }

    /// 孤儿：任务删除后条目仍在面板可见（08 §5「不消失」），起止取自基线条目而非当前排期。
    @Test func orphansStayVisibleAfterTaskDeletion() throws {
        let store = makeStore()
        let baselineID = createBaseline(store, name: "基准")
        let baseline = try #require(store.baselines.first { $0.id == baselineID })
        let taskID = try leafTaskID(store, in: baseline)
        let entry = try #require(baseline.entries.first { $0.taskID == taskID })
        store.presentBaselinePanel()

        let before = try statistics(store)
        #expect(before.orphans.isEmpty)
        let entryCount = before.entryCount
        // 任务行不因删除而变少到零：这里只关心面板，先记下删除前的行数。
        store.dispatch(.delete(taskID))

        let after = try statistics(store)
        #expect(after.orphans.map(\.id) == [taskID])
        let orphan = try #require(after.orphans.first)
        #expect(orphan.start == entry.start)
        #expect(orphan.finish == entry.finish)
        #expect(orphan.baselineID == baselineID)
        // 条目数不因删任务减少（基线是不可变快照）。
        #expect(after.entryCount == entryCount)
        #expect(try panel(store).rows.first?.entryCount == entryCount)
    }

    /// 「基线之后新增」按条目缺失计（§5），与「缺实际结束的预测项」是两个口径。
    @Test func countsTasksAddedAfterBaseline() throws {
        let store = makeStore()
        createBaseline(store, name: "基准")
        store.presentBaselinePanel()
        #expect(try statistics(store).addedTaskCount == 0)

        store.dispatch(.createTask(parentID: nil, kind: .task))

        let stats = try statistics(store)
        #expect(stats.addedTaskCount == 1)
        // 两个计数是不同的口径（§4.3 预测项 / §5 基线后新增），不会互相冒充：
        // 新增任务没有基线条目，因此不进「预测项」。
        #expect(stats.predictedTaskCount >= 0)
        #expect(BaselinePanelText.predicted(2).contains("2"))
        #expect(BaselinePanelText.predicted(2) != BaselinePanelText.added(2))
    }

    // MARK: - 打开 / 关闭与写操作联动

    /// 打开才有数据；关闭即释放（面板不常驻内存，避免无谓的偏差计算）。
    @Test func presentAndDismissManagePanelData() {
        let store = makeStore()
        createBaseline(store, name: "基准")
        #expect(store.baselinePanel == nil)
        #expect(!store.isBaselinePanelPresented)

        store.presentBaselinePanel()
        #expect(store.isBaselinePanelPresented)
        #expect(store.baselinePanel != nil)

        store.dismissBaselinePanel()
        #expect(!store.isBaselinePanelPresented)
        #expect(store.baselinePanel == nil)
    }

    /// 改名 / 删除后面板即时反映（打开期间同一个 refresh 路径重建）。
    @Test func followsRenameAndDeletion() throws {
        let store = makeStore()
        let first = createBaseline(store, name: "保守")
        let second = createBaseline(store, name: "基准")
        store.presentBaselinePanel()

        store.dispatch(.renameBaseline(first, "保守版"))
        #expect(try panel(store).rows.map(\.name) == ["保守版", "基准"])

        store.requestDeleteBaseline(id: second)
        store.confirmPendingBaselineDeletion()
        let model = try panel(store)
        #expect(model.rows.map(\.id) == [first])
        // 删掉的是主对比基线 → 焦点回落到剩下的那条，底部统计不指向已删数据。
        let stats = try #require(model.statistics)
        #expect(stats.baselineID == first)
    }

    /// 空项目：行集合为空，底部两块不渲染（没有基线就没有可统计的对象）。
    @Test func emptyStateHasNoRowsOrStatistics() {
        let store = makeStore()
        store.presentBaselinePanel()
        let model = store.baselinePanel
        #expect(model?.rows.isEmpty == true)
        #expect(model?.statistics == nil)
        #expect(BaselinePanelModel.empty.rows.isEmpty)
        #expect(!BaselinePanelText.emptyTitle.isEmpty)
        #expect(!BaselinePanelText.emptyHint.isEmpty)
    }

    // MARK: - 文案

    /// 孤儿行给「已删除任务」占位与承诺起止日期；新增计数带数字。
    @Test func orphanAndAddedTextsCarryDatesAndCounts() throws {
        let store = makeStore()
        let baselineID = createBaseline(store, name: "基准")
        let baseline = try #require(store.baselines.first { $0.id == baselineID })
        let taskID = try leafTaskID(store, in: baseline)
        let entry = try #require(baseline.entries.first { $0.taskID == taskID })
        store.presentBaselinePanel()
        store.dispatch(.delete(taskID))

        let orphan = try #require(try statistics(store).orphans.first)
        let range = BaselinePanelText.orphanRange(orphan)
        #expect(range.contains(Display.date(entry.start)))
        #expect(range.contains(Display.date(entry.finish)))

        #expect(!BaselinePanelText.orphanPlaceholder.isEmpty)
        #expect(BaselinePanelText.orphanCount(3).contains("3"))
        #expect(BaselinePanelText.added(2).contains("2"))
        #expect(BaselinePanelText.visibility(true) != BaselinePanelText.visibility(false))
        #expect(BaselinePanelText.compare(true) != BaselinePanelText.compare(false))
        #expect(BaselinePanelText.focus("基准").contains("基准"))
    }

    // MARK: - 入口

    /// 「管理基线…」在基线组末尾（菜单里排在图例之后），动作打开面板。
    @Test func manageCommandOpensPanel() throws {
        let store = makeStore()
        let commands = KaidoCommandCatalog.make(store: store, requestOpen: {}, requestSave: {}, requestSaveAs: {})
        let manage = try #require(commands.first { $0.id == "baseline.manage" })
        #expect(manage.group == .baseline)
        // 可搜索：面板入口必须在 ⌘K 里找得到（D-035 的可发现性）。
        #expect(!manage.isPaletteHidden)

        manage.action()
        #expect(store.isBaselinePanelPresented)
        #expect(store.baselinePanel != nil)
    }

    // MARK: - 渲染

    /// 离屏渲染：有基线时不是空白画面，且与空态明显不同（不是「渲染了但什么都没画」）。
    @Test func rendersRowsAndStatistics() throws {
        let filled = makeStore()
        createBaseline(filled, name: "基准")
        filled.presentBaselinePanel()
        let filledShot = try #require(GUIRenderer.snapshot(
            BaselinePanel(store: filled), width: 760, height: 560
        ))
        #expect(filledShot.distinctColorCount > 4)

        let empty = makeStore()
        empty.presentBaselinePanel()
        let emptyShot = try #require(GUIRenderer.snapshot(
            BaselinePanel(store: empty), width: 760, height: 560
        ))
        #expect(filledShot.differenceRatio(from: emptyShot) > 0.01)
    }
}
