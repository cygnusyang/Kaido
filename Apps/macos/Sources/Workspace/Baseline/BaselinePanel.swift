import SwiftUI
import ZenoCore
import ZenoPresentation

/// 基线管理面板（v0.15 / docs/features/08-baselines.md §5、10-multi-baseline-gantt.md §5）。
///
/// 菜单逐条下发命令快，适合「一眼切换」；但「有几条、各自多少条目、哪些任务已删除」
/// 这类需要对照阅读的信息在菜单里放不下——面板补的就是这块：一屏看全，行内可操作。
///
/// 信息密度与职责划分：
/// - 行：颜色 / 名称 / 创建时间 / 条目数 / 甘特显示 / 主对比 + 行内操作；
/// - 底部两块只回答**焦点基线**（主对比 ?? 最新）之后发生了什么：孤儿条目与基线后新增；
/// - 所有动作都走 `WorkspaceStore.dispatch`，面板不自己改模型；显隐与对比是纯视图状态，
///   改色 / 改名 / 删除照旧进撤销栈（§9-10）。
///
/// 删除不在面板内弹二次确认：主窗口的 `confirmationDialog` 是唯一确认出口（08 §11），
/// 面板与它同抢 `pendingBaselineDeletion` 会出两个对话框。故删除动作先登记待删
/// 再关掉面板，把确认交回主窗口——路径只有一条，撤销语义与菜单完全一致。
struct BaselinePanel: View {
    @ObservedObject var store: WorkspaceStore

    /// 正在改名的基线；非 nil 即弹出改名输入框。
    @State private var renaming: BaselinePanelRow?
    @State private var renameDraft = ""

    private var model: BaselinePanelModel { store.baselinePanel ?? .empty }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.isEmpty {
                emptyState
            } else {
                columnHeader
                Divider()
                baselineList
                Divider()
                statisticsSection
            }
            Divider()
            footer
        }
        .frame(width: 780, height: 580)
        .background(DesignTokens.surfaceBase)
        .alert(
            I18n.t("alert.baseline.rename.title", "Rename Baseline"),
            isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )
        ) {
            TextField(
                I18n.t("alert.baseline.rename.placeholder", "Baseline name"),
                text: $renameDraft
            )
            Button(I18n.t("action.ok", "OK")) { commitRename() }
            Button(I18n.t("action.cancel", "Cancel"), role: .cancel) { renaming = nil }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "flag.checkered")
                .font(.system(size: 16))
                .foregroundStyle(DesignTokens.accentStrong)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(I18n.t("panel.baseline.title", "Baselines"))
                    .font(.system(size: DesignTokens.bodyFontSize, weight: .semibold))
                    .foregroundStyle(DesignTokens.textPrimary)
                Text(I18n.t(
                    "panel.baseline.subtitle",
                    "Snapshots of the schedule. Showing in Gantt and comparing are independent."
                ))
                .font(.system(size: DesignTokens.captionFontSize))
                .foregroundStyle(DesignTokens.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 列表

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 10, height: 1)
            Text(I18n.t("panel.baseline.column.name", "Name"))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(I18n.t("panel.baseline.column.created", "Created"))
                .frame(width: 96, alignment: .leading)
            Text(I18n.t("panel.baseline.column.entries", "Tasks"))
                .frame(width: 56, alignment: .trailing)
            Text(I18n.t("panel.baseline.column.gantt", "Gantt"))
                .frame(width: 64, alignment: .center)
            Text(I18n.t("panel.baseline.column.compare", "Compare"))
                .frame(width: 84, alignment: .center)
            Color.clear.frame(width: 88, height: 1)
        }
        .font(.system(size: DesignTokens.captionFontSize))
        .foregroundStyle(DesignTokens.textSecondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var baselineList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.rows) { row in
                    rowView(row)
                    Divider()
                }
            }
        }
    }

    private func rowView(_ row: BaselinePanelRow) -> some View {
        HStack(spacing: 8) {
            BaselineSwatch.image(row.colorIndex)
            Text(row.name)
                .font(.system(size: DesignTokens.bodyFontSize))
                .foregroundStyle(DesignTokens.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(Display.date(row.createdAt))
                .font(.system(size: DesignTokens.captionFontSize))
                .foregroundStyle(DesignTokens.textSecondary)
                .frame(width: 96, alignment: .leading)
            Text("\(row.entryCount)")
                .font(.system(size: DesignTokens.bodyFontSize))
                .monospacedDigit()
                .foregroundStyle(DesignTokens.textSecondary)
                .frame(width: 56, alignment: .trailing)
            visibilityBadge(row)
            compareBadge(row)
            actions(row)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(minHeight: DesignTokens.rowHeight + 8)
    }

    private func visibilityBadge(_ row: BaselinePanelRow) -> some View {
        Text(BaselinePanelText.visibility(row.isVisibleInGantt))
            .font(.system(size: DesignTokens.captionFontSize))
            .foregroundStyle(row.isVisibleInGantt ? DesignTokens.accentStrong : DesignTokens.textSecondary)
            .frame(width: 64, alignment: .center)
    }

    private func compareBadge(_ row: BaselinePanelRow) -> some View {
        Text(BaselinePanelText.compare(row.isCompared))
            .font(.system(size: DesignTokens.captionFontSize, weight: row.isCompared ? .semibold : .regular))
            .foregroundStyle(row.isCompared ? DesignTokens.accentStrong : DesignTokens.textSecondary)
            .frame(width: 84, alignment: .center)
    }

    /// 行内操作：改显隐 / 设为主对比（两个高频单点动作直接给按钮）+ 其余进「⋯」。
    private func actions(_ row: BaselinePanelRow) -> some View {
        HStack(spacing: 2) {
            Button {
                store.dispatch(.setBaselineVisible(row.id, !row.isVisibleInGantt))
            } label: {
                Image(systemName: row.isVisibleInGantt ? "eye" : "eye.slash")
            }
            .buttonStyle(.borderless)
            .disabled(row.isVisibilityBlocked)
            .help(row.isVisibilityBlocked
                ? BaselinePanelText.visibilityBlocked(BaselineLanes.maxVisible)
                : I18n.t("panel.baseline.action.toggle_gantt", "Show / Hide in Gantt"))

            Button {
                store.dispatch(.setBaseline(row.id))
            } label: {
                Image(systemName: row.isCompared ? "flag.fill" : "flag")
            }
            .buttonStyle(.borderless)
            .disabled(row.isCompared)
            .help(I18n.t("panel.baseline.action.compare", "Set as Compared Baseline"))

            Menu {
                Menu(I18n.t("menu.baseline.color_menu", "Color")) {
                    ForEach(0 ..< BaselineColorNames.count, id: \.self) { colorIndex in
                        Button(BaselineMenuMark.title(
                            BaselineColorNames.title(colorIndex),
                            isOn: colorIndex == row.colorIndex
                        )) {
                            store.dispatch(.setBaselineColor(row.id, colorIndex))
                        }
                    }
                }
                Button(I18n.t("menu.baseline.rename", "Rename Baseline…")) {
                    renameDraft = row.name
                    renaming = row
                }
                Divider()
                Button(I18n.t("panel.baseline.action.delete", "Delete…"), role: .destructive) {
                    // 二次确认交回主窗口（面板内再弹一个就会有两个对话框），故先关面板。
                    store.requestDeleteBaseline(id: row.id)
                    store.dismissBaselinePanel()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
            .help(I18n.t("panel.baseline.action.more", "More Actions"))
        }
        .frame(width: 88, alignment: .trailing)
    }

    private func commitRename() {
        guard let target = renaming, let name = BaselineRenamePrompt.normalized(renameDraft) else {
            renaming = nil
            return
        }
        renaming = nil
        store.dispatch(.renameBaseline(target.id, name))
    }

    // MARK: - 底部两块

    private var statisticsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let statistics = model.statistics {
                statisticsContent(statistics)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func statisticsContent(_ statistics: BaselinePanelStatistics) -> some View {
        HStack(spacing: 12) {
            Text(BaselinePanelText.focus(statistics.name))
                .font(.system(size: DesignTokens.captionFontSize, weight: .semibold))
                .foregroundStyle(DesignTokens.textPrimary)
            Text(BaselinePanelText.added(statistics.addedTaskCount))
                .font(.system(size: DesignTokens.captionFontSize))
                .foregroundStyle(DesignTokens.textSecondary)
            Text(BaselinePanelText.predicted(statistics.predictedTaskCount))
                .font(.system(size: DesignTokens.captionFontSize))
                .foregroundStyle(DesignTokens.textSecondary)
            Spacer(minLength: 0)
        }
        Text(BaselinePanelText.orphanCount(statistics.orphans.count))
            .font(.system(size: DesignTokens.captionFontSize))
            .foregroundStyle(DesignTokens.textSecondary)
        orphanList(statistics.orphans)
    }

    @ViewBuilder
    private func orphanList(_ orphans: [BaselinePanelOrphan]) -> some View {
        if orphans.isEmpty {
            Text(I18n.t("panel.baseline.orphans.none", "None"))
                .font(.system(size: DesignTokens.captionFontSize))
                .foregroundStyle(DesignTokens.textSecondary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(orphans) { orphan in
                        HStack(spacing: 8) {
                            Image(systemName: "minus.circle")
                                .font(.system(size: DesignTokens.captionFontSize))
                                .foregroundStyle(DesignTokens.textSecondary)
                            Text(BaselinePanelText.orphanPlaceholder)
                                .font(.system(size: DesignTokens.captionFontSize))
                                .foregroundStyle(DesignTokens.textSecondary)
                            Text(BaselinePanelText.orphanRange(orphan))
                                .font(.system(size: DesignTokens.captionFontSize))
                                .monospacedDigit()
                                .foregroundStyle(DesignTokens.textPrimary)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 92)
        }
    }

    // MARK: - 空态 / 底部

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            Image(systemName: "flag.checkered")
                .font(.system(size: 24))
                .foregroundStyle(DesignTokens.textSecondary)
            Text(BaselinePanelText.emptyTitle)
                .font(.system(size: DesignTokens.bodyFontSize, weight: .semibold))
                .foregroundStyle(DesignTokens.textPrimary)
            Text(BaselinePanelText.emptyHint)
                .font(.system(size: DesignTokens.captionFontSize))
                .foregroundStyle(DesignTokens.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button(I18n.t("panel.baseline.close", "Close")) {
                store.dismissBaselinePanel()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
