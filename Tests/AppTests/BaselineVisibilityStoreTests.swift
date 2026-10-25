import Foundation
import Testing
import KairoCore
import KairoPresentation
@testable import KairoMacApp

// v0.14 多基线的应用层接线（docs/features/10-multi-baseline-gantt.md §6、§4）。
//
// 覆盖用户可见路径：① 显隐是纯视图偏好——不进撤销栈、不置脏、跨实例保留；
// ② 同屏上限 3 条，第 4 条被拒且不改动已有显示；③ 改色写模型、进撤销栈、可一步撤销；
// ④ 删除基线后不再占显示名额。

@MainActor
@Suite("基线显隐与配色（v0.14）")
struct BaselineVisibilityStoreTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "kairo.v014.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeStore(defaults: UserDefaults) -> WorkspaceStore {
        WorkspaceStore(defaults: defaults, seedsDemoData: true)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kairo-v014-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 建一条基线并落盘（改色用例先要一个干净态，才能断言「改色置脏」）。
    private func createBaseline(_ store: WorkspaceStore, name: String = "基准") -> UUID {
        store.dispatch(.createBaseline(name))
        return store.baselines.last?.id ?? UUID()
    }

    // MARK: - 显隐：纯视图偏好

    /// 勾上一条：快照出现基线条；不进撤销栈、不置脏。
    @Test func showingBaselineDrawsItWithoutTouchingHistoryOrDirtyFlag() throws {
        let store = makeStore(defaults: makeDefaults())
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("plan.kairo")
        store.save(to: url)
        #expect(!store.hasUnsavedChanges)

        store.dispatch(.createBaseline(nil))
        let id = try #require(store.baselines.first?.id)
        // 先退回未显示：新建会自动加入显示（§6），第 4 条才需要显式勾选。
        store.dispatch(.setBaselineVisible(id, false))
        store.save(to: url)
        let depth = store.undoDepthForTesting
        #expect(!store.hasUnsavedChanges)

        store.dispatch(.setBaselineVisible(id, true))

        #expect(store.undoDepthForTesting == depth)
        #expect(!store.hasUnsavedChanges)
        #expect(store.viewState.visibleBaselineIDs == [id])
        #expect(!store.snapshot.gantt.visibleBaselineIDs.isEmpty)
        #expect(!store.snapshot.gantt.baselineBars.isEmpty)
    }

    /// 取消勾选：条消失，几何回到 N=0。
    @Test func hidingBaselineRestoresLegacyGeometry() throws {
        let store = makeStore(defaults: makeDefaults())
        let id = createBaseline(store)
        store.dispatch(.setBaselineVisible(id, true))
        #expect(!store.snapshot.gantt.baselineBars.isEmpty)

        store.dispatch(.setBaselineVisible(id, false))
        #expect(store.viewState.visibleBaselineIDs.isEmpty)
        #expect(store.snapshot.gantt.baselineBars.isEmpty)
        #expect(store.snapshot.gantt.baselineLanes == BaselineLanes.layout(visibleCount: 0))
    }

    /// 跨实例保留：同一份 UserDefaults 上的新 store 读回同一组显示 ID。
    @Test func visibilityPreferenceSurvivesNewStore() throws {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)
        let id = createBaseline(store)
        store.dispatch(.setBaselineVisible(id, true))

        let reopened = makeStore(defaults: defaults)
        #expect(reopened.viewState.visibleBaselineIDs == [id])
    }

    /// 打开同一个文件的新实例：基线 ID 一致，显示集合直接生效（图上真的画出条）。
    @Test func visibilityAppliesAfterReopeningProject() throws {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("plan.kairo")
        store.dispatch(.createBaseline(nil))
        let id = try #require(store.baselines.first?.id)
        store.dispatch(.setBaselineVisible(id, true))
        store.save(to: url)
        #expect(store.alertMessage == nil)

        let reopened = makeStore(defaults: defaults)
        #expect(reopened.open(url: url))
        #expect(reopened.baselines.map(\.id) == [id])
        #expect(!reopened.snapshot.gantt.baselineBars.isEmpty)
    }

    /// 上限 3 条：第 4 条被拒，已有三条一条不少（不替换、不插队）。
    @Test func fourthVisibleBaselineIsRejected() throws {
        let store = makeStore(defaults: makeDefaults())
        var ids: [UUID] = []
        for index in 0..<4 {
            ids.append(createBaseline(store, name: "基线 " + String(index)))
            // §6：未满 3 条时新建自动加入显示；已满 3 条不替换、不插队。
            #expect(store.viewState.visibleBaselineIDs.count == min(index + 1, BaselineLanes.maxVisible))
        }
        #expect(store.viewState.visibleBaselineIDs == Set(ids.prefix(3)))
        #expect(!store.viewState.visibleBaselineIDs.contains(ids[3]))

        store.dispatch(.setBaselineVisible(ids[3], true))
        #expect(store.viewState.visibleBaselineIDs.count == BaselineLanes.maxVisible)
        #expect(!store.viewState.visibleBaselineIDs.contains(ids[3]))
        #expect(store.snapshot.gantt.visibleBaselineIDs.count == BaselineLanes.maxVisible)
    }

    /// 悬挂 ID（撤销回退到创建之前）：不报错、不占轨道。
    @Test func unknownBaselineVisibilityIsIgnored() throws {
        let store = makeStore(defaults: makeDefaults())
        let depth = store.undoDepthForTesting
        store.dispatch(.setBaselineVisible(UUID(), true))
        #expect(store.viewState.visibleBaselineIDs.isEmpty)
        #expect(store.undoDepthForTesting == depth)
        #expect(store.alertMessage == nil)
    }

    // MARK: - 配色：写模型 + 撤销

    /// 改色：写入模型、置脏、一个撤销步；撤销后回到原色。
    @Test func changingColorIsOneUndoableStep() throws {
        let store = makeStore(defaults: makeDefaults())
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("plan.kairo")
        let id = createBaseline(store)
        store.dispatch(.setBaselineVisible(id, true))
        store.save(to: url)
        let before = try #require(store.baselines.first?.colorIndex)
        #expect(before != 5)
        #expect(!store.hasUnsavedChanges)
        let depth = store.undoDepthForTesting

        store.dispatch(.setBaselineColor(id, 5))

        #expect(store.baselines.first?.colorIndex == 5)
        #expect(store.hasUnsavedChanges)
        #expect(store.undoDepthForTesting == depth + 1)
        // 图上真的换了色：图例索引取自基线本身。
        #expect(store.snapshot.gantt.baselineLegend.first?.colorIndex == 5)

        store.dispatch(.undo)
        #expect(store.baselines.first?.colorIndex == before)
        #expect(store.snapshot.gantt.baselineLegend.first?.colorIndex == before)
    }

    /// 越界索引由会话拒绝：不改数据、不置脏、不产生撤销点。
    @Test func invalidColorIndexIsRejected() throws {
        let store = makeStore(defaults: makeDefaults())
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("plan.kairo")
        let id = createBaseline(store)
        store.save(to: url)
        let before = try #require(store.baselines.first?.colorIndex)
        let depth = store.undoDepthForTesting

        store.dispatch(.setBaselineColor(id, BaselinePalette.count))

        #expect(store.baselines.first?.colorIndex == before)
        #expect(!store.hasUnsavedChanges)
        #expect(store.undoDepthForTesting == depth)
        #expect(store.alertMessage != nil)
    }

    // MARK: - 删除基线

    /// 删掉的基线不再占显示名额（展示卫生，不产生撤销点）。
    @Test func deletingBaselineRemovesItFromVisibility() throws {
        let store = makeStore(defaults: makeDefaults())
        let id = createBaseline(store)
        store.dispatch(.setBaselineVisible(id, true))
        #expect(store.viewState.visibleBaselineIDs == [id])

        store.dispatch(.deleteBaseline(id))
        store.confirmPendingBaselineDeletion()

        #expect(store.baselines.isEmpty)
        #expect(store.viewState.visibleBaselineIDs.isEmpty)
        #expect(store.snapshot.gantt.baselineBars.isEmpty)
    }
}
