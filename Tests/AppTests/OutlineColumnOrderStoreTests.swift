import Foundation
import Testing
import KaidoPresentation
@testable import KaidoMacApp

// v0.16「大纲列顺序」（#12）应用层接线：动作 → 视图状态 → 偏好持久化 → 快照。
//
// 锁定四件事：① 重排是纯视图偏好（不进撤销栈、不置脏）；② 拖回原位不写偏好；
// ③ 旧偏好缺字段 / 含未知列时读入不丢列；④ 默认顺序写 nil，不为「没动过」多长一个键。

@MainActor
@Suite("大纲列顺序的存储与快照（v0.16 / #12）")
struct OutlineColumnOrderStoreTests {
    private func makePreferencesDefaults() -> UserDefaults {
        let suite = "kaido.apptests.columnorder.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func writePreferences(_ json: String, to defaults: UserDefaults) {
        defaults.set(Data(json.utf8), forKey: WorkspaceStore.preferencesKey)
    }

    private func storedPreferencesJSON(_ defaults: UserDefaults) throws -> String {
        let data = try #require(defaults.data(forKey: WorkspaceStore.preferencesKey))
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 动作

    /// 重排落到状态与快照：表头/行/列宽覆盖都按列身份走，因此看列集合即可。
    @Test func reorderUpdatesStateAndSnapshot() {
        let store = WorkspaceStore(defaults: makePreferencesDefaults(), seedsDemoData: false)
        #expect(store.viewState.columnOrder == OutlineColumnPreferences.defaultOrder)

        let visible = store.snapshot.outline.columns
        let next = OutlineColumnPreferences.movedOrder(
            store.viewState.columnOrder, visible: visible,
            moving: .progress, toInsertionIndex: 0
        )
        store.dispatch(.setOutlineColumnOrder(next))

        #expect(store.viewState.columnOrder == next)
        #expect(store.snapshot.outline.columns.first == .progress, "快照列集合同步重排")
        #expect(Set(store.viewState.columnOrder) == Set(OutlineColumn.allCases), "不得丢列")
    }

    /// 视图偏好：不进撤销栈、不把项目标记为已修改。
    @Test func reorderDoesNotPushUndoOrDirtyProject() {
        let store = WorkspaceStore(defaults: makePreferencesDefaults(), seedsDemoData: false)
        let depthBefore = store.undoDepthForTesting
        let dirtyBefore = store.hasUnsavedChanges

        store.dispatch(.setOutlineColumnOrder(
            OutlineColumnPreferences.normalizedOrder([.progress, .status])
        ))

        #expect(store.undoDepthForTesting == depthBefore, "列顺序不得产生撤销点")
        #expect(store.hasUnsavedChanges == dirtyBefore, "视图偏好不得把项目标记为已修改")
    }

    /// 拖回原位不写偏好：顺序相同直接返回，JSON 逐字节不变。
    @Test func dispatchingSameOrderIsNoOp() throws {
        let defaults = makePreferencesDefaults()
        let store = WorkspaceStore(defaults: defaults, seedsDemoData: false)
        // 先经一次视图偏好变化落盘，再比较「拖回原位」前后的偏好字节。
        store.dispatch(.toggleOutlineColumn(.predecessors))
        let before = try storedPreferencesJSON(defaults)

        store.dispatch(.setOutlineColumnOrder(OutlineColumnPreferences.defaultOrder))
        #expect(try storedPreferencesJSON(defaults) == before, "未改动的顺序不该触发写入")
    }

    /// 「重置列顺序」回到默认：拖乱之后能一键还原，且隐藏状态不受影响。
    @Test func resetRestoresDefaultOrderWithoutTouchingVisibility() {
        let store = WorkspaceStore(defaults: makePreferencesDefaults(), seedsDemoData: false)
        store.dispatch(.toggleOutlineColumn(.predecessors))
        store.dispatch(.setOutlineColumnOrder(
            OutlineColumnPreferences.normalizedOrder([.progress, .assignee])
        ))
        #expect(store.viewState.columnOrder.first == .progress)

        store.dispatch(.setOutlineColumnOrder(OutlineColumnPreferences.defaultOrder))

        #expect(store.viewState.columnOrder == OutlineColumnPreferences.defaultOrder)
        #expect(store.viewState.hiddenOutlineColumns == ["predecessors"], "重置顺序不动显隐")
        #expect(!store.snapshot.outline.columns.contains(.predecessors))
    }

    // MARK: - 持久化

    /// 往返：新实例读回同一份顺序（并进入生效列集合，不只是字段回填）。
    @Test func orderRoundTripsThroughDefaults() {
        let defaults = makePreferencesDefaults()
        let first = WorkspaceStore(defaults: defaults, seedsDemoData: false)
        let reversed = Array(OutlineColumn.allCases.reversed())
        first.dispatch(.setOutlineColumnOrder(reversed))
        #expect(first.viewState.columnOrder == reversed)

        let second = WorkspaceStore(defaults: defaults, seedsDemoData: false)
        #expect(second.viewState.columnOrder == reversed)
        let expected = OutlineColumnPreferences.ordered(second.snapshot.outline.columns, by: reversed)
        #expect(second.snapshot.outline.columns == expected, "读回的顺序必须真的生效")
    }

    /// 旧偏好没有该字段：回落默认顺序，且不为「没动过」写出新键。
    @Test func legacyPreferencesWithoutOrderUseDefaultAndStayUnchanged() throws {
        let defaults = makePreferencesDefaults()
        writePreferences(
            """
            {
              "outlineWidth": 480,
              "expandedTaskIDs": [],
              "zoom": "week",
              "usesFitZoom": true,
              "inspectorWidth": 320,
              "inspectorTab": "inspector",
              "hiddenOutlineColumns": ["predecessors"]
            }
            """,
            to: defaults
        )

        let store = WorkspaceStore(defaults: defaults, seedsDemoData: false)
        #expect(store.viewState.columnOrder == OutlineColumnPreferences.defaultOrder)
        #expect(store.snapshot.outline.columns ==
                OutlineColumnPreferences.visibleColumns(
                    outlineWidth: 480, hidden: [.predecessors], focused: false
                ))

        // 触发一次偏好落盘（写回的是当前状态），确认默认顺序不会凭空写出新键。
        store.dispatch(.setOutlineWidth(480))
        #expect(!(try storedPreferencesJSON(defaults)).contains("outlineColumnOrder"),
                "默认顺序不落键：旧用户升上来后偏好文件不该平白多一项")
    }

    /// 损坏顺序（未知列 + 缺列）：不丢列，缺失项补齐，其余偏好不受牵连。
    @Test func corruptedOrderKeepsEveryColumn() {
        let defaults = makePreferencesDefaults()
        writePreferences(
            """
            {
              "outlineWidth": 480,
              "expandedTaskIDs": [],
              "zoom": "week",
              "usesFitZoom": true,
              "inspectorWidth": 320,
              "inspectorTab": "inspector",
              "outlineColumnOrder": ["bogus", "progress", "number", "progress"]
            }
            """,
            to: defaults
        )

        let store = WorkspaceStore(defaults: defaults, seedsDemoData: false)
        #expect(store.viewState.columnOrder.prefix(2) == [.progress, .number], "未知列丢弃、重复只留一次")
        #expect(Set(store.viewState.columnOrder) == Set(OutlineColumn.allCases), "缺的列补齐，不丢列")
        #expect(store.viewState.outlineWidth == 480, "其余偏好不受牵连")
    }

    /// 换项目保留顺序：与列宽 / 显隐同属应用级视图偏好。
    @Test func orderSurvivesProjectSwitch() throws {
        let defaults = makePreferencesDefaults()
        let store = WorkspaceStore(defaults: defaults, seedsDemoData: true)
        let reordered = OutlineColumnPreferences.normalizedOrder([.assignee, .progress, .title])
        store.dispatch(.setOutlineColumnOrder(reordered))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaido-v016-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("other.kaido")
        store.save(to: url)
        #expect(store.open(url: url), "换项目本身应成功")

        #expect(store.viewState.columnOrder == reordered, "换项目不得把列顺序打回默认")
    }
}
