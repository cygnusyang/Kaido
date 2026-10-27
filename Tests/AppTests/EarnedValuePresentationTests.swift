import Foundation
import Testing
import KairoCore
import KairoPresentation
@testable import KairoMacApp

// v1.3 挣值展示（docs/features/17-evm-status-date.md §3 / §5）。
//
// 判据集中在快照与行集两层：视图只排版，读数与「显示不显示数字」都由
// `EarnedValueRows` 决定，因此不渲染界面也能锁死两条硬要求——
// 「SPI 无计划价值时显示占位符，绝不出 0」与「CPI / CV 恒为禁用态且不给任何数字」。

@MainActor
@Suite("挣值展示（v1.3）")
struct EarnedValuePresentationTests {

    // MARK: - 夹具

    /// 夹具时区固定 UTC：期望值写死，不随主机时区漂移。
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: dayOfMonth))!
    }

    /// 本机日历下的某一天零点：应用层（`WorkspaceStore`）的数据日期按本机时区归一，
    /// 撤销栈断言必须用同一把尺子，否则 `+08:00` 主机会把 UTC 零点读成前一天。
    private func localDay(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth))!
        return CalendarDayMath.startOfDay(date, calendar: calendar)
    }

    /// 一条 40 小时、跨 5 个工作日的任务：10-05（周一）→ 10-12（右端开区间）。
    private func task(_ id: UUID) -> TaskItem {
        TaskItem(id: id, title: "任务", effortHours: 40, durationDays: 5, progress: 0.5)
    }

    private func scheduled(_ id: UUID) -> ScheduledTask {
        let start = day(2026, 10, 5)
        let finish = day(2026, 10, 12)
        return ScheduledTask(
            taskID: id,
            durationDays: 5,
            earliestStart: start,
            earliestFinish: finish,
            latestStart: start,
            latestFinish: finish,
            scheduledStart: start,
            scheduledFinish: finish,
            totalSlackDays: 0,
            freeSlackDays: 0
        )
    }

    /// 五天工作周 + 8 小时/天：10-05 → 10-07 是 2 个工作日，
    /// 故 PV = 40 × 2/5 = 16、EV = 40 × 0.5 = 20、SV = +4、SPI = 1.25。
    ///
    /// 数据日期走 `setStatusDate(_:calendar:)`：`init(statusDate:)` 按本机时区归一，
    /// 拿 UTC 构造的日期直接塞进去会落到前一天，夹具必须显式给出同一本日历。
    private func metadata(statusDate: Date?) -> ProjectMetadata {
        var metadata = ProjectMetadata(
            title: "项目",
            calendar: WorkCalendar(workingWeekdays: WorkCalendar.mondayToFriday, hoursPerDay: 8)
        )
        metadata.setStatusDate(statusDate, calendar: utc)
        return metadata
    }

    private func projectInspector(statusDate: Date?, now: Date) throws -> ProjectInspector {
        let id = UUID()
        let state = ProjectState(metadata: metadata(statusDate: statusDate), tasks: [task(id)], resources: [])
        let schedule = ScheduleResult(
            tasks: [scheduled(id)],
            projectStart: day(2026, 10, 5),
            projectEnd: day(2026, 10, 12)
        )
        let snapshot = WorkspacePresenter.make(
            state: state,
            schedule: schedule,
            violations: [],
            viewState: WorkspaceViewState(),
            viewport: WorkspaceViewport(canvasWidth: 800, canvasHeight: 600),
            calendar: utc,
            locale: Locale(identifier: "en_US"),
            now: now
        )
        guard case .project(let inspector) = snapshot.inspector.content else {
            throw TestFailure.projectInspectorUnavailable
        }
        return inspector
    }

    private enum TestFailure: Error {
        case projectInspectorUnavailable
    }

    private func row(_ rows: [EarnedValueRows.Row], _ key: String) throws -> EarnedValueRows.Row {
        try #require(rows.first { $0.labelKey == key }, "缺少行：\(key)")
    }

    // MARK: - 快照读数

    /// 项目摘要带 SPI 与 SV（小时）：数值与计算层同源，行集把它们排出来。
    @Test func summaryCarriesSpiAndScheduleVariance() throws {
        let inspector = try projectInspector(statusDate: day(2026, 10, 7), now: day(2026, 11, 20))
        let summary = try #require(inspector.earnedValue)

        #expect(summary.isStatusDateFixed)
        #expect(summary.statusDate == day(2026, 10, 7))
        #expect(abs(summary.plannedValue - 16) < 1e-9)
        #expect(abs(summary.earnedValue - 20) < 1e-9)
        #expect(abs(summary.scheduleVariance - 4) < 1e-9)
        #expect(abs((summary.schedulePerformanceIndex ?? .nan) - 1.25) < 1e-9)

        let rows = EarnedValueRows.rows(for: summary)
        let spi = try row(rows, "inspector.evm.spi")
        let sv = try row(rows, "inspector.evm.sv")
        #expect(spi.value == "1.25")
        #expect(spi.isDisabled == false)
        #expect(spi.noteKey == nil)
        #expect(sv.value == "+4", "正的 SV 补加号：方向由符号表达")
        #expect(sv.isDisabled == false)
    }

    /// 数据日期早于计划开始：ΣPV = 0，SPI 无定义 → 占位符 + 原因，**绝不写 0**。
    @Test func missingPlannedValueShowsPlaceholderAndReason() throws {
        let inspector = try projectInspector(statusDate: day(2026, 9, 1), now: day(2026, 9, 1))
        let summary = try #require(inspector.earnedValue)
        #expect(summary.schedulePerformanceIndex == nil)
        #expect(abs(summary.plannedValue) < 1e-9)

        let rows = EarnedValueRows.rows(for: summary)
        let spi = try row(rows, "inspector.evm.spi")
        let sv = try row(rows, "inspector.evm.sv")
        #expect(spi.value == Display.placeholder)
        #expect(spi.value != "0.00")
        #expect(spi.noteKey == "inspector.evm.spi.no_planned_value")
        #expect(spi.noteFallback?.isEmpty == false)
        #expect(sv.value == Display.placeholder, "没有计划价值时 SV 同样不给数字")
    }

    /// CPI / CV 恒为禁用态：没有费率与实际成本，一个数字都不能给。
    @Test func costRowsAreDisabledAndCarryNoNumbers() {
        let rows = EarnedValueRows.costRows()
        #expect(rows.map(\.labelKey) == ["inspector.evm.cpi", "inspector.evm.cv"])
        #expect(rows.allSatisfy { $0.isDisabled })
        #expect(rows.allSatisfy { $0.value == nil })
        #expect(EarnedValueRows.costDisabledNote.key == "inspector.evm.cost.disabled")
        #expect(EarnedValueRows.costDisabledNote.fallback.isEmpty == false)
    }

    /// §5 的两句已知局限必须随块呈现，原文不得改写。
    @Test func limitationsAreAlwaysPresent() {
        let limitations = EarnedValueRows.limitations
        #expect(limitations.count == 2)
        #expect(limitations.map(\.key) == [
            "inspector.evm.limit.spi_end",
            "inspector.evm.limit.effort_profile",
        ])
    }

    // MARK: - 数据日期

    /// 固定数据日期后，同一次计算与「今天」无关：换 `now` 快照读数逐字段相等。
    @Test func fixedStatusDateIsReproducible() throws {
        let fixed = day(2026, 10, 7)
        let first = try #require(try projectInspector(statusDate: fixed, now: day(2026, 10, 7)).earnedValue)
        let later = try #require(try projectInspector(statusDate: fixed, now: day(2026, 11, 20)).earnedValue)
        #expect(first == later, "固定数据日期的报告必须可复现")
    }

    /// 未固定时按当天算：状态标为未固定，换一天读数就变（界面据此提示不可复现）。
    @Test func unfixedStatusDateFollowsToday() throws {
        let today = try #require(try projectInspector(statusDate: nil, now: day(2026, 10, 7)).earnedValue)
        #expect(today.isStatusDateFixed == false)
        #expect(today.statusDate == day(2026, 10, 7))

        let rows = EarnedValueRows.rows(for: today)
        #expect(try row(rows, "inspector.evm.status_date").noteKey == "inspector.evm.status_date.unfixed")

        let tomorrow = try #require(try projectInspector(statusDate: nil, now: day(2026, 10, 9)).earnedValue)
        #expect(tomorrow.statusDate == day(2026, 10, 9))
        #expect(tomorrow.scheduleVariance != today.scheduleVariance)
    }

    @Test func fixedStatusDateRowSaysReproducible() throws {
        let summary = try #require(
            try projectInspector(statusDate: day(2026, 10, 7), now: day(2026, 10, 7)).earnedValue
        )
        let rows = EarnedValueRows.rows(for: summary)
        #expect(try row(rows, "inspector.evm.status_date").value == Display.date(day(2026, 10, 7)))
        #expect(try row(rows, "inspector.evm.status_date").noteKey == "inspector.evm.status_date.fixed")
    }

    // MARK: - 应用层接线

    private func makeStore() -> WorkspaceStore {
        let suite = "kairo.apptests.evm.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return WorkspaceStore(defaults: defaults, seedsDemoData: true)
    }

    private func projectContent(_ store: WorkspaceStore) throws -> ProjectInspector {
        store.dispatch(.select(nil))
        guard case .project(let inspector) = store.snapshot.inspector.content else {
            throw TestFailure.projectInspectorUnavailable
        }
        return inspector
    }

    /// 设置数据日期：落库、标记已固定、进撤销栈且一步可回退。
    @Test func settingStatusDateIsUndoableInOneStep() throws {
        let store = makeStore()
        #expect(store.statusDate == nil)
        let depthBefore = store.undoDepthForTesting

        store.dispatch(.setStatusDate(localDay(2026, 10, 7)))
        #expect(store.statusDate == localDay(2026, 10, 7))
        #expect(store.hasUnsavedChanges, "数据日期是项目数据，必须置脏")
        #expect(store.undoDepthForTesting == depthBefore + 1)

        let fixed = try #require(try projectContent(store).earnedValue)
        #expect(fixed.isStatusDateFixed)
        #expect(fixed.statusDate == localDay(2026, 10, 7))

        store.dispatch(.undo)
        #expect(store.statusDate == nil, "一步撤销回到「未固定」")
        #expect(try projectContent(store).earnedValue?.isStatusDateFixed == false)
    }

    /// 改回「今天（未固定）」：清空字段，报告重新跟当天走。
    @Test func clearingStatusDateReturnsToToday() throws {
        let store = makeStore()
        store.dispatch(.setStatusDate(localDay(2026, 10, 7)))
        store.dispatch(.setStatusDate(nil))
        #expect(store.statusDate == nil)
        #expect(try projectContent(store).earnedValue?.isStatusDateFixed == false)
    }

    /// 同一天重复提交不留空撤销步（面板每敲一次都在提交）。
    @Test func settingTheSameDayTwiceDoesNotPushUndo() {
        let store = makeStore()
        store.dispatch(.setStatusDate(localDay(2026, 10, 7)))
        let depth = store.undoDepthForTesting
        store.dispatch(.setStatusDate(localDay(2026, 10, 7)))
        #expect(store.undoDepthForTesting == depth)
    }

    // MARK: - 文案登记

    /// 挣值块用到的键全部在中英两侧有译文；两句局限的原文逐字锁定。
    @Test func everyKeyExistsInCatalog() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Apps/macos/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(object["strings"] as? [String: Any])

        func localization(_ key: String, _ language: String) throws -> String {
            let entry = try #require(strings[key] as? [String: Any], "缺少键：\(key)")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            let unit = try #require(
                (localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any],
                "缺少 \(language) 译文：\(key)"
            )
            return try #require(unit["value"] as? String)
        }

        let summary = try #require(
            try projectInspector(statusDate: day(2026, 9, 1), now: day(2026, 9, 1)).earnedValue
        )
        var keys = EarnedValueRows.rows(for: summary).flatMap { row in
            [row.labelKey, row.noteKey].compactMap { $0 }
        }
        keys += EarnedValueRows.costRows().map(\.labelKey)
        keys.append(EarnedValueRows.costDisabledNote.key)
        keys += EarnedValueRows.limitations.map(\.key)
        keys += [
            "inspector.section.earned_value",
            "panel.settings.section.status_date",
            "panel.settings.status_date.today",
            "panel.settings.status_date.fixed",
            "panel.settings.status_date.unfixed_note",
            "panel.settings.status_date.fixed_note",
        ]

        for key in Set(keys) {
            #expect(try localization(key, "en").isEmpty == false, "英文为空：\(key)")
            #expect(try localization(key, "zh-Hans").isEmpty == false, "中文为空：\(key)")
        }

        #expect(try localization("inspector.evm.limit.spi_end", "zh-Hans")
                == "SPI 在项目末期会回归 1，只适合观察进行中的趋势")
        #expect(try localization("inspector.evm.limit.effort_profile", "zh-Hans")
                == "工时口径下，工作量前重后轻时早期 SPI 会偏高")
        #expect(try localization("inspector.evm.cost.disabled", "zh-Hans")
                == "未启用成本与费率，无法计算成本绩效")
    }
}
