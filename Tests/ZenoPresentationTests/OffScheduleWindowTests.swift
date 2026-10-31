import Foundation
import Testing
import ZenoCore
import ZenoPresentation

// D-054 呈现层判据：窗口与**排期区间**的关系必须可判定，且「回到排期」的落点存在。
//
// 用户口径（2026-10-30）：「在任何时候，只要当前的窗口不在任务规划的区间内，在那一行上面
// 就应该有一个按钮，可以快速回到任务排期的周期里面。」
//
// 本文件只钉**状态**（快照层，纯函数、秒级）：
// - 窗口与排期区间是否相交，用什么口径判定（半开区间，与 GanttWindowCoverage 同源）；
// - 不相交时快照里是否仍有入口信号（今天是哪一侧 / 窗口外条数）；
// - 「回到排期」的目标窗口算得出来、且铺满排期（bars 非空）。
//
// 入口的**位置与点击**属于视图层（AppTests/ReturnToScheduleEntryTests）：判定在 v1.4.0
// 就已经成立，D-054 的失效面是入口被画到了视口之外，不是信号缺失。那条结论由
// entrySignalNeverMissingWhenWindowOutsideSchedule 反向钉住——谁要在快照层把信号也
// 一并抑制掉（例如再引入一个「canFit ? .none」式的短路），这里先红。

/// 排期区间口径：半开 [contentStart, contentEnd)，与 GanttWindowCoverage 的边界取等一致。
/// 不相交 = 窗口终点压在排期首日或更早，或窗口起点压在排期末日或更晚。
private func windowIsOutsideSchedule(_ gantt: GanttSnapshot) -> Bool {
    guard let start = gantt.contentStart, let end = gantt.contentEnd else { return false }
    return gantt.windowEnd <= start || gantt.windowStart >= end
}

@Suite("窗口离开排期区间")
struct OffScheduleWindowTests {
    /// 排期：2025-01-06 起三条 3 天任务（占 01-06 … 01-11）。
    private let taskStarts = [6, 7, 8]

    private func tasks() -> [TaskItem] {
        taskStarts.map { day in
            TaskItem(title: "任务 \(day)", startDate: makeDate(2025, 1, day), durationDays: 3)
        }
    }

    /// - Parameters:
    ///   - windowStart: 窗口起点（非 nil 即「用户平移过」，优先于任何默认起点）。
    ///   - canvasWidth: 画布宽；配合 .preset(.day)（32pt/天）决定窗口跨度，
    ///     96pt ≈ 3 天（窄窗口，能落在排期**内部**），800pt ≈ 25 天（宽窗口，能盖住整个排期）。
    private func snapshot(
        windowStart: Date,
        canvasWidth: Double,
        mode: WindowWidthMode = .preset(.day),
        now: Date = makeDate(2025, 3, 10)
    ) -> WorkspaceSnapshot {
        let items = tasks()
        var view = WorkspaceViewState()
        view.widthMode = mode
        view.windowStart = windowStart
        return makeSnapshot(
            state: makeState(items, projectStart: makeDate(2025, 1, 6)),
            schedule: makeSchedule(items, projectStart: makeDate(2025, 1, 6), now: now),
            viewState: view,
            viewport: WorkspaceViewport(canvasWidth: canvasWidth, canvasHeight: 400),
            now: now
        )
    }

    // MARK: - 四象限：窗口在排期之前 / 之后 / 部分相交 / 完全相交

    /// 全部任务在窗口**之后**：窗口与排期不相交，画布无条，外溢方向是「右侧」。
    @Test func windowEntirelyBeforeSchedule() {
        let gantt = snapshot(windowStart: makeDate(2024, 12, 20), canvasWidth: 96).gantt

        #expect(windowIsOutsideSchedule(gantt), "窗口 [12-20, 12-23) 应判为在排期之前：\(gantt.windowStart)..\(gantt.windowEnd)")
        #expect(gantt.bars.isEmpty, "与排期不相交时画布不该有条，实测 \(gantt.bars.count) 条")
        #expect(gantt.offWindow.offWindowCount == taskStarts.count, "三条任务全部外溢，实测 \(gantt.offWindow.offWindowCount)")
        #expect(gantt.offWindow.side == .after, "任务在窗口右侧，side 应为 .after，实测 \(gantt.offWindow.side)")
        #expect(gantt.todaySide != .none, "窗口外还应有今天方向信号（今天晚于窗口）")
    }

    /// 全部任务在窗口**之前**：这正是用户「朝右滚动」到排期之外的形态。
    @Test func windowEntirelyAfterSchedule() {
        let gantt = snapshot(windowStart: makeDate(2025, 6, 1), canvasWidth: 96).gantt

        #expect(windowIsOutsideSchedule(gantt), "窗口 [06-01, 06-04) 应判为在排期之后：\(gantt.windowStart)..\(gantt.windowEnd)")
        #expect(gantt.bars.isEmpty, "与排期不相交时画布不该有条，实测 \(gantt.bars.count) 条")
        #expect(gantt.offWindow.offWindowCount == taskStarts.count, "三条任务全部外溢，实测 \(gantt.offWindow.offWindowCount)")
        #expect(gantt.offWindow.side == .before, "任务在窗口左侧，side 应为 .before，实测 \(gantt.offWindow.side)")
        #expect(gantt.todaySide == .left, "窗口跑到今天之后，今天在左侧，实测 \(gantt.todaySide)")
    }

    /// 部分相交：窗口起点压在排期内部、终点在排期内，属于「与排期相交」。
    /// 判据不取「看得到的条数少于总数」——布局对跨窗口边界的条是整条保留的
    /// （guard finish > windowStart, start < windowEnd），3 天窗口里三条都够得着。
    @Test func windowPartiallyOverlapsSchedule() {
        let gantt = snapshot(windowStart: makeDate(2025, 1, 7), canvasWidth: 96).gantt
        let start = gantt.contentStart!
        let end = gantt.contentEnd!

        #expect(!windowIsOutsideSchedule(gantt), "窗口 [01-07, 01-10) 与排期相交，不该判为窗外")
        #expect(gantt.windowStart > start && gantt.windowEnd < end, "夹具前提：窗口两端都压在排期内部")
        #expect(!gantt.bars.isEmpty, "相交时画布应至少有一条，实测 \(gantt.bars.count) 条")
    }

    /// 完全相交：窗口盖住整个排期，bars 全在，无外溢。
    @Test func windowFullyCoversSchedule() {
        let gantt = snapshot(windowStart: makeDate(2025, 1, 5), canvasWidth: 800).gantt

        #expect(!windowIsOutsideSchedule(gantt), "宽窗口应完整覆盖排期")
        #expect(gantt.bars.count == taskStarts.count, "三条任务应全部可见，实测 \(gantt.bars.count) 条")
        #expect(gantt.offWindow.offWindowCount == 0, "无外溢条，实测 \(gantt.offWindow.offWindowCount)")
    }

    // MARK: - 入口信号在快照层永不缺失（D-054 的失效面不在状态层）

    /// **今天落在窗口内**但窗口整个在排期之后：todaySide 为 .none，
    /// 此时「窗口外提示」是唯一的入口信号——它挂在滚动内容顶部，纵向一滚就没了（AppTests 钉）。
    @Test func todayInsideWindowWhileWindowOutsideSchedule() {
        let gantt = snapshot(windowStart: makeDate(2025, 3, 5), canvasWidth: 800).gantt

        #expect(windowIsOutsideSchedule(gantt), "窗口 [03-05, 03-30) 整体在排期之后")
        #expect(gantt.todaySide == .none, "今天(03-10)落在窗口内，方向信号应缺席，实测 \(gantt.todaySide)")
        #expect(gantt.offWindow.offWindowCount == taskStarts.count, "此时唯一信号是外溢计数，实测 \(gantt.offWindow.offWindowCount)")
    }

    /// 窗口起点扫一遍（前后各两个月，3 天窄窗口），断言：
    /// **只要与排期不相交，快照就必须还留着一个入口信号**（今天方向 或 外溢计数）。
    ///
    /// 这条同时证伪 D-054 登记里「两个入口的可见性条件互相顶替、出现一个都没有的空档」这一
    /// 根因假设：状态层没有空档，空档只可能来自入口被画到了视口之外。
    @Test func entrySignalNeverMissingWhenWindowOutsideSchedule() {
        var checked = 0
        for offset in stride(from: -60, through: 60, by: 3) {
            let start = testCalendar.date(byAdding: .day, value: offset, to: makeDate(2025, 1, 6))!
            let gantt = snapshot(windowStart: start, canvasWidth: 96).gantt
            guard windowIsOutsideSchedule(gantt) else { continue }
            checked += 1
            let hasSignal = gantt.todaySide != .none || gantt.offWindow.offWindowCount > 0
            #expect(
                hasSignal,
                "窗口 \(gantt.windowStart)..\(gantt.windowEnd) 与排期 \(String(describing: gantt.contentStart))..\(String(describing: gantt.contentEnd)) 不相交，却没有任何入口信号（todaySide=\(gantt.todaySide) offWindow=\(gantt.offWindow.offWindowCount)）"
            )
        }
        #expect(checked >= 20, "扫描样本太少（\(checked) 个窗外窗口），这条断言会变成空断言")
    }

    // MARK: - 「回到排期」的落点算得出来、且铺满排期

    /// 目标窗口的判据（AppTests 点击入口后就按这三条断言）：
    /// 1) 窗口与排期区间相交；2) 排期区间整个落在窗口内；3) bars 非空。
    ///
    /// 这里先在呈现层证明「这样的落点存在」——fit 口径（清空 windowStart + 铺满内容）
    /// 就是最小落点。若哪天 fit 都铺不满排期，用例会先在这里红，AppTests 的点击断言才有意义。
    @Test func fitLandingPutsWholeScheduleInsideWindow() {
        let outside = snapshot(windowStart: makeDate(2025, 6, 1), canvasWidth: 96)
        #expect(windowIsOutsideSchedule(outside.gantt), "夹具前提：起点确实在排期之外")

        // fit 落点必须像 .setFitZoom 那样**清掉** windowStart：显式起点在呈现层永远优先，
        // 留着它，fit 也只会在原处铺（判据会因此假红）。
        var view = WorkspaceViewState()
        view.widthMode = .fit(.day)
        let items = tasks()
        let landing = makeSnapshot(
            state: makeState(items, projectStart: makeDate(2025, 1, 6)),
            schedule: makeSchedule(items, projectStart: makeDate(2025, 1, 6), now: makeDate(2025, 3, 10)),
            viewState: view,
            viewport: WorkspaceViewport(canvasWidth: 800, canvasHeight: 400),
            now: makeDate(2025, 3, 10)
        )
        let gantt = landing.gantt
        let start = gantt.contentStart!
        let end = gantt.contentEnd!

        #expect(!windowIsOutsideSchedule(gantt), "回到排期后窗口必须与排期相交：\(gantt.windowStart)..\(gantt.windowEnd)")
        #expect(gantt.windowStart <= start && gantt.windowEnd >= end, "回到排期后窗口应盖住整个排期区间")
        #expect(gantt.bars.count == taskStarts.count, "回到排期后所有任务条都应在窗口内，实测 \(gantt.bars.count) 条")
    }
}
