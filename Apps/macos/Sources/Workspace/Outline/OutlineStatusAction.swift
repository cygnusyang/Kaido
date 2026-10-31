import KaidoCore

/// 状态选择后的动作（D-037）：转「已取消」必须先填原因。
///
/// 为什么单独抽出来：检查器与大纲行内菜单是两个入口，规则若各写一遍迟早分叉 ——
/// v0.16.0 就因为行内菜单没有原因输入，把「已取消」整项藏了起来（D-037）。
/// 现在两处都调这一个函数，弹不弹层只有一个答案。
enum OutlineStatusAction: Equatable {
    /// 直接提交状态（含「已取消」以外的全部状态，以及在已取消状态下再选已取消）。
    case apply(TaskStatus)
    /// 先弹原因输入层，确认后再提交。
    case promptCancelReason

    /// - Parameters:
    ///   - status: 用户在菜单里选中的状态。
    ///   - current: 该行当前状态（已是已取消时不重复弹层，原因已经存在）。
    static func forSelection(_ status: TaskStatus, current: TaskStatus) -> OutlineStatusAction {
        if status == .cancelled, current != .cancelled { return .promptCancelReason }
        return .apply(status)
    }
}
