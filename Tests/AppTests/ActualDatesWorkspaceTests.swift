import Foundation
import Testing
import ZenoCore
import ZenoCommands
import ZenoPresentation
@testable import ZenoMacApp

// F-0719 应用层接线：实际开始 / 实际结束（docs/features/07-actual-dates.md §4、§5）。
//
// 覆盖四条用户可见路径：① 大纲两个实际列默认隐藏、打开后紧随结束列；
// ② 检查器写入 → 快照刷新 → 大纲同步（含清空回 nil）；③ 群组行不表达实际；
// ④ 顺序校验失败不写库、不产生撤销点。列策略本身在 ZenoPresentationTests 里锁定。

@MainActor
@Suite("F-0719 实际时间动作与展示")
struct ActualDatesWorkspaceTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "zeno.f0719.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeStore(defaults: UserDefaults? = nil) -> WorkspaceStore {
        WorkspaceStore(defaults: defaults ?? makeDefaults(), seedsDemoData: true)
    }

    private func makeDay(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = Calendar.current.date(from: components) else {
            fatalError("测试日期构造失败：\(year)-\(month)-\(day)")
        }
        return date
    }

    private func task(_ store: WorkspaceStore, _ id: UUID) throws -> TaskItem {
        try #require(store.exportProject.tasks.first { $0.id == id })
    }

    private func row(_ store: WorkspaceStore, _ id: UUID) throws -> PlanRow {
        try #require(store.snapshot.outline.rows.first { $0.id == id })
    }

    private func taskInspector(_ store: WorkspaceStore) throws -> TaskInspector {
        guard case .task(let inspector) = store.snapshot.inspector.content else {
            throw TestFailure("检查器未处于任务页")
        }
        return inspector
    }

    private func plainTask(_ store: WorkspaceStore) throws -> TaskItem {
        try #require(store.exportProject.tasks.first {
            $0.kind != .group && $0.actualStart == nil && $0.completedAt == nil
        })
    }

    /// 测试内部的失败类型：让正常路径断言失败时给出可读原因。
    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: - 大纲列

    /// 默认隐藏：新会话的快照里没有实际列（判据 11 前半）。
    @Test func optionalColumnsAreHiddenByDefault() throws {
        let store = makeStore()
        #expect(store.viewState.visibleOptionalColumns.isEmpty)
        #expect(!store.snapshot.outline.columns.contains(.actualStart))
        #expect(!store.snapshot.outline.columns.contains(.actualFinish))
    }

    /// 打开后紧随结束列，并与视图列集合同源（视图与 Presenter 都调 \(visibleColumns)）。
    @Test func togglingOptionalColumnShowsItAfterFinish() throws {
        let store = makeStore()
        store.dispatch(.toggleOutlineColumn(.actualStart))
        store.dispatch(.toggleOutlineColumn(.actualFinish))

        #expect(store.viewState.visibleOptionalColumns == ["actualStart", "actualFinish"])
        let columns = store.snapshot.outline.columns
        #expect(columns.contains(.actualStart))
        #expect(columns.contains(.actualFinish))
        if let finishIndex = columns.firstIndex(of: .finish) {
            #expect(columns[finishIndex + 1] == .actualStart)
            #expect(columns[finishIndex + 2] == .actualFinish)
        } else {
            #expect(columns.last == .actualFinish, "结束列降级时实际列追加到末尾")
        }
    }

    /// 再点一次即隐藏：可选列回到隐藏态，不残留隐藏集合（两条偏好互不污染）。
    @Test func togglingOptionalColumnAgainHidesIt() throws {
        let store = makeStore()
        store.dispatch(.toggleOutlineColumn(.actualStart))
        store.dispatch(.toggleOutlineColumn(.actualStart))

        #expect(store.viewState.visibleOptionalColumns.isEmpty)
        #expect(store.viewState.hiddenOutlineColumns.isEmpty)
        #expect(!store.snapshot.outline.columns.contains(.actualStart))
    }

    /// 无值占位：大纲单元格文案取 \(Display.date)，nil 一律是「—」。
    @Test func missingActualDateRendersPlaceholder() throws {
        let store = makeStore()
        let id = try plainTask(store).id
        let item = try row(store, id)
        #expect(item.actualStart == nil)
        #expect(item.actualFinish == nil)
        #expect(Display.date(item.actualStart) == Display.placeholder)
        #expect(Display.placeholder == "—")
        #expect(Display.date(makeDay(2026, 3, 4)) != Display.placeholder)
    }

    // MARK: - 写入与刷新

    /// 写实际开始：模型与快照同步；pending 任务顺带开工（设计 §4）。
    @Test func setActualStartUpdatesModelAndSnapshot() throws {
        let store = makeStore()
        let original = try plainTask(store)
        let day = makeDay(2025, 11, 3)

        store.dispatch(.setActualStart(original.id, day))

        let updated = try task(store, original.id)
        #expect(updated.actualStart == day)
        #expect(updated.status == .inProgress, "有实际开始即已开工")
        #expect(try row(store, original.id).actualStart == day)
    }

    /// 清空实际开始：模型与快照都回 nil（nil = 清除，设计 §4）。
    @Test func clearingActualStartWritesNilBack() throws {
        let store = makeStore()
        let original = try plainTask(store)
        store.dispatch(.setActualStart(original.id, makeDay(2025, 11, 3)))

        store.dispatch(.setActualStart(original.id, nil))

        #expect(try task(store, original.id).actualStart == nil)
        #expect(try row(store, original.id).actualStart == nil)
    }

    /// 写实际结束：置 done + progress 1，检查器 completedAt 与大纲实际结束同步。
    @Test func setActualFinishCompletesTaskAndUpdatesInspector() throws {
        let store = makeStore()
        let original = try plainTask(store)
        let day = makeDay(2025, 11, 7)

        store.dispatch(.select(original.id))
        store.dispatch(.setActualFinish(original.id, day))

        let updated = try task(store, original.id)
        #expect(updated.completedAt == day)
        #expect(updated.status == .done)
        #expect(updated.progress == 1)
        #expect(try row(store, original.id).actualFinish == day)
        #expect(try taskInspector(store).completedAt == day, "实际结束复用 completedAt")
    }

    /// 清空实际结束不回退状态：只清时间戳（判据 8）。
    @Test func clearingActualFinishKeepsDoneStatus() throws {
        let store = makeStore()
        let original = try plainTask(store)
        store.dispatch(.setActualFinish(original.id, makeDay(2025, 11, 7)))

        store.dispatch(.setActualFinish(original.id, nil))

        let updated = try task(store, original.id)
        #expect(updated.completedAt == nil)
        #expect(updated.status == .done)
        #expect(try row(store, original.id).actualFinish == nil)
    }

    /// 每次编辑各占一步撤销，且 \(mergeKey) 不跨字段合并。
    @Test func eachActualEditIsOneUndoStep() throws {
        let store = makeStore()
        let original = try plainTask(store)
        let depth = store.undoDepthForTesting

        store.dispatch(.setActualStart(original.id, makeDay(2025, 11, 3)))
        #expect(store.undoDepthForTesting == depth + 1)

        store.dispatch(.setActualFinish(original.id, makeDay(2025, 11, 7)))
        #expect(store.undoDepthForTesting == depth + 2)
    }

    /// 顺序非法（结束早于开始）：提示原因、任务不被修改、不产生撤销点（判据 9）。
    @Test func outOfOrderActualDatesAreRejectedWithoutUndoPoint() throws {
        let store = makeStore()
        let original = try plainTask(store)
        let start = makeDay(2025, 11, 10)
        store.dispatch(.setActualStart(original.id, start))
        let depth = store.undoDepthForTesting
        let before = try task(store, original.id)

        store.dispatch(.setActualFinish(original.id, makeDay(2025, 11, 1)))

        #expect(store.alertMessage != nil, "失败必须给出可操作提示，不静默丢弃")
        #expect(store.undoDepthForTesting == depth, "失败请求不得留下空撤销步")
        let after = try task(store, original.id)
        #expect(after.completedAt == before.completedAt)
        #expect(after.status == before.status)
    }

    // MARK: - 群组

    /// 群组行不表达实际：父行与检查器都为空，子任务各自保留（判据 12）。
    ///
    /// 命令层不拦截群组写入（与 startDate 同口径），因此这里**主动把脏数据写进群组**，
    /// 再断言呈现层抑制——否则「命令层没写」也能让断言恒真，发现不了抑制漏写。
    @Test func groupRowNeverCarriesActualDates() throws {
        let store = makeStore()
        store.dispatch(.createTask(parentID: nil, kind: .group))
        let groupID = try #require(store.viewState.selectedTaskID)
        store.dispatch(.createTask(parentID: groupID, kind: .task))
        let childID = try #require(store.viewState.selectedTaskID)
        store.dispatch(.setActualFinish(childID, makeDay(2025, 11, 7)))

        let groupDay = makeDay(2025, 11, 4)
        store.dispatch(.setActualStart(groupID, groupDay))
        store.dispatch(.setActualFinish(groupID, groupDay))
        // 前置确认：脏数据确实落进模型（抑制只能靠呈现层，不靠写入口）。
        let dirtyGroup = try task(store, groupID)
        #expect(dirtyGroup.actualStart == groupDay)
        #expect(dirtyGroup.completedAt == groupDay)

        let groupRow = try row(store, groupID)
        #expect(groupRow.isAggregate)
        #expect(groupRow.actualStart == nil)
        #expect(groupRow.actualFinish == nil)
        #expect(try row(store, childID).actualFinish != nil, "子任务的实际结束不受群组影响")

        store.dispatch(.select(groupID))
        let inspector = try taskInspector(store)
        #expect(inspector.isAggregate)
        #expect(inspector.actualStart == nil)
        #expect(inspector.completedAt == nil)
    }

    // MARK: - 偏好与命令入口

    /// 可选列偏好持久化：换会话（同一偏好域）后仍开着。
    @Test func optionalColumnPreferencePersists() throws {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)
        store.dispatch(.toggleOutlineColumn(.actualFinish))

        let reopened = makeStore(defaults: defaults)
        #expect(reopened.viewState.visibleOptionalColumns == ["actualFinish"])
        #expect(reopened.snapshot.outline.columns.contains(.actualFinish))
    }

    /// 命令面板与表头菜单同源：两个实际列各有显隐命令。
    @Test func commandCatalogIncludesActualColumnToggles() throws {
        let store = makeStore()
        let catalog = ZenoCommandCatalog.make(
            store: store, requestOpen: {}, requestSave: {}, requestSaveAs: {}
        )
        #expect(catalog.contains { $0.id == "view.outlineColumn.actualStart" })
        #expect(catalog.contains { $0.id == "view.outlineColumn.actualFinish" })
    }
}
