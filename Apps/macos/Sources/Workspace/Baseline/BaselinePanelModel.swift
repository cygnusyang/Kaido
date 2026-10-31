import Foundation
import KaidoCore
import KaidoPresentation

/// 基线面板一行（v0.15 / docs/features/08-baselines.md §5、10-multi-baseline-gantt.md §5）。
///
/// 纯值：面板与测试读同一份折算结果。颜色 / 显隐 / 对比三态的归一化口径与
/// `BaselineMenuModel` 完全一致（同一函数），否则会出现「面板说显示、图上没有」。
struct BaselinePanelRow: Identifiable, Hashable {
    /// 基线 ID：行内命令的稳定键（删掉中间一条不会让操作指到别的基线）。
    var id: UUID
    /// 用户数据，原样显示，不做本地化。
    var name: String
    /// 归一化后的调色板索引（缺失 / 越界 / 重复也能给出确定颜色）。
    var colorIndex: Int
    var createdAt: Date
    /// 条目数 = 快照时的已排期任务数。**不是当前任务数**：任务删掉后条目仍在（§5）。
    var entryCount: Int
    /// 「在甘特图中显示」（多选）。
    var isVisibleInGantt: Bool
    /// 当前对比基线（单选，驱动大纲四列与检查器）。
    var isCompared: Bool
    /// 已满 `BaselineLanes.maxVisible` 条且本身未显示：会话会拒绝勾选，面板据此置灰并解释原因。
    var isVisibilityBlocked: Bool
}

/// 孤儿条目（任务已删除、条目仍在）：只读展示（§5）。
///
/// 条目刻意不存 title（§3），所以标题只能是「已删除任务」占位；
/// 可核对的信息是承诺起止，这也是唯一还能证明「这条承诺曾经存在」的东西。
struct BaselinePanelOrphan: Identifiable, Hashable {
    /// 任务 ID：同一条基线内唯一，可直接作列表 id。
    var id: UUID
    var baselineID: UUID
    var start: Date
    var finish: Date
}

/// 面板底部统计：只算**焦点基线**（主对比 ?? 最新一条）。
///
/// 不为每条基线各算一份偏差：3 条基线 × 5k 任务就是 3 次全量比较，
/// 而面板同一时刻只回答「这一条基线之后发生了什么」。
struct BaselinePanelStatistics: Hashable {
    var baselineID: UUID
    var name: String
    var entryCount: Int
    /// 条目在、任务已删（按 `start` 升序，同起点按任务 ID 稳定排序）。
    var orphans: [BaselinePanelOrphan]
    /// 基线之后新增的任务数（条目缺失）。与 `predictedTaskCount` 是两个口径（§4.3 / §5）。
    var addedTaskCount: Int
    /// 缺实际结束的已基线任务数：摘要按 plan 参与汇总时必须可见的「预测项」个数。
    var predictedTaskCount: Int
}

/// 基线面板的数据视图（纯值，无 SwiftUI）。
struct BaselinePanelModel: Hashable {
    /// 全部基线，按创建顺序（= 面板里的排列顺序）。
    var rows: [BaselinePanelRow]
    /// 底部两块的数据；无基线时为 nil（两块整体不渲染）。
    var statistics: BaselinePanelStatistics?

    var isEmpty: Bool { rows.isEmpty }

    init(rows: [BaselinePanelRow], statistics: BaselinePanelStatistics?) {
        self.rows = rows
        self.statistics = statistics
    }

    /// 空模型：面板未打开 / 项目还没有基线时占位（视图不必区分这两种情形）。
    static let empty = BaselinePanelModel(rows: [], statistics: nil)

    /// - Parameters:
    ///   - report: 焦点基线的偏差报告（只用于孤儿与「基线之后新增」计数）。
    ///     报告与焦点对不上时**整份丢弃**：宁可两块不显示，也不把另一条基线的数字
    ///     挂到这条基线名下（§4.5 任何偏差输出都必须带正确基线标识）。
    init(baselines: [Baseline], viewState: WorkspaceViewState, report: BaselineVarianceReport?) {
        let visible = viewState.normalizedVisibleBaselineIDs(in: baselines)
        let visibleIDs = Set(visible)
        let comparedID = viewState.normalizedBaselineID(in: baselines)
        // 颜色走读路径归一（不改数据、不置脏）：与菜单 / 甘特同一函数。
        let colors = BaselinePalette.resolve(baselines.map(\.colorIndex))
        let isFull = visible.count >= BaselineLanes.maxVisible

        rows = baselines.enumerated().map { index, baseline in
            let isVisible = visibleIDs.contains(baseline.id)
            return BaselinePanelRow(
                id: baseline.id,
                name: baseline.name,
                colorIndex: colors[index],
                createdAt: baseline.createdAt,
                entryCount: baseline.entries.count,
                isVisibleInGantt: isVisible,
                isCompared: baseline.id == comparedID,
                isVisibilityBlocked: isFull && !isVisible
            )
        }

        // 焦点 = 主对比基线；不比较时取最新一条（用户刚拍的那份最有参考价值）。
        let focusID = comparedID ?? baselines.last?.id
        guard let focusID,
              let focus = baselines.first(where: { $0.id == focusID }) else {
            statistics = nil
            return
        }
        let focused = report?.baselineID == focusID ? report : nil
        let entries: [BaselineEntry] = focused?.orphans ?? []
        var orphans: [BaselinePanelOrphan] = []
        orphans.reserveCapacity(entries.count)
        for entry in entries {
            orphans.append(BaselinePanelOrphan(
                id: entry.taskID,
                baselineID: focusID,
                start: entry.start,
                finish: entry.finish
            ))
        }
        // 顺序稳定（起点升序，同起点按任务 ID）：面板每次重建不该让孤儿行跳来跳去。
        orphans.sort {
            $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start
        }
        statistics = BaselinePanelStatistics(
            baselineID: focusID,
            name: focus.name,
            entryCount: focus.entries.count,
            orphans: orphans,
            addedTaskCount: focused?.tasksWithoutBaseline ?? 0,
            predictedTaskCount: focused?.predictedTaskCount ?? 0
        )
    }
}

/// 面板文案（§5 的「已删除任务」「基线之后新增」等固定说法）。
///
/// 集中在一处：视图只排布，措辞不散落在 body 里，测试也能直接断言
/// 「孤儿行带两个日期」「计数带数字」。
enum BaselinePanelText {
    /// 空态：没有基线。
    static var emptyTitle: String {
        I18n.t("panel.baseline.empty_title", "No Baselines Yet")
    }

    /// 空态指引：入口在哪（D-035 的教训——不写清楚就找不到）。
    static var emptyHint: String {
        I18n.t(
            "panel.baseline.empty_hint",
            "Create one from the Baseline menu to snapshot the current schedule."
        )
    }

    /// 甘特显示状态。
    static func visibility(_ isVisible: Bool) -> String {
        isVisible
            ? I18n.t("panel.baseline.visibility.shown", "Shown")
            : I18n.t("panel.baseline.visibility.hidden", "Hidden")
    }

    /// 主对比状态。
    static func compare(_ isCompared: Bool) -> String {
        isCompared
            ? I18n.t("panel.baseline.compare.on", "Comparing")
            : I18n.t("panel.baseline.compare.off", "Off")
    }

    /// 孤儿条目的占位标题：条目不存 title，只能说明「任务已删除」。
    static var orphanPlaceholder: String {
        I18n.t("panel.baseline.orphans.placeholder", "Deleted task")
    }

    /// 孤儿区块标题（含个数）。
    static func orphanCount(_ count: Int) -> String {
        I18n.t("panel.baseline.orphans.header", "Deleted baseline tasks: %1$ld", count)
    }

    /// 孤儿一行：承诺起止（排他端点，与大纲同口径）。
    static func orphanRange(_ orphan: BaselinePanelOrphan) -> String {
        I18n.t(
            "panel.baseline.orphans.range",
            "%1$@ → %2$@",
            Display.date(orphan.start),
            Display.date(orphan.finish)
        )
    }

    /// 「基线之后新增」计数（不含进项目偏差，§5）。
    ///
    /// 与 `predicted(_:)` 是两个口径：这里数「条目缺失的任务」，
    /// 那边数「有基线但还缺实际结束、只能拿 plan 顶上的任务」。
    static func added(_ count: Int) -> String {
        I18n.t("panel.baseline.added", "Tasks added after this baseline: %1$ld", count)
    }

    /// 预测项计数（§4.3：摘要按 plan 参与汇总时必须标出来，回落必须可见）。
    static func predicted(_ count: Int) -> String {
        I18n.t("panel.baseline.predicted", "Forecast items: %1$ld", count)
    }

    /// 底部两块作用于哪条基线（不写清就会以为是全项目汇总）。
    static func focus(_ name: String) -> String {
        I18n.t("panel.baseline.focus", "Details for “%1$@”", name)
    }

    /// 显隐已满上限时的解释（置灰的行凭什么点不动）。
    static func visibilityBlocked(_ count: Int) -> String {
        I18n.t(
            "panel.baseline.visibility_blocked",
            "Already showing %1$ld baselines (limit)",
            count
        )
    }
}
