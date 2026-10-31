import Foundation
import ZenoCore
import ZenoPresentation

/// 一条基线在「基线」菜单里的状态（v0.14 / docs/features/10-multi-baseline-gantt.md §5）。
///
/// 纯值：菜单栏与测试读同一份折算结果，避免「菜单里勾着的」与「甘特图画着的」各算一套。
struct BaselineMenuItem: Identifiable, Hashable {
    /// 基线 ID：同时是命令 id 的稳定键（删掉中间一条不会让命令指到别的基线）。
    var id: UUID
    /// 用户数据，原样显示，不做本地化。
    var name: String
    /// 归一化后的调色板索引：旧文件缺 colorIndex / 越界 / 重复时也能给出确定颜色。
    var colorIndex: Int
    /// 「在甘特图中显示」是否勾选。
    var isVisibleInGantt: Bool
    /// 是否为当前对比基线（单选，驱动大纲四列与检查器）。
    var isCompared: Bool
    /// 已满 BaselineLanes.maxVisible 条且本身未显示：会话会拒绝勾选，
    /// 菜单据此置灰，并由底部「另有 N 条未显示」解释原因——而不是让点了没反应。
    var isVisibilityBlocked: Bool
    var createdAt: Date
}

/// 「基线」菜单的数据视图（纯值，无 SwiftUI）。
///
/// 两个概念各算各的（§6）：isVisibleInGantt 是**多选**画图，isCompared 是**单选**读数。
struct BaselineMenuModel: Hashable {
    /// 全部基线，按创建顺序（= 菜单里的排列顺序）。
    var items: [BaselineMenuItem]
    /// 图例，顺序 = 甘特轨道顺序（normalizedVisibleBaselineIDs：创建顺序、已截断到上限）。
    var legend: [BaselineLegendItem]
    /// **被显示上限截断**的条数（不是「没勾上的条数」）；0 时不出现「另有 N 条未显示」。
    ///
    /// 只在勾选已满 BaselineLanes.maxVisible 时才非零：那条提示解释的是「为什么第 4 条
    /// 画不出来」，而不是替用户数「我还有几条没勾」。故 1 条基线没勾 / 5 条只勾 1 条
    /// 都不出提示，只有「3 条占满 + 还有剩」才出。
    var hiddenCount: Int
    /// 「不对比」是否打勾（没有可用的对比基线时为真）。
    var isCompareCleared: Bool

    init(baselines: [Baseline], viewState: WorkspaceViewState) {
        let visible = viewState.normalizedVisibleBaselineIDs(in: baselines)
        let visibleIDs = Set(visible)
        let comparedID = viewState.normalizedBaselineID(in: baselines)
        // 颜色索引走读路径归一（不改数据、不置脏）：与 Presenter 同一函数，
        // 两处派生结果必须一致，否则菜单里的色点会和图上的条对不上。
        let colors = BaselinePalette.resolve(baselines.map(\.colorIndex))
        let isFull = visible.count >= BaselineLanes.maxVisible

        items = baselines.enumerated().map { index, baseline in
            let isVisible = visibleIDs.contains(baseline.id)
            return BaselineMenuItem(
                id: baseline.id,
                name: baseline.name,
                colorIndex: colors[index],
                isVisibleInGantt: isVisible,
                isCompared: baseline.id == comparedID,
                isVisibilityBlocked: isFull && !isVisible,
                createdAt: baseline.createdAt
            )
        }

        var colorByID: [UUID: Int] = [:]
        for (baseline, color) in zip(baselines, colors) {
            colorByID[baseline.id] = color
        }
        legend = visible.compactMap { id in
            guard let baseline = baselines.first(where: { $0.id == id }) else { return nil }
            return BaselineLegendItem(
                baselineID: id,
                name: baseline.name,
                colorIndex: colorByID[id] ?? 0,
                createdAt: baseline.createdAt
            )
        }
        hiddenCount = visible.count >= BaselineLanes.maxVisible
            ? max(baselines.count - visible.count, 0)
            : 0
        isCompareCleared = comparedID == nil
    }

    /// 图例一行：名称 · 颜色名 · 创建日期（§4：名称 + 创建日期，色名兜底色块在菜单里被灰化）。
    static func legendTitle(_ item: BaselineLegendItem) -> String {
        I18n.t(
            "menu.baseline.legend.item",
            "%1$@ · %2$@ · %3$@",
            item.name,
            BaselineColorNames.title(item.colorIndex),
            Display.date(item.createdAt)
        )
    }
}

/// 菜单勾选前缀：与既有缩放 / 对比菜单同一写法（勾中项前加「✓ 」，非本地化文案）。
enum BaselineMenuMark {
    static func title(_ title: String, isOn: Bool) -> String {
        isOn ? "✓ \(title)" : title
    }
}

/// 调色板颜色名（索引 0…7）：只用于菜单文字与图例。
///
/// 颜色值在 DesignTokens.baselinePalette，名字在 String Catalog 里；
/// 两边的顺序都以 BaselinePalette.count 为约束（数量由测试断言）。
enum BaselineColorNames {
    static var count: Int { BaselinePalette.count }

    static func title(_ index: Int) -> String {
        switch index {
        case 0: return I18n.t("baseline.color.teal", "Teal")
        case 1: return I18n.t("baseline.color.amber", "Amber")
        case 2: return I18n.t("baseline.color.green", "Green")
        case 3: return I18n.t("baseline.color.magenta", "Magenta")
        case 4: return I18n.t("baseline.color.olive", "Olive")
        case 5: return I18n.t("baseline.color.indigo", "Indigo")
        case 6: return I18n.t("baseline.color.brown", "Brown")
        case 7: return I18n.t("baseline.color.steel_blue", "Steel Blue")
        default: return I18n.t("baseline.color.unknown", "Color %1$ld", index)
        }
    }
}
