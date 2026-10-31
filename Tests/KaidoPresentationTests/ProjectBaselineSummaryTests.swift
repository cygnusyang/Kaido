import Foundation
import Testing
import KaidoCore
import KaidoPresentation

// v0.15 项目摘要偏差块（docs/features/09-baseline-version-plan.md §4）。
//
// 锁定的口径：
// ① 未选基线 / 悬挂选择 → baselineSummary 为 nil，视图整段不显示（不显示一排 0）；
// ② 选中后字段与 BaselineEngine 的报表逐字段一致，presenter 不做二次计算；
// ③ 「无基线条目」与「已删除条目」两种缺口分开计数，互不混淆。

@Suite("项目摘要偏差（v0.15）")
struct ProjectBaselineSummaryTests {
    private let now = makeDate(2025, 11, 10)

    // MARK: - 夹具

    private func makeTask(
        _ title: String,
        startDate: Date?,
        duration: Double = 3,
        status: TaskStatus = .pending,
        completedAt: Date? = nil
    ) -> TaskItem {
        TaskItem(
            title: title,
            startDate: startDate,
            status: status,
            durationDays: duration,
            completedAt: completedAt
        )
    }

    /// 用当前排期拍一份基线（与 KaidoSession.createBaseline 同一条引擎路径）。
    private func makeBaseline(name: String, tasks: [TaskItem], projectStart: Date?) -> Baseline {
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
        projectStart: Date?
    ) -> WorkspaceSnapshot {
        let state = makeState(tasks, projectStart: projectStart, baselines: baselines)
        let viewState = WorkspaceViewState(selectedBaselineID: selected)
        return makeSnapshot(
            state: state,
            schedule: makeSchedule(tasks, projectStart: projectStart, now: now),
            viewState: viewState,
            now: now
        )
    }

    /// 项目页内容；未选任务时快照必然是项目页，取不到即用例失败。
    private func projectInspector(_ snapshot: WorkspaceSnapshot) -> ProjectInspector? {
        guard case .project(let inspector) = snapshot.inspector.content else { return nil }
        return inspector
    }

    // MARK: - 显隐

    /// 未选基线：整块为 nil（v0.13 的基线面板同样为 nil，两字段同生命周期）。
    @Test func summaryIsNilWithoutSelection() throws {
        let projectStart = makeDate(2025, 11, 1)
        let task = makeTask("设计", startDate: projectStart)
        let baseline = makeBaseline(name: "基线 1", tasks: [task], projectStart: projectStart)

        let snapshot = makeSnapshotWithBaseline(
            tasks: [task], baselines: [baseline], selected: nil, projectStart: projectStart
        )
        let inspector = try #require(projectInspector(snapshot), "未选任务时应为项目页")
        #expect(inspector.baselineSummary == nil)
        #expect(inspector.baseline == nil, "摘要与面板必须同时缺席")
    }

    /// 悬挂选择（撤销创建后 ID 仍指着已不存在的基线）：按未选处理。
    @Test func summaryIsNilForDanglingSelection() throws {
        let projectStart = makeDate(2025, 11, 1)
        let task = makeTask("设计", startDate: projectStart)
        let baseline = makeBaseline(name: "基线 1", tasks: [task], projectStart: projectStart)

        let snapshot = makeSnapshotWithBaseline(
            tasks: [task], baselines: [baseline], selected: UUID(), projectStart: projectStart
        )
        let inspector = try #require(projectInspector(snapshot), "未选任务时应为项目页")
        #expect(inspector.baselineSummary == nil)
    }

    /// 选中基线：摘要与面板同时存在（视图据此判断整段是否显示）。
    @Test func summaryAppearsWithSelection() throws {
        let projectStart = makeDate(2025, 11, 1)
        let task = makeTask("设计", startDate: projectStart)
        let baseline = makeBaseline(name: "基线 1", tasks: [task], projectStart: projectStart)

        let snapshot = makeSnapshotWithBaseline(
            tasks: [task], baselines: [baseline], selected: baseline.id, projectStart: projectStart
        )
        let inspector = try #require(projectInspector(snapshot), "未选任务时应为项目页")
        let summary = try #require(inspector.baselineSummary)
        #expect(summary.baselineID == baseline.id)
        #expect(summary.name == "基线 1")
        #expect(summary.createdAt == baseline.createdAt)
        #expect(inspector.baseline != nil)
    }

    // MARK: - 字段一致性（与 BaselineEngine 报表对等）

    /// 逐字段与引擎报表一致：presenter 只做改名与收口，不重算。
    @Test func summaryMirrorsVarianceReport() throws {
        let projectStart = makeDate(2025, 11, 1)
        // 已结束但晚于基线结束（late）+ 未结束且已逾期（overdue open）+ 基线后新增（无条目）。
        let done = makeTask(
            "已完成", startDate: projectStart, status: .done, completedAt: makeDate(2025, 11, 20)
        )
        let open = makeTask("进行中", startDate: makeDate(2025, 11, 6))
        let baselinedTasks = [done, open]
        let baseline = makeBaseline(name: "基线 1", tasks: baselinedTasks, projectStart: projectStart)
        let added = makeTask("基线后新增", startDate: makeDate(2025, 11, 12))
        let currentTasks = baselinedTasks + [added]

        // 报表按同一份输入、同一引擎算一遍——presenter 的值必须与它逐个相等。
        let schedule = makeSchedule(currentTasks, projectStart: projectStart, now: now)
        let report = BaselineEngine.variance(
            baseline: baseline,
            tasks: currentTasks,
            schedules: BaselineEngine.scheduleIndex(from: schedule),
            now: now,
            calendar: testCalendar
        )

        let snapshot = makeSnapshotWithBaseline(
            tasks: currentTasks, baselines: [baseline], selected: baseline.id, projectStart: projectStart
        )
        let inspector = try #require(projectInspector(snapshot), "未选任务时应为项目页")
        let summary = try #require(inspector.baselineSummary)
        #expect(summary.baselineID == report.baselineID)
        #expect(summary.name == report.baselineName)
        #expect(summary.createdAt == report.baselineCreatedAt)
        #expect(summary.finishVariance == report.projectFinishVariance)
        #expect(summary.lateTaskCount == report.lateTaskCount)
        #expect(summary.overdueOpenCount == report.overdueOpenCount)
        #expect(summary.tasksWithoutBaseline == report.tasksWithoutBaseline)
        #expect(summary.predictedTaskCount == report.predictedTaskCount)
        #expect(summary.orphanCount == report.orphans.count)
        // 报表本身的读数也要成立，否则「对等」可能只是两个 0 对等。
        #expect(summary.lateTaskCount == 1, "已完成且晚于承诺 → 晚完成 1")
        #expect(summary.overdueOpenCount == 1, "未完成且已过承诺结束 → 逾期 1")
        #expect(summary.tasksWithoutBaseline == 1)
        #expect(summary.predictedTaskCount == 1, "未结束的已基线任务按计划参与汇总 → 预测 1")
        #expect(summary.orphanCount == 0)
    }

    /// 已删除条目计入孤儿数，不计入无基线条目；两种缺口互不混淆。
    @Test func deletedEntryCountsAsOrphan() throws {
        let projectStart = makeDate(2025, 11, 1)
        let kept = makeTask("保留", startDate: projectStart)
        let removed = makeTask("将被删除", startDate: makeDate(2025, 11, 3))
        let baseline = makeBaseline(name: "基线 1", tasks: [kept, removed], projectStart: projectStart)

        let snapshot = makeSnapshotWithBaseline(
            tasks: [kept], baselines: [baseline], selected: baseline.id, projectStart: projectStart
        )
        let inspector = try #require(projectInspector(snapshot), "未选任务时应为项目页")
        let summary = try #require(inspector.baselineSummary)
        #expect(summary.orphanCount == 1)
        #expect(summary.tasksWithoutBaseline == 0)
    }

    /// 结束偏差的空值语义：两侧没有可比较的结束 → nil，不是 0。
    @Test func finishVarianceIsNilWithoutSchedule() throws {
        let projectStart = makeDate(2025, 11, 1)
        // 空基线：既无承诺结束也无计划结束，无从比较。
        let baseline = makeBaseline(name: "空基线", tasks: [], projectStart: projectStart)

        let snapshot = makeSnapshotWithBaseline(
            tasks: [], baselines: [baseline], selected: baseline.id, projectStart: projectStart
        )
        let inspector = try #require(projectInspector(snapshot), "未选任务时应为项目页")
        let summary = try #require(inspector.baselineSummary)
        #expect(summary.finishVariance == nil)
    }
}
