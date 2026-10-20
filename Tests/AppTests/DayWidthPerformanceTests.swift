import Foundation
import Testing
import KairoCore
import KairoCommands
@testable import KairoMacApp

/// 日宽提交性能预算（Sprint 6 / T5 / D-014 取证）。
///
/// 口径与 `AppPerformanceTests` 保持一致：1000 任务项目、debug 构建阈值、单次动作耗时。
/// 断言写**单次平均**（非批量总耗时），并另设宽松的单次最差上限，避免平均值掩盖离群点。
///
/// 背景（D-014）：`setCustomDayWidth` 走 `WorkspaceStore.refresh()`，
/// 每次提交都会触发排期重算（`session.computeSchedule()`）与偏好写盘
/// （`savePreferences()` → UserDefaults 同步写）。本用例量测该成本，用于判断
/// Sprint 7 是否需要引入 `lastSchedule` 复用。
@MainActor
@Suite("日宽性能")
struct DayWidthPerformanceTests {
    private struct Fixture {
        var store: WorkspaceStore
        var directory: URL
        var projectURL: URL
        var suite: String

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
    }

    /// 1000 任务（100 群组 × 9 子任务）的项目，结构与 `AppPerformanceTests` 一致。
    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kairo-daywidth-perf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("perf.kairo")

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let project = Project()
        project.metadata.title = "日宽性能项目"
        project.metadata.projectStart = start
        project.metadata.projectEnd = calendar.date(byAdding: .day, value: 90, to: start)

        for groupIndex in 0..<100 {
            let group = TaskItem(
                title: "群组 \(groupIndex)",
                startDate: start,
                kind: .group
            )
            project.add(group)
            for childIndex in 0..<9 {
                let dayOffset = (groupIndex + childIndex) % 30
                let leaf = TaskItem(
                    title: "任务 \(groupIndex)-\(childIndex)",
                    startDate: calendar.date(byAdding: .day, value: dayOffset, to: start),
                    parentID: group.id,
                    durationDays: 1
                )
                project.add(leaf)
            }
        }

        try KairoFile.save(project, to: url)

        let suite = "kairo.apptests.daywidthperf.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)

        let store = WorkspaceStore(defaults: defaults)
        store.open(url: url)
        #expect(store.alertMessage == nil)
        #expect(store.snapshot.outline.rows.count == 1000, "性能夹具必须是 1000 任务")

        return Fixture(store: store, directory: directory, projectURL: url, suite: suite)
    }

    private func milliseconds(_ block: () -> Void) -> Double {
        let started = Date()
        block()
        return Date().timeIntervalSince(started) * 1000
    }

    /// 1000 任务下 `setCustomDayWidth` 单次提交耗时的预算。
    ///
    /// 阈值参照既有性能测试口径（`AppPerformanceTests`）：
    /// 「缩放」类动作 ≤ 100ms、排期重算类 ≤ 1000ms（均为 debug 构建）。
    /// 日宽提交与 `setZoom` 走同一条 `refresh()` 管线（含排期重算与偏好写盘），
    /// 因此取与缩放同一档的 100ms 作为**单次平均**上限。
    @Test func setCustomDayWidthMeetsBudgetOnThousandTaskProject() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store

        // 预热：首次提交含冷启动成本（惰性初始化、偏好域建立），不计入统计。
        store.dispatch(.setCustomDayWidth(20))

        // 连续提交不同日宽：模拟拖动过程中的多次节流提交。
        let widths: [Double] = [21, 22, 23, 24, 25, 26, 27, 28, 29, 30]
        var samples: [Double] = []
        for width in widths {
            let elapsed = milliseconds {
                store.dispatch(.setCustomDayWidth(width))
            }
            samples.append(elapsed)
        }

        let average = samples.reduce(0, +) / Double(samples.count)
        let worst = samples.max() ?? 0
        print(
            "[day-width-perf] 1000 任务 setCustomDayWidth 单次提交耗时（ms）："
            + samples.map { String(format: "%.1f", $0) }.joined(separator: ", ")
            + "；单次平均 \(String(format: "%.1f", average))；单次最差 \(String(format: "%.1f", worst))"
        )

        // 断言写单次平均，不写批量总耗时。
        #expect(
            average < 100,
            "1000 任务日宽提交单次平均耗时 \(String(format: "%.1f", average)) ms，超出 100ms 预算"
        )
        // 单次最差值另设宽松上限：平均值不得掩盖离群点（偶发抖动）。
        #expect(
            worst < 500,
            "1000 任务日宽提交单次最差耗时 \(String(format: "%.1f", worst)) ms，超出 500ms 上限"
        )

        // 结果必须真的生效（提交确实改变了渲染输入），否则测的是一个空动作。
        #expect(store.viewState.customDayWidth == 30)
        #expect(store.snapshot.gantt.dayWidth == 30)
    }

    /// 隔离量测「排期重算」本身的耗时（D-014 的优化靶点）。
    ///
    /// 日宽变更**不影响**任务排期（只影响画布布局），但 `WorkspaceStore.refresh()`
    /// 每次提交都会调用 `session.computeSchedule()` 重算整表排期。
    /// 本用例在同一个 1000 任务项目上单独量测排期重算耗时，
    /// 与 `setCustomDayWidthMeetsBudgetOnThousandTaskProject` 的单次平均对比，
    /// 给出「排期重算占总提交耗时多少」——这是 Sprint 7 是否值得做 `lastSchedule` 复用的判据。
    @Test func scheduleRecomputeCostIsIsolatedForDayWidthCommit() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        // 用独立会话打开同一份 1000 任务项目，单独量测排期重算。
        let session = KairoSession()
        try session.openProject(at: fixture.projectURL)

        var samples: [Double] = []
        for _ in 0..<10 {
            let elapsed = milliseconds {
                _ = try? session.computeSchedule()
            }
            samples.append(elapsed)
        }

        let average = samples.reduce(0, +) / Double(samples.count)
        print(
            "[day-width-perf] 1000 任务 computeSchedule 排期重算耗时（ms）："
            + samples.map { String(format: "%.1f", $0) }.joined(separator: ", ")
            + "；单次平均 \(String(format: "%.1f", average))"
        )

        // 排期重算是既有口径的独立预算（`scheduleRecomputeMeetsBudget` ≤ 1000ms）。
        #expect(
            average < 1000,
            "1000 任务排期重算单次平均耗时 \(String(format: "%.1f", average)) ms，超出 1000ms 预算"
        )
        // 非空校验：确实重算了排期（结果非空），否则测的是空操作。
        #expect(session.lastSchedule != nil)
    }
}
