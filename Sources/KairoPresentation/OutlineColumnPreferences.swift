import Foundation

/// 大纲列的用户可配置策略（F-14-20）：固定列、可调宽度区间、默认宽与生效列集合。
///
/// 视图（`WorkspaceView` 的表头与行）与呈现层（`Presenter` 的快照）共用本策略，
/// 消除「列集合各算一份」的多处口径；本文件不依赖 SwiftUI/AppKit（ADR-013）。
public enum OutlineColumnPreferences {
    /// 序号与任务说明固定显示：不进入显隐开关列表，隐藏请求一律忽略。
    public static let alwaysVisible: Set<OutlineColumn> = [.number, .title]

    /// 可显隐配置的列：`allCases` 顺序减去固定列（序号、任务说明）。
    public static var configurable: [OutlineColumn] {
        OutlineColumn.allCases.filter { !alwaysVisible.contains($0) }
    }

    /// 该列能否拖拽调宽。任务说明是弹性列（吃余量，最小 120pt），不参与拖拽。
    public static func isResizable(_ column: OutlineColumn) -> Bool {
        column != .title
    }

    /// 列宽拖拽区间（点）：状态/违例是窄图标列、序号是短编号列，其余为文本列。
    ///
    /// 下界必须同时包住「默认宽」与「最窄窗口下的压缩宽」（×0.6），否则拖动
    /// 手柄第一个像素就会跳变：status 10.8 / number 18 / 其余 ≤33.6。
    public static func widthRange(for column: OutlineColumn) -> ClosedRange<Double> {
        switch column {
        case .status, .violation: return 10...60
        case .number: return 18...80
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
    public static func visibleColumns(
        outlineWidth: Double,
        hidden: Set<OutlineColumn>,
        focused: Bool
    ) -> [OutlineColumn] {
        if focused { return [.status, .violation, .title] }
        let hiddenConfigurable = hidden.subtracting(alwaysVisible)
        return OutlineColumn.visibleColumns(outlineWidth: outlineWidth)
            .filter { !hiddenConfigurable.contains($0) }
    }
}
