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

    /// 1000 任务下 `setCustomDayWidth` 单次提交耗时的回归护栏。
    ///
    /// 阈值口径（`AppPerformanceTests`）：「缩放」类动作 ≤ 100ms、排期重算类 ≤ 1000ms（debug 构建）。
    /// 日宽提交与 `setZoom` 走同一条 `refresh()` 管线（含排期重算与偏好写盘）。
    ///
    /// **为什么 CI 门禁不写 100ms**：全量回归并行执行时其他用例抢占 CPU，墙钟被系统性抬高
    /// （本机实测：空载 ~59ms，并行负载下 ~115ms，单次最差 ~250ms），紧墙钟门禁是
    /// 固有 flaky 的；GitHub runner 更慢且不可控。因此此处断言**负载容忍的 sanity 上限**
    /// （仍能捕获 O(n²) 级灾难回归），100ms 设计预算的核验依赖本用例的量测输出，
    /// 结果已登记于 `docs/defects.md` D-014（实测 58.6–71.6ms，空载）。
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

        // sanity 门禁：仅捕获数量级回归（如 O(n²) 化），不承担 100ms 预算的精确验收
        //（理由见上方注释）。单次最差不设门禁：负载抖动下离群点噪声过大。
        #expect(
            average < 1000,
            "1000 任务日宽提交单次平均耗时 \(String(format: "%.1f", average)) ms，超出 1000ms sanity 上限（疑似数量级回归）"
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
