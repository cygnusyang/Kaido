import Foundation
import Testing
import KaidoCore
import KaidoPresentation

// v0.14 多基线叠加的呈现口径（docs/features/10-multi-baseline-gantt.md §7、§8、§10）。
//
// 锁定的四件事：
// ① 基线细条与计划条共用同一横向换算（同一日期必然同 x，D-024）；
// ② 图上最多 3 条，按创建顺序取前 3（旧偏好存 4+ 条也只画 3）；
// ③ 没有可画的基线时叠加层完全为空，行内几何与 v0.13 逐项一致（A7 基准）；
// ④ 只为可见行生成条：收起 / 被筛选的行不插行、不报错。

@Suite("多基线叠加（v0.14）")
struct GanttBaselineBarsTests {
    private let now = makeDate(2025, 11, 10)
    private let projectStart = makeDate(2025, 11, 1)

    // MARK: - 夹具

    private func makeTask(
        _ title: String,
        id: UUID = UUID(),
        startDate: Date?,
        duration: Double = 5,
        kind: TaskKind = .task,
        parentID: UUID? = nil
    ) -> TaskItem {
        TaskItem(
            id: id,
            title: title,
            startDate: startDate,
            kind: kind,
            parentID: parentID,
            durationDays: duration
        )
    }

    private func makeBaseline(
        _ name: String,
        entries: [BaselineEntry],
        colorIndex: Int? = nil,
        createdAt: Date = makeDate(2025, 11, 1)
    ) -> Baseline {
        Baseline(name: name, createdAt: createdAt, entries: entries, colorIndex: colorIndex)
    }

    private func makeEntry(
        _ taskID: UUID,
        start: Date,
        finish: Date,
        isMilestone: Bool = false
    ) -> BaselineEntry {
        BaselineEntry(
            taskID: taskID,
            start: start,
            finish: finish,
            progress: 0,
            isMilestone: isMilestone
        )
    }

    private func makeOverlaySnapshot(
        tasks: [TaskItem],
        baselines: [Baseline],
        visible: Set<UUID>,
        expanded: Set<UUID> = []
    ) -> WorkspaceSnapshot {
        let state = makeState(tasks, projectStart: projectStart, baselines: baselines)
        var viewState = WorkspaceViewState(expandedTaskIDs: expanded, widthMode: .fit(.week))
        viewState.visibleBaselineIDs = visible
        return makeSnapshot(
            state: state,
            schedule: makeSchedule(tasks, projectStart: projectStart, now: now),
            viewState: viewState,
            now: now
        )
    }

    // MARK: - 横向换算同源

    /// 同一区间：基线细条的 x / width 必须与计划条逐位相等（共用 GanttLayoutEngine）。
    @Test func baselineBarSharesPlanBarAxis() throws {
        let task = makeTask("任务 A", startDate: makeDate(2025, 11, 3))
        let baseline = makeBaseline("基准", entries: [
            makeEntry(task.id, start: makeDate(2025, 11, 3), finish: makeDate(2025, 11, 8))
        ])
        let snapshot = makeOverlaySnapshot(tasks: [task], baselines: [baseline], visible: [baseline.id])

        let planBar = try #require(snapshot.gantt.bars.first { $0.taskID == task.id })
        let baselineBar = try #require(snapshot.gantt.baselineBars[task.id]?.first)
        #expect(baselineBar.x == planBar.x)
        #expect(baselineBar.width == planBar.width)
        #expect(baselineBar.baselineID == baseline.id)

        // 非空校验：换一份更早的承诺，x 必须左移，证明断言不是恒真。
        let earlier = makeBaseline("保守", entries: [
            makeEntry(task.id, start: makeDate(2025, 11, 1), finish: makeDate(2025, 11, 6))
        ])
        let shifted = makeOverlaySnapshot(tasks: [task], baselines: [earlier], visible: [earlier.id])
        let shiftedBar = try #require(shifted.gantt.baselineBars[task.id]?.first)
        #expect(shiftedBar.x == planBar.x - 2 * snapshot.gantt.dayWidth)
    }

    /// 起点与排期结果同源：换算只经 GanttLayoutEngine，不出现第二份除法实现。
    @Test func baselineBarMatchesLayoutEngineDirectly() throws {
        let task = makeTask("任务 B", startDate: makeDate(2025, 11, 4))
        let start = makeDate(2025, 11, 2)
        let finish = makeDate(2025, 11, 7)
        let baseline = makeBaseline("基准", entries: [makeEntry(task.id, start: start, finish: finish)])
        let snapshot = makeOverlaySnapshot(tasks: [task], baselines: [baseline], visible: [baseline.id])

        let bar = try #require(snapshot.gantt.baselineBars[task.id]?.first)
        #expect(bar.x == GanttLayoutEngine.x(
            for: start,
            windowStart: snapshot.gantt.windowStart,
            dayWidth: snapshot.gantt.dayWidth
        ))
        #expect(bar.width == GanttLayoutEngine.width(
            from: start,
            to: finish,
            dayWidth: snapshot.gantt.dayWidth
        ))
    }

    // MARK: - 同屏上限

    /// 勾了 4 条：图上只画前 3 条（创建顺序），第 4 条不替换、不插队。
    @Test func visibleBaselinesAreCappedAtThreeInCreationOrder() {
        let task = makeTask("任务 A", startDate: makeDate(2025, 11, 3))
        let entry = makeEntry(task.id, start: makeDate(2025, 11, 3), finish: makeDate(2025, 11, 8))
        let baselines = (0..<4).map { index in
            makeBaseline("基线 " + String(index), entries: [entry], colorIndex: index)
        }
        let snapshot = makeOverlaySnapshot(
            tasks: [task],
            baselines: baselines,
            visible: Set(baselines.map(\.id))
        )

        #expect(snapshot.gantt.visibleBaselineIDs == Array(baselines.prefix(3)).map(\.id))
        #expect(snapshot.gantt.baselineLanes.baselineTops.count == 3)
        #expect(snapshot.gantt.baselineBars[task.id]?.count == 3)
        #expect(!snapshot.gantt.visibleBaselineIDs.contains(baselines[3].id))
    }

    // MARK: - 空态与既有几何

    /// 一条都不勾：叠加层为空，行内几何等于 N=0（A7 逐像素基准）。
    @Test func emptyVisibilityKeepsLegacyGeometry() {
        let task = makeTask("任务 A", startDate: makeDate(2025, 11, 3))
        let baseline = makeBaseline("基准", entries: [
            makeEntry(task.id, start: makeDate(2025, 11, 1), finish: makeDate(2025, 11, 4))
        ])
        let snapshot = makeOverlaySnapshot(tasks: [task], baselines: [baseline], visible: [])

        #expect(snapshot.gantt.baselineBars.isEmpty)
        #expect(snapshot.gantt.visibleBaselineIDs.isEmpty)
        #expect(snapshot.gantt.baselineLegend.isEmpty)
        #expect(snapshot.gantt.baselineLanes == BaselineLanes.layout(visibleCount: 0))
        #expect(snapshot.gantt.baselineLanes.plan.top == 7)
        #expect(snapshot.gantt.baselineLanes.plan.height == 14)
    }

    /// 一条基线都没有时与「未引入本功能」逐位一致：计划条几何不受影响。
    @Test func noBaselinesProduceNoOverlay() {
        let task = makeTask("任务 A", startDate: makeDate(2025, 11, 3))
        let snapshot = makeOverlaySnapshot(tasks: [task], baselines: [], visible: [])
        #expect(snapshot.gantt.baselineBars.isEmpty)
        #expect(snapshot.gantt.baselineLanes.baselineTops.isEmpty)
        #expect(snapshot.gantt.bars.count == 1)
    }

    /// 可见基线在图上但没有任何可画条目（基线之后新增任务）：不出现空轨。
    @Test func baselineWithoutDrawableEntriesCollapsesToZero() {
        let task = makeTask("任务 A", startDate: makeDate(2025, 11, 3))
        let baseline = makeBaseline("基准", entries: [])
        let snapshot = makeOverlaySnapshot(tasks: [task], baselines: [baseline], visible: [baseline.id])

        #expect(snapshot.gantt.baselineBars.isEmpty)
        #expect(snapshot.gantt.visibleBaselineIDs.isEmpty)
        #expect(snapshot.gantt.baselineLanes == BaselineLanes.layout(visibleCount: 0))
    }

    // MARK: - 里程碑与悬挂 ID

    /// 里程碑基线零宽：视图据此画菱形，不画 0 宽胶囊。
    @Test func milestoneBaselineHasZeroWidth() throws {
        let task = makeTask("里程碑", startDate: makeDate(2025, 11, 5), duration: 0)
        let marker = makeDate(2025, 11, 5)
        let baseline = makeBaseline("基准", entries: [
            makeEntry(task.id, start: marker, finish: marker, isMilestone: true)
        ])
        let snapshot = makeOverlaySnapshot(tasks: [task], baselines: [baseline], visible: [baseline.id])

        let bar = try #require(snapshot.gantt.baselineBars[task.id]?.first)
        #expect(bar.isMilestone)
        #expect(bar.width == 0)
    }

    /// 悬挂 ID（撤销到基线创建之前 / 换了项目）：剔除，不报错、不占轨道。
    @Test func hangingVisibleIDIsIgnored() {
        let task = makeTask("任务 A", startDate: makeDate(2025, 11, 3))
        let baseline = makeBaseline("基准", entries: [
            makeEntry(task.id, start: makeDate(2025, 11, 1), finish: makeDate(2025, 11, 4))
        ])
        let snapshot = makeOverlaySnapshot(
            tasks: [task],
            baselines: [baseline],
            visible: [baseline.id, UUID()]
        )
        #expect(snapshot.gantt.visibleBaselineIDs == [baseline.id])
        #expect(snapshot.gantt.baselineLanes.baselineTops.count == 1)
    }

    // MARK: - 颜色派生

    /// 缺 colorIndex 的旧数据按创建顺序派生 0,1（只读，不改数据、不置脏）。
    @Test func missingColorIndexIsResolvedWithoutMutatingBaseline() {
        let task = makeTask("任务 A", startDate: makeDate(2025, 11, 3))
        let entry = makeEntry(task.id, start: makeDate(2025, 11, 3), finish: makeDate(2025, 11, 8))
        let first = makeBaseline("一", entries: [entry], colorIndex: nil)
        let second = makeBaseline("二", entries: [entry], colorIndex: nil)
        let snapshot = makeOverlaySnapshot(tasks: [task], baselines: [first, second], visible: [first.id, second.id])

        #expect(snapshot.gantt.baselineLegend.map(\.colorIndex) == [0, 1])
        #expect(snapshot.gantt.baselineBars[task.id]?.map(\.colorIndex) == [0, 1])
        #expect(first.colorIndex == nil)
        #expect(second.colorIndex == nil)
    }

    /// 重复索引不串色：第二条按最小未占用派生。
    @Test func duplicateColorIndexDoesNotCollide() {
        let task = makeTask("任务 A", startDate: makeDate(2025, 11, 3))
        let entry = makeEntry(task.id, start: makeDate(2025, 11, 3), finish: makeDate(2025, 11, 8))
        let first = makeBaseline("一", entries: [entry], colorIndex: 3)
        let second = makeBaseline("二", entries: [entry], colorIndex: 3)
        let snapshot = makeOverlaySnapshot(tasks: [task], baselines: [first, second], visible: [first.id, second.id])
        #expect(snapshot.gantt.baselineLegend.map(\.colorIndex) == [3, 0])
    }

    // MARK: - 可见行

    /// 收起的群组行不生成基线条：不插行、不额外生成行。
    @Test func collapsedGroupChildrenProduceNoBars() throws {
        let groupID = UUID()
        let parent = makeTask("群组", id: groupID, startDate: nil, kind: .group)
        let child = makeTask("子任务", startDate: makeDate(2025, 11, 3), parentID: groupID)
        let baseline = makeBaseline("基准", entries: [
            makeEntry(child.id, start: makeDate(2025, 11, 3), finish: makeDate(2025, 11, 8))
        ])

        let collapsed = makeOverlaySnapshot(
            tasks: [parent, child],
            baselines: [baseline],
            visible: [baseline.id],
            expanded: []
        )
        #expect(collapsed.gantt.baselineBars[child.id] == nil)
        #expect(collapsed.gantt.visibleBaselineIDs.isEmpty)

        let expanded = makeOverlaySnapshot(
            tasks: [parent, child],
            baselines: [baseline],
            visible: [baseline.id],
            expanded: [groupID]
        )
        #expect(expanded.gantt.baselineBars[child.id]?.count == 1)
    }

    /// 图例与轨道同序：下标即 lane，名称与创建时间原样带入。
    @Test func legendFollowsLaneOrder() throws {
        let task = makeTask("任务 A", startDate: makeDate(2025, 11, 3))
        let entry = makeEntry(task.id, start: makeDate(2025, 11, 3), finish: makeDate(2025, 11, 8))
        let conservative = makeBaseline(
            "保守基线", entries: [entry], colorIndex: 1, createdAt: makeDate(2025, 11, 1)
        )
        let aggressive = makeBaseline(
            "激进基线", entries: [entry], colorIndex: 2, createdAt: makeDate(2025, 11, 2)
        )
        // 勾选顺序与创建顺序相反：轨道仍按创建顺序（§2「不随勾选重排」）。
        let snapshot = makeOverlaySnapshot(
            tasks: [task],
            baselines: [conservative, aggressive],
            visible: [aggressive.id, conservative.id]
        )

        #expect(snapshot.gantt.visibleBaselineIDs == [conservative.id, aggressive.id])
        #expect(snapshot.gantt.baselineLegend.map(\.name) == ["保守基线", "激进基线"])
        #expect(snapshot.gantt.baselineLegend.first?.createdAt == makeDate(2025, 11, 1))
    }
}
