import SwiftUI

/// 甘特画布的「内容 + 横向滚动承接层」统一位移单元（D-050）。
///
/// **为什么要有这一层**：`GanttScrollSurface` 是 `NSViewRepresentable`，作为
/// `background` 贴在被装饰视图的布局位置上。SwiftUI 的 `.offset` 只位移它包裹的
/// 子树，写在 `.offset` **之后**的 `.background(...)` 不跟着位移——承接层的 NSView
/// 于是停在「内容顶部」的布局位置，纵向滚过一屏后整条移出视口：
/// `ScrollSurfaceView.cursorInsideBounds()` 恒为 false，路由器返回
/// `ignore(.outsideViewport)`，横向滚动静默失效；滚回顶部又恢复（表现为
/// 「横滑时灵时不灵」）。
///
/// 本类型把「内容」与「承接层」封进同一个位移单元，`.offset` 只有一个出口，
/// 且位于 `.background` 之后、覆盖两者——承接层的 frame 因此恒等于视口矩形
/// （`width × viewportHeight`），与内容同进同退。
///
/// **手势必须留在本视图外层**：`onContinuousHover` / `SpatialTapGesture` /
/// `simultaneousGesture(DragGesture)` 拿到的是未位移的布局坐标，调用方靠
/// `point.y + offset` 换算成内容坐标；若把它们挂进本视图，外层调用方的 offset
/// 换算会与本层的位移叠加两次，点选、拖条、拖依赖全部错位。
struct TimelineCanvasViewport<Content: View>: View {
    /// 纵向滚动偏移（点，非负）：内容向上位移多少，承接层就跟着位移多少。
    let offset: CGFloat
    /// 画布宽度（内容坐标系的横向总宽）。
    let width: CGFloat
    /// 视口高度：固定为可视高度，承接层据此判定光标是否在画布内。
    let viewportHeight: CGFloat
    /// 当前生效日宽（承接层像素 → 整天的换算基准）。
    let dayWidth: Double
    /// 横向平移提交（亚日精度，正 = 内容右移）。
    let onDays: (Double) -> Void
    /// 画布内容（`Canvas`）；尺寸由本视图的 `frame` 统一给定。
    let content: () -> Content

    init(
        offset: CGFloat,
        width: CGFloat,
        viewportHeight: CGFloat,
        dayWidth: Double,
        onDays: @escaping (Double) -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.offset = offset
        self.width = width
        self.viewportHeight = viewportHeight
        self.dayWidth = dayWidth
        self.onDays = onDays
        self.content = content
    }

    var body: some View {
        content()
            // 内容与承接层共用的布局尺寸：承接层必须等于视口，否则命中判定恒为「不在视口内」。
            .frame(width: width, height: viewportHeight)
            .background(GanttScrollSurface(dayWidth: dayWidth, onDays: onDays))
            // 唯一的位移出口：写在 background 之后，内容与承接层一起移。
            .offset(y: offset)
    }
}
