import Foundation
import Testing
import KairoCore
@testable import KairoMacApp

/// 应用层性能预算（计划 §5 第 10 条）：1000 任务、50 条依赖。
/// 选择/展开/缩放 ≤ 100ms；排期重算 ≤ 1s。
@MainActor
@Suite("应用性能")
struct AppPerformanceTests {
    private struct Fixture {
        var store: WorkspaceStore
        var groupIDs: [UUID]
        var leafIDs: [UUID]
    }

    private func makeStore() -> WorkspaceStore {
        let suite = "kairo.apptests.perf.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return WorkspaceStore(defaults: defaults)
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kairo-perf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("perf.kairo")

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let project = Project()
        project.metadata.title = "性能项目"
        project.metadata.projectStart = start
        project.metadata.projectEnd = calendar.date(byAdding: .day, value: 90, to: start)

        var groupIDs: [UUID] = []
        var leafIDs: [UUID] = []
        for groupIndex in 0..<100 {
            let group = TaskItem(
                title: "群组 \(groupIndex)",
                startDate: start,
                kind: .group
            )
            groupIDs.append(group.id)
            project.add(group)
            for childIndex in 0..<9 {
                let dayOffset = (groupIndex + childIndex) % 30
                var dependencies: [TaskDependency] = []
                if let previous = leafIDs.last, leafIDs.count <= 50 {
                    dependencies = [TaskDependency(predecessorID: previous)]
                }
                let leaf = TaskItem(
                    title: "任务 \(groupIndex)-\(childIndex)",
                    startDate: calendar.date(byAdding: .day, value: dayOffset, to: start),
                    parentID: group.id,
                    durationDays: 1,
                    dependencies: dependencies
                )
                leafIDs.append(leaf.id)
                project.add(leaf)
            }
        }

        try KairoFile.save(project, to: url)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = makeStore()
        store.open(url: url)
        #expect(store.alertMessage == nil)
        #expect(store.snapshot.outline.rows.count == 1000)
        return Fixture(store: store, groupIDs: groupIDs, leafIDs: leafIDs)
    }

    private func milliseconds(_ block: () -> Void) -> Double {
        let started = Date()
        block()
        return Date().timeIntervalSince(started) * 1000
    }

    /// 横向翻窗的单帧预算（ms）：release 按 60Hz 帧预算，debug 按同口径留 3 倍余量。
    static var panFrameBudgetMilliseconds: Double {
        #if DEBUG
        return 50
        #else
        return 16.7
        #endif
    }

    static var panFrameBudgetLabel: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    /// 1000 任务交互动作的性能护栏。
    ///
    /// 设计预算（debug 构建）：选择 / 展开 / 缩放类 ≤ 100ms。**CI 门禁不写 100ms**：
    /// 全量回归并行执行时其他用例抢占 CPU，墙钟被系统性抬高（空载 ~30–60ms 的动作
    /// 在负载下实测可达 ~115ms），紧墙钟门禁固有 flaky，会随机炸发版流水线；
    /// GitHub runner 更慢且不可控。此处断言**负载容忍的 sanity 上限**（捕获 O(n²) 级
    /// 数量级回归），各动作的空载量测值已随历史版本记录。
    @Test func thousandTaskActionsMeetBudget() throws {
        let fixture = try makeFixture()
        let store = fixture.store

        let selectMS = milliseconds {
            store.dispatch(.select(fixture.leafIDs[500]))
        }
        let collapseMS = milliseconds {
            store.dispatch(.toggleExpanded(fixture.groupIDs[50]))
        }

        let zoomMS = milliseconds {
            store.dispatch(.setZoom(.day))
        }
        // 实测值随历史版本记录（docs/perf-1.0.md）：门禁是 sanity 上限，预算核验看这里的数字。
        print(String(
            format: "[app-perf] 1000 任务交互（ms）：选择 %.1f；展开/收合 %.1f；缩放 %.1f",
            selectMS, collapseMS, zoomMS
        ))
        #expect(selectMS < 1000, "1000 任务选择耗时 \(selectMS) ms（超出 sanity 上限，疑似数量级回归）")
        #expect(collapseMS < 1000, "1000 任务展开/收合耗时 \(collapseMS) ms（超出 sanity 上限，疑似数量级回归）")
        #expect(zoomMS < 1000, "1000 任务缩放耗时 \(zoomMS) ms（超出 sanity 上限，疑似数量级回归）")
    }

    /// 1000 行甘特「横向翻页」的单次刷新耗时 —— 滚动帧预算的直接证据。
    ///
    /// 横向滚动每来一帧就翻一次窗（v1.3.7 起亚日精度，不再「攒满一天才提交」），
    /// 每次翻窗只重建甘特与状态栏，复用大纲与检查器（D-038 / `RefreshScope.windowPan`）。
    /// 所以这条单帧预算同时也是「连续滚动不掉帧」的证据：一帧一次提交，1 次 ≤ 1 帧。
    /// 60Hz 下单帧预算 16.7ms（10-multi-baseline-gantt §9「滚动单帧 CPU < 16ms」），
    /// 因此这里直接按帧预算门禁：release ≤ 16.7ms；debug 另有 3 倍余量（≤ 50ms），
    /// 两档都写，避免只盯 release 让本地日常回归失去意义、或只盯 debug 让门禁失真。
    @Test func ganttPanStepStaysWithinSanityCeilingOnThousandRows() throws {
        let fixture = try makeFixture()
        let store = fixture.store
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())

        // 预热：首轮含惰性初始化成本，不计入统计。
        store.dispatch(.panWindow(to: start))

        var samples: [Double] = []
        for offset in 1...10 {
            let target = calendar.date(byAdding: .day, value: offset, to: start) ?? start
            let elapsed = milliseconds {
                store.dispatch(.panWindow(to: target))
            }
            samples.append(elapsed)
        }

        let average = samples.reduce(0, +) / Double(samples.count)
        let worst = samples.max() ?? 0
        print(
            "[app-perf] 1000 行横向翻窗（ms）："
            + samples.map { String(format: "%.1f", $0) }.joined(separator: ", ")
            + "；单次平均 \(String(format: "%.1f", average))；单次最差 \(String(format: "%.1f", worst))"
        )
        #expect(store.snapshot.outline.rows.count == 1000)
        // 单帧预算（release 16.7ms / debug 50ms）：取平均而不是最差，最差会被并行回归的
        // CPU 抢占偶然抬高；平均仍能捕获「退回整表 refresh」这类数量级回退（30ms+）。
        let budget = Self.panFrameBudgetMilliseconds
        #expect(average <= budget, "1000 行横向翻窗单次平均 \(String(format: "%.1f", average)) ms，超出 \(Self.panFrameBudgetLabel) 单帧预算 \(budget) ms")
    }

    @Test func scheduleRecomputeMeetsBudget() throws {
        let fixture = try makeFixture()
        let store = fixture.store

        let elapsed = milliseconds {
            store.dispatch(.setDuration(fixture.leafIDs[0], 3))
        }
        print(String(format: "[app-perf] 1000 任务排期重算（ms）：%.1f", elapsed))
        #expect(elapsed < 1000, "1000 任务排期重算耗时 \(elapsed) ms")
        #expect(store.alertMessage == nil)
    }
}
