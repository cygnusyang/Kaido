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
        var viewState = WorkspaceViewState(widthMode: .fit(.week))
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

    /// 横向翻窗（增量快照）相对判据 —— 与同环境下的全量重建比倍数（D-038、#27）。
    ///
    /// 走 `WorkspacePresenter.makeWindowPan`：只重建甘特与状态栏，复用大纲与检查器。
    ///
    /// **不写墙钟绝对阈值**：本用例曾在固定 50ms 预算下按机型漂移假红（#27：实测
    /// 50.98–51.58ms，5 次红 3 次；同一份代码在快机器上只要 8.5ms）。现在基线取
    /// 「同一份数据、同一进程、紧邻执行」的 `WorkspacePresenter.make` 全量重建耗时：
    /// 两者共享 CPU 与并发负载，相除即抵消机型差异与共享 runner 的抖动。
    /// 被断言的是 D-038 的架构契约本身——翻窗只重建甘特，必须显著快于整体重建；
    /// 一旦退化成整体重建（重建量被悄悄放大），比值逼近 1 即变红。
    /// 正确性由 `GanttWindowPanEqualityTests` 逐窗口比对（增量结果 == 全量重建）。
    @Test func windowPanKeepsSnapshotRebuildWithinFrameBudget() {
        let fixture = makeFixture()
        var viewState = WorkspaceViewState()
        viewState.visibleBaselineIDs = Set(fixture.baselines.map(\.id))
        let viewport = WorkspaceViewport(canvasWidth: 1_280, canvasHeight: 720)

        func fullSnapshot() -> WorkspaceSnapshot {
            WorkspacePresenter.make(
                state: fixture.state,
                schedule: fixture.schedule,
                violations: [],
                viewState: viewState,
                viewport: viewport,
                calendar: testCalendar,
                locale: testLocale,
                now: now
            )
        }

        /// 从上一帧翻窗到 `projectStart + dayOffset` 天。
        func pan(from previous: WorkspaceSnapshot, dayOffset: Int) -> WorkspaceSnapshot {
            viewState.windowStart = testCalendar.date(
                byAdding: .day, value: dayOffset, to: projectStart
            )
            return WorkspacePresenter.makeWindowPan(
                previous: previous,
                state: fixture.state,
                schedule: fixture.schedule,
                viewState: viewState,
                viewport: viewport,
                saveState: .saved,
                calendar: testCalendar,
                locale: testLocale,
                now: now
            )
        }

        // 预热：首轮含惰性初始化成本（字体度量、日历缓存），不计入统计；两条路径都要预热，
        // 否则基线与被测值冷热不均，比值本身就带系统偏差。
        viewState.windowStart = projectStart
        var previous = fullSnapshot()
        var warmedFull = previous
        for step in 0..<Self.warmupCount {
            warmedFull = fullSnapshot()
            previous = pan(from: previous, dayOffset: step + 1)
        }

        var measuredFull = previous
        var fullSamples: [Double] = []
        var panSamples: [Double] = []
        for step in 0..<Self.iterationCount {
            let dayOffset = Self.warmupCount + step + 1
            // 交替采样：同一轮里的负载毛刺同时落在基线与被测值上；先跑完一侧再跑另一侧，
            // 会把「后半段变热 / 被抢 CPU」整体记到某一侧，比值直接失真。
            let fullStarted = DispatchTime.now().uptimeNanoseconds
            measuredFull = fullSnapshot()
            fullSamples.append(Double(DispatchTime.now().uptimeNanoseconds - fullStarted) / 1_000_000)

            let panStarted = DispatchTime.now().uptimeNanoseconds
            previous = pan(from: previous, dayOffset: dayOffset)
            panSamples.append(Double(DispatchTime.now().uptimeNanoseconds - panStarted) / 1_000_000)
        }

        // 前提：确实复用了 1000 行大纲，且甘特/基线细条随窗口重建（否则测的是空动作）。
        #expect(measuredFull.outline.rows.count == rowCount, "全量重建的行数与翻窗同源")
        #expect(warmedFull.gantt.baselineLanes.baselineTops.count == baselineCount, "预热帧已构造基线泳道")
        #expect(previous.outline.rows.count == rowCount)
        let barCount = previous.gantt.baselineBars.values.reduce(0) { $0 + $1.count }
        #expect(barCount == rowCount * baselineCount, "基线细条应随窗口重建")
        #expect(previous.gantt.windowStart == viewState.windowStart, "窗口起点跟随翻窗")

        let fullMedian = Self.median(fullSamples)
        let panMedian = Self.median(panSamples)
        let ratio = panMedian / fullMedian
        print(String(
            format: "[gantt-render-perf] 横向翻窗 vs 全量重建（1000 行 × %d 基线，ms）："
                + "翻窗中位 %.2f（%@）；全量重建中位 %.2f（%@）；比值 %.2f（上限 %.2f）",
            baselineCount,
            panMedian,
            panSamples.map { String(format: "%.2f", $0) }.joined(separator: ", "),
            fullMedian,
            fullSamples.map { String(format: "%.2f", $0) }.joined(separator: ", "),
            ratio,
            Self.panToFullRebuildRatioLimit
        ))

        #expect(
            panMedian <= fullMedian * Self.panToFullRebuildRatioLimit,
            "横向翻窗中位 \(String(format: "%.2f", panMedian)) ms 是全量重建中位 \(String(format: "%.2f", fullMedian)) ms 的 \(String(format: "%.2f", ratio)) 倍，超出上限 \(Self.panToFullRebuildRatioLimit) 倍（疑似翻窗退化为整体重建）"
        )
        // 病态兜底：只防「卡死」，不防「慢一点」——慢一点的判别由上面的比值负责，
        // 把绝对数字当作帧预算用，就是 #27 那种按机型漂移假的来源。
        #expect(
            panMedian < Self.pathologicalCeilingMilliseconds,
            "横向翻窗中位 \(String(format: "%.2f", panMedian)) ms 超出病态上限 \(Self.pathologicalCeilingMilliseconds) ms（疑似死循环或数量级回归）"
        )
    }

    /// 采样轮数：每轮 = 一次全量重建 + 一次翻窗（本机约 50ms），连同预热约 0.5s。
    static let iterationCount = 7
    /// 预热轮数：两条路径各预热一次，抹掉首轮的惰性初始化成本。
    static let warmupCount = 2
    /// 翻窗 / 全量重建 的耗时比上限：实测本机 ≈ 0.20，留 2.5 倍裕量。
    static let panToFullRebuildRatioLimit = 0.5
    /// 病态兜底上限：只防「卡死」，不防「慢一点」。
    static let pathologicalCeilingMilliseconds = 500.0

    /// 中位数：墙钟样本右侧有长尾（被抢占 / 被降频），取平均会被整体抬高。
    private static func median(_ samples: [Double]) -> Double {
        let sorted = samples.sorted()
        guard !sorted.isEmpty else { return .infinity }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}
