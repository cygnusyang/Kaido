import Foundation
import KaidoCore

/// 工作周模板（项目设置面板的四选一）。
///
/// 只有 4 个预设，任意别的组合一律落到 `.custom`：模板是**读取**时从上班日集合反推的，
/// 不是另存一份状态——否则「集合」与「模板」两处迟早漂移。
enum WorkWeekTemplate: CaseIterable, Hashable, Sendable {
    /// 全周 7 天（默认，与「没有日历」等价）。
    case sevenDays
    /// 周一至周六。
    case sixDays
    /// 周一至周五。
    case fiveDays
    /// 自定义：由面板上 7 个星期开关决定。
    case custom

    /// 模板预设的上班日（`Calendar` 星期序号，1 = 周日 … 7 = 周六）；`.custom` 无预设。
    var weekdays: Set<Int>? {
        switch self {
        case .sevenDays: return WorkCalendar.allWeekdays
        case .sixDays: return [2, 3, 4, 5, 6, 7]
        case .fiveDays: return WorkCalendar.mondayToFriday
        case .custom: return nil
        }
    }

    /// 面板选项标题。
    var title: String {
        switch self {
        case .sevenDays: return I18n.t("panel.settings.template.seven", "7 days")
        case .sixDays: return I18n.t("panel.settings.template.six", "Mon–Sat")
        case .fiveDays: return I18n.t("panel.settings.template.five", "Mon–Fri")
        case .custom: return I18n.t("panel.settings.template.custom", "Custom")
        }
    }
}

/// 项目设置面板的编辑草稿：面板只改这份值，提交时一次性折算成 `WorkCalendar?`。
///
/// 抽成纯类型而不是把逻辑写在视图里，是因为三条判定值得被单元测试钉住：
/// 模板反推、同日例外只留一条、以及「全默认 ⇒ nil」（不写键、不改变渲染）。
struct WorkCalendarDraft: Equatable {
    /// 面板默认每日工时（与 `WorkCalendar` 的默认值同一口径）。
    static let defaultHoursPerDay: Double = 8

    /// 上班日（1 = 周日 … 7 = 周六）。
    var weekdays: Set<Int>
    /// 一个工作日折算的工时。
    var hoursPerDay: Double
    /// 例外日；同一天最多一条，按日期升序。
    var exceptions: [CalendarException]

    init(calendar: WorkCalendar?) {
        let value = calendar ?? WorkCalendar()
        // 脏值 / 空集合先按引擎口径归一：面板只展示真正生效的工作周，不把越界值带进 UI。
        weekdays = value.effectiveWeekdays
        hoursPerDay = value.effectiveHoursPerDay
        exceptions = value.exceptions.sorted { $0.date < $1.date }
    }

    /// 当前上班日反推出的模板。
    var template: WorkWeekTemplate {
        switch weekdays {
        case WorkCalendar.allWeekdays: return .sevenDays
        case [2, 3, 4, 5, 6, 7]: return .sixDays
        case WorkCalendar.mondayToFriday: return .fiveDays
        default: return .custom
        }
    }

    /// 是否已是最保守的默认值（全周 7 天 + 默认工时 + 无例外）。
    var isDefault: Bool { storedCalendar == nil }

    /// 提交给会话的值。
    ///
    /// 全周 7 天 + 默认工时 + 无例外时不落任何日历：`.kaido` 不写该键，
    /// 排期与甘特渲染回到引入工作日历之前——「恢复默认」要真的恢复，而不是存一份等价物。
    var storedCalendar: WorkCalendar? {
        let value = WorkCalendar(
            workingWeekdays: weekdays,
            exceptions: exceptions,
            hoursPerDay: hoursPerDay
        )
        if value.isEveryDayWorking && value.effectiveHoursPerDay == Self.defaultHoursPerDay {
            return nil
        }
        return value
    }

    // MARK: - 编辑

    /// 选模板：只接受三个预设；`.custom` 是面板的编辑态（不改上班日、不写库），
    /// 由视图自己维护，因此这里忽略它。
    mutating func select(_ template: WorkWeekTemplate) {
        guard let days = template.weekdays else { return }
        weekdays = days
    }

    /// 切一个星期的上班 / 下班。
    ///
    /// 最后一个上班日不允许关掉：空集合会被引擎退化成全周 7 天（`isDegenerate`），
    /// 用户以为「全都不上班」，排期却按 7 天走——这是界面必须挡住的边界。
    mutating func toggle(_ weekday: Int) {
        guard (1...7).contains(weekday) else { return }
        if weekdays.contains(weekday) {
            guard weekdays.count > 1 else { return }
            weekdays.remove(weekday)
        } else {
            weekdays.insert(weekday)
        }
    }

    /// 设每日工时；非正值按默认值处理（与引擎的 `effectiveHoursPerDay` 同口径）。
    mutating func setHoursPerDay(_ hours: Double) {
        hoursPerDay = hours > 0 ? hours : Self.defaultHoursPerDay
    }

    /// 新增一条例外日；同日已有条目被替换（引擎「后写覆盖先写」的语义在界面上落到实处）。
    mutating func addException(
        date: Date,
        isWorking: Bool,
        note: String?,
        calendar: Calendar = .current
    ) {
        upsert(date: date, isWorking: isWorking, note: note, replacing: nil, calendar: calendar)
    }

    /// 改第 index 条例外日（日期 / 类型 / 备注）；日期撞到别的条目时，后者被替换。
    mutating func updateException(
        at index: Int,
        date: Date,
        isWorking: Bool,
        note: String?,
        calendar: Calendar = .current
    ) {
        upsert(date: date, isWorking: isWorking, note: note, replacing: index, calendar: calendar)
    }

    mutating func removeException(at index: Int) {
        guard exceptions.indices.contains(index) else { return }
        exceptions.remove(at: index)
    }

    // MARK: - 私有

    private mutating func upsert(
        date: Date,
        isWorking: Bool,
        note: String?,
        replacing index: Int?,
        calendar: Calendar
    ) {
        let day = calendar.startOfDay(for: date)
        let entry = CalendarException(
            date: day,
            isWorking: isWorking,
            note: Self.normalized(note)
        )
        var next = exceptions
        if let index, next.indices.contains(index) { next.remove(at: index) }
        next.removeAll { calendar.startOfDay(for: $0.date) == day }
        next.append(entry)
        // 稳定序：面板按日期升序展示，用户读到的顺序与「哪条覆盖哪条」无关。
        next.sort { $0.date < $1.date }
        exceptions = next
    }

    /// 备注归一：空白等价于没写（不落空字符串，读回来也不会显示一行空白）。
    private static func normalized(_ note: String?) -> String? {
        guard let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
