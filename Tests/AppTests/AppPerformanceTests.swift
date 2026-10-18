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

    @Test func thousandTaskActionsMeetBudget() throws {
        let fixture = try makeFixture()
        let store = fixture.store

        let selectMS = milliseconds {
            store.dispatch(.select(fixture.leafIDs[500]))
        }
        #expect(selectMS < 100, "1000 任务选择耗时 \(selectMS) ms")

        let collapseMS = milliseconds {
            store.dispatch(.toggleExpanded(fixture.groupIDs[50]))
        }
        #expect(collapseMS < 100, "1000 任务展开/收合耗时 \(collapseMS) ms")

        let zoomMS = milliseconds {
            store.dispatch(.setZoom(.day))
        }
        #expect(zoomMS < 100, "1000 任务缩放耗时 \(zoomMS) ms")
    }

    @Test func scheduleRecomputeMeetsBudget() throws {
        let fixture = try makeFixture()
        let store = fixture.store

        let elapsed = milliseconds {
            store.dispatch(.setDuration(fixture.leafIDs[0], 3))
        }
        #expect(elapsed < 1000, "1000 任务排期重算耗时 \(elapsed) ms")
        #expect(store.alertMessage == nil)
    }
}
