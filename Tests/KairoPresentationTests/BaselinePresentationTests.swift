import Foundation
import Testing
import KairoCore
import KairoPresentation

// v0.13 基线呈现（docs/features/08-baselines.md §4、§5、§8）。
//
// 锁定的口径：
// ① 四个基线列是可选列且默认隐藏，未选基线时即使勾选也不出现（§5「整体隐藏」）；
// ② 大纲列对比 plan vs baseline，正数 = 比承诺晚、负数 = 提前，空缺是 nil 而不是 0；
// ③ 检查器同时给计划偏差与实际偏差，实际为空就是空，不拿 plan 冒充 actual（§4.3）。

@Suite("基线呈现（v0.13）")
struct BaselinePresentationTests {
    private let now = makeDate(2025, 11, 10)

    // MARK: - 夹具

    private func makeTask(
        _ title: String,
        startDate: Date?,
        duration: Double = 3,
        status: TaskStatus = .pending,
        actualStart: Date? = nil,
        completedAt: Date? = nil
    ) -> TaskItem {
        TaskItem(
            title: title,
            startDate: startDate,
            status: status,
            durationDays: duration,
            completedAt: completedAt,
            actualStart: actualStart
        )
    }

    /// 用当前排期拍一份基线（与 `KairoSession.createBaseline` 同一条引擎路径）。
    private func makeBaseline(
        name: String,
        tasks: [TaskItem],
        projectStart: Date?
    ) -> Baseline {
        let schedule = makeSchedule(tasks, projectStart: projectStart, now: now)
        return BaselineEngine.snapshot(
            tasks: tasks,
            schedules: BaselineEngine.scheduleIndex(from: schedule),
            name: name,
            anchor: projectStart,
            now: now
        )
    }

    private func makeSnapshotWithBaseline(
        tasks: [TaskItem],
        baselines: [Baseline],
        selected: UUID?,
        projectStart: Date?,
        selectedTaskID: UUID? = nil,
        shownOptional: Set<OutlineColumn> = []
    ) -> WorkspaceSnapshot {
        let state = makeState(
            tasks,
            projectStart: projectStart,
            baselines: baselines
        )
        let viewState = WorkspaceViewState(
            outlineWidth: 640,
            selectedTaskID: selectedTaskID,
            visibleOptionalColumns: Set(shownOptional.map(\.rawValue)),
            selectedBaselineID: selected
        )
        return makeSnapshot(
            state: state,
            schedule: makeSchedule(tasks, projectStart: projectStart, now: now),
            viewState: viewState,
            now: now
        )
    }

    private func row(_ snapshot: WorkspaceSnapshot, _ id: UUID) throws -> PlanRow {
        try #require(snapshot.outline.rows.first { $0.id == id })
    }

    // MARK: - 列集合（§11「四列默认隐藏」）

    /// 四个基线列都是可选列，与固定列/其余可配置列不重叠。
    @Test func baselineColumnsAreOptional() {
        #expect(OutlineColumnPreferences.baseline == [
            .baselineStart, .baselineFinish, .startVariance, .finishVariance,
        ])
        #expect(OutlineColumnPreferences.baseline.isSubset(of: OutlineColumnPreferences.optional))
        #expect(OutlineColumnPreferences.baseline.isDisjoint(with: OutlineColumnPreferences.alwaysVisible))
        #expect(Set(OutlineColumnPreferences.configurable).isDisjoint(with: OutlineColumnPreferences.baseline))
    }

    /// 列宽按日期列/数字列口径：基线日期同 `finish`，偏差同 `duration`。
    @Test func baselineColumnWidthsFollowDateAndNumberColumns() {
        #expect(OutlineColumn.baselineStart.width(bodyFontSize: 13)
            == OutlineColumn.finish.width(bodyFontSize: 13))
        #expect(OutlineColumn.baselineFinish.width(bodyFontSize: 13)
            == OutlineColumn.finish.width(bodyFontSize: 13))
        #expect(OutlineColumn.startVariance.width(bodyFontSize: 13)
            == OutlineColumn.duration.width(bodyFontSize: 13))
        #expect(OutlineColumn.finishVariance.width(bodyFontSize: 26)
            == OutlineColumn.duration.width(bodyFontSize: 26))
    }

    /// 默认隐藏：未勾选时任何宽度档位都不出现基线列。
    @Test(arguments: [180.0, 340.0, 454.0, 600.0, 640.0])
    func baselineColumnsAreHiddenByDefault(width: Double) {
        let columns = OutlineColumnPreferences.visibleColumns(
            outlineWidth: width, hidden: [], focused: false, hasSelectedBaseline: true
        )
        for column in OutlineColumnPreferences.baseline {
            #expect(!columns.contains(column))
        }
    }

    /// 未选基线时勾选也不出现；选中后按 `allCases` 顺序紧随实际列。
    @Test func baselineColumnsRequireSelectedBaseline() {
        let all = OutlineColumnPreferences.baseline
        let without = OutlineColumnPreferences.visibleColumns(
            outlineWidth: 640, hidden: [], focused: false,
            shownOptional: all, hasSelectedBaseline: false
        )
        for column in all {
            #expect(!without.contains(column))
        }

        let with = OutlineColumnPreferences.visibleColumns(
            outlineWidth: 640, hidden: [], focused: false,
            shownOptional: all, hasSelectedBaseline: true
        )
        #expect(with == [
            .status, .violation, .number, .title, .predecessors,
            .start, .finish,
            .baselineStart, .baselineFinish, .startVariance, .finishVariance,
            .duration, .assignee, .progress,
        ])
    }

    /// 实际列与基线列同时打开时：实际在前、基线在后（`allCases` 顺序）。
    @Test func actualAndBaselineColumnsCoexistInCanonicalOrder() throws {
        let columns = OutlineColumnPreferences.visibleColumns(
            outlineWidth: 640, hidden: [], focused: false,
            shownOptional: [
                .baselineFinish, .actualStart, .finishVariance, .actualFinish,
                .baselineStart, .startVariance,
            ],
            hasSelectedBaseline: true
        )
        let finishIndex = try #require(columns.firstIndex(of: .finish))
        #expect(Array(columns[(finishIndex + 1)...]) == [
            .actualStart, .actualFinish,
            .baselineStart, .baselineFinish, .startVariance, .finishVariance,
            .duration, .assignee, .progress,
        ])
    }

    /// 未选基线时 Presenter 出的列集合里没有基线列（与视图同一策略）。
    @Test func snapshotOmitsBaselineColumnsWithoutSelection() throws {
        let task = makeTask("设计", startDate: makeDate(2025, 11, 1))
        let baseline = makeBaseline(name: "基线 1", tasks: [task], projectStart: makeDate(2025, 11, 1))
        let snapshot = makeSnapshotWithBaseline(
            tasks: [task], baselines: [baseline], selected: nil,
            projectStart: makeDate(2025, 11, 1), shownOptional: OutlineColumnPreferences.baseline
        )
        for column in OutlineColumnPreferences.baseline {
            #expect(!snapshot.outline.columns.contains(column))
        }
        let row = try row(snapshot, task.id)
        #expect(row.baselineStart == nil)
        #expect(row.hasBaseline == false)
    }

    // MARK: - 计划偏差（列）

    /// 计划晚 3 天：`finishVariance == +3`，基线起止来自条目。
    @Test func planVarianceIsPositiveWhenLaterThanBaseline() throws {
        let projectStart = makeDate(2025, 11, 1)
        let task = makeTask("设计", startDate: projectStart)
        let baseline = makeBaseline(name: "基线 1", tasks: [task], projectStart: projectStart)

        var moved = task
        moved.startDate = makeDate(2025, 11, 4)
        let snapshot = makeSnapshotWithBaseline(
            tasks: [moved], baselines: [baseline], selected: baseline.id,
            projectStart: projectStart,
            shownOptional: [.baselineStart, .baselineFinish, .startVariance, .finishVariance]
        )
        let row = try row(snapshot, task.id)
        #expect(row.hasBaseline)
        #expect(row.baselineStart == makeDate(2025, 11, 1))
        #expect(row.baselineFinish == makeDate(2025, 11, 4))
        #expect(row.planFinishVariance == 3)
        #expect(row.planStartVariance == 3)
        #expect(snapshot.outline.columns.contains(.baselineStart))
        #expect(snapshot.outline.columns.contains(.finishVariance))
    }

    /// 提前 1 天：偏差为负（符号即方向）。
    @Test func planVarianceIsNegativeWhenEarlierThanBaseline() throws {
        let projectStart = makeDate(2025, 11, 1)
        // 基线记 11-02 开工（晚于项目开始日，才留出「提前一天」的空间）。
        let task = makeTask("设计", startDate: makeDate(2025, 11, 2))
        let baseline = makeBaseline(name: "基线 1", tasks: [task], projectStart: projectStart)

        var moved = task
        moved.startDate = makeDate(2025, 11, 1)
        let snapshot = makeSnapshotWithBaseline(
            tasks: [moved], baselines: [baseline], selected: baseline.id,
            projectStart: projectStart
        )
        let row = try row(snapshot, task.id)
        #expect(row.planFinishVariance == -1)
    }

    /// 基线之后新增：`hasBaseline == false`，四列取值为 nil（不是 0）。
    @Test func taskAddedAfterBaselineHasNoVariance() throws {
        let projectStart = makeDate(2025, 11, 1)
        let existing = makeTask("设计", startDate: projectStart)
        let baseline = makeBaseline(name: "基线 1", tasks: [existing], projectStart: projectStart)
        let added = makeTask("基线后新增", startDate: makeDate(2025, 11, 5))

        let snapshot = makeSnapshotWithBaseline(
            tasks: [existing, added], baselines: [baseline], selected: baseline.id,
            projectStart: projectStart
        )
        let addedRow = try row(snapshot, added.id)
        #expect(!addedRow.hasBaseline)
        #expect(addedRow.baselineStart == nil)
        #expect(addedRow.baselineFinish == nil)
        #expect(addedRow.planStartVariance == nil)
        #expect(addedRow.planFinishVariance == nil)
        // 已有条目的任务照样有读数：证明缺口只落在新任务上。
        #expect(try row(snapshot, existing.id).planFinishVariance == 0)
    }

    /// 切换基线：同一任务的读数整体变化（列内容随选中项走）。
    @Test func switchingBaselineChangesVariance() throws {
        let projectStart = makeDate(2025, 11, 1)
        let task = makeTask("设计", startDate: projectStart)
        // 基线 A：11-01 起 3 天；基线 B：11-02 起 3 天（晚一天）。
        let early = makeBaseline(name: "基线 A", tasks: [task], projectStart: projectStart)
        var shifted = task
        shifted.startDate = makeDate(2025, 11, 2)
        let late = makeBaseline(name: "基线 B", tasks: [shifted], projectStart: projectStart)

        var current = task
        current.startDate = makeDate(2025, 11, 3)

        let withEarly = makeSnapshotWithBaseline(
            tasks: [current], baselines: [early, late], selected: early.id,
            projectStart: projectStart
        )
        let withLate = makeSnapshotWithBaseline(
            tasks: [current], baselines: [early, late], selected: late.id,
            projectStart: projectStart
        )
        #expect(try row(withEarly, task.id).planFinishVariance == 2)
        #expect(try row(withLate, task.id).planFinishVariance == 1)
        #expect(try row(withEarly, task.id).baselineStart == makeDate(2025, 11, 1))
        #expect(try row(withLate, task.id).baselineStart == makeDate(2025, 11, 2))
    }

    /// 没有排期的任务（群组空壳）不该造出 0 偏差。
    @Test func unscheduledTaskHasNilVariance() throws {
        let projectStart = makeDate(2025, 11, 1)
        let task = makeTask("设计", startDate: projectStart)
        let baseline = makeBaseline(name: "基线 1", tasks: [task], projectStart: projectStart)

        var group = TaskItem(title: "空群组", kind: .group)
        group.startDate = nil
        let snapshot = makeSnapshotWithBaseline(
            tasks: [task, group], baselines: [baseline], selected: baseline.id,
            projectStart: projectStart
        )
        let groupRow = try row(snapshot, group.id)
        #expect(groupRow.planFinishVariance == nil)
        #expect(groupRow.baselineFinish == nil)
    }

    // MARK: - 检查器（§4.3 不对称口径）

    /// 计划层与事实层分开：未完成 → 实际偏差 nil、逾期有值；已完成 → 实际偏差有值、逾期 nil。
    @Test func inspectorSeparatesPlanAndActualVariance() throws {
        let projectStart = makeDate(2025, 11, 1)
        let open = makeTask("进行中", startDate: projectStart)
        let baseline = makeBaseline(name: "基线 1", tasks: [open], projectStart: projectStart)

        var movedOpen = open
        movedOpen.startDate = makeDate(2025, 11, 4)
        let openSnapshot = makeSnapshotWithBaseline(
            tasks: [movedOpen], baselines: [baseline], selected: baseline.id,
            projectStart: projectStart, selectedTaskID: open.id
        )
        guard case .task(let openInspector) = openSnapshot.inspector.content else {
            Issue.record("选中任务时应为任务检查器页")
            return
        }
        let section = try #require(openInspector.baseline)
        #expect(section.baselineID == baseline.id)
        #expect(section.name == "基线 1")
        #expect(section.planFinishVariance == 3)
        #expect(section.actualFinishVariance == nil, "未完成不拿 plan 冒充 actual")
        #expect(section.overdueDays == 6)

        // 同一基线 + 已完成任务：实际偏差是事实层读数，逾期计数归零。
        let done = TaskItem(
            title: "已完成",
            startDate: projectStart,
            status: .done,
            durationDays: 3,
            completedAt: makeDate(2025, 11, 6),
            actualStart: makeDate(2025, 11, 1)
        )
        let doneBaseline = makeBaseline(name: "基线 2", tasks: [done], projectStart: projectStart)
        let doneSnapshot = makeSnapshotWithBaseline(
            tasks: [done], baselines: [doneBaseline], selected: doneBaseline.id,
            projectStart: projectStart, selectedTaskID: done.id
        )
        guard case .task(let doneInspector) = doneSnapshot.inspector.content else {
            Issue.record("选中任务时应为任务检查器页")
            return
        }
        let doneSection = try #require(doneInspector.baseline)
        #expect(doneSection.planFinishVariance == 0)
        #expect(doneSection.actualFinishVariance == 2)
        #expect(doneSection.overdueDays == nil)
    }

    /// 基线后新增的任务不出基线段（不给一行「无数据」）。
    @Test func inspectorOmitsSectionForTaskWithoutEntry() throws {
        let projectStart = makeDate(2025, 11, 1)
        let existing = makeTask("设计", startDate: projectStart)
        let baseline = makeBaseline(name: "基线 1", tasks: [existing], projectStart: projectStart)
        let added = makeTask("基线后新增", startDate: makeDate(2025, 11, 5))

        let snapshot = makeSnapshotWithBaseline(
            tasks: [existing, added], baselines: [baseline], selected: baseline.id,
            projectStart: projectStart, selectedTaskID: added.id
        )
        guard case .task(let inspector) = snapshot.inspector.content else {
            Issue.record("选中任务时应为任务检查器页")
            return
        }
        #expect(inspector.baseline == nil)
    }

    /// 未选基线：检查器基线段同样不出现。
    @Test func inspectorHasNoSectionWithoutSelection() throws {
        let projectStart = makeDate(2025, 11, 1)
        let task = makeTask("设计", startDate: projectStart)
        let baseline = makeBaseline(name: "基线 1", tasks: [task], projectStart: projectStart)
        let snapshot = makeSnapshotWithBaseline(
            tasks: [task], baselines: [baseline], selected: nil,
            projectStart: projectStart, selectedTaskID: task.id
        )
        guard case .task(let inspector) = snapshot.inspector.content else {
            Issue.record("选中任务时应为任务检查器页")
            return
        }
        #expect(inspector.baseline == nil)
    }

    // MARK: - 基线面板（§5：孤儿与基线后新增不插大纲行）

    /// 已删除任务进面板孤儿列表（只读），不计入大纲行也不计入项目偏差。
    @Test func deletedTaskShowsUpAsOrphanInPanel() throws {
        let projectStart = makeDate(2025, 11, 1)
        let kept = makeTask("保留", startDate: projectStart)
        let removed = makeTask("将被删除", startDate: makeDate(2025, 11, 3))
        let baseline = makeBaseline(name: "基线 1", tasks: [kept, removed], projectStart: projectStart)

        // 任务已删：state 里只剩 kept；基线条目仍在。
        let snapshot = makeSnapshotWithBaseline(
            tasks: [kept], baselines: [baseline], selected: baseline.id,
            projectStart: projectStart
        )
        #expect(snapshot.outline.rows.count == 1, "孤儿不为它插大纲行")
        guard case .project(let project) = snapshot.inspector.content else {
            Issue.record("未选任务时应为项目页")
            return
        }
        let panel = try #require(project.baseline)
        #expect(panel.baselineID == baseline.id)
        #expect(panel.orphans.count == 1)
        #expect(panel.orphans.first?.taskID == removed.id)
        #expect(panel.orphans.first?.start == makeDate(2025, 11, 3))
        #expect(panel.tasksWithoutBaseline == 0)
    }

    /// 基线后新增进计数而不是孤儿；面板同一份数据里两种缺口互不混淆。
    @Test func panelSeparatesOrphansFromTasksWithoutEntry() throws {
        let projectStart = makeDate(2025, 11, 1)
        let existing = makeTask("已有条目", startDate: projectStart)
        let baseline = makeBaseline(name: "基线 1", tasks: [existing], projectStart: projectStart)
        let added = makeTask("基线后新增", startDate: makeDate(2025, 11, 4))

        let snapshot = makeSnapshotWithBaseline(
            tasks: [existing, added], baselines: [baseline], selected: baseline.id,
            projectStart: projectStart
        )
        guard case .project(let project) = snapshot.inspector.content else {
            Issue.record("未选任务时应为项目页")
            return
        }
        let panel = try #require(project.baseline)
        #expect(panel.orphans.isEmpty)
        #expect(panel.tasksWithoutBaseline == 1)
    }

    /// 未选基线：项目页没有基线面板（整段隐藏）。
    @Test func panelIsAbsentWithoutSelection() throws {
        let projectStart = makeDate(2025, 11, 1)
        let task = makeTask("设计", startDate: projectStart)
        let baseline = makeBaseline(name: "基线 1", tasks: [task], projectStart: projectStart)
        let snapshot = makeSnapshotWithBaseline(
            tasks: [task], baselines: [baseline], selected: nil, projectStart: projectStart
        )
        guard case .project(let project) = snapshot.inspector.content else {
            Issue.record("未选任务时应为项目页")
            return
        }
        #expect(project.baseline == nil)
    }

    // MARK: - 视图状态与动作

    /// 悬挂 ID 的读取侧归一化：只读、不改写视图状态（撤销到基线创建之前的情形）。
    @Test func danglingSelectionNormalizesOnRead() {
        let known = UUID()
        let dangling = UUID()
        let baseline = Baseline(id: known, name: "基线", createdAt: makeDate(2025, 11, 1))

        var state = WorkspaceViewState(selectedBaselineID: dangling)
        #expect(state.normalizedBaselineID(in: []) == nil)
        #expect(state.normalizedBaselineID(in: [baseline]) == nil, "找不到的基线按未选处理")
        #expect(state.selectedBaselineID == dangling, "归一化是只读，不得改写视图状态")

        state.selectedBaselineID = known
        #expect(state.normalizedBaselineID(in: [baseline]) == known)
        #expect(WorkspaceViewState().normalizedBaselineID(in: [baseline]) == nil)
    }

    /// 悬挂选择下快照与未选基线等价：四列隐藏、项目页面板为空、检查器无基线段。
    @Test func danglingSelectionSnapshotMatchesNoSelection() throws {
        let projectStart = makeDate(2025, 11, 1)
        let task = makeTask("设计", startDate: projectStart)
        let baseline = makeBaseline(name: "基线 1", tasks: [task], projectStart: projectStart)

        let dangling = makeSnapshotWithBaseline(
            tasks: [task], baselines: [baseline], selected: UUID(),
            projectStart: projectStart, shownOptional: OutlineColumnPreferences.baseline
        )
        let none = makeSnapshotWithBaseline(
            tasks: [task], baselines: [baseline], selected: nil,
            projectStart: projectStart, shownOptional: OutlineColumnPreferences.baseline
        )
        #expect(dangling.outline.columns == none.outline.columns)
        for column in OutlineColumnPreferences.baseline {
            #expect(!dangling.outline.columns.contains(column))
        }
        guard case .project(let project) = dangling.inspector.content else {
            Issue.record("未选任务时应为项目页")
            return
        }
        #expect(project.baseline == nil)
        #expect(try row(dangling, task.id).hasBaseline == false)
    }

    /// 视图状态默认不选基线；动作按值可比较（视图可安全去重）。
    @Test func viewStateHasNoBaselineByDefault() {
        #expect(WorkspaceViewState().selectedBaselineID == nil)
        let id = UUID()
        #expect(WorkspaceAction.setBaseline(id) == .setBaseline(id))
        #expect(WorkspaceAction.setBaseline(nil) != .setBaseline(id))
        #expect(WorkspaceAction.deleteBaseline(id) != .setBaseline(id))
        #expect(WorkspaceAction.createBaseline(nil) == .createBaseline(nil))
        #expect(WorkspaceAction.renameBaseline(id, "B") == .renameBaseline(id, "B"))
    }
}
