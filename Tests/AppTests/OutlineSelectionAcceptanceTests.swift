import CoreGraphics
import Foundation
import Testing
import ZenoCore
import ZenoPresentation
@testable import ZenoMacApp

// D-033 验收用例（GitHub issue #13 / docs/defects.md）。
//
// 缺陷：行整行挂 `.onDrag`（DragReorderModifier）与行 `.onTapGesture` 竞争，指针一抖
// 就变成拖拽 → 「点行选不中」；`OutlineColumnResizeHandle` 只在表头存在 → 行区域列交界
// 拖动无响应，既没调宽也没选中。
//
// 分工（避免与 `OutlineRowInteractionTests.swift` 重复维护）：
//   - `OutlineRowInteractionTests`（coder）→ 命中带几何：交界 x、带宽、不重叠、末列内缩、
//     聚焦模式无带、视口外裁剪、行节距不变；
//   - 本文件（tester）→ **行为验收**：点选与检查器联动（判据 1）、重排入口/整行拖拽已移除
//     （判据 2，源码结构守卫）、交界热区 ≥ 8pt 的口径（判据 3）、拖宽持久化（判据 4）。
//
// 可测边界（不夸大）：SwiftUI 手势与 NSCursor 无法在测试进程内注入真实事件。
// 判据 1/2 的「点击是否被拖拽接管」在本文件里由**源码结构守卫**锁：整行 `.onDrag` 必须
// 消失、`.onDrag` 只剩握把一处、行 tap 仍挂在整行容器上。真人手感与光标形态走
// docs/features/09-d033-cases.md §3 手动走查（M-01…M-10）。

@MainActor
@Suite("D-033 大纲点选与列宽调整（行为验收）")
struct OutlineSelectionAcceptanceTests {

    // MARK: - 夹具

    private func freshDefaults() -> UserDefaults {
        let suite = "zeno.apptests.d033.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeStore(
        defaults: UserDefaults? = nil,
        seedsDemoData: Bool = true
    ) -> WorkspaceStore {
        WorkspaceStore(
            defaults: defaults ?? freshDefaults(),
            seedsDemoData: seedsDemoData,
            projectLoader: { try ZenoFile.read(from: $0) }
        )
    }

    /// 视图里「点行」的等价行为：行 tap → `.select(row.id)`（整行一个入口，不按列分流）。
    private func clickRow(_ row: PlanRow, in store: WorkspaceStore) {
        store.dispatch(.select(row.id))
    }

    private func inspectorTask(_ store: WorkspaceStore) throws -> TaskInspector {
        guard case .task(let inspector) = store.snapshot.inspector.content else {
            throw TestFailure("检查器应为任务检查器，实际 \(store.snapshot.inspector.content)")
        }
        return inspector
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: - 判据 1：单击行 → 选中 + 检查器联动

    /// 判据 1：点任一行都选中该行，检查器与状态栏同步跟随（不依赖点在哪一列：
    /// 行 tap 挂在整行容器上，见 `rowTapIsStillOnWholeRowContainer`）。
    @Test func clickingAnyRowSelectsTaskAndDrivesInspector() throws {
        let store = makeStore()
        let rows = store.snapshot.outline.rows
        #expect(rows.count >= 3, "夹具应有多行")
        _ = try #require(rows.first)

        for row in rows.prefix(3) {
            clickRow(row, in: store)
            #expect(store.selection == row.id)
            #expect(store.snapshot.statusBar.selectionSummary == row.title)
            let inspector = try inspectorTask(store)
            #expect(inspector.taskID == row.id)
            #expect(inspector.title == row.title)
        }
    }

    /// 边界：群组 / 里程碑 / 子任务行都要能选中（不同 `kind`、不同深度都挂了行手势）。
    @Test func everyRowKindIsSelectable() throws {
        let store = makeStore()
        let parent = try #require(store.snapshot.outline.rows.first)
        // 种子数据可能只有普通任务：显式造一个群组行，确保不同 kind 都被覆盖。
        store.dispatch(.createTask(parentID: parent.id, kind: .group))

        let rows = store.snapshot.outline.rows
        #expect(!rows.isEmpty)
        #expect(rows.contains { $0.kind == .group }, "夹具应包含群组行")
        #expect(Set(rows.map(\.kind)).count >= 2, "夹具应包含多种行类型")

        for row in rows {
            clickRow(row, in: store)
            #expect(store.selection == row.id, "行 \(row.title)（\(row.kind)）应可选")
            #expect(try inspectorTask(store).taskID == row.id)
        }
    }

    /// 判据 1（回归）：已选中行被重复点击不丢选中 —— 用户在行上连点是常态。
    @Test func repeatedClickKeepsSelection() throws {
        let store = makeStore()
        let row = try #require(store.snapshot.outline.rows.first)

        for attempt in 1...3 {
            clickRow(row, in: store)
            #expect(store.selection == row.id, "第 \(attempt) 次点击后选中丢失")
            #expect(try inspectorTask(store).taskID == row.id)
        }
    }

    /// 判据 1：换行点选后检查器跟着换（联动双向，不是只首次生效）。
    @Test func selectingAnotherRowMovesInspector() throws {
        let store = makeStore()
        let rows = store.snapshot.outline.rows
        let first = try #require(rows.first)
        let second = try #require(rows.dropFirst().first)

        clickRow(first, in: store)
        clickRow(second, in: store)

        #expect(store.selection == second.id)
        #expect(try inspectorTask(store).taskID == second.id)
        #expect(store.snapshot.statusBar.selectionSummary == second.title)
    }

    /// 判据 1（用户场景）：选中某行后再调列宽，选中不得被清掉。
    @Test func selectionSurvivesColumnResizeCommit() throws {
        let store = makeStore()
        let row = try #require(store.snapshot.outline.rows.first)

        clickRow(row, in: store)
        store.dispatch(.setOutlineColumnWidth(.start, 140))

        #expect(store.selection == row.id, "调列宽不应清选中")
        #expect(try inspectorTask(store).taskID == row.id)
    }

    /// 负路径：选中不存在的 id 不崩，检查器给出 selectionMissing 而非残留上一选中。
    @Test func selectingUnknownTaskKeepsInspectorSafe() {
        let store = makeStore()
        store.dispatch(.select(UUID()))

        guard case .project = store.snapshot.inspector.content else {
            Issue.record("未知 id 应回落到工程检查器")
            return
        }
        #expect(store.snapshot.inspector.selectionMissing)
    }

    /// 负路径：空工程没有行可点，选中接口不应崩、检查器保持工程检查器。
    @Test func emptyProjectHasNoRowsAndStaysSafe() {
        let store = makeStore(seedsDemoData: false)
        #expect(store.snapshot.outline.rows.isEmpty)
        store.dispatch(.select(nil))
        #expect(store.selection == nil)
        guard case .project = store.snapshot.inspector.content else {
            Issue.record("空工程应为工程检查器")
            return
        }
        #expect(store.snapshot.inspector.selectionMissing == false)
    }

    /// 负路径：筛选下重排被禁用，但点选必须仍然可用（禁拖拽不得连累选中）。
    @Test func filterDisablesReorderButKeepsSelectionUsable() throws {
        let store = makeStore()
        store.dispatch(.setFilter("发布"))
        #expect(store.allowsDragReorder == false)

        let row = try #require(store.snapshot.outline.rows.first)
        clickRow(row, in: store)
        #expect(store.selection == row.id, "筛选下点行仍应选中")
        #expect(try inspectorTask(store).taskID == row.id)
    }

    // MARK: - 判据 2：重排不再是整行入口（源码结构守卫）

    /// 判据 2：整行 `.onDrag` 必须删除，`.onDrag` 只剩握把一处。
    ///
    /// SwiftUI 的拖拽会话无法在测试进程内触发，「点击被拖拽接管」只能从**挂载位置**上锁：
    /// 整行不再注册 onDrag，就不存在与行 tap 竞争的手势（issue #13 根因）。
    @Test func outlineTableNoLongerAttachesDragToWholeRow() throws {
        let source = try outlineTableSource()

        // 旧结构：整行挂 `DragReorderModifier`，其 body 对 `content` 直接 `.onDrag`。
        #expect(!source.contains(".modifier(DragReorderModifier"),
                "整行不得再挂 DragReorderModifier；重排只能从握把发起（D-033 根因）")
        #expect(!source.contains("DragReorderModifier("),
                "旧的整行拖拽 modifier 应已删除")

        // 新结构：行只剩落点（ReorderDropModifier），拖拽源在握把（OutlineReorderGrip）。
        #expect(source.contains("struct ReorderDropModifier"), "行应只保留 onDrop 落点能力")
        let grip = try #require(source.range(of: "struct OutlineReorderGrip"),
                                "重排拖拽源应是行首握把 OutlineReorderGrip")

        // 关键判据：`.onDrag` 不得出现在握把声明之前 —— 握把之前只有行/单元格，任何一处
        // 都是「整行又变成拖拽源」，会和行 tap 抢点击。
        var searchStart = source.startIndex
        var dragSites: [String.Index] = []
        while let found = source.range(of: ".onDrag", range: searchStart..<source.endIndex) {
            dragSites.append(found.lowerBound)
            searchStart = found.upperBound
        }
        #expect(!dragSites.isEmpty, "握把本身要能拖拽（.onDrag 应存在）")
        for site in dragSites {
            let lineNumber = source[source.startIndex..<site].filter { $0 == "\n" }.count + 1
            #expect(site > grip.lowerBound,
                    "第 \(lineNumber) 行的 .onDrag 位于握把之外 —— 行又被变成拖拽源，会抢走单击")
        }
    }

    /// 判据 1（入口仍在，且不按列分流）：行 tap 仍挂在整行容器上 → 点任意列都走同一入口。
    @Test func rowTapIsStillOnWholeRowContainer() throws {
        let source = try outlineTableSource()
        #expect(source.contains("dispatch(.select(row.id))"),
                "行点击入口必须保留（只允许改挂载位置，不允许移除选中）")
        #expect(source.contains(".contentShape(Rectangle())"),
                "整行需要 contentShape，否则空白列区域点不中")
        #expect(!source.contains(".onTapGesture { store.dispatch(.select(column"),
                "行 tap 不应按列分流（按列分流会重新引入「某些列点不中」）")
    }

    /// 判据 3：交界热区口径唯一 —— 表头手柄与行区域共用同一常量，且 ≥ 8pt。
    @Test func resizeHotZoneIsSharedAndWideEnough() throws {
        #expect(OutlineColumnResizeMetrics.hotZone >= 8,
                "列交界命中区须 ≥ 8pt，实际 \(OutlineColumnResizeMetrics.hotZone)")

        let source = try outlineTableSource()
        #expect(source.contains("OutlineColumnResizeMetrics.hotZone"),
                "表头与行必须引用同一热区常量，不得各留一份字面量")
        #expect(!source.contains("hotZoneWidth: CGFloat = 6"),
                "旧的 6pt 私有热区应已删除（D-033：6pt 用户对不准）")
    }

    /// 判据 4（结构守卫）：行区域调宽与表头走同一提交链路 —— 松手由 store 动作落盘。
    @Test func rowResizeCommitsThroughTheSameStoreAction() throws {
        let table = try source("Apps/macos/Sources/Workspace/Outline/OutlineTable.swift")
        let view = try source("Apps/macos/Sources/Workspace/WorkspaceView.swift")
        #expect(table.contains("onResizeEnded") || table.contains("onResizeChanged"),
                "行列表需要接收调宽回调，否则行区域拖动无提交路径")
        #expect(view.contains("commitLiveColumnResize") || view.contains(".setOutlineColumnWidth("),
                "调宽落盘必须走既有 setOutlineColumnWidth / commitLiveColumnResize 链路")
    }

    private func outlineTableSource() throws -> String {
        try source("Apps/macos/Sources/Workspace/Outline/OutlineTable.swift")
    }

    /// 读仓库内源码（结构守卫用）：路径相对仓库根，避免依赖 cwd。
    private func source(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/AppTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // 仓库根
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - 判据 4：拖宽持久化

    /// 判据 4：拖宽结果持久化到偏好域，重开（新 store 同域）仍在，且布局按覆盖值渲染。
    @Test func committedWidthPersistsAcrossStores() {
        let defaults = freshDefaults()
        let first = makeStore(defaults: defaults)
        first.dispatch(.setOutlineColumnWidth(.start, 140))
        first.dispatch(.setOutlineColumnWidth(.assignee, 200))

        let second = makeStore(defaults: defaults)
        #expect(second.viewState.outlineColumnWidths == ["start": 140, "assignee": 200])

        var overrides: [OutlineColumn: Double] = [:]
        for (raw, width) in second.viewState.outlineColumnWidths {
            guard let column = OutlineColumn(rawValue: raw) else { continue }
            overrides[column] = width
        }
        let layout = OutlineColumnLayout(
            columns: OutlineColumnPreferences.visibleColumns(
                outlineWidth: 900, hidden: [], focused: false
            ),
            totalWidth: 900,
            focused: false,
            widthOverrides: overrides
        )
        #expect(layout.width(of: .start) == 140)
        #expect(layout.width(of: .assignee) == 200)
    }

    /// 判据 4：复位（双击交界）后新 store 也不再读到覆盖值，宽度回到默认派生宽。
    @Test func resetClearsPersistedOverride() {
        let defaults = freshDefaults()
        let first = makeStore(defaults: defaults)
        first.dispatch(.setOutlineColumnWidth(.start, 140))
        first.dispatch(.setOutlineColumnWidth(.start, nil))

        let second = makeStore(defaults: defaults)
        #expect(second.viewState.outlineColumnWidths["start"] == nil)

        let layout = OutlineColumnLayout(
            columns: OutlineColumnPreferences.visibleColumns(
                outlineWidth: 900, hidden: [], focused: false
            ),
            totalWidth: 900,
            focused: false
        )
        let defaultWidth = CGFloat(OutlineColumnPreferences.defaultWidth(for: .start))
        #expect(abs(layout.width(of: .start) - defaultWidth) < 0.001,
                "复位后应回到默认派生宽 \(defaultWidth)，实际 \(layout.width(of: .start))")
    }
}
