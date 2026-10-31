import CoreGraphics
import Testing
import KaidoCore
import KaidoPresentation
@testable import KaidoMacApp

// F-14-20「大纲列宽可调」布局单测（设计稿 §3.3 与 §4「布局」行）。
//
// `OutlineColumnLayout.width(of:)` 的优先级是：拖拽草稿（live）→ 用户覆盖值
// （**不乘压缩系数**，否则拖宽无效）→ 默认派生宽（乘 600pt 基准的压缩系数）。
// 既有回归 `outlineColumnsScaleWithWidth` / `outlineColumnsDegradeWithWidth` 锁定
// 无覆盖值时的压缩与降级口径，本文件补三块：
//   ① 无覆盖值时 600 / 360 两档逐位等于引入本机制前的派生结果（含 title 吃余量与 120 下限）；
//   ② 覆盖值原样生效，不乘压缩系数，并正确从 title 的余量里扣减；
//   ③ 拖拽草稿优先于已提交的覆盖值。
//
// 所有宽度都是确定值：不读字体、不读屏幕、不依赖时间。

@MainActor
@Suite("大纲列宽布局（F-14-20）")
struct OutlineColumnLayoutTests {
    /// 布局里除 `title` 外的固定列宽度合计（与实现同一求和口径）。
    private func fixedSum(_ layout: OutlineColumnLayout) -> CGFloat {
        layout.columns
            .filter { $0 != .title }
            .reduce(0) { $0 + layout.width(of: $1) }
    }

    // MARK: - 无覆盖值 = 现状

    /// 600pt 基准（scale = 1）：非标题列取派生宽，标题吃余量并被 120pt 下限托底。
    @Test func defaultWidthsAt600PointMatchLegacyDerivation() {
        let columns = OutlineColumn.visibleColumns(outlineWidth: 600)
        let layout = OutlineColumnLayout(columns: columns, totalWidth: 600, focused: false)

        #expect(layout.width(of: .status) == 18)
        #expect(layout.width(of: .violation) == 18)
        // v0.14.4：序号列 30 → 44（容纳「10.12」这类三级序号）。
        #expect(layout.width(of: .number) == 44)
        #expect(layout.width(of: .predecessors) == 96)
        #expect(layout.width(of: .start) == 78)
        #expect(layout.width(of: .finish) == 78)
        #expect(layout.width(of: .duration) == 56)
        #expect(layout.width(of: .assignee) == 76)
        #expect(layout.width(of: .progress) == 72)
        // 固定列合计 536pt：600 − 536 = 64 < 120 下限 → 标题取 120（总宽溢出，右侧裁切）。
        #expect(fixedSum(layout) == 536)
        #expect(layout.width(of: .title) == 120)
    }

    /// 360pt（scale 落到 0.6 下限）：固定列等比压缩，标题吃剩余宽度。
    @Test func defaultWidthsAt360PointMatchLegacyCompression() {
        let columns = OutlineColumn.visibleColumns(outlineWidth: 360)
        #expect(columns == [.status, .violation, .number, .title, .progress])
        let layout = OutlineColumnLayout(columns: columns, totalWidth: 360, focused: false)

        #expect(layout.width(of: .status) == 18 * 0.6)
        #expect(layout.width(of: .violation) == 18 * 0.6)
        #expect(layout.width(of: .number) == 44 * 0.6)
        #expect(layout.width(of: .progress) == 72 * 0.6)

        let fixed = fixedSum(layout)
        #expect(abs(fixed - 91.2) < 0.001)
        #expect(abs(layout.width(of: .title) - (360 - fixed)) < 0.001)
        #expect(abs(layout.width(of: .title) - 268.8) < 0.001)
        #expect(layout.width(of: .title) >= 120, "标题下限 120pt")
        #expect(abs(layout.width(of: .title) + fixed - 360) < 0.001, "未溢出时总宽正好等于大纲宽度")
    }

    // MARK: - 覆盖值

    /// 覆盖值不乘压缩系数，并从标题余量里扣减（360 宽 + start=120 → start 仍 120）。
    @Test func overrideIsNotMultipliedByCompressionScale() {
        let layout = OutlineColumnLayout(
            columns: [.number, .title, .start],
            totalWidth: 360,
            focused: false,
            widthOverrides: [.start: 120]
        )

        // 默认派生宽是 78 × 0.6 = 46.8；覆盖值必须原样生效，否则拖宽无效（设计 §2「用户宽度」）。
        #expect(layout.width(of: .start) == 120)
        #expect(layout.width(of: .start) != 78 * 0.6)
        // 未覆盖的列继续走压缩口径（用户改动只影响被拖的那一列）。
        #expect(layout.width(of: .number) == 44 * 0.6)
        // 标题吃余量：360 − (18 + 120) = 222，且不低于 120。
        #expect(layout.width(of: .title) == 213.6)
        #expect(layout.width(of: .title) >= 120)
    }

    /// 窄图标列（状态 18–60）的覆盖值同样不压缩：60 不会变成 36。
    @Test func iconColumnOverrideIsNotScaled() {
        let layout = OutlineColumnLayout(
            columns: [.status, .violation, .title],
            totalWidth: 360,
            focused: false,
            widthOverrides: [.status: 60]
        )
        #expect(layout.width(of: .status) == 60)
        #expect(layout.width(of: .status) != 18 * 0.6)
        #expect(abs(layout.width(of: .title) - (360 - (60 + 18 * 0.6))) < 0.001)
    }

    /// 覆盖值把固定列撑爆时，标题仍保底 120（设计 R3：溢出由右侧裁切兜底，不压缩用户宽度）。
    @Test func titleKeepsMinimumWidthWhenFixedColumnsOverflow() {
        let layout = OutlineColumnLayout(
            columns: [.number, .title, .assignee],
            totalWidth: 300,
            focused: false,
            widthOverrides: [.assignee: 320]
        )
        #expect(layout.width(of: .assignee) == 320)
        // 30 × 0.6 = 18；18 + 320 = 338 > 300 → 标题 = max(300 − 338, 120) = 120。
        #expect(layout.width(of: .title) == 120)
    }

    // MARK: - 拖拽草稿

    /// 拖拽草稿优先于已提交的覆盖值，标题按草稿同步让位（跨行预览一致）。
    @Test func liveResizeBeatsWidthOverride() {
        let layout = OutlineColumnLayout(
            columns: [.number, .title, .start],
            totalWidth: 360,
            focused: false,
            widthOverrides: [.start: 200],
            liveResize: (column: .start, width: 90)
        )
        #expect(layout.width(of: .start) == 90, "拖动中的草稿优先于已提交的覆盖值")
        #expect(layout.width(of: .title) == 243.6, "标题按草稿宽度让位：360 − (18 + 90)")
    }

    /// 草稿只作用于自己那一列；草稿为负时夹到 0（不留负宽度给 SwiftUI 布局）。
    @Test func liveResizeAffectsOnlyItsColumnAndClampsNegative() {
        let other = OutlineColumnLayout(
            columns: [.number, .title, .start],
            totalWidth: 360,
            focused: false,
            widthOverrides: [.start: 200],
            liveResize: (column: .finish, width: 90)
        )
        #expect(other.width(of: .start) == 200, "草稿换到别的列时覆盖值仍生效")

        let negative = OutlineColumnLayout(
            columns: [.number, .title, .start],
            totalWidth: 360,
            focused: false,
            liveResize: (column: .start, width: -30)
        )
        #expect(negative.width(of: .start) == 0, "负宽度夹到 0，不把负值传给 SwiftUI 布局")
        // 草稿夹到 0 后标题吃余量：360 − (26.4 + 0) = 333.6（序号列 44 × 0.6）。
        let expectedTitle: CGFloat = 333.6
        #expect(negative.width(of: .title) == expectedTitle)
    }

    // MARK: - 聚焦口径

    /// 聚焦标签栏不压缩；标题下限按 0 处理（否则窄标签栏会撑破容器）。
    @Test func focusedLayoutHasNoTitleMinimum() {
        let layout = OutlineColumnLayout(
            columns: [.status, .violation, .title],
            totalWidth: 180,
            focused: true
        )
        #expect(layout.width(of: .status) == 18)
        #expect(layout.width(of: .violation) == 18)
        #expect(layout.width(of: .title) == 144)
    }
}
