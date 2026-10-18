import Foundation
import Testing
@testable import KairoCore

/// 演示数据契约：应用首启动依赖这份数据，时间线必须锚定到当前周。
struct SeedDataTests {
    @Test func demoProjectSeedsTenTasks() {
        #expect(SeedData.makeProject().tasks.count == 10)
    }

    @Test func demoProjectAnchorsTimelineNearToday() throws {
        let project = SeedData.makeProject()
        let start = try #require(project.metadata.projectStart)
        let end = try #require(project.metadata.projectEnd)

        #expect(end > start)
        // 排期引擎在无项目起点时从 1970 纪元起算（D-002）。
        #expect(start.timeIntervalSince1970 > 1_000_000_000)
        #expect(abs(start.timeIntervalSinceNow) < 7 * 86_400)
    }
}
