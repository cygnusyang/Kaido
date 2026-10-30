import Foundation

/// 定位（reveal）时的窗口滚动（D-042）：目标整段在窗口内就不动，否则把目标起点放到
/// 窗口左侧 1/4 处。
///
/// 为什么是 1/4 而不是左对齐：定位是把注意力带到某个任务，不是把画布推到它的起点。
/// 左边留 1/4 让「紧邻的前序任务」仍在视野里，右边 3/4 是接下来要看的内容。
public enum RevealWindow {
    /// 目标起点落在窗口宽度的比例位置。
    public static let leadFraction: Double = 0.25

    /// 计算滚动后的窗口起点。
    ///
    /// - Parameters:
    ///   - target: 目标占据的时间段（`start` ≤ `end`；零宽即里程碑/单点）。
    ///   - window: 当前可见窗口。
    /// - Returns: 目标**不完全**在窗口内时返回新的窗口起点；已完整可见时返回 `nil`
    ///   （窗口不动，避免「本来就在眼前还跳一下」）。窗口长度非正时同样返回 `nil`——
    ///   没有宽度就没有比例可言，让调用方保持原状。
    public static func scrolledStart(target: DateInterval, window: DateInterval) -> Date? {
        let windowLength = window.end.timeIntervalSince(window.start)
        guard windowLength > 0, windowLength.isFinite else { return nil }
        // `DateInterval` 自身保证 start ≤ end，无需再归一；日期本身也不存在 NaN。
        if target.start >= window.start && target.end <= window.end { return nil }
        return target.start.addingTimeInterval(-windowLength * leadFraction)
    }
}
