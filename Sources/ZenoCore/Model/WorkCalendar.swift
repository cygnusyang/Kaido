import Foundation

/// 单个日期的工作日例外（F-22-06 / 16-work-calendar §2）。
///
/// 两个方向共用一种记录：「国庆放假」把工作日标成非工作日，「周六补班」把周末标成工作日。
/// `date` 存项目时区的当天零点，与排期里所有日期同一口径（整日、本地零点）。
public struct CalendarException: Codable, Hashable, Sendable {
    /// 例外日期（当天零点）。
    public var date: Date
    /// `false` = 节假日（该日不工作）；`true` = 调休上班（该日工作）。
    public var isWorking: Bool
    /// 备注（「国庆」「春节调休」），仅用于展示。
    public var note: String?

    public init(date: Date, isWorking: Bool, note: String? = nil) {
        self.date = date
        self.isWorking = isWorking
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case date, isWorking, note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(Date.self, forKey: .date)
        isWorking = try c.decode(Bool.self, forKey: .isWorking)
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }
}

/// 项目工作日历（F-22-06 / 16-work-calendar）。
///
/// 语义只有一条：**工期单位是工作日**。默认 `workingWeekdays` 为全周 7 天时，
/// 工作日与日历天重合，排期结果与 v1.0.x 完全一致（D1：兼容性的唯一保证）。
///
/// 工作职别用 `Calendar` 的 weekday 编号（1 = 周日 … 7 = 周六），与
/// `GanttLayout.nonWorkingWeekdays` 同一口径，两处不必再换一次编号。
public struct WorkCalendar: Codable, Hashable, Sendable {
    /// 全周 7 天上班：默认值，与「没有日历」等价。
    public static let allWeekdays: Set<Int> = [1, 2, 3, 4, 5, 6, 7]
    /// 周一至周五上班（最常见的项目日历）。
    public static let mondayToFriday: Set<Int> = [2, 3, 4, 5, 6]

    /// 一周里上班的日子（1 = 周日 … 7 = 周六）。
    public var workingWeekdays: Set<Int>
    /// 例外日（节假日 / 调休）；同日重复时后一条生效。
    public var exceptions: [CalendarException]
    /// 一个工作日折算的工时，用于 `投入小时 ÷ (hoursPerDay × 人数) → 工期`。
    public var hoursPerDay: Double

    public init(
        workingWeekdays: Set<Int> = WorkCalendar.allWeekdays,
        exceptions: [CalendarException] = [],
        hoursPerDay: Double = 8
    ) {
        self.workingWeekdays = workingWeekdays
        self.exceptions = exceptions
        self.hoursPerDay = hoursPerDay
    }

    // MARK: - Codable 兼容（ADR-011：新增字段缺失给默认值）

    private enum CodingKeys: String, CodingKey {
        case workingWeekdays, exceptions, hoursPerDay
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workingWeekdays = try c.decodeIfPresent(Set<Int>.self, forKey: .workingWeekdays)
            ?? WorkCalendar.allWeekdays
        exceptions = try c.decodeIfPresent([CalendarException].self, forKey: .exceptions) ?? []
        let hours = try c.decodeIfPresent(Double.self, forKey: .hoursPerDay) ?? 8
        // 非正工时会算出无穷工期（effort ÷ 0）：按「未设置」回落到 8，不静默产出脏排期。
        hoursPerDay = hours > 0 ? hours : 8
    }

    // MARK: - 派生

    /// 归一化后的工作周：剔除 1…7 之外的脏值；**空集合退化为全周 7 天**（D3 边界）。
    ///
    /// 退化而不是报错，是因为排期是纯函数、没有「拒绝」的出口：返回空窗口比按全周排
    /// 更糟（任务全部落空），而死循环更不可接受。退化事实由 `isDegenerate` 暴露，
    /// 调度层据此产出一条 info 违例说明「日历不可用，已按全周排」。
    public var effectiveWeekdays: Set<Int> {
        let valid = workingWeekdays.filter { (1...7).contains($0) }
        return valid.isEmpty ? WorkCalendar.allWeekdays : valid
    }

    /// 用于工期的每工作日工时：非正值按 8 计（脏数据不得算出无穷工期）。
    public var effectiveHoursPerDay: Double {
        hoursPerDay > 0 ? hoursPerDay : 8
    }

    /// `workingWeekdays` 是否为空（或全是越界值）而被退化为全周。
    public var isDegenerate: Bool {
        workingWeekdays.allSatisfy { !(1...7).contains($0) }
    }

    /// 甘特铺灰用的非工作日（与 `GanttLayout.nonWorkingWeekdays` 同口径）：工作周的补集。
    /// 只影响绘制，不参与排期：排期看 `isWorkingDay`（含例外日，铺灰只看周设置）。
    public var nonWorkingWeekdays: Set<Int> {
        WorkCalendar.allWeekdays.subtracting(effectiveWeekdays)
    }

    /// 是否「每天都上班且无例外」——此时工作日算术与日历日算术逐位相等。
    public var isEveryDayWorking: Bool {
        exceptions.isEmpty && effectiveWeekdays == WorkCalendar.allWeekdays
    }

    // MARK: - 工作日算术

    /// 某一天是否上班：例外日优先于工作周设置。
    public func isWorkingDay(_ date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Bool {
        WorkDayResolver(workCalendar: self, calendar: calendar).isWorkingDay(date)
    }

    /// 当天或之后第一个工作日（时间归到当天零点）。
    public func nextWorkingDay(
        onOrAfter date: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> Date {
        WorkDayResolver(workCalendar: self, calendar: calendar).nextWorkingDay(onOrAfter: date)
    }

    /// 当天或之前第一个工作日（时间归到当天零点）。
    public func previousWorkingDay(
        onOrBefore date: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> Date {
        WorkDayResolver(workCalendar: self, calendar: calendar).previousWorkingDay(onOrBefore: date)
    }

    /// 按工作日加减：`addingWorkDays(5, to: 周五)` = 下周五（与 `finish = start + 工期` 的
    /// 半开区间口径一致：5 个工作日指起点之后数 5 个工作日）。
    ///
    /// 小数部分按 86 400 秒折算到日内时刻，与日历日算术同口径（投入驱动的非整数工期）。
    public func addingWorkDays(
        _ days: Double,
        to date: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> Date {
        WorkDayResolver(workCalendar: self, calendar: calendar).addingWorkDays(days, to: date)
    }

    /// 两个日期之间隔了几个工作日（可为小数、可为负）。
    public func workDaysBetween(
        _ from: Date,
        _ to: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> Double {
        WorkDayResolver(workCalendar: self, calendar: calendar).workDaysBetween(from, to)
    }
}

/// 工作日算术的执行体：把日历归一化一次，供一次排期里的成千次查询复用。
///
/// 公开模型 `WorkCalendar` 的方法每次调用都新建一个解析器（对单次查询无所谓），
/// 调度引擎则在入口建一次、全程复用——否则每个任务每个日期都要重算工作周与例外表。
struct WorkDayResolver {
    let calendar: Calendar
    /// 归一化后的工作周（非空）。
    let weekdays: Set<Int>
    /// 例外日：键为当天零点。
    let exceptionByDay: [Date: Bool]
    /// 工作周为空而被退化为全周（供调度层产出 info 违例）。
    let isDegenerate: Bool

    /// 十天兜底：连续十天都非工作日（脏到极端）时不再滚动，避免异常数据把排期挂死。
    private static let maxScanDays = 3660
    /// 一天的秒数：小数工作日余量折算用（与 `ScheduleEngine` 同口径）。
    private static let secondsPerDay: Double = 86_400

    init(workCalendar: WorkCalendar?, calendar: Calendar) {
        self.calendar = calendar
        let value = workCalendar ?? WorkCalendar()
        self.weekdays = value.effectiveWeekdays
        self.isDegenerate = value.isDegenerate
        var map: [Date: Bool] = [:]
        // 同日多条例外：后写的覆盖先写的（数组顺序即用户书写顺序）。
        for exception in value.exceptions {
            map[calendar.startOfDay(for: exception.date)] = exception.isWorking
        }
        self.exceptionByDay = map
    }

    /// 每天都上班且无例外：工作日的算术可以直接走日历日算术（保证与旧行为逐位相等）。
    var isPlainWeek: Bool {
        weekdays.count == 7 && exceptionByDay.isEmpty
    }

    /// 向后再吸附到工作日；全周上班时原样返回（不做零点归一，避免截断日内余量）。
    func snapping(_ date: Date) -> Date {
        isPlainWeek ? date : nextWorkingDay(onOrAfter: date)
    }

    /// 向前吸附到工作日；全周上班时原样返回。
    func snappingBackward(_ date: Date) -> Date {
        isPlainWeek ? date : previousWorkingDay(onOrBefore: date)
    }

    func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    func isWorkingDay(_ date: Date) -> Bool {
        let day = calendar.startOfDay(for: date)
        if let overridden = exceptionByDay[day] { return overridden }
        let weekday = calendar.component(.weekday, from: day)
        return weekdays.contains(weekday)
    }

    func nextWorkingDay(onOrAfter date: Date) -> Date {
        var cursor = calendar.startOfDay(for: date)
        var scanned = 0
        while !isWorkingDay(cursor) {
            guard scanned < Self.maxScanDays,
                  let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
            scanned += 1
        }
        return cursor
    }

    func previousWorkingDay(onOrBefore date: Date) -> Date {
        var cursor = calendar.startOfDay(for: date)
        var scanned = 0
        while !isWorkingDay(cursor) {
            guard scanned < Self.maxScanDays,
                  let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
            scanned += 1
        }
        return cursor
    }

    func addingWorkDays(_ days: Double, to date: Date) -> Date {
        let wholeDays = days.rounded(.towardZero)
        let base: Date
        if wholeDays == 0 {
            base = date
        } else if isPlainWeek && exceptionByDay.isEmpty {
            // 全周上班：一次 `Calendar` 整日加减，与 v1.0.x 的 `addDays` 完全一致。
            if let whole = Int(exactly: wholeDays),
               let shifted = calendar.date(byAdding: .day, value: whole, to: date) {
                base = shifted
            } else {
                base = date.addingTimeInterval(wholeDays * Self.secondsPerDay)
            }
        } else {
            base = step(date, workDays: wholeDays)
        }
        let remainder = days - wholeDays
        return remainder == 0 ? base : base.addingTimeInterval(remainder * Self.secondsPerDay)
    }

    func workDaysBetween(_ from: Date, _ to: Date) -> Double {
        if isPlainWeek { return calendarDaysBetween(from, to) }
        let fromDay = calendar.startOfDay(for: from)
        let toDay = calendar.startOfDay(for: to)
        var count = 0.0
        var cursor = fromDay
        var scanned = 0
        if toDay >= fromDay {
            while cursor < toDay, scanned < Self.maxScanDays {
                if isWorkingDay(cursor) { count += 1 }
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
                scanned += 1
            }
        } else {
            while cursor > toDay, scanned < Self.maxScanDays {
                if isWorkingDay(cursor) { count -= 1 }
                guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
                cursor = previous
                scanned += 1
            }
        }
        // 日内余量：两端相对各自零点的偏移差，按 86 400 秒折算（跨 DST 的整日部分已由上面按日计）。
        let fraction = (to.timeIntervalSince(toDay) - from.timeIntervalSince(fromDay)) / Self.secondsPerDay
        return count + fraction
    }

    // MARK: - 私有

    /// 按工作日整日滚动（`workDays` 为同号整数）；方向由符号决定。
    private func step(_ date: Date, workDays: Double) -> Date {
        let delta = workDays > 0 ? 1 : -1
        var remaining = Int(workDays.magnitude)
        var cursor = date
        var scanned = 0
        while remaining > 0, scanned < Self.maxScanDays {
            guard let next = calendar.date(byAdding: .day, value: delta, to: cursor) else { break }
            cursor = next
            scanned += 1
            if isWorkingDay(cursor) { remaining -= 1 }
        }
        return cursor
    }

    /// 日历日差（整日走 `Calendar`，余量按 86 400 秒折算）：与旧实现逐位相同。
    private func calendarDaysBetween(_ from: Date, _ to: Date) -> Double {
        let wholeDays = calendar.dateComponents([.day], from: from, to: to).day ?? 0
        guard let shifted = calendar.date(byAdding: .day, value: wholeDays, to: from) else {
            return to.timeIntervalSince(from) / Self.secondsPerDay
        }
        return Double(wholeDays) + to.timeIntervalSince(shifted) / Self.secondsPerDay
    }
}
