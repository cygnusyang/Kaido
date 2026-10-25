import Foundation
import Testing
import KairoCore
import KairoPresentation

// 1,000 行渲染的性能取证（08-baselines §6 NFR「1,000 行不掉帧」、
// 10-multi-baseline-gantt §9「快照构造 P50 < 100 ms（debug，1000 行 × 3 基线）」）。
//
// 口径与前两处性能用例一致：debug 构建、1000 任务、单次动作耗时；
// 门禁只设**负载容忍的 sanity 上限**（1000ms，捕获 O(可见行 × 可见基线) 之上的
// 二次复杂度回归），100ms 设计预算的核验依赖本用例打印的实测值（docs/perf-1.0.md）。
//
// 此处量的是「一次状态变化要重建多少东西」：1000 可见行 + 3 条基线的完整快照
// （大纲行、甘特条、基线细条、图例）。逐帧滚动成本由绘制侧的行窗口裁剪决定
// （10 §9：只画视口内约 40 行），单元测试里没有逐帧钩子，故不在本用例范围内。

/// 固定 UTC 日历已在 TestSupport 中以 `testCalendar` 提供。
@Suite("甘特渲染性能")
struct GanttRenderPerformanceTests {
    private let rowCount = 1_000
    private let baselineCount = 3
    private let projectStart = makeDate(2025, 11, 1)
    private let now = makeDate(2025, 11, 10)

    private struct Fixture {
        var tasks: [TaskItem]
        var baselines: [Baseline]
        var state: ProjectState
        var schedule: ScheduleResult
    }

    /// 1000 个平级任务 × 3 条基线（每条覆盖全部任务）。
    private func makeFixture() -> Fixture {
        var tasks: [TaskItem] = []
        tasks.reserveCapacity(rowCount)
        for index in 0..<rowCount {
            tasks.append(TaskItem(
                title: "任务 \(index)",
                startDate: makeDate(2025, 11, 1 + index % 20),
                durationDays: Double(index % 7 + 1),
                progress: Double(index % 4) / 4
            ))
        }

        let baselines: [Baseline] = (0..<baselineCount).map { lane in
            let entries = tasks.map { task in
                BaselineEntry(
                    taskID: task.id,
                    start: makeDate(2025, 11, 1 + lane),
                    finish: makeDate(2025, 11, 8 + lane),
                    progress: 0,
                    isMilestone: false
                )
            }
            return Baseline(name: "基线 \(lane + 1)", createdAt: now, entries: entries)
        }

        let state = makeState(tasks, projectStart: projectStart, baselines: baselines)
        let schedule = makeSchedule(tasks, projectStart: projectStart, now: now)
        return Fixture(tasks: tasks, baselines: baselines, state: state, schedule: schedule)
    }

    /// 1000 行 × 3 基线的快照构造耗时。
    ///
    /// 取 5 次样本的**最小值**做门禁（并行回归时其他用例抢 CPU，墙钟被系统性抬高），
    /// 同时打印中位数与最差值，供 docs/perf-1.0.md 对照 10 §9 的 100ms 预算。
    @Test func thousandRowsWithThreeBaselinesKeepSnapshotBuildWithinBudget() throws {
        let fixture = makeFixture()
        var viewState = WorkspaceViewState(usesFitZoom: true)
        viewState.visibleBaselineIDs = Set(fixture.baselines.map(\.id))

        // 预热：首轮含惰性缓存与字体度量建立成本，不计入统计。
        _ = makeSnapshot(
            state: fixture.state,
            schedule: fixture.schedule,
            viewState: viewState,
            now: now
        )

        var samples: [Double] = []
        var snapshot: WorkspaceSnapshot?
        for _ in 0..<5 {
            let started = DispatchTime.now().uptimeNanoseconds
            snapshot = makeSnapshot(
                state: fixture.state,
                schedule: fixture.schedule,
                viewState: viewState,
                now: now
            )
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        }

        let result = try #require(snapshot)
        // 前提：确实构造了 1000 可见行 × 3 条基线的图层，否则测的是空动作。
        // `baselineBars` 按任务 ID 分组（每行一条数组），故按扁平后的条数校验。
        let barCount = result.gantt.baselineBars.values.reduce(0) { $0 + $1.count }
        #expect(result.outline.rows.count == rowCount)
        #expect(barCount == rowCount * baselineCount)
        #expect(result.gantt.baselineLanes.baselineTops.count == baselineCount)

        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let best = sorted.first ?? .infinity
        let worst = sorted.last ?? .infinity
        print(String(
            format: "[gantt-render-perf] 1000 行 × %d 基线快照构造（ms）：%@；P50 %.1f；最快 %.1f；最差 %.1f"
                + "（行 %d、基线细条 %d）",
            baselineCount,
            samples.map { String(format: "%.1f", $0) }.joined(separator: ", "),
            median,
            best,
            worst,
            result.outline.rows.count,
            barCount
        ))

        #expect(
            best < 1000,
            "1000 行 × 3 基线快照构造最快耗时 \(String(format: "%.1f", best)) ms，超出 sanity 上限（疑似数量级回归）"
        )
    }
}
