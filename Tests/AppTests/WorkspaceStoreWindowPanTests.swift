import Foundation
import Testing
import ZenoCore
import ZenoPresentation
@testable import ZenoMacApp

// 横向翻窗增量刷新的**应用层**正确性门禁（D-038）。
//
// `WorkspaceStore.panWindow` 走 `RefreshScope.windowPan`：只重建甘特与状态栏，
// 复用大纲与检查器，且不碰 `exportState`。本套用例拿真实会话（排期缓存、基线、筛选）
// 走一遍翻窗，再强制一次全量 refresh，逐字段比对两份快照。
//
// 比性能门禁更硬：增量算错了就是错数据，所以这条先于性能成立才允许合入。

/// 固定种子 LCG：窗口序列可复现（失败时按日志里的偏移量即可重放）。
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

@MainActor
@Suite("横向翻窗增量刷新")
struct WorkspaceStoreWindowPanTests {
    private let groupCount = 100
    private let childrenPerGroup = 9
    private let baselineCount = 3

    private struct Fixture {
        var store: WorkspaceStore
        var groupIDs: [UUID]
        var leafIDs: [UUID]
        var windowStart: Date
    }

    private func makeStore() -> WorkspaceStore {
        let suite = "zeno.apptests.windowpan.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return WorkspaceStore(defaults: defaults)
    }

    /// 100 群组 × 9 子任务（展开后恰好 1000 行，含群组行的聚合口径）。
    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zeno-windowpan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("windowpan.zeno")

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let project = Project()
        project.metadata.title = "翻窗项目"
        project.metadata.projectStart = start
        project.metadata.projectEnd = calendar.date(byAdding: .day, value: 90, to: start)

        var groupIDs: [UUID] = []
        var leafIDs: [UUID] = []
        for groupIndex in 0..<groupCount {
            let group = TaskItem(title: "群组 \(groupIndex)", startDate: start, kind: .group)
            groupIDs.append(group.id)
            project.add(group)
            for childIndex in 0..<childrenPerGroup {
                let dayOffset = (groupIndex + childIndex) % 30
                let leaf = TaskItem(
                    title: "任务 \(groupIndex)-\(childIndex)",
                    startDate: calendar.date(byAdding: .day, value: dayOffset, to: start),
                    parentID: group.id,
                    durationDays: Double(childIndex % 5 + 1)
                )
                leafIDs.append(leaf.id)
                project.add(leaf)
            }
        }

        try ZenoFile.save(project, to: url)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = makeStore()
        store.open(url: url)
        #expect(store.alertMessage == nil)

        // 展开全部群组：1000 行（100 群组 + 900 子任务）。
        store.dispatch(.setExpanded(Set(groupIDs)))
        #expect(store.snapshot.outline.rows.count == groupCount + groupCount * childrenPerGroup)

        // 3 条基线并全部画在甘特上：覆盖「翻窗时基线细条随窗口平移」这条链路。
        for _ in 0..<baselineCount {
            store.dispatch(.createBaseline(nil))
        }
        let baselines = store.baselines
        #expect(baselines.count == baselineCount)
        for baseline in baselines {
            store.dispatch(.setBaselineVisible(baseline.id, true))
        }
        store.dispatch(.setBaseline(baselines.first?.id))
        #expect(store.snapshot.gantt.visibleBaselineIDs.count == baselineCount)

        // 选中 + 锁定 + 非工作日带：把「与窗口无关的视图状态」都摆上，翻窗后必须原样保留。
        store.dispatch(.select(leafIDs[500]))
        store.dispatch(.setInspectorLocked(true))
        store.dispatch(.toggleNonWorkingDays)

        let windowStart = store.snapshot.gantt.windowStart
        return Fixture(store: store, groupIDs: groupIDs, leafIDs: leafIDs, windowStart: windowStart)
    }

    /// 强制一次全量 refresh（视图状态一字不改）：拿它当增量结果的对照基线。
    private func fullRefresh(_ store: WorkspaceStore) {
        store.dispatch(.setInspectorWidth(store.viewState.inspectorWidth))
    }

    /// 5 个随机窗口：翻窗结果必须与「同一视图状态下的全量重建」逐字段相等。
    @Test func panWindowSnapshotEqualsFullRefresh() throws {
        let fixture = try makeFixture()
        let store = fixture.store
        var rng = SeededGenerator(seed: 0x5EED_0038)

        for step in 0..<5 {
            let offset = Int.random(in: -45...45, using: &rng)
            let target = Calendar.current.date(
                byAdding: .day,
                value: offset,
                to: store.viewState.windowStart ?? fixture.windowStart
            ) ?? fixture.windowStart
            let dayAtStart = Calendar.current.startOfDay(for: Date())
            store.dispatch(.panWindow(to: target))
            let incremental = store.snapshot

            fullRefresh(store)
            let full = store.snapshot
            // 两次刷新各自取 `Date()`：若这一跳恰好跨过本地零点，"今天"变了会让 todayX /
            // 逾期计数天然不同，那与增量无关。跳过该跳，不让午夜撞线变成随机红。
            if Calendar.current.startOfDay(for: Date()) != dayAtStart { continue }

            // 两次刷新各自取 `Date()`：生成时刻天然不同，其余字段必须逐位一致。
            var comparableIncremental = incremental
            var comparableFull = full
            comparableIncremental.generatedAt = .distantPast
            comparableFull.generatedAt = .distantPast

            let label = "第 \(step + 1) 跳（偏移 \(offset) 天）"
            #expect(incremental.gantt.windowStart == full.gantt.windowStart, "\(label)：窗口起点不等")
            #expect(comparableIncremental.outline == comparableFull.outline, "\(label)：大纲快照不等")
            #expect(comparableIncremental.gantt == comparableFull.gantt, "\(label)：甘特快照不等")
            #expect(comparableIncremental.inspector == comparableFull.inspector, "\(label)：检查器快照不等")
            #expect(comparableIncremental.statusBar == comparableFull.statusBar, "\(label)：状态栏快照不等")
            let equal = comparableIncremental == comparableFull
            #expect(equal, "\(label)：增量快照与全量快照不等")
        }
    }

    /// 版本兜底：内容变了但快照还没重建时，翻窗必须退化成全量重建，不能拿过期大纲凑合。
    ///
    /// 这里绕过 store 直接改会话（`sessionForTesting`），制造「会话版本领先快照」的状态——
    /// 正常路径上每次写入都会全量 refresh，因此这条防线只在异常时序下起作用，需要显式构造。
    @Test func staleSessionFallsBackToFullRefresh() throws {
        let fixture = try makeFixture()
        let store = fixture.store
        let revisionBefore = store.sessionForTesting.revision

        _ = try store.sessionForTesting.updateTask(id: fixture.leafIDs[0], title: "改名后")
        #expect(store.sessionForTesting.revision != revisionBefore)

        store.panWindow(byDays: 1)

        let row = store.snapshot.outline.rows.first { $0.id == fixture.leafIDs[0] }
        #expect(row?.title == "改名后", "会话版本领先快照时，翻窗必须走全量重建")
    }

    /// 翻窗不动项目内容：`exportState`（文件导出值快照）与选中、展开、基线选择都保持原样。
    @Test func panWindowLeavesContentAndViewStateUntouched() throws {
        let fixture = try makeFixture()
        let store = fixture.store
        let before = store.exportState
        let outlineBefore = store.snapshot.outline
        let inspectorBefore = store.snapshot.inspector
        let selectedBefore = store.viewState.selectedTaskID
        let expandedBefore = store.viewState.expandedTaskIDs
        let baselinesBefore = store.snapshot.gantt.visibleBaselineIDs
        let windowBefore = store.snapshot.gantt.windowStart

        store.panWindow(byDays: 4)

        #expect(store.exportState == before, "翻窗不得改动文件导出快照")
        #expect(store.snapshot.outline == outlineBefore, "翻窗复用大纲行")
        #expect(store.snapshot.inspector == inspectorBefore, "翻窗复用检查器")
        #expect(store.viewState.selectedTaskID == selectedBefore)
        #expect(store.viewState.expandedTaskIDs == expandedBefore)
        #expect(store.snapshot.gantt.visibleBaselineIDs == baselinesBefore)
        #expect(store.snapshot.gantt.windowStart != windowBefore, "窗口确实移动了")
    }
}
