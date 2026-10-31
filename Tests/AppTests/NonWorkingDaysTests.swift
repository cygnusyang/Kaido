import Foundation
import Testing
import ZenoCommands
import ZenoCore
import ZenoPresentation
@testable import ZenoMacApp

/// 非工作日着色开关（F-14-14 / #10）：默认一周 7 天不标灰，打开后才画周末带，
/// 且选择作为应用级视图偏好持久化（换项目 / 重启保留）。
@MainActor
@Suite("非工作日着色")
struct NonWorkingDaysTests {

    private func makeStore() -> WorkspaceStore {
        let suite = "zeno.apptests.nonworking.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return WorkspaceStore(
            defaults: defaults,
            seedsDemoData: true,
            projectLoader: { try ZenoFile.read(from: $0) }
        )
    }

    @Test func bandsAreOffByDefault() {
        let store = makeStore()
        #expect(store.viewState.showsNonWorkingDays == false)
        #expect(store.snapshot.gantt.bands.isEmpty, "默认按日历天排期，一周 7 天，不画非工作带")
    }

    @Test func togglingShowsWeekendBands() {
        let store = makeStore()
        let calendar = Calendar.current
        store.dispatch(.toggleNonWorkingDays)

        #expect(store.viewState.showsNonWorkingDays)
        #expect(!store.snapshot.gantt.bands.isEmpty, "打开开关后应画出非工作带")

        // 带子必须落在周六或周日。
        let start = store.snapshot.gantt.windowStart
        let dayWidth = store.snapshot.gantt.dayWidth
        for band in store.snapshot.gantt.bands {
            let dayOffset = Int((band.x / dayWidth).rounded())
            let day = calendar.date(byAdding: .day, value: dayOffset, to: start)!
            let weekday = calendar.component(.weekday, from: day)
            #expect(weekday == 1 || weekday == 7, "非工作带应落在周末，实际 weekday=\(weekday)")
        }
    }

    @Test func togglingAgainHidesThem() {
        let store = makeStore()
        store.dispatch(.toggleNonWorkingDays)
        store.dispatch(.toggleNonWorkingDays)
        #expect(store.viewState.showsNonWorkingDays == false)
        #expect(store.snapshot.gantt.bands.isEmpty)
    }

    @Test func choicePersistsAcrossStoreInstances() {
        let suite = "zeno.apptests.nonworking.persist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let loader: @Sendable (URL) throws -> DecodedProject = { try ZenoFile.read(from: $0) }

        let first = WorkspaceStore(defaults: defaults, seedsDemoData: true, projectLoader: loader)
        first.dispatch(.toggleNonWorkingDays)

        let second = WorkspaceStore(defaults: defaults, seedsDemoData: true, projectLoader: loader)
        #expect(second.viewState.showsNonWorkingDays, "视图偏好应跨进程保留")
        #expect(!second.snapshot.gantt.bands.isEmpty)
    }
}
