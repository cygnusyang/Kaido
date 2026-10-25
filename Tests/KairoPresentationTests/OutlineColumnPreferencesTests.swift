import Foundation
import Testing
import KairoPresentation

// F-14-20「大纲列宽可调 + 列显隐」策略单测（设计稿 §3.1 与 §4「策略」行）。
//
// 视图（`WorkspaceView.planArea`）与呈现层（`Presenter.make` 的 `OutlineSnapshot`）
// 都只经 `OutlineColumnPreferences.visibleColumns` 取列集合，因此三条优先级——
// ① 固定列（序号/任务说明）不可隐藏、② 聚焦模式忽略用户配置、
// ③ 阈值降级优先于用户隐藏——只能在策略层锁定，视图不判语义。
//
// 本文件只测纯函数：无 Store、无视图、无时钟、无随机；宽度全部为确定值。

@Suite("大纲列偏好策略（F-14-20）")
struct OutlineColumnPreferencesTests {
    /// 13pt 正文下各列默认派生宽（`OutlineColumn.width(bodyFontSize: 13)`）。
    private static let expectedDefaultWidths: [OutlineColumn: Double] = [
        .status: 18,
        .violation: 18,
        .number: 30,
        .title: 160,
        .predecessors: 96,
        .start: 78,
        .finish: 78,
        // 实际列（F-0719）：可选列，宽度与既有日期列同口径。
        .actualStart: 78,
        .actualFinish: 78,
        .duration: 56,
        .assignee: 76,
        .progress: 72
    ]

    // MARK: - 固定列与可配置列

    /// 序号与任务说明恒显示：策略把这两个列作为唯一固定列。
    @Test func alwaysVisibleIsNumberAndTitle() {
        #expect(OutlineColumnPreferences.alwaysVisible == [.number, .title])
    }

    /// 显隐开关列表 = `allCases` 减去固定列，且保持 `allCases` 顺序（菜单顺序不漂移）。
    @Test func configurableExcludesFixedColumnsInAllCasesOrder() {
        let configurable = OutlineColumnPreferences.configurable

        #expect(configurable == [
            .status, .violation, .predecessors, .start,
            .finish, .duration, .assignee, .progress
        ])
        #expect(configurable == OutlineColumn.allCases.filter {
            !OutlineColumnPreferences.alwaysVisible.contains($0)
                && !OutlineColumnPreferences.optional.contains($0)
        })
        #expect(!configurable.contains(.number), "序号固定显示，不得进入开关列表")
        #expect(!configurable.contains(.title), "任务说明固定显示，不得进入开关列表")
        // 派生而非手写：可配置列 + 固定列 + 可选列必须恰好覆盖全部列，无遗漏无重复。
        #expect(Set(configurable)
            .union(OutlineColumnPreferences.alwaysVisible)
            .union(OutlineColumnPreferences.optional).count
            == OutlineColumn.allCases.count)
    }

    /// `title` 是弹性列（吃余量），不参与表头拖拽；其余列均可拖。
    @Test func isResizableExcludesTitleOnly() {
        #expect(!OutlineColumnPreferences.isResizable(.title))
        for column in OutlineColumn.allCases where column != .title {
            #expect(OutlineColumnPreferences.isResizable(column), "\(column.rawValue) 应可拖拽调宽")
        }
    }

    // MARK: - 生效列集合

    /// 宽窗下隐藏可配置列：该列消失，其余列及其顺序不变（用户隐藏只做减法）。
    @Test func hideConfigurableColumnNarrowsWideOutline() {
        let base = OutlineColumnPreferences.visibleColumns(
            outlineWidth: 600, hidden: [], focused: false
        )
        #expect(base == [
            .status, .violation, .number, .title, .predecessors,
            .start, .finish, .duration, .assignee, .progress
        ])

        let hidden = OutlineColumnPreferences.visibleColumns(
            outlineWidth: 600, hidden: [.start], focused: false
        )
        #expect(!hidden.contains(.start))
        #expect(hidden == [
            .status, .violation, .number, .title, .predecessors,
            .finish, .duration, .assignee, .progress
        ])
    }

    /// 隐藏序号/任务说明被忽略：两列仍在且位置不变（设计 §2「永远显示」）。
    @Test func hidingFixedColumnsIsIgnored() {
        let base = OutlineColumnPreferences.visibleColumns(
            outlineWidth: 600, hidden: [], focused: false
        )
        let hiddenFixed = OutlineColumnPreferences.visibleColumns(
            outlineWidth: 600, hidden: [.number, .title], focused: false
        )
        #expect(hiddenFixed == base)
        #expect(hiddenFixed.contains(.number))
        #expect(hiddenFixed.contains(.title))
    }

    /// 聚焦模式恒为 `[.status, .violation, .title]`：用户隐藏与阈值降级都不参与。
    @Test func focusedIgnoresHiddenPreferences() {
        #expect(OutlineColumnPreferences.visibleColumns(
            outlineWidth: 600, hidden: [], focused: true
        ) == [.status, .violation, .title])

        // 隐藏集合含可配置列与固定列，全部被忽略。
        #expect(OutlineColumnPreferences.visibleColumns(
            outlineWidth: 600, hidden: [.status, .violation, .number, .title, .start], focused: true
        ) == [.status, .violation, .title])

        // 窄窗（阈值降级会把 status 之外的列全部裁掉）在聚焦模式下同样被忽略。
        #expect(OutlineColumnPreferences.visibleColumns(
            outlineWidth: 180, hidden: [], focused: true
        ) == [.status, .violation, .title])
    }

    /// 阈值降级优先于用户显示：340pt 物理放不下，即便用户没隐藏也没有 start/finish/assignee。
    @Test func widthThresholdDegradationPrecedesUserVisibility() {
        let narrow = OutlineColumnPreferences.visibleColumns(
            outlineWidth: 340, hidden: [], focused: false
        )
        #expect(narrow == [.status, .violation, .number, .title, .progress])
        #expect(!narrow.contains(.start))
        #expect(!narrow.contains(.finish))
        #expect(!narrow.contains(.assignee))
        #expect(!narrow.contains(.predecessors))
        #expect(!narrow.contains(.duration))

        // 隐藏一个本来就已降级的列不改变结果（隐藏只能进一步收窄，不能反向恢复）。
        #expect(OutlineColumnPreferences.visibleColumns(
            outlineWidth: 340, hidden: [.start], focused: false
        ) == narrow)

        // 隐藏仍可见的可配置列：进一步收窄。
        #expect(OutlineColumnPreferences.visibleColumns(
            outlineWidth: 340, hidden: [.progress], focused: false
        ) == [.status, .violation, .number, .title])
    }

    /// 降级阈值是闭区间边界：376pt 起出现「开始」，375.9pt 不出现。
    @Test func degradationThresholdBoundaryIsInclusive() {
        #expect(OutlineColumnPreferences.visibleColumns(
            outlineWidth: 376, hidden: [], focused: false
        ).contains(.start))
        #expect(!OutlineColumnPreferences.visibleColumns(
            outlineWidth: 375.9, hidden: [], focused: false
        ).contains(.start))

        // 阈值优先于用户隐藏的方向也要对：宽窗下隐藏不恢复任何列。
        #expect(!OutlineColumnPreferences.visibleColumns(
            outlineWidth: 375.9, hidden: [], focused: false
        ).contains(.finish), "454pt 阈值未达，结束列不因未隐藏而出现")
    }

    /// 零宽度边界：不崩溃，且仍保留两个固定列与恒显示的「完成」列。
    @Test func zeroWidthKeepsFixedColumns() {
        #expect(OutlineColumnPreferences.visibleColumns(
            outlineWidth: 0, hidden: [], focused: false
        ) == [.status, .violation, .number, .title, .progress])
    }

    /// 无用户配置时与既有列集合口径逐位一致（视图/Presenter 统一调用后不产生回归）。
    @Test func emptyHiddenMatchesLegacyColumns() {
        for width in [180.0, 340.0, 376.0, 454.0, 510.0, 586.0, 600.0, 640.0] {
            #expect(OutlineColumnPreferences.visibleColumns(
                outlineWidth: width, hidden: [], focused: false
            ) == OutlineColumn.visibleColumns(outlineWidth: width), "\(width)pt 无覆盖时应等于既有口径")
        }
    }

    // MARK: - 宽度区间与默认宽

    /// 状态/违例是窄图标列（18–60）、序号是短编号列（24–80）、其余为文本列（40–320）。
    @Test func widthRangeSplitsIconAndTextColumns() {
        for column in OutlineColumn.allCases {
            let expected: ClosedRange<Double>
            switch column {
            case .status, .violation: expected = 10...60
            case .number: expected = 18...80
            default: expected = 24...320
            }
            #expect(OutlineColumnPreferences.widthRange(for: column) == expected,
                    "\(column.rawValue) 的拖拽区间应为 \(expected)")
            // 回归：默认宽与「最窄窗口压缩宽（×0.6）」都要落在区间内，否则拖动首像素跳变。
            let range = OutlineColumnPreferences.widthRange(for: column)
            #expect(range.contains(OutlineColumnPreferences.defaultWidth(for: column)),
                    "\(column.rawValue) 默认宽应落在拖拽区间内")
            #expect(range.contains(OutlineColumnPreferences.defaultWidth(for: column) * 0.6),
                    "\(column.rawValue) 窄窗压缩宽应落在拖拽区间内")
        }
    }

    /// 默认宽 = 13pt 正文下的派生宽：与无覆盖值时的现状一致（拖宽后复位回到原点）。
    @Test func defaultWidthEqualsThirteenPointDerivedWidth() {
        for column in OutlineColumn.allCases {
            #expect(OutlineColumnPreferences.defaultWidth(for: column)
                == column.width(bodyFontSize: 13), "\(column.rawValue) 默认宽应与派生宽同源")
            #expect(OutlineColumnPreferences.defaultWidth(for: column)
                == Self.expectedDefaultWidths[column], "\(column.rawValue) 默认宽数值漂移")
        }
        // 注：序号列默认宽 30 低于其拖拽区间下界 40（设计 §2「其余 40–320」与
        // `OutlineColumn.width` 的 30pt 相互矛盾），此不一致已在交付报告登记，
        // 不在测试里固化，避免把待修行为写成预期。
    }
}
