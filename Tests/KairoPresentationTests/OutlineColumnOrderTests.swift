import Foundation
import Testing
import KairoPresentation

// v0.16「大纲列顺序可拖拽 + 列右键菜单」（#12）策略单测。
//
// 三个纯函数承重：§normalizedOrder§（不丢列）、§ordered§（稳定重排）、
// §movedOrder§（把一次拖拽翻译成完整顺序，隐藏列守住槽位）。视图只做
// 「落点 → 下标」的几何换算，语义全在这里锁定，因此这些用例是回归的主证据。
//
// 判据（issue #12 用户裁定）：默认顺序与改动前逐列一致；固定列可重排但不可隐藏；
// 旧偏好/未知列读入不丢列。

@Suite("大纲列顺序（v0.16 / #12）")
struct OutlineColumnOrderTests {
    /// 默认顺序 = §allCases§：新增列自动落在末尾，不需要同步第二份清单。
    @Test func defaultOrderIsAllCases() {
        #expect(OutlineColumnPreferences.defaultOrder == OutlineColumn.allCases)
    }

    /// 回归：默认顺序下生效列集合与改动前逐位一致（视图与 Presenter 都走这一处）。
    @Test func defaultOrderReproducesLegacyColumnSets() {
        for width in [180.0, 340.0, 376.0, 454.0, 510.0, 586.0, 600.0, 640.0] {
            #expect(
                OutlineColumnPreferences.visibleColumns(
                    outlineWidth: width, hidden: [], focused: false,
                    order: OutlineColumnPreferences.defaultOrder
                ) == OutlineColumn.visibleColumns(outlineWidth: width),
                "\(width)pt 默认顺序应与既有口径逐位一致"
            )
        }
    }

    // MARK: - 归一化

    /// 未知/缺失列补齐：顺序里没有的列按 §allCases§ 追加到末尾，一列都不能丢。
    @Test func normalizedOrderAppendsMissingColumnsAtTail() {
        let order = OutlineColumnPreferences.normalizedOrder([.progress, .title])
        #expect(Array(order.prefix(2)) == [.progress, .title])
        #expect(order.count == OutlineColumn.allCases.count, "不得丢列")
        #expect(Set(order) == Set(OutlineColumn.allCases), "不得丢列也不得重复")
        let tail = Array(order.dropFirst(2))
        #expect(tail == OutlineColumn.allCases.filter { $0 != .progress && $0 != .title },
                "缺失列按 allCases 顺序追加")
    }

    /// 重复项只保留第一次出现的位置。
    @Test func normalizedOrderDropsDuplicates() {
        let order = OutlineColumnPreferences.normalizedOrder([.finish, .start, .finish, .start])
        #expect(Array(order.prefix(2)) == [.finish, .start])
        #expect(order.count == OutlineColumn.allCases.count)
    }

    /// 空顺序 = 默认顺序（旧偏好缺字段的等价路径）。
    @Test func normalizedEmptyOrderFallsBackToDefault() {
        #expect(OutlineColumnPreferences.normalizedOrder([]) == OutlineColumnPreferences.defaultOrder)
    }

    // MARK: - 稳定重排

    /// 传入列集合的次序不影响结果：同一份顺序 → 同一份输出。
    @Test func orderedIsStableRegardlessOfInputOrder() {
        let order: [OutlineColumn] = [.title, .number, .status, .progress]
        let shuffled: [OutlineColumn] = [.progress, .status, .number, .title, .assignee]
        // 未在 order 里出现的列（assignee）按传入顺序排在最后。
        let expected: [OutlineColumn] = [.title, .number, .status, .progress, .assignee]
        #expect(OutlineColumnPreferences.ordered(shuffled, by: order) == expected)
        #expect(OutlineColumnPreferences.ordered(Array(shuffled.reversed()), by: order) == expected,
                "输入集合的次序不该影响结果")
    }

    // MARK: - 用户顺序 → 生效列

    /// 固定列（序号 / 任务说明）可换位置，但隐藏请求仍被忽略。
    @Test func fixedColumnsCanMoveButNotHide() {
        let order = OutlineColumnPreferences.normalizedOrder([.title, .number, .status, .violation])
        let columns = OutlineColumnPreferences.visibleColumns(
            outlineWidth: 600, hidden: [.number, .title], focused: false, order: order
        )
        #expect(Array(columns.prefix(3)) == [.title, .number, .status], "固定列参与重排")
        #expect(columns.contains(.number), "隐藏序号请求被忽略")
        #expect(columns.contains(.title), "隐藏任务说明请求被忽略")
    }

    /// 顺序跨窗口宽度稳定：先宽后窄，被保留列的相对顺序不跳。
    @Test func orderSurvivesWidthDegradation() {
        let order = OutlineColumnPreferences.normalizedOrder([.progress, .start, .duration, .status])
        let wide = OutlineColumnPreferences.visibleColumns(
            outlineWidth: 640, hidden: [], focused: false, order: order
        )
        let narrow = OutlineColumnPreferences.visibleColumns(
            outlineWidth: 340, hidden: [], focused: false, order: order
        )
        #expect(wide.first == .progress)
        #expect(narrow.first == .progress, "窄窗下「完成」仍在最前，不回到默认位置")
        // 窄窗里存活列在宽窗顺序中的相对位置不变。
        let survivors = wide.filter { narrow.contains($0) }
        #expect(survivors == narrow, "存活列的相对顺序必须与宽窗一致")
    }

    /// 聚焦标签栏不看用户顺序：恒为三列（标签栏口径，设计 §2）。
    @Test func focusedModeIgnoresUserOrder() {
        let order = OutlineColumnPreferences.normalizedOrder([.title, .status, .violation])
        #expect(OutlineColumnPreferences.visibleColumns(
            outlineWidth: 600, hidden: [], focused: true, order: order
        ) == [.status, .violation, .title])
    }

    /// 隐藏列不因重排回到列集合；可选列仍以 §shownOptional§ 为唯一权威。
    @Test func hiddenAndOptionalSemanticsSurviveReorder() {
        let order = OutlineColumnPreferences.normalizedOrder([.progress, .actualStart, .start])
        let columns = OutlineColumnPreferences.visibleColumns(
            outlineWidth: 600, hidden: [.start], focused: false,
            shownOptional: [.actualStart], order: order
        )
        #expect(!columns.contains(.start))
        #expect(columns.contains(.actualStart))
        #expect(columns.first == .progress)
    }

    // MARK: - 拖拽落点 → 插入下标

    /// 中点为分界：落点在某个中点右侧 → 排到它后面。
    @Test func insertionIndexUsesColumnMidpoints() {
        let midpoints = [10.0, 30.0, 50.0]
        #expect(OutlineColumnPreferences.insertionIndex(dropX: 5, midpoints: midpoints) == 0)
        #expect(OutlineColumnPreferences.insertionIndex(dropX: 10, midpoints: midpoints) == 0,
                "正好落在中点 = 仍在它之前（严格小于才算越过）")
        #expect(OutlineColumnPreferences.insertionIndex(dropX: 20, midpoints: midpoints) == 1)
        #expect(OutlineColumnPreferences.insertionIndex(dropX: 30, midpoints: midpoints) == 1)
        #expect(OutlineColumnPreferences.insertionIndex(dropX: 60, midpoints: midpoints) == 3,
                "越过全部中点 = 追加到末尾")
        #expect(OutlineColumnPreferences.insertionIndex(dropX: -100, midpoints: midpoints) == 0,
                "越界靠左夹到 0")
        #expect(OutlineColumnPreferences.insertionIndex(dropX: 0, midpoints: []) == 0)
    }

    // MARK: - 重排提交（movedOrder）

    /// 拖到最前：完整顺序里该列第一，其余可见列相对顺序不变。
    @Test func movedOrderMovesColumnToFront() {
        let visible = OutlineColumnPreferences.visibleColumns(
            outlineWidth: 600, hidden: [], focused: false
        )
        let order = OutlineColumnPreferences.movedOrder(
            OutlineColumnPreferences.defaultOrder, visible: visible,
            moving: .progress, toInsertionIndex: 0
        )
        #expect(order.first == .progress)
        #expect(OutlineColumnPreferences.ordered(visible, by: order) ==
                [.progress] + visible.filter { $0 != .progress })
        #expect(Set(order) == Set(OutlineColumn.allCases), "重排不得丢列")
    }

    /// 隐藏列守住槽位：只在可见列之间换位，隐藏列不被挤到末尾。
    @Test func movedOrderKeepsHiddenColumnsInPlace() {
        let visible = OutlineColumnPreferences.visibleColumns(
            outlineWidth: 600, hidden: [.start], focused: false
        )
        let order = OutlineColumnPreferences.movedOrder(
            OutlineColumnPreferences.defaultOrder, visible: visible,
            moving: .progress, toInsertionIndex: 0
        )
        // .start 被隐藏：它在完整顺序中的槽位不变。
        let startIndex = order.firstIndex(of: .start)
        #expect(startIndex == OutlineColumnPreferences.defaultOrder.firstIndex(of: .start),
                "隐藏列的槽位不得因重排漂移")
        #expect(order.first == .progress)
    }

    /// 拖到原位 = 顺序不变（落点停在原处时不应产生新顺序）。
    @Test func movedOrderToSameSlotKeepsOrder() {
        let visible = OutlineColumnPreferences.visibleColumns(
            outlineWidth: 600, hidden: [], focused: false
        )
        let index = visible.firstIndex(of: .duration) ?? 0
        let order = OutlineColumnPreferences.movedOrder(
            OutlineColumnPreferences.defaultOrder, visible: visible,
            moving: .duration, toInsertionIndex: index
        )
        #expect(OutlineColumnPreferences.ordered(visible, by: order) == visible)
    }

    /// 下标越界夹取：负数落 0，超过长度落末尾。
    @Test func movedOrderClampsInsertionIndex() {
        let visible: [OutlineColumn] = [.status, .number, .title, .progress]
        let head = OutlineColumnPreferences.movedOrder(
            OutlineColumnPreferences.defaultOrder, visible: visible,
            moving: .progress, toInsertionIndex: -5
        )
        #expect(OutlineColumnPreferences.ordered(visible, by: head) ==
                [.progress, .status, .number, .title])

        let tail = OutlineColumnPreferences.movedOrder(
            OutlineColumnPreferences.defaultOrder, visible: visible,
            moving: .status, toInsertionIndex: 99
        )
        #expect(OutlineColumnPreferences.ordered(visible, by: tail) ==
                [.number, .title, .progress, .status])
    }

    /// 被拖列不在可见集合里（理论上不可达）：原样返回归一化顺序，不产生半截顺序。
    @Test func movedOrderIgnoresInvisibleColumn() {
        let visible: [OutlineColumn] = [.status, .number, .title]
        let order = OutlineColumnPreferences.movedOrder(
            OutlineColumnPreferences.defaultOrder, visible: visible,
            moving: .finish, toInsertionIndex: 0
        )
        #expect(order == OutlineColumnPreferences.defaultOrder)
    }
}
