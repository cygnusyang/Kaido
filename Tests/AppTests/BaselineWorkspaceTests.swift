import Foundation
import Testing
import ZenoCommands
import ZenoCore
import ZenoPresentation
@testable import ZenoMacApp

// v0.13 基线：应用层接线（docs/features/08-baselines.md §5、§8、§11）。
//
// 覆盖用户可见路径：① 四列默认隐藏且未选基线时整体隐藏；② 选中/切换基线驱动列与检查器；
// ③ 删除必须二次确认；④ 切换基线只改视图状态（不进撤销栈、不置脏）。
// 列策略与偏差口径本身在 ZenoPresentationTests 锁定，这里只验接线。

@MainActor
@Suite("基线工作台（v0.13）")
struct BaselineWorkspaceTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "zeno.v013.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeStore(defaults: UserDefaults? = nil) -> WorkspaceStore {
        WorkspaceStore(defaults: defaults ?? makeDefaults(), seedsDemoData: true)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zeno-baseline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func firstScheduledRow(_ store: WorkspaceStore) throws -> PlanRow {
        try #require(store.snapshot.outline.rows.first { !$0.isAggregate && $0.hasSchedule })
    }

    private func row(_ store: WorkspaceStore, _ id: UUID) throws -> PlanRow {
        try #require(store.snapshot.outline.rows.first { $0.id == id })
    }

    /// 把基线四列全部打开（列显隐是纯视图偏好）。
    private func showBaselineColumns(_ store: WorkspaceStore) {
        for column in OutlineColumnPreferences.baseline {
            store.dispatch(.toggleOutlineColumn(column))
        }
    }

    // MARK: - 列显隐与选择

    /// 默认隐藏；勾选后仍不出现（未选基线）；选中基线后才出现（§5「未选时整体隐藏」）。
    @Test func baselineColumnsAppearOnlyAfterSelectingBaseline() throws {
        let store = makeStore()
        for column in OutlineColumnPreferences.baseline {
            #expect(!store.snapshot.outline.columns.contains(column))
        }

        showBaselineColumns(store)
        #expect(store.selectedBaseline == nil)
        for column in OutlineColumnPreferences.baseline {
            #expect(!store.snapshot.outline.columns.contains(column))
        }

        store.dispatch(.createBaseline(nil))
        #expect(store.selectedBaseline != nil)
        for column in OutlineColumnPreferences.baseline {
            #expect(store.snapshot.outline.columns.contains(column))
        }
    }

    /// 新建基线：进撤销栈、置脏、自动选中新基线（点「新建」就是拿它做对比）。
    @Test func createBaselineSelectsNewBaseline() throws {
        let store = makeStore()
        let depth = store.undoDepthForTesting
        store.dispatch(.createBaseline(nil))

        #expect(store.baselines.count == 1)
        let created = try #require(store.baselines.first)
        #expect(store.viewState.selectedBaselineID == created.id)
        #expect(store.undoDepthForTesting == depth + 1)
        #expect(store.hasUnsavedChanges)
        // 条目数 = 已排期任务数（未排期任务不入条目）。
        let scheduled = store.snapshot.outline.rows.filter(\.hasSchedule).count
        #expect(created.entries.count >= scheduled)
        #expect(!created.entries.isEmpty)
    }

    /// 改名只改名字，条目不变。
    @Test func renameBaselineKeepsEntries() throws {
        let store = makeStore()
        store.dispatch(.createBaseline(nil))
        let created = try #require(store.baselines.first)

        store.dispatch(.renameBaseline(created.id, "冻结版"))
        let renamed = try #require(store.baselines.first)
        #expect(renamed.name == "冻结版")
        #expect(renamed.entries == created.entries)
        #expect(renamed.createdAt == created.createdAt)
    }

    // MARK: - 切换基线是纯视图状态

    /// 切换基线：不产生撤销点、不置脏（判据 §9-10）。
    @Test func setBaselineIsViewStateOnly() throws {
        let store = makeStore()
        let directory = try makeTemporaryDirectory()
        store.dispatch(.createBaseline(nil))
        store.dispatch(.createBaseline("第二个"))
        // 先落盘清脏，才能证明切换基线不会重新置脏。
        store.save(to: directory.appendingPathComponent("baseline.zeno"))
        #expect(store.saveState == .saved)
        #expect(!store.hasUnsavedChanges)

        let firstID = try #require(store.baselines.first?.id)
        let depth = store.undoDepthForTesting
        store.dispatch(.setBaseline(firstID))

        #expect(store.viewState.selectedBaselineID == firstID)
        #expect(store.undoDepthForTesting == depth, "切换基线不进撤销栈")
        #expect(!store.hasUnsavedChanges, "切换基线不置脏")
    }

    /// 撤销不会把选择改回去：选择不在撤销栈里。
    @Test func undoKeepsSelectedBaseline() throws {
        let store = makeStore()
        store.dispatch(.createBaseline(nil))
        let firstID = try #require(store.baselines.first?.id)
        store.dispatch(.createBaseline(nil))
        store.dispatch(.setBaseline(firstID))

        store.dispatch(.undo)
        #expect(store.baselines.count == 1)
        #expect(store.viewState.selectedBaselineID == firstID)
    }

    /// 指向不存在的基线按「不比较」落库，不留悬挂 ID。
    @Test func setUnknownBaselineClearsSelection() throws {
        let store = makeStore()
        store.dispatch(.createBaseline(nil))
        #expect(store.selectedBaseline != nil)
        store.dispatch(.setBaseline(UUID()))
        #expect(store.viewState.selectedBaselineID == nil)
        #expect(!store.hasSelectedBaseline)
    }

    // MARK: - 切换基线驱动读数

    /// 切换基线后同一行的偏差整体变化：列内容确实跟着选中项走。
    @Test func switchingBaselineUpdatesRowVariance() throws {
        let store = makeStore()
        showBaselineColumns(store)
        store.dispatch(.createBaseline(nil))
        let baselineA = try #require(store.baselines.first)

        let target = try firstScheduledRow(store)
        let start = try #require(target.scheduledStart)
        let later = Calendar.current.date(byAdding: .day, value: 3, to: start) ?? start
        store.dispatch(.setTaskStart(target.id, later))
        #expect(try row(store, target.id).planFinishVariance == 3)

        // 第二份基线记录「当前已晚 3 天」的计划 → 对它而言偏差归零。
        store.dispatch(.createBaseline(nil))
        #expect(store.baselines.count == 2)
        #expect(try row(store, target.id).planFinishVariance == 0)

        store.dispatch(.setBaseline(baselineA.id))
        #expect(try row(store, target.id).planFinishVariance == 3)
    }

    /// 偏差显示口径：晚为正、早为负；无条目为占位符而非 0。
    @Test func varianceSignsAndMissingEntries() throws {
        let store = makeStore()
        showBaselineColumns(store)
        store.dispatch(.createBaseline(nil))
        let baseline = try #require(store.baselines.first)

        // 先把「晚 2 天」当作基线，再改回原日期 → 相对基线提前 2 天（负数）。
        // 反过来做会被排期锚点夹到项目开始日，测不到负号。
        let target = try firstScheduledRow(store)
        let start = try #require(target.scheduledStart)
        let later = Calendar.current.date(byAdding: .day, value: 2, to: start) ?? start
        store.dispatch(.setTaskStart(target.id, later))
        store.dispatch(.createBaseline(nil))
        store.dispatch(.setTaskStart(target.id, start))
        let movedRow = try self.row(store, target.id)
        #expect(movedRow.planFinishVariance == -2)
        #expect(Display.varianceDays(movedRow.planFinishVariance) == "-2")

        // 基线之后新增的任务：四列占位符，0 只属于「准时」。
        store.dispatch(.createTask(parentID: nil, kind: .task))
        let added = try #require(store.exportProject.tasks.last)
        #expect(!baseline.entries.contains { $0.taskID == added.id })
        let addedRow = try row(store, added.id)
        #expect(!addedRow.hasBaseline)
        #expect(addedRow.baselineStart == nil)
        #expect(addedRow.planFinishVariance == nil)
        #expect(Display.varianceDays(addedRow.planFinishVariance) == Display.placeholder)
    }

    // MARK: - 检查器

    /// 检查器基线段：有条目才有段；计划偏差与实际偏差分开（未完成 → 实际为空）。
    @Test func inspectorShowsBaselineSectionOnlyForEntries() throws {
        let store = makeStore()
        store.dispatch(.createBaseline(nil))
        let baseline = try #require(store.baselines.first)
        let target = try firstScheduledRow(store)
        store.dispatch(.select(target.id))

        guard case .task(let inspector) = store.snapshot.inspector.content else {
            Issue.record("选中任务应显示任务检查器")
            return
        }
        let section = try #require(inspector.baseline)
        #expect(section.baselineID == baseline.id)
        #expect(section.name == baseline.name)
        #expect(section.planFinishVariance != nil)
        if inspector.completedAt == nil {
            #expect(section.actualFinishVariance == nil, "未完成不拿 plan 冒充 actual")
        }

        // 基线后新增：整段不出现。
        store.dispatch(.createTask(parentID: nil, kind: .task))
        let added = try #require(store.exportProject.tasks.last)
        store.dispatch(.select(added.id))
        guard case .task(let addedInspector) = store.snapshot.inspector.content else {
            Issue.record("选中任务应显示任务检查器")
            return
        }
        #expect(addedInspector.baseline == nil)
    }

    // MARK: - 删除二次确认（§11）

    /// 未确认时不删除：只登记待确认；取消后仍是原样。
    @Test func deleteBaselineRequiresConfirmation() throws {
        let store = makeStore()
        store.dispatch(.createBaseline(nil))
        let created = try #require(store.baselines.first)
        let depth = store.undoDepthForTesting

        store.dispatch(.deleteBaseline(created.id))
        #expect(store.pendingBaselineDeletion?.id == created.id)
        #expect(store.baselines.count == 1, "未确认不得删除")
        #expect(store.undoDepthForTesting == depth, "未确认不产生撤销点")

        store.cancelPendingBaselineDeletion()
        #expect(store.pendingBaselineDeletion == nil)
        #expect(store.baselines.count == 1)

        // 确认后才真正删；删的是当前对比基线时回落成「不比较」。
        store.dispatch(.deleteBaseline(created.id))
        store.confirmPendingBaselineDeletion()
        #expect(store.baselines.isEmpty)
        #expect(store.viewState.selectedBaselineID == nil)
        #expect(store.undoDepthForTesting == depth + 1)
    }

    // MARK: - 不写文件 / 不置脏（§3 app 行）

    /// 切换基线后：不置脏、文件 mtime 与字节均不变（选择只落在 UserDefaults）。
    @Test func switchingBaselineDoesNotTouchProjectFile() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("no-write.zeno")
        let store = makeStore()
        store.dispatch(.createBaseline(nil))
        store.dispatch(.createBaseline(nil))
        store.save(to: url)
        #expect(!store.hasUnsavedChanges)

        let before = try #require(Self.modificationDate(of: url))
        let beforeBytes = try Data(contentsOf: url)
        let firstID = try #require(store.baselines.first?.id)

        store.dispatch(.setBaseline(firstID))
        #expect(store.viewState.selectedBaselineID == firstID)
        #expect(!store.hasUnsavedChanges, "切换基线不置脏")
        #expect(Self.modificationDate(of: url) == before, "切换基线不得写文件")
        #expect(try Data(contentsOf: url) == beforeBytes)
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    // MARK: - 列头文案（§3 app 行：必须写「计划偏差」）

    /// 列头与悬停提示都显式区分「计划偏差」，不退化成笼统的「偏差」；
    /// 没有 .lproj 时英文兜底也必须带 Plan（否则裸跑看到的是模糊文案）。
    @Test func baselineColumnCopySaysPlanVariance() throws {
        let strings = try Self.catalogStrings()

        func value(_ key: String, _ language: String) throws -> String {
            let entry = try #require(strings[key] as? [String: Any])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            let unit = try #require(localizations[language] as? [String: Any])
            let stringUnit = try #require(unit["stringUnit"] as? [String: Any])
            return try #require(stringUnit["value"] as? String)
        }

        for key in ["column.start_variance", "column.finish_variance"] {
            #expect(try value(key, "zh-Hans").contains("计划"))
            #expect(try value(key, "en").contains("Plan"))
        }
        // 悬停提示讲清符号方向（§4.1：正 = 晚、负 = 提前）。
        #expect(try value("column.variance.help", "zh-Hans").contains("正数"))
        #expect(try value("column.variance.help", "en").contains("Positive"))
        // 视图兜底文案与 Catalog 同源。
        #expect(Display.outlineColumnTitle(.startVariance).contains("Plan"))
        #expect(Display.outlineColumnTitle(.finishVariance).contains("Plan"))
    }

    /// 无基线条目的单元格文本是占位符，不是 0（§3 app 行）。
    @Test func missingEntryCellsRenderPlaceholder() throws {
        let store = makeStore()
        store.dispatch(.createBaseline(nil))
        store.dispatch(.createTask(parentID: nil, kind: .task))
        let added = try #require(store.exportProject.tasks.last)
        let row = try self.row(store, added.id)

        #expect(!row.hasBaseline)
        #expect(Display.date(row.baselineStart) == Display.placeholder)
        #expect(Display.date(row.baselineFinish) == Display.placeholder)
        #expect(Display.varianceDays(row.planStartVariance) == Display.placeholder)
        #expect(Display.varianceDays(row.planFinishVariance) == Display.placeholder)
    }

    private static func catalogStrings() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
        let url = root.appendingPathComponent("Apps/macos/Resources/Localizable.xcstrings")
        let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        return try #require(object?["strings"] as? [String: Any])
    }

    // MARK: - 偏差缓存（§4：5k 任务 0.28 s/次，不能每帧重算）

    /// 纯视图动作命中缓存；任务编辑与切换基线才重算。
    @Test func varianceIsCachedAcrossViewOnlyActions() throws {
        let store = makeStore()
        store.dispatch(.createBaseline(nil))
        let firstID = try #require(store.baselines.first?.id)
        let afterCreate = store.baselineVarianceComputationCountForTesting
        #expect(afterCreate == 1)

        // 纯视图动作：日宽步进、缩放、面板开关都不 bump revision。
        store.dispatch(.nudgeCustomDayWidth(by: GanttScale.dayWidthStep))
        store.dispatch(.nudgeCustomDayWidth(by: -GanttScale.dayWidthStep))
        store.dispatch(.setInspectorVisible(false))
        #expect(store.baselineVarianceComputationCountForTesting == afterCreate,
                "纯视图动作不得重算偏差")

        // 任务编辑 bump revision → 重算一次。
        let target = try firstScheduledRow(store)
        store.dispatch(.setProgress(target.id, 0.5))
        #expect(store.baselineVarianceComputationCountForTesting == afterCreate + 1)

        // 切换基线换 key → 重算一次；再切回原基线同样各算一次（键不同）。
        store.dispatch(.createBaseline(nil))
        let afterSecondCreate = store.baselineVarianceComputationCountForTesting
        store.dispatch(.setBaseline(firstID))
        #expect(store.baselineVarianceComputationCountForTesting == afterSecondCreate + 1)
    }

    // MARK: - 基线面板（孤儿只读）

    /// 删除任务后：项目页基线面板可见「已删除」条目，大纲行数不变。
    @Test func deletedTaskAppearsInBaselinePanel() throws {
        let store = makeStore()
        store.dispatch(.createBaseline(nil))
        let victim = try firstScheduledRow(store)
        let rowsBefore = store.snapshot.outline.rows.count

        store.dispatch(.delete(victim.id))
        store.dispatch(.select(nil))

        #expect(store.snapshot.outline.rows.count == rowsBefore - 1, "大纲只减少被删任务那一行")
        guard case .project(let project) = store.snapshot.inspector.content else {
            Issue.record("取消选择后应显示项目页")
            return
        }
        let panel = try #require(project.baseline)
        #expect(panel.orphans.count == 1)
        #expect(panel.orphans.first?.taskID == victim.id)
    }

    // MARK: - 悬挂选择（撤销后）读取侧归一化

    /// 撤销导致的悬挂选择：不崩、四列隐藏、检查器无基线段，且归一化只读不改写视图状态。
    @Test func danglingBaselineSelectionIsNormalizedAfterUndo() throws {
        let store = makeStore()
        showBaselineColumns(store)
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("undo.zeno")

        // 阶段 A（lead 给的顺序）：create → setBaseline → delete → undo。
        store.dispatch(.createBaseline(nil))
        let id = try #require(store.baselines.first?.id)
        store.dispatch(.setBaseline(id))
        store.dispatch(.deleteBaseline(id))
        store.confirmPendingBaselineDeletion()
        store.dispatch(.undo)

        #expect(store.baselines.count == 1, "撤销应把基线恢复回来")
        #expect(!store.hasSelectedBaseline)
        for column in OutlineColumnPreferences.baseline {
            #expect(!store.snapshot.outline.columns.contains(column))
        }
        guard case .project(let project) = store.snapshot.inspector.content else {
            Issue.record("未选任务时应为项目页")
            return
        }
        #expect(project.baseline == nil)

        // 阶段 B（真正的悬挂）：选中 B 后撤销「创建 B」，选择仍指着已不存在的基线。
        store.dispatch(.createBaseline(nil))
        let secondID = try #require(store.baselines.last?.id)
        store.dispatch(.setBaseline(secondID))
        store.save(to: url)
        #expect(!store.hasUnsavedChanges)
        store.dispatch(.undo)
        #expect(store.baselines.count == 1)
        #expect(store.viewState.selectedBaselineID == secondID, "选择不进撤销栈，ID 仍悬空")
        #expect(!store.hasSelectedBaseline, "读取侧归一化为未选")

        // 归一化只影响展示：视图动作不改写 ID、也不额外置脏。
        let dirtyBefore = store.hasUnsavedChanges
        store.dispatch(.setInspectorVisible(true))
        #expect(store.viewState.selectedBaselineID == secondID)
        #expect(store.hasUnsavedChanges == dirtyBefore)
        for column in OutlineColumnPreferences.baseline {
            #expect(!store.snapshot.outline.columns.contains(column))
        }

        // 检查器（选中任务）同样无基线段。
        let target = try firstScheduledRow(store)
        store.dispatch(.select(target.id))
        guard case .task(let inspector) = store.snapshot.inspector.content else {
            Issue.record("选中任务应显示任务检查器")
            return
        }
        #expect(inspector.baseline == nil)
    }

    // MARK: - 持久化

    /// 基线选择写进应用偏好：重启后打开同一项目仍指向同一条基线。
    ///
    /// 偏好只存 ID（基线本身随项目文件走），所以必须连同项目文件一起验：
    /// ID 解析得到才算「选中」，指向不存在的基线按「不比较」处理。
    @Test func selectedBaselinePersistsAcrossLaunch() throws {
        let defaults = makeDefaults()
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("persisted.zeno")
        let store = makeStore(defaults: defaults)
        store.dispatch(.createBaseline("冻结版"))
        let id = try #require(store.baselines.first?.id)
        store.save(to: url)

        let relaunched = makeStore(defaults: defaults)
        #expect(relaunched.open(url: url))
        #expect(relaunched.baselines.first?.id == id)
        #expect(relaunched.viewState.selectedBaselineID == id)
        #expect(relaunched.hasSelectedBaseline)
    }
}
