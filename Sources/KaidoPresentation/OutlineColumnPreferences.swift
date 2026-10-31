import Foundation

/// 大纲列的用户可配置策略（F-14-20）：固定列、可调宽度区间、默认宽与生效列集合。
///
/// 视图（`WorkspaceView` 的表头与行）与呈现层（`Presenter` 的快照）共用本策略，
/// 消除「列集合各算一份」的多处口径；本文件不依赖 SwiftUI/AppKit（ADR-013）。
public enum OutlineColumnPreferences {
    /// 序号与任务说明固定显示：不进入显隐开关列表，隐藏请求一律忽略。
    public static let alwaysVisible: Set<OutlineColumn> = [.number, .title]

    /// 可选列（F-0719 实际列 / v0.13 基线列）：默认隐藏，只能经 `shownOptional` 显式打开。
    ///
    /// 不复用 `hiddenOutlineColumns`：旧用户存过隐藏偏好，那一层无法区分「用户没隐藏」
    /// 与「这一列当时还不存在」，把默认值塞进去会让升级后凭空多出两列（设计 §5）。
    public static let optional: Set<OutlineColumn> = [
        .actualStart, .actualFinish,
        .baselineStart, .baselineFinish, .startVariance, .finishVariance,
    ]

    /// 基线列（08-baselines §11）：只在选定对比基线后才有意义。
    ///
    /// 未选基线时即使已勾选也不进入列集合——「没有对比对象」的列只会输出一列占位符，
    /// 是纯粹的界面噪音（设计 §5「未选基线时整体隐藏」）。
    public static let baseline: Set<OutlineColumn> = [
        .baselineStart, .baselineFinish, .startVariance, .finishVariance,
    ]

    /// 可显隐配置的列：`allCases` 顺序减去固定列（序号、任务说明）与可选列。
    ///
    /// 可选列不在其中——它的缺省态是「隐藏」，勾选态的数据源与写入路径都不同
    /// （见 `visibleColumns(…shownOptional:)`）。
    public static var configurable: [OutlineColumn] {
        OutlineColumn.allCases.filter { !alwaysVisible.contains($0) && !optional.contains($0) }
    }

    /// 显隐开关的全部列：固定列之外的全部列（可隐藏列 + 可选列），保持 `allCases` 顺序。
    ///
    /// 表头右键菜单与命令面板都从这一处派生，避免两份清单漂移。
    public static var toggleable: [OutlineColumn] {
        OutlineColumn.allCases.filter { !alwaysVisible.contains($0) }
    }

    /// 列的规范顺序（v0.16 / #12）：`allCases` —— 与引入可拖拽重排前的渲染顺序逐位一致。
    ///
    /// 「重置列顺序」回到这里，而不是另立一份清单：默认顺序只有一个来源，
    /// 新增列时 `allCases` 追加即尾部追加，不需要同步第二处。
    public static let defaultOrder: [OutlineColumn] = OutlineColumn.allCases

    /// 归一化列顺序：去重后保留用户顺序，缺失的列按 `allCases` 顺序追加到末尾。
    ///
    /// 不丢列是硬约束：旧偏好里没有的列（升级后新增）、以及降级后再回退的列，
    /// 都必须出现在表头里，否则用户升级后会看到「列凭空消失」且菜单里无法恢复。
    public static func normalizedOrder(_ order: [OutlineColumn]) -> [OutlineColumn] {
        var seen = Set<OutlineColumn>()
        var result: [OutlineColumn] = []
        result.reserveCapacity(OutlineColumn.allCases.count)
        for column in order where seen.insert(column).inserted {
            result.append(column)
        }
        result.append(contentsOf: OutlineColumn.allCases.filter { !seen.contains($0) })
        return result
    }

    /// 按用户顺序稳定重排：`order` 里的列按其次序排在前，其余列保持传入顺序排在末尾。
    ///
    /// 稳定排序（同排名按传入下标）保证「同一份列集合 + 同一份顺序 = 同一个结果」，
    /// 调用方不必关心自己传进来的列集合本身是什么次序。
    public static func ordered(_ columns: [OutlineColumn], by order: [OutlineColumn]) -> [OutlineColumn] {
        let rank = Dictionary(
            uniqueKeysWithValues: normalizedOrder(order).enumerated().map { ($0.element, $0.offset) }
        )
        return columns.enumerated()
            .sorted { lhs, rhs in
                let left = rank[lhs.element] ?? Int.max
                let right = rank[rhs.element] ?? Int.max
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
    }

    /// 拖动落点 → 插入下标（0…count）：以各列中点为分界，落点在某个中点右侧就排到它后面。
    ///
    /// - Parameters:
    ///   - dropX: 拖动位置（点，相对大纲左缘）。
    ///   - midpoints: **不含被拖列**的可见列中点，顺序与可见列一致。
    public static func insertionIndex(dropX: Double, midpoints: [Double]) -> Int {
        midpoints.filter { $0 < dropX }.count
    }

    /// 把某列拖到可见序列的新位置，返回重排后的**完整**列顺序。
    ///
    /// 只在可见列之间重排：当前不可见的列（用户隐藏 / 宽度降级 / 未开启的可选列）
    /// 各自守住原来的槽位，不会被挤到末尾——否则窗口一窄再变宽，隐藏列的相对位置
    /// 就跟着漂。`column` 不在 `visible` 里（理论上不可达）时原样返回归一化顺序。
    ///
    /// - Parameter index: 插入下标，语义为「在去掉被拖列之后的序列中插入到该位置」，
    ///   越界由本函数夹取，调用方不需要自己算边界。
    public static func movedOrder(
        _ order: [OutlineColumn],
        visible: [OutlineColumn],
        moving column: OutlineColumn,
        toInsertionIndex index: Int
    ) -> [OutlineColumn] {
        let normalized = normalizedOrder(order)
        guard let from = visible.firstIndex(of: column) else { return normalized }
        var nextVisible = visible
        nextVisible.remove(at: from)
        nextVisible.insert(column, at: min(max(index, 0), nextVisible.count))
        let visibleSet = Set(visible)
        var iterator = nextVisible.makeIterator()
        return normalized.map { visibleSet.contains($0) ? (iterator.next() ?? $0) : $0 }
    }

    /// 该列能否拖拽调宽。任务说明是弹性列（吃余量，最小 120pt），不参与拖拽。
    public static func isResizable(_ column: OutlineColumn) -> Bool {
        column != .title
    }

    /// 列宽拖拽区间（点）：状态/违例是窄图标列、序号是短编号列，其余为文本列。
    ///
    /// 下界必须同时包住「默认宽」与「最窄窗口下的压缩宽」（×0.6），否则拖动
    /// 手柄第一个像素就会跳变：status 10.8 / number 18 / 其余 ≤33.6。
    ///
    /// 序号上界 120：内容自适应（#48）算出的宽度可达 80 以上——六级含两位数的
    /// 「1.2.3.10.4.11」在 11pt 等宽数字下约 73pt，加内边距后 83pt，若上界仍是 80，
    /// 用户一拖就被夹回去、又变成截断。120 可容下约 16 字符的序号。
    public static func widthRange(for column: OutlineColumn) -> ClosedRange<Double> {
        switch column {
        case .status, .violation: return 10...60
        case .number: return 18...120
        default: return 24...320
        }
    }

    /// 默认列宽（点）：13pt 正文字号下的派生宽度（与无覆盖值时的现状一致）。
    public static func defaultWidth(for column: OutlineColumn) -> Double {
        column.width(bodyFontSize: 13)
    }

    /// 生效列集合。
    ///
    /// 优先级（设计 §2「优先级」）：聚焦模式忽略用户配置，固定 `status/violation/title`；
    /// 其余情况先按大纲宽度做阈值降级，用户隐藏只能进一步收窄——固定列忽略隐藏请求。
    ///
    /// - Parameters:
    ///   - outlineWidth: 大纲当前有效宽度（点）。
    ///   - hidden: 用户隐藏的列；其中序号/任务说明不生效。
    ///   - focused: 图表聚焦模式（标签栏口径）。
    ///   - shownOptional: 用户显式打开的可选列（F-0719）；缺省空集 = 全部默认隐藏，
    ///     因此既有调用方的列集合逐位不变。
    ///   - hasSelectedBaseline: 是否已选定对比基线（v0.13）；`false` 时基线四列一律不出现，
    ///     与是否勾选无关（设计 §5「未选基线时四列整体隐藏」）。
    ///   - order: 用户列顺序（v0.16 / #12）；缺省 `defaultOrder` = 改动前的渲染顺序。
    ///
    /// 成员判定与排序分两步：先按阈值 / 隐藏 / 可选列算出「该出现哪些列」，
    /// 再按 `order` 稳定重排。可选列的显隐权威仍是 `shownOptional`（命中隐藏集合不影响），
    /// 显式打开不受宽度阈值裁剪——阈值降级是「没得选时的自动取舍」，用户点名要看就得看到。
    ///
    /// 位置由 `order` 决定，取代 v0.15 的「跟随 `.finish`、无锚点则追加到末尾」：
    /// 用户拖过之后位置必须稳定，不能随窗口宽窄在两个位置之间跳。
    public static func visibleColumns(
        outlineWidth: Double,
        hidden: Set<OutlineColumn>,
        focused: Bool,
        shownOptional: Set<OutlineColumn> = [],
        hasSelectedBaseline: Bool = false,
        order: [OutlineColumn] = OutlineColumnPreferences.defaultOrder
    ) -> [OutlineColumn] {
        if focused { return [.status, .violation, .title] }
        let hiddenConfigurable = hidden.subtracting(alwaysVisible)
        var included = Set(OutlineColumn.visibleColumns(outlineWidth: outlineWidth))
            .subtracting(hiddenConfigurable)
        included.formUnion(optional.filter { column in
            shownOptional.contains(column) && (hasSelectedBaseline || !baseline.contains(column))
        })
        let candidates = OutlineColumn.allCases.filter { included.contains($0) }
        return ordered(candidates, by: order)
    }
}
