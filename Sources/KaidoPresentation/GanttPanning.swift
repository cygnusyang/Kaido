import Foundation

/// 画布横向平移的像素 → 天换算（F-14-18）。
///
/// **亚日精度是刻意的**（v1.3.7 / D-049）：窗口起点自 v1.3.7 起允许落在一天
/// 中间的任意位置，所以一段像素位移直接折算成小数天提交即可，画布逐帧跟手。
/// 旧实现把起点归一为整天、位移先攒满一天再提交，代价是「整日蹦」——跨度模式
/// 一天 171pt，手指滑了 160pt 画面纹丝不动，然后整幅跳一天，用户感受就是拖不动。
///
/// 语义：返回值正 = 内容右移（窗口起点减小）；负 = 内容左移。
public enum HorizontalPan {
    /// 日宽下限 0.5pt（与 `GanttLayoutEngine.make` 的夹取同式）。
    public static let minimumDayWidth: Double = 0.5

    /// 像素位移 → 天位移。
    public static func days(deltaX: Double, dayWidth: Double) -> Double {
        deltaX / max(dayWidth, minimumDayWidth)
    }
}

// MARK: - 滚动事件处置（F-14-18）

/// 一条横向滚动输入的放行/消费结论。
public enum GanttScrollDecision: Equatable, Sendable {
    /// 消费该事件并平移画布：`pixels` 正 = 内容右移（看更早日期）。
    case pan(pixels: Double)
    /// 放行该事件（交给纵向滚动容器等），附原因便于日志定位。
    case ignore(reason: GanttScrollIgnoreReason)
}

/// 放行原因（诊断口径：真机排查时一眼看出是哪一道闸挡住了）。
public enum GanttScrollIgnoreReason: String, Equatable, Sendable {
    /// 没有横向意图（横向分量为 0 或低于噪声阈值）。
    case verticalOnly
    /// 视口所属窗口未知（视图尚未挂载/已卸载）。
    case windowUnavailable
    /// 光标不在画布视口内。
    case outsideViewport
    /// 文本编辑中，不抢滚动。
    case editingText
}

/// 一次滚动输入的完整上下文（视图层只负责采集，判定全在此）。
///
/// 几何比较（光标是否在视口内）由 AppKit 侧用 `CGRect.contains` 算出后传入布尔值：
/// 呈现层不引入 CoreGraphics，保持 Linux CI 可编译（ADR-004 平台无关纪律）。
public struct GanttScrollInput: Sendable {
    /// 事件横向位移（点，正 = 内容右移）。
    public var deltaX: Double
    /// 事件纵向位移（点）。
    public var deltaY: Double
    /// 是否按住 Shift（无横向滚轮的鼠标替代入口）。
    public var shift: Bool
    /// 画布视口是否已知（视图已挂载并上报过几何）。
    public var hasViewport: Bool
    /// 光标位置是否已知（事件窗口可解析）。
    public var hasCursor: Bool
    /// 光标是否落在画布视口内（同一坐标空间内由调用方判定）。
    public var cursorInsideViewport: Bool
    /// 首响应者是否为文本输入（编辑中）。
    public var isEditingText: Bool
    /// 低于该横向位移视为「没有横向意图」（噪声）。默认 0.01 点。
    public var minimumDelta: Double

    public init(
        deltaX: Double,
        deltaY: Double,
        shift: Bool,
        hasViewport: Bool,
        hasCursor: Bool,
        cursorInsideViewport: Bool,
        isEditingText: Bool,
        minimumDelta: Double = 0.01
    ) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.shift = shift
        self.hasViewport = hasViewport
        self.hasCursor = hasCursor
        self.cursorInsideViewport = cursorInsideViewport
        self.isEditingText = isEditingText
        self.minimumDelta = minimumDelta
    }
}

/// 滚动输入 → 消费/放行的纯函数（F-14-18）。
///
/// 判定顺序即优先级：分量方向 → 几何已知 → 文本编辑 → 视口命中 → 平移。
/// 不按「事件属于哪个窗口」判定：`scrollWheel` 的 `window` 常为 nil、`keyWindow`
/// 也可能指向辅助窗口，按身份比会把真机双指横滑全部放行（D-027 现场日志实证）。
/// 事件层（`HorizontalScrollMonitor`）只采集输入并执行结论，规则不内联在视图里
/// （D-027 教训：AppKit 事件胶水层的判定必须可单测，否则只能靠人工手测）。
public enum GanttScrollRouter {
    /// 横纵**同时生效**：横向分量交给甘特平移，纵向分量原样放行给纵向滚动。
    /// 不再按「谁更大」二选一——真实双指手势几乎不纯水平，分量大的那一帧会把
    /// 另一轴的位移整条丢掉，表现为「有时拖不动」（v1.3.6 现场反馈）。
    public static func decide(_ input: GanttScrollInput) -> GanttScrollDecision {
        let shiftVertical = input.shift && abs(input.deltaY) > 0
        let delta = shiftVertical ? input.deltaY : input.deltaX
        guard abs(delta) >= input.minimumDelta else {
            return .ignore(reason: .verticalOnly)
        }
        guard input.hasViewport, input.hasCursor else {
            return .ignore(reason: .windowUnavailable)
        }
        guard input.isEditingText == false else { return .ignore(reason: .editingText) }
        guard input.cursorInsideViewport else {
            return .ignore(reason: .outsideViewport)
        }
        return .pan(pixels: delta)
    }
}
