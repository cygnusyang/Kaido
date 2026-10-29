import Foundation
import Testing
import KairoCore
import KairoPresentation
@testable import KairoMacApp

/// 启动窗口契约（7 天 / 锚定今天）的应用层验收用例。
///
/// 需求口径（已拍板，不随实现现状放宽）：
/// - 启动窗口跨度恒 7 天，起点 = `startOfDay(now)`；
/// - 日宽 = 画布宽 / 7（默认画布 518pt ⇒ 74.0 px/天）；
/// - 7 天是**窗口跨度**，不是新增的「7px/天」档位（day/week/month = 32/12/5 保留）；
/// - `windowStart` 不跨启动恢复：重启永远回到今天；
/// - 偏好 schema 1 → 2 迁移时重置 zoom / usesFitZoom / windowStart / customDayWidth 四项。
///
/// 实现未落地时本文件预期为红——这些断言就是验收判据。
@MainActor
@Suite("启动窗口 7 天")
struct StartupWindowTests {
    /// 与 store 同源的日历：格里高利历 + 本机时区（store 也这样建自己的 calendar）。
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    /// 启动跨度（天）：单源引用生产常量，不在用例里写死 7。
    private static let spanDays = WorkspaceViewState.defaultWindowSpanDays
    private static let spanSeconds: TimeInterval = Double(spanDays) * 86_400

    /// 非跨度模式 `goToToday` 回退的天数。
    ///
    /// **刻意不复用 `spanDays`**：它对应 store 里 `today.addingTimeInterval(-7 * 86_400)`
    /// 这句字面量（WorkspaceStore.swift:738），是改动前的历史口径，与「启动跨度」是两个
    /// 概念——今天恰好都是 7，不代表以后必须同步。谁要是把默认跨度调成 14，这条非跨度
    /// 口径仍应是 today−7；把两者绑在一起会让用例跟着错。
    private static let legacyGoToTodayLookbackDays = 7

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suite = "kairo.apptests.startupwindow.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeStore(
        _ name: String,
        seedsDemoData: Bool = true,
        defaults: UserDefaults? = nil
    ) -> WorkspaceStore {
        WorkspaceStore(
            defaults: defaults ?? makeDefaults(name),
            seedsDemoData: seedsDemoData
        )
    }

    /// 窗口跨度（秒）：半开区间 `[windowStart, windowEnd)`。
    private func span(_ gantt: GanttSnapshot) -> TimeInterval {
        gantt.windowEnd.timeIntervalSince(gantt.windowStart)
    }

    // MARK: - C1 空偏好启动即 7 天

    @Test func startupWindowSpansSevenDays() {
        let store = makeStore("span")
        store.setViewport(canvasWidth: 518, canvasHeight: 640)

        #expect(store.viewState.windowSpanDays == Self.spanDays, "启动应进入默认跨度模式")
        #expect(abs(span(store.snapshot.gantt) - Self.spanSeconds) < 1, "启动窗口跨度应为 7 天")
        // 状态栏档位：跨度有自己的档位，不冒充 fit / 自定义。
        #expect(store.snapshot.statusBar.zoom.preset == .span)
    }

    // MARK: - C2 起点 = 今天，与内容起点无关

    @Test(arguments: [2020, 2030])
    func startupWindowAnchorsTodayNotContentStart(year: Int) throws {
        // 空项目里造一条落在 2020 / 2030 的任务：内容起点即该年份，与「今天」相距数年。
        // 注意不能只用 projectStart 造内容范围——没有任务时 contentRange 为空，
        // 守卫会退化（fixture 失去区分度），所以这里用任务把内容起点钉死。
        let store = makeStore("anchor\(year)", seedsDemoData: false)
        store.dispatch(.createTask(parentID: nil, kind: .task))
        let taskID = try #require(store.viewState.selectedTaskID)
        let contentDay = try #require(
            calendar.date(from: DateComponents(year: year, month: 3, day: 1))
        )
        store.dispatch(.canvasEditSchedule(taskID, startDate: contentDay, durationDays: 5))
        let today = calendar.startOfDay(for: Date())
        store.setViewport(canvasWidth: 518, canvasHeight: 640)

        let gantt = store.snapshot.gantt
        // 区分度守卫：内容起点必须真的落在参数年份上，否则「锚定今天」不可证。
        #expect(
            gantt.contentStart.map { calendar.component(.year, from: $0) } == year,
            "夹具失效：内容起点没有落在参数年份上"
        )
        #expect(gantt.windowStart == today, "起点应锚定今天而不是内容起点")
        #expect(abs(span(gantt) - Self.spanSeconds) < 1)
    }

    // MARK: - C3 日宽 = 画布宽 / 7

    @Test func startupDayWidthIsCanvasWidthDividedBySeven() {
        let store = makeStore("daywidth")
        store.setViewport(canvasWidth: 518, canvasHeight: 640)

        // 518 / 7 = 74.0（精确等分，不存在取整或夹取）。
        let expected = 518.0 / Double(Self.spanDays)
        #expect(abs(store.snapshot.gantt.dayWidth - expected) < 1e-9)
    }

    // MARK: - C7 画布宽度矩阵：跨度恒 7 天、日宽精确等分、刻度逐日

    @Test(arguments: [320.0, 768.0, 1024.0])
    func startupWindowScalesWithCanvasWidth(width: Double) {
        let store = makeStore("width\(Int(width))")
        store.setViewport(canvasWidth: width, canvasHeight: 640)

        let gantt = store.snapshot.gantt
        let expectedWidth = width / Double(Self.spanDays)
        #expect(abs(span(gantt) - Self.spanSeconds) < 1, "跨度应恒为默认跨度（画布宽 \(width)）")
        #expect(abs(gantt.dayWidth - expectedWidth) < 1e-9, "日宽应为画布宽 / 跨度（画布宽 \(width)）")
        // 45.7 / 109.7 / 146.3 px/天 都 ≥ 18，刻度应逐日。
        #expect(gantt.tickGranularity == .day)
    }

    // MARK: - C8 平移不改跨度

    @Test func panningKeepsTheSevenDaySpan() {
        let store = makeStore("pan")
        store.setViewport(canvasWidth: 518, canvasHeight: 640)
        let today = calendar.startOfDay(for: Date())

        store.panWindow(byDays: 3)

        let gantt = store.snapshot.gantt
        #expect(
            calendar.dateComponents([.day], from: gantt.windowStart, to: today).day == 3,
            "平移 3 天应把起点前移 3 天"
        )
        #expect(abs(span(gantt) - Self.spanSeconds) < 1, "平移只改起点，跨度仍为 7 天")
    }

    // MARK: - C12 平移后重启：回到今天 + 7 天

    @Test func pannedWindowSnapsBackToTodayOnNextLaunch() {
        let defaults = makeDefaults("relaunch")
        let first = makeStore("relaunch", defaults: defaults)
        first.setViewport(canvasWidth: 518, canvasHeight: 640)
        let today = calendar.startOfDay(for: Date())
        first.panWindow(byDays: 5)
        #expect(
            calendar.dateComponents([.day], from: first.snapshot.gantt.windowStart, to: today).day == 5,
            "前置条件：第一次会话已平移到 5 天前"
        )

        // 同一份偏好域重建 store = 重启应用。
        let second = WorkspaceStore(defaults: defaults, seedsDemoData: true)
        second.setViewport(canvasWidth: 518, canvasHeight: 640)

        #expect(second.snapshot.gantt.windowStart == today, "windowStart 不跨启动恢复")
        #expect(second.viewState.windowSpanDays == Self.spanDays)
        #expect(abs(span(second.snapshot.gantt) - Self.spanSeconds) < 1)
    }

    // MARK: - C13 旧偏好迁移（schema 1 → 2）

    @Test func legacyPreferencesMigrateToSevenDayWindow() {
        let defaults = makeDefaults("legacy")
        // 旧偏好（无 schema 键 = schema 1）：日宽四项都是「非默认」值，迁移后必须被重置。
        let legacy = """
        {
          "outlineWidth": 480,
          "outlineVisible": false,
          "expandedTaskIDs": [],
          "zoom": "day",
          "usesFitZoom": true,
          "customDayWidth": 20,
          "windowStart": 0,
          "inspectorWidth": 360,
          "inspectorTab": "violations"
        }
        """
        defaults.set(Data(legacy.utf8), forKey: WorkspaceStore.preferencesKey)

        let store = WorkspaceStore(defaults: defaults, seedsDemoData: true)

        // 迁移重置的四项（schema 2 语义）。
        #expect(store.viewState.zoom == .week, "zoom 应重置为默认档位")
        // usesFitZoom：旧值 true 必须被丢弃；启动固定跨度时 fit 一律关闭
        // （span 在 Presenter.zoomPreset 里排在 fit 之前，fit 只是惰性状态）。
        // 迁移的判别力在相邻的 zoom / customDayWidth 两行——它们存的是非默认值。
        #expect(store.viewState.usesFitZoom == false, "启动固定跨度时 fit 必须关闭")
        #expect(store.viewState.customDayWidth == nil, "customDayWidth 应重置")
        #expect(store.viewState.windowStart == nil, "windowStart 应重置 / 不再持久化")
        #expect(store.viewState.windowSpanDays == Self.spanDays, "迁移后回到默认跨度启动窗口")
        // 其余偏好原样保留。
        #expect(store.viewState.outlineWidth == 480)
        #expect(store.viewState.outlineVisible == false)
        #expect(store.viewState.inspectorWidth == 360)
        #expect(store.viewState.inspectorTab == .violations)

        store.setViewport(canvasWidth: 518, canvasHeight: 640)
        #expect(abs(span(store.snapshot.gantt) - Self.spanSeconds) < 1)
    }

    // MARK: - goToToday：跨度模式取今天，非跨度模式保持 today−7

    @Test func goToTodayPutsTodayInsideTheSpanWindow() {
        let store = makeStore("gototoday")
        store.setViewport(canvasWidth: 518, canvasHeight: 640)
        let today = calendar.startOfDay(for: Date())
        store.panWindow(byDays: 4)
        store.dispatch(.goToToday)

        let gantt = store.snapshot.gantt
        // 半开区间 [start, end)：起点写 today−7 会把今天整天排除，用户点「今天」反而看不到今天。
        #expect(gantt.windowStart == today, "跨度模式点今天应让今天落在窗口内")
        #expect(gantt.todayOutOfRange == false)
        #expect(abs(span(gantt) - Self.spanSeconds) < 1)
    }

    @Test func goToTodayKeepsLegacySevenDaysBackOutsideSpanMode() {
        let store = makeStore("gototodaylegacy")
        // 选档位即退出跨度，回到非跨度口径（A7 逐位不变）。
        store.dispatch(.setZoom(.week))
        #expect(store.viewState.windowSpanDays == nil)

        let today = calendar.startOfDay(for: Date())
        store.dispatch(.goToToday)
        #expect(
            calendar.dateComponents([.day], from: store.snapshot.gantt.windowStart, to: today).day
                == Self.legacyGoToTodayLookbackDays,
            "非跨度模式点今天仍是 today−7（沿用改动前的字面量，与跨度常量无关）"
        )
    }

    // MARK: - 口径确认：custom 抑制 span、平移后选档位

    @Test func persistedCustomDayWidthSuppressesSpanInjection() {
        // H1 定案：载入路径不再让 custom 与 span 并存——有自定义日宽时不注入跨度
        // （与 setCustomDayWidth 动作同口径）。起点仍锚今天：呈现层非 fit 路径的默认起点是今天。
        let defaults = makeDefaults("customoverspan")
        let current = """
        {
          "schema": \(WorkspaceStore.currentPreferencesSchema),
          "outlineWidth": 600,
          "outlineVisible": true,
          "expandedTaskIDs": [],
          "zoom": "week",
          "usesFitZoom": false,
          "customDayWidth": 20,
          "inspectorWidth": 320,
          "inspectorTab": "inspector"
        }
        """
        defaults.set(Data(current.utf8), forKey: WorkspaceStore.preferencesKey)

        let store = WorkspaceStore(defaults: defaults, seedsDemoData: true)
        #expect(store.viewState.customDayWidth == 20)
        #expect(store.viewState.windowSpanDays == nil, "有自定义日宽时不得注入跨度")

        let today = calendar.startOfDay(for: Date())
        store.setViewport(canvasWidth: 518, canvasHeight: 640)

        let gantt = store.snapshot.gantt
        #expect(gantt.dayWidth == 20)
        #expect(store.snapshot.statusBar.zoom.preset == .custom)
        #expect(gantt.windowStart == today, "自定义日宽路径的默认起点是今天，不回到内容起点")
    }

    @Test func panningThenChoosingPresetKeepsPannedStart() {
        let store = makeStore("panThenZoom")
        store.setViewport(canvasWidth: 518, canvasHeight: 640)
        let today = calendar.startOfDay(for: Date())
        store.panWindow(byDays: 2)
        #expect(
            calendar.dateComponents([.day], from: store.snapshot.gantt.windowStart, to: today).day == 2,
            "前置条件：已向左平移到 2 天前"
        )

        store.dispatch(.setZoom(.week))

        #expect(store.viewState.windowSpanDays == nil, "选档位应退出跨度")
        #expect(
            calendar.dateComponents([.day], from: store.snapshot.gantt.windowStart, to: today).day == 2,
            "setZoom 不清 windowStart：平移后的起点保留"
        )
        // 起点已固化进状态（不是"因为 nil 才回落到今天"）：用户平移过的位置不被离开跨度覆盖。
        #expect(
            calendar.dateComponents([.day], from: store.viewState.windowStart ?? Date.distantPast, to: today).day == 2
        )
        #expect(store.snapshot.gantt.dayWidth == GanttZoom.week.dayWidth)
    }

    /// 离开跨度的那一刻把当前可见起点固化下来（H1 口径 2）：
    /// 「启动(跨度, 今天) → 点日档位」不能跳回项目起点——此前 windowStart 为 nil，
    /// 退出跨度后预设档位按内容起点渲染，用户会觉得画面被一下拽回几个月前。
    @Test func choosingPresetAfterStartupKeepsTodayAnchor() {
        let store = makeStore("startupThenZoom")
        store.setViewport(canvasWidth: 518, canvasHeight: 640)
        let today = calendar.startOfDay(for: Date())
        #expect(store.snapshot.gantt.windowStart == today, "前置条件：启动窗口锚定今天")

        store.dispatch(.setZoom(.day))

        let gantt = store.snapshot.gantt
        #expect(store.viewState.windowSpanDays == nil, "选档位应退出跨度")
        #expect(gantt.windowStart == today, "离开跨度时固化起点：仍是今天，不跳回项目起点")
        #expect(gantt.dayWidth == GanttZoom.day.dayWidth)
        // 固化进状态，而不是靠"nil 回落"凑巧相等：换个项目/重算都不该再变。
        #expect(store.viewState.windowStart == today)
    }

    /// 口径 2 的另两个入口：从跨度态拖滑杆 / 步进日宽，同样把起点留在今天。
    /// 三个入口（setZoom / setCustomDayWidth / nudge）实现相同但路径不同，各钉一条。
    @Test func choosingCustomDayWidthAfterStartupKeepsTodayAnchor() {
        let store = makeStore("startupThenCustom")
        store.setViewport(canvasWidth: 518, canvasHeight: 640)
        let today = calendar.startOfDay(for: Date())

        store.dispatch(.setCustomDayWidth(20))

        #expect(store.viewState.windowSpanDays == nil, "设自定义日宽应退出跨度")
        #expect(store.viewState.customDayWidth == 20)
        #expect(store.viewState.windowStart == today, "离开跨度时固化起点：今天")
        #expect(store.snapshot.gantt.windowStart == today)
        #expect(store.snapshot.statusBar.zoom.preset == .custom)
    }

    @Test func nudgingDayWidthAfterStartupKeepsTodayAnchor() {
        let store = makeStore("startupThenNudge")
        store.setViewport(canvasWidth: 518, canvasHeight: 640)
        let today = calendar.startOfDay(for: Date())
        let spanDayWidth = 518.0 / Double(Self.spanDays)

        store.dispatch(.nudgeCustomDayWidth(by: 1))

        #expect(store.viewState.windowSpanDays == nil, "步进日宽应退出跨度")
        // 基准是跨度态的生效日宽（518 / 跨度），不是档位默认宽度。
        #expect(store.viewState.customDayWidth == ((spanDayWidth + 1) * 10).rounded() / 10)
        #expect(store.viewState.windowStart == today, "离开跨度时固化起点：今天")
        #expect(store.snapshot.statusBar.zoom.preset == .custom)
    }

    /// **反例**：非跨度态（custom / preset）反复点档位**不得**固化 windowStart。
    ///
    /// 固化只发生在"离开跨度"这一转换上；若无条件固化，预设档位就会被钉在今天，
    /// A7「预设按内容起点定位」立刻失效。这条用例是防止将来把固化改成无条件的守卫。
    @Test func presetChoicesOutsideSpanDoNotFreezeStart() throws {
        // 用带 custom 的 v2 偏好进入非跨度态：此时 windowStart 恒为 nil（不回放）。
        let defaults = makeDefaults("presetNoFreeze")
        let current = """
        {
          "schema": \(WorkspaceStore.currentPreferencesSchema),
          "outlineWidth": 600,
          "outlineVisible": true,
          "expandedTaskIDs": [],
          "zoom": "week",
          "usesFitZoom": false,
          "customDayWidth": 20,
          "inspectorWidth": 320,
          "inspectorTab": "inspector"
        }
        """
        defaults.set(Data(current.utf8), forKey: WorkspaceStore.preferencesKey)

        let store = WorkspaceStore(defaults: defaults, seedsDemoData: true)
        #expect(store.viewState.windowStart == nil, "前置条件：非跨度态起点未固化")
        let contentStart = try #require(store.snapshot.gantt.contentStart)

        store.dispatch(.setZoom(.week))
        #expect(store.viewState.windowStart == nil, "非跨度态点档位不得固化起点")
        store.dispatch(.setZoom(.day))
        #expect(store.viewState.windowStart == nil, "反复点档位仍不得固化")

        // 预设档位仍按内容起点定位（不是今天）——A7 依赖这条。
        #expect(store.snapshot.gantt.windowStart == contentStart)
    }

    // MARK: - C6 跨度态调日宽 ⇒ 转到自定义并退出跨度

    @Test func nudgingDayWidthLeavesSpanModeForCustom() {
        let store = makeStore("nudge")
        store.setViewport(canvasWidth: 518, canvasHeight: 640)
        #expect(
            store.snapshot.gantt.dayWidth == 518.0 / Double(Self.spanDays),
            "前置条件：跨度日宽 = 画布宽 / 跨度"
        )

        store.dispatch(.nudgeCustomDayWidth(by: 1))

        // 基准是生效日宽（74.0）而不是档位默认（12）：跨度态步进必须从这里接上。
        #expect(store.viewState.customDayWidth == 75.0)
        #expect(store.viewState.windowSpanDays == nil, "自定义日宽优先，跨度模式退出")
        #expect(store.viewState.usesFitZoom == false)
        #expect(store.snapshot.statusBar.zoom.preset == .custom)
        #expect(store.snapshot.gantt.dayWidth == 75.0)
    }
}
