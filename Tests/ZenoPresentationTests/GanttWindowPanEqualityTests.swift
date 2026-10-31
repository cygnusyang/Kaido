import Foundation
import Testing
import ZenoCore
import ZenoPresentation

// 横向翻窗增量快照的正确性门禁（D-038）。
//
// 增量路径（`WorkspacePresenter.makeWindowPan`）复用上一帧的大纲行与检查器，只重建
// 甘特与状态栏。它的**唯一**正确性判据是：同一窗口下与全量 `make` 产出相等快照。
// 本套用例逐窗口、逐子快照断言这一点——增量算错了比慢更糟，所以这里比性能门禁更硬。
//
// 窗口起点用固定种子的 LCG 抽取（不用 `Int.random`）：失败要可复现，且 CI 不受随机源影响。

/// 固定种子 LCG：同一份代码在每次运行里抽出同一组窗口。
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

@Suite("横向翻窗增量快照")
struct GanttWindowPanEqualityTests {
    private let rowCount = 1_000
    private let baselineCount = 3
    private let projectStart = makeDate(2025, 11, 1)
    private let now = makeDate(2025, 11, 10)
    private let windowStart = makeDate(2025, 11, 3)
    private let viewport = WorkspaceViewport(canvasWidth: 1_280, canvasHeight: 720)

    private struct Fixture {
        var tasks: [TaskItem]
        var state: ProjectState
        var schedule: ScheduleResult
        var baselines: [Baseline]
    }

    /// 1000 个平级任务 × 3 条基线（与 `GanttRenderPerformanceTests` 同构，
    /// 让相等性门禁与性能门禁测的是同一个负载）。
    private func makeFixture() -> Fixture {
        var tasks: [TaskItem] = []
        tasks.reserveCapacity(rowCount)
        for index in 0..<rowCount {
            tasks.append(TaskItem(
                title: "任务 \(index)",
                startDate: makeDate(2025, 11, 1 + index % 20),
                dueDate: index % 5 == 0 ? makeDate(2025, 11, 8 + index % 10) : nil,
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
        return Fixture(tasks: tasks, state: state, schedule: schedule, baselines: baselines)
    }

    /// 覆盖翻窗会碰到的全部视图状态组合：档位 / 自定义日宽 / 适合项目 / 基线叠加 /
    /// 选中与锁定 / 筛选 / 非工作日带。
    private func scenarios(fixture: Fixture) -> [(String, WorkspaceViewState)] {
        var base = WorkspaceViewState()
        base.windowStart = windowStart

        // 注意：`WorkspaceViewState()` 的旧默认是「适合项目 + 周档位」，所以这三个
        // 场景在合并前（D-041）实际跑的是 **fit 路径的不同基准档位**，不是预设档位路径。
        // 这里按枚举逐字保留那个组合（`fit(base)`），不借重构顺手改掉测试覆盖面。
        var day = base
        day.widthMode = .fit(.day)

        var week = base
        week.widthMode = .fit(.week)

        var month = base
        month.widthMode = .fit(.month)

        // 自定义日宽是唯一权威日宽：与 fit 同真时也让位（合并前口径）。
        var custom = base
        custom.widthMode = .custom(dayWidth: 20, base: .day)

        // 翻窗前是「适合项目」：翻窗会关掉 fit，日宽随之改变（大纲行不变，甘特全变）。
        var fit = base
        fit.widthMode = .fit(.week)
        fit.windowStart = nil

        var overlays = base
        overlays.widthMode = .fit(.day)
        overlays.selectedBaselineID = fixture.baselines[0].id
        overlays.visibleBaselineIDs = Set(fixture.baselines.map(\.id))
        overlays.showsNonWorkingDays = true
        overlays.showBarLabels = true
        overlays.showCriticalPath = true

        var selected = base
        selected.widthMode = .fit(.week)
        selected.selectedTaskID = fixture.tasks[500].id
        selected.inspectorLocked = true

        var filtered = base
        filtered.widthMode = .fit(.day)
        filtered.filterText = "逾期"

        return [
            ("day", day),
            ("week", week),
            ("month", month),
            ("custom-day-width", custom),
            ("fit-zoom", fit),
            ("baseline-overlays", overlays),
            ("selected-locked", selected),
            ("filtered", filtered)
        ]
    }

    /// 5 个随机窗口（固定种子）逐窗口比对：增量结果 == 全量结果。
    ///
    /// 链条从上一帧的**增量**结果继续，所以一旦复用的大纲/检查器开始漂移，
    /// 后面的窗口会立刻不等——不是只看第一跳。
    @Test func incrementalWindowPanEqualsFullRebuild() throws {
        let fixture = makeFixture()
        var rng = SeededGenerator(seed: 0xC0FFEE_2026)

        for (name, viewState) in scenarios(fixture: fixture) {
            var state = viewState
            var previous = WorkspacePresenter.make(
                state: fixture.state,
                schedule: fixture.schedule,
                violations: [],
                viewState: state,
                viewport: viewport,
                calendar: testCalendar,
                locale: testLocale,
                now: now
            )

            for step in 0..<5 {
                let offset = Int.random(in: -45...45, using: &rng)
                let origin = state.windowStart
                    ?? previous.gantt.windowStart
                state.windowStart = testCalendar.date(byAdding: .day, value: offset, to: origin)
                // 与 `WorkspaceStore.panWindow` 同一写法：翻窗即退出「适合项目」。
                state.widthMode = state.widthMode.withoutFit

                let incremental = WorkspacePresenter.makeWindowPan(
                    previous: previous,
                    state: fixture.state,
                    schedule: fixture.schedule,
                    viewState: state,
                    viewport: viewport,
                    saveState: .saved,
                    calendar: testCalendar,
                    locale: testLocale,
                    now: now
                )
                let full = WorkspacePresenter.make(
                    state: fixture.state,
                    schedule: fixture.schedule,
                    violations: [],
                    viewState: state,
                    viewport: viewport,
                    calendar: testCalendar,
                    locale: testLocale,
                    now: now
                )

                let label = "场景 \(name) / 第 \(step + 1) 跳（偏移 \(offset) 天）"
                #expect(incremental.outline == full.outline, "\(label)：大纲快照不等")
                #expect(incremental.gantt == full.gantt, "\(label)：甘特快照不等")
                #expect(incremental.inspector == full.inspector, "\(label)：检查器快照不等")
                #expect(incremental.statusBar == full.statusBar, "\(label)：状态栏快照不等")
                #expect(incremental.generatedAt == full.generatedAt, "\(label)：生成时刻不等")
                // 整体相等用布尔形式断言：失败时只报一句话，不把两份 1000 行快照打进日志。
                let equal = incremental == full
                #expect(equal, "\(label)：增量快照与全量快照不等")

                previous = incremental
            }
        }
    }

    /// 增量路径必须真的「复用」：大纲行与检查器逐字段等于上一帧（否则上一条用例
    /// 只是碰巧相等，性能收益也无从谈起）。
    @Test func windowPanReusesOutlineAndInspector() {
        let fixture = makeFixture()
        var viewState = WorkspaceViewState()
        viewState.widthMode = .fit(.day)
        viewState.windowStart = windowStart
        viewState.selectedTaskID = fixture.tasks[42].id

        let previous = WorkspacePresenter.make(
            state: fixture.state,
            schedule: fixture.schedule,
            violations: [],
            viewState: viewState,
            viewport: viewport,
            calendar: testCalendar,
            locale: testLocale,
            now: now
        )

        viewState.windowStart = testCalendar.date(byAdding: .day, value: 6, to: windowStart)
        viewState.widthMode = .preset(.day)

        let incremental = WorkspacePresenter.makeWindowPan(
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

        #expect(incremental.outline.rows.count == rowCount)
        #expect(incremental.outline == previous.outline)
        #expect(incremental.inspector == previous.inspector)
        #expect(incremental.gantt.windowStart != previous.gantt.windowStart, "窗口确实移动了")
        #expect(incremental.gantt.bars != previous.gantt.bars, "条体几何随窗口平移")
        #expect(incremental.statusBar.visibleStart == incremental.gantt.windowStart)
        #expect(incremental.statusBar.visibleEnd == incremental.gantt.windowEnd)
    }
}
