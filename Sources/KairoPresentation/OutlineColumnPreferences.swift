import Foundation

/// 大纲列的用户可配置策略（F-14-20）：固定列、可调宽度区间、默认宽与生效列集合。
///
/// 视图（`WorkspaceView` 的表头与行）与呈现层（`Presenter` 的快照）共用本策略，
/// 消除「列集合各算一份」的多处口径；本文件不依赖 SwiftUI/AppKit（ADR-013）。
public enum OutlineColumnPreferences {
    /// 序号与任务说明固定显示：不进入显隐开关列表，隐藏请求一律忽略。
    public static let alwaysVisible: Set<OutlineColumn> = [.number, .title]

    /// 可选列（F-0719）：默认隐藏，只能经 `shownOptional` 显式打开。
    ///
    /// 不复用 `hiddenOutlineColumns`：旧用户存过隐藏偏好，那一层无法区分「用户没隐藏」
    /// 与「这一列当时还不存在」，把默认值塞进去会让升级后凭空多出两列（设计 §5）。
    public static let optional: Set<OutlineColumn> = [.actualStart, .actualFinish]

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
    ///   - shownOptional: 用户显式打开的可选列（F-0719）；缺省空集 = 全部默认隐藏，
    ///     因此既有调用方的列集合逐位不变。
    ///
    /// 可选列的插入规则（设计 §6）：按 `allCases` 顺序（实际开始 → 实际结束）插入；
    /// 基准列含 `.finish` 时紧随其后，否则追加到末尾。显式打开不受宽度阈值裁剪——
    /// 阈值降级是「没得选时的自动取舍」，用户点名要看就得看到。
    public static func visibleColumns(
        outlineWidth: Double,
        hidden: Set<OutlineColumn>,
        focused: Bool,
        shownOptional: Set<OutlineColumn> = []
    ) -> [OutlineColumn] {
        if focused { return [.status, .violation, .title] }
        let hiddenConfigurable = hidden.subtracting(alwaysVisible)
        var columns = OutlineColumn.visibleColumns(outlineWidth: outlineWidth)
            .filter { !hiddenConfigurable.contains($0) }

        let enabled = OutlineColumn.allCases.filter {
            optional.contains($0) && shownOptional.contains($0)
        }
        guard !enabled.isEmpty else { return columns }
        if let finishIndex = columns.firstIndex(of: .finish) {
            columns.insert(contentsOf: enabled, at: finishIndex + 1)
        } else {
            columns.append(contentsOf: enabled)
        }
        return columns
    }
}
