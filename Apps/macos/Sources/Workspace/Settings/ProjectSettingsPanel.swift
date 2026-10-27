import SwiftUI
import KairoCore
import KairoPresentation

/// 项目设置面板（F-22-06 / docs/features/16-work-calendar.md）。
///
/// 三块内容按「先定工作周、再看折算、最后处理特例」排列：工作周决定甘特铺灰与工期单位，
/// 每日工时决定投入折算，例外日按天覆盖工作周。所有编辑**即时生效**（甘特与排期同步变），
/// 一次编辑一个撤销点（同一串连续调整在会话层按 mergeKey 合并）。
///
/// 样式沿用基线管理面板：图标徽章 + 标题 + 说明的头部、分区卡片、右对齐的底部按钮——
/// 不用系统裸对话框，因为这里有列表编辑，裸对话框放不下也不该放。
struct ProjectSettingsPanel: View {
    @ObservedObject var store: WorkspaceStore
    /// 编辑草稿：面板内的改动先落在本地，再整体折算成 `WorkCalendar?` 提交。
    @State private var draft: WorkCalendarDraft
    /// 是否停在「自定义」编辑态。
    ///
    /// 纯编辑态、不是项目数据：从 5 天模板点「自定义」时上班日还没变，
    /// 若只靠上班日反推，选择会立刻弹回「周一至周五」，7 个开关永远点不出来。
    /// 因此它留在视图里，不参与 `WorkCalendarDraft` 的比较与落盘。
    @State private var editsCustomWeekdays = false

    /// 星期开关按周一起排（与排期表的「周首 = 周一」惯例一致，不跟系统区域走）。
    private static let mondayFirstWeekdays = [2, 3, 4, 5, 6, 7, 1]

    init(store: WorkspaceStore) {
        _store = ObservedObject(wrappedValue: store)
        _draft = State(initialValue: WorkCalendarDraft(calendar: store.workCalendar))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                weekSection
                hoursSection
                statusDateSection
                exceptionsSection
            }
            .padding(16)
            // 固定几块之后不再有弹性内容：例外日再多也只滚动它自己的列表，
            // 工作周、工时与数据日期始终可见（不用整页滚动去找「今天改了没有」）。
            Spacer(minLength: 0)
            Divider()
            footer
        }
        // 高度比 v1.2 多 80：新增的数据日期段需要整段可见，
        // 例外日列表仍只滚自己那一块（上限不变），不会把工作周挤出视野。
        .frame(width: 620, height: 700)
        .background(DesignTokens.surfaceBase)
        // 面板开着时撤销 / 重做会换掉项目日历：草稿跟上，否则下一次编辑会把旧值写回去。
        .onChange(of: store.workCalendar) { _, value in
            let latest = WorkCalendarDraft(calendar: value)
            if latest != draft { draft = latest }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 16))
                .foregroundStyle(DesignTokens.accentStrong)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(I18n.t("panel.settings.title", "Project Settings"))
                    .font(.system(size: DesignTokens.bodyFontSize, weight: .semibold))
                    .foregroundStyle(DesignTokens.textPrimary)
                Text(I18n.t(
                    "panel.settings.subtitle",
                    "The working week, daily hours and exceptions drive scheduling and the shaded bands in the timeline."
                ))
                .font(.system(size: DesignTokens.captionFontSize))
                .foregroundStyle(DesignTokens.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 工作周

    private var weekSection: some View {
        section(I18n.t("panel.settings.section.week", "Working week")) {
            Picker("", selection: templateBinding) {
                ForEach(WorkWeekTemplate.allCases, id: \.self) { template in
                    Text(template.title).tag(template)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if editsCustomWeekdays || draft.template == .custom {
                weekdayToggles
            } else {
                Text(workingDaysSummary)
                    .font(.system(size: DesignTokens.captionFontSize))
                    .foregroundStyle(DesignTokens.textSecondary)
            }
        }
    }

    private var weekdayToggles: some View {
        HStack(spacing: 6) {
            ForEach(Self.mondayFirstWeekdays, id: \.self) { weekday in
                weekdayChip(weekday)
            }
            Spacer(minLength: 0)
        }
    }

    private func weekdayChip(_ weekday: Int) -> some View {
        let isOn = draft.weekdays.contains(weekday)
        return Button {
            draft.toggle(weekday)
            commit()
        } label: {
            Text(Display.weekdayName(weekday))
                .font(.system(size: DesignTokens.bodyFontSize, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? DesignTokens.surfaceBase : DesignTokens.textSecondary)
                .frame(width: 32, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isOn ? DesignTokens.accentStrong : DesignTokens.surfaceElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(DesignTokens.separator, lineWidth: isOn ? 0 : 1)
                )
        }
        .buttonStyle(.plain)
        .help(Display.weekdayFullName(weekday))
        .accessibilityLabel(Display.weekdayFullName(weekday))
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    /// 预设模板下的一句话摘要：让用户不用数开关就知道当前实际在哪些天上班。
    private var workingDaysSummary: String {
        let names = Self.mondayFirstWeekdays
            .filter { draft.weekdays.contains($0) }
            .map { Display.weekdayFullName($0) }
        return I18n.t("panel.settings.working_days", "Working days: %1$@", names.joined(separator: " · "))
    }

    // MARK: - 每日工时

    private var hoursSection: some View {
        section(I18n.t("panel.settings.section.hours", "Hours per working day")) {
            HStack(spacing: 8) {
                Text(String(format: "%g", draft.hoursPerDay))
                    .font(.system(size: DesignTokens.bodyFontSize, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.textPrimary)
                Stepper("", value: hoursBinding, in: 0.5 ... 24, step: 0.5)
                    .labelsHidden()
                Spacer(minLength: 0)
            }
            Text(I18n.t(
                "panel.settings.hours.help",
                "Effort hours are converted into duration with this figure; scheduling still counts whole working days."
            ))
            .font(.system(size: DesignTokens.captionFontSize))
            .foregroundStyle(DesignTokens.textSecondary)
        }
    }

    // MARK: - 数据日期

    /// 数据日期（v1.3 / 17-evm-status-date §2）：**报告参数**，不是排期输入。
    ///
    /// 未固定时按当天算，同一份周报明天再看就不同——这句话必须当场说出来，
    /// 用户才有理由去固定它；固定之后提示可复现，让「周报对得上」成为可验证的事。
    private var statusDateSection: some View {
        section(I18n.t("panel.settings.section.status_date", "Status date")) {
            HStack(spacing: 8) {
                Picker("", selection: statusDateModeBinding) {
                    Text(I18n.t("panel.settings.status_date.today", "Today (not fixed)"))
                        .tag(false)
                    Text(I18n.t("panel.settings.status_date.fixed", "Fixed to…"))
                        .tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 236)

                if let statusDate = store.statusDate {
                    DatePicker(
                        "",
                        selection: statusDatePickerBinding(statusDate),
                        displayedComponents: .date
                    )
                    .labelsHidden()
                    .frame(width: 124)
                } else {
                    Text(Display.date(Date()))
                        .font(.system(size: DesignTokens.bodyFontSize))
                        .foregroundStyle(DesignTokens.textSecondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Image(systemName: store.statusDate == nil ? "clock.arrow.circlepath" : "pin")
                    .font(.system(size: DesignTokens.captionFontSize))
                    .foregroundStyle(DesignTokens.textSecondary)
                Text(store.statusDate == nil
                    ? I18n.t(
                        "panel.settings.status_date.unfixed_note",
                        "Not fixed: every look is computed against today, so the same report differs tomorrow."
                    )
                    : I18n.t(
                        "panel.settings.status_date.fixed_note",
                        "Fixed: the report is reproducible."
                    ))
                .font(.system(size: DesignTokens.captionFontSize))
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 例外日

    private var exceptionsSection: some View {
        section(I18n.t("panel.settings.section.exceptions", "Exceptions")) {
            if draft.exceptions.isEmpty {
                emptyExceptions
            } else {
                // 只有列表自己滚动并封顶：例外日通常会堆到几十条，整页滚动会把
                // 「添加例外日」按钮推到看不见的地方。
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(draft.exceptions.enumerated()), id: \.offset) { index, exception in
                            exceptionRow(index: index, exception: exception)
                            if index < draft.exceptions.count - 1 { Divider() }
                        }
                    }
                }
                .frame(maxHeight: 168)
            }
            HStack(spacing: 8) {
                Button(I18n.t("panel.settings.exception.add", "Add Exception")) {
                    draft.addException(date: Date(), isWorking: false, note: nil)
                    commit()
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var emptyExceptions: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.system(size: DesignTokens.captionFontSize))
                .foregroundStyle(DesignTokens.textSecondary)
            Text(I18n.t(
                "panel.settings.exception.empty",
                "No exceptions yet. Add holidays or make-up workdays below."
            ))
            .font(.system(size: DesignTokens.captionFontSize))
            .foregroundStyle(DesignTokens.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func exceptionRow(index: Int, exception: CalendarException) -> some View {
        HStack(spacing: 8) {
            DatePicker(
                "",
                selection: dateBinding(index: index, exception: exception),
                displayedComponents: .date
            )
            .labelsHidden()
            .frame(width: 116)

            Picker("", selection: kindBinding(index: index, exception: exception)) {
                Text(I18n.t("panel.settings.exception.kind.holiday", "Holiday")).tag(false)
                Text(I18n.t("panel.settings.exception.kind.working", "Make-up workday")).tag(true)
            }
            .labelsHidden()
            .frame(width: 158)

            TextField(
                I18n.t("panel.settings.exception.note.placeholder", "Note (optional)"),
                text: noteBinding(index: index, exception: exception)
            )
            .textFieldStyle(.roundedBorder)

            Button {
                draft.removeException(at: index)
                commit()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(I18n.t("panel.settings.exception.delete", "Remove this exception"))
            .accessibilityLabel(I18n.t("panel.settings.exception.delete", "Remove this exception"))
        }
        .padding(.vertical, 2)
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 8) {
            Button(I18n.t("panel.settings.restore", "Restore Defaults (7-day week)")) {
                draft = WorkCalendarDraft(calendar: nil)
                editsCustomWeekdays = false
                commit()
            }
            .disabled(draft.isDefault)
            Spacer(minLength: 0)
            Button(I18n.t("panel.settings.done", "Done")) {
                store.dismissProjectSettings()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 绑定与提交

    private var templateBinding: Binding<WorkWeekTemplate> {
        Binding(
            get: { editsCustomWeekdays ? .custom : draft.template },
            set: { template in
                guard template != .custom else {
                    // 进自定义只是打开开关，不写库：上班日一个都没动，没有可提交的变更。
                    editsCustomWeekdays = true
                    return
                }
                editsCustomWeekdays = false
                draft.select(template)
                commit()
            }
        )
    }

    /// 「今天（未固定）/ 固定为…」：切到固定时从「今天」起步，
    /// 用户接下来只会微调日期，不该先面对一个空字段。切回未固定即清空字段。
    private var statusDateModeBinding: Binding<Bool> {
        Binding(
            get: { store.statusDate != nil },
            set: { isFixed in
                guard isFixed else {
                    store.dispatch(.setStatusDate(nil))
                    return
                }
                store.dispatch(.setStatusDate(store.statusDate ?? Date()))
            }
        )
    }

    private func statusDatePickerBinding(_ current: Date) -> Binding<Date> {
        Binding(
            get: { store.statusDate ?? current },
            set: { store.dispatch(.setStatusDate($0)) }
        )
    }

    private var hoursBinding: Binding<Double> {
        Binding(
            get: { draft.hoursPerDay },
            set: { hours in
                draft.setHoursPerDay(hours)
                commit()
            }
        )
    }

    private func dateBinding(index: Int, exception: CalendarException) -> Binding<Date> {
        Binding(
            get: { exception.date },
            set: { date in
                guard draft.exceptions.indices.contains(index) else { return }
                let current = draft.exceptions[index]
                draft.updateException(
                    at: index,
                    date: date,
                    isWorking: current.isWorking,
                    note: current.note
                )
                commit()
            }
        )
    }

    private func kindBinding(index: Int, exception: CalendarException) -> Binding<Bool> {
        Binding(
            get: { !exception.isWorking },
            set: { isHoliday in
                guard draft.exceptions.indices.contains(index) else { return }
                let current = draft.exceptions[index]
                draft.updateException(
                    at: index,
                    date: current.date,
                    isWorking: !isHoliday,
                    note: current.note
                )
                commit()
            }
        )
    }

    private func noteBinding(index: Int, exception: CalendarException) -> Binding<String> {
        Binding(
            get: { exception.note ?? "" },
            set: { text in
                guard draft.exceptions.indices.contains(index) else { return }
                let current = draft.exceptions[index]
                draft.updateException(
                    at: index,
                    date: current.date,
                    isWorking: current.isWorking,
                    note: text
                )
                commit()
            }
        )
    }

    /// 提交一次：草稿折算成值后交给会话（全默认时传 nil，文件不写日历键）。
    private func commit() {
        store.dispatch(.setWorkCalendar(draft.storedCalendar))
    }

    // MARK: - 分区容器

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: DesignTokens.captionFontSize, weight: .semibold))
                .foregroundStyle(DesignTokens.textSecondary)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.surfaceChrome, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
