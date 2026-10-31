import Foundation
import KaidoInterop

/// 写出结果：MSPDI 字节 + 导出侧有损登记。
///
/// 「FormatAdapter.write」只能返回 Data，但「取消原因 / 基线颜色 / blocked」这些 Kaido 独有
/// 信息按 13-mapping §5 必须落**导出旁注文件**、不得写进对方的 Notes。因此写出端另外暴露
/// 这份登记：上层拿到后自行渲染「<项目名>.kaido-export-notes.md」。
public struct MSPDIExport: Sendable, Equatable {
    /// 写出的 MSPDI 文档（UTF-8）。
    public let data: Data
    /// 导出侧有损登记（已并入 InteropDocument.ledger 中上层预置的说明）。
    public let ledger: FidelityLedger

    public init(data: Data, ledger: FidelityLedger) {
        self.data = data
        self.ledger = ledger
    }
}

/// MS Project XML（MSPDI）写出（docs/features/14-interop-architecture.md P1）。
///
/// 边界与读入同一套硬规则：
/// - 只 import KaidoInterop，不认识 Kaido 的业务模型；
/// - **不做「工作日 ↔ 日历天」换算**，日期按 IR 原样写出（换算只在 KaidoBridge）；
/// - 输出只由输入决定：同一份 IR 写两次字节完全相同（不生成随机 GUID、不读当前时间）。
///
/// ## 日期口径：为什么默认写 7 天工作周
///
/// Kaido 按**日历天**排期（一周 7 天都算工作日），MSPDI 按**工作日**推进。同一个日期在两种
/// 口径下每天差一天，FS 链会随链长线性漂移。所以 Kaido 侧导出的文档**写 7 天全工作周日历**，
/// 让 IR 的一天恰好等于 MSPDI 的一个工作日——日期可以无损往返，对方的「工期 5 天」也正好
/// 覆盖 5 个自然日。
///
/// 唯一的例外：IR 里的日历本身就是 5/6 天工作周（多来自用户导入的对方文件）。那份日期是
/// 按来源工作日算出来的，**如实写出原日历**才保真；代价是「导出后按工作日推进，日期可能与
/// Kaido 里的原计划不同」，必须登记到 FidelityLedger 让用户看见，不能静默处理。
///
/// ## Kaido 独有信息
///
/// 取消原因、blocked 状态、基线颜色等 **绝不写进 Task/Notes**（会污染对方的备注原文）。
/// 任务级信息在 IR 里用 InteropTask.attributes 的「kaido.」保留前缀承载，写出时被剥离并
/// 登记；文档级信息由上层预置在 InteropDocument.ledger，写出时合并后一并返回。
public struct MSPDIWriter: Sendable {
    public init() {}

    /// 把 IR 写成 MSPDI。
    ///
    /// - Parameter document: 供应商无关的计划文档。
    /// - Returns: XML 字节与导出侧有损登记。
    public func write(_ document: InteropDocument) -> MSPDIExport {
        var ledger = FidelityLedger()
        let taskPlan = UIDPlan(ids: document.tasks.map(\.id), floor: 1)
        let resourcePlan = UIDPlan(ids: document.resources.map(\.id), floor: 1)
        let calendarPlan = UIDPlan(ids: document.calendars.map(\.id), floor: 1)

        recordRenumbering(taskPlan, field: "task.uid", noun: "任务", ledger: &ledger)
        recordRenumbering(resourcePlan, field: "resource.uid", noun: "资源", ledger: &ledger)
        recordRenumbering(calendarPlan, field: "calendar.uid", noun: "日历", ledger: &ledger)

        let encoder = MSPDIEncoder(
            document: document,
            taskPlan: taskPlan,
            resourcePlan: resourcePlan,
            calendarPlan: calendarPlan
        )
        let xml = encoder.render(ledger: &ledger)
        return MSPDIExport(data: Data(xml.utf8), ledger: document.ledger.merging(ledger))
    }

    private func recordRenumbering(
        _ plan: UIDPlan,
        field: String,
        noun: String,
        ledger: inout FidelityLedger
    ) {
        guard !plan.renumberedIDs.isEmpty else { return }
        ledger.record(
            field: field,
            kind: .derived,
            count: plan.renumberedIDs.count,
            detail: "\(noun) id 不是整数或与已用 UID 冲突，MSPDI 的 UID 必须是整数：按出现顺序重新编号，"
                + "回导后 id 与来源不再对应，需要旁路映射表才能回写。",
            samples: plan.renumberedIDs
        )
    }
}

// MARK: - UID 分配

/// 把 IR 的字符串 id 映射成 MSPDI 的整数 UID。
///
/// 规则刻意简单且确定：能解析成整数且不重复的 id 原样保留（这样真实样本往返后 UID 不变），
/// 其余按出现顺序补空位。不排序、不哈希，保证同一输入得到同一编号。
struct UIDPlan {
    private let uids: [Int]
    private let byID: [String: Int]
    /// 被重新编号的 id（按出现顺序，供登记样例）。
    let renumberedIDs: [String]

    init(ids: [String], floor: Int) {
        var used: Set<Int> = []
        var assigned = [Int?](repeating: nil, count: ids.count)
        var map: [String: Int] = [:]
        for (index, id) in ids.enumerated() {
            guard let value = Int(id), !used.contains(value) else { continue }
            used.insert(value)
            assigned[index] = value
            if map[id] == nil { map[id] = value }
        }
        var next = floor
        var renumbered: [String] = []
        for index in ids.indices where assigned[index] == nil {
            while used.contains(next) { next += 1 }
            used.insert(next)
            assigned[index] = next
            renumbered.append(ids[index])
            if map[ids[index]] == nil { map[ids[index]] = next }
        }
        self.uids = assigned.map { $0 ?? floor }
        self.byID = map
        self.renumberedIDs = renumbered
    }

    /// 第 index 个对象的 UID。
    func uid(at index: Int) -> Int { uids[index] }

    /// 来源 id 对应的 UID；未知 id 返回 nil。
    func uid(for id: String) -> Int? { byID[id] }
}

// MARK: - 写出

/// 一次写出的全部状态：三个 UID 计划 + 源文档。
private struct MSPDIEncoder {
    let document: InteropDocument
    let taskPlan: UIDPlan
    let resourcePlan: UIDPlan
    let calendarPlan: UIDPlan

    func render(ledger: inout FidelityLedger) -> String {
        let fields = makeFieldIDs(ledger: &ledger)
        let baselines = makeBaselineSlots(ledger: &ledger)
        let defaults = projectDefaults(ledger: &ledger)

        var lines: [String] = []
        lines.append(#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#)
        lines.append("<Project xmlns=\"\(MSPDIReader.namespace)\">")
        lines.append(contentsOf: projectHeader(defaults: defaults))
        lines.append(contentsOf: extendedAttributeDefinitions(fields: fields))
        lines.append(contentsOf: calendars(defaults: defaults, ledger: &ledger))
        lines.append(contentsOf: tasks(fields: fields, baselines: baselines, ledger: &ledger))
        lines.append(contentsOf: resources(ledger: &ledger))
        lines.append(contentsOf: assignments(ledger: &ledger))
        lines.append("</Project>")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: 项目级

    private struct ProjectDefaults {
        var calendarUID: Int
        var hoursPerDay: Double
        var minutesPerDay: Int
        var minutesPerWeek: Int
    }

    private func projectDefaults(ledger: inout FidelityLedger) -> ProjectDefaults {
        if document.calendars.isEmpty {
            // Kaido 没有日历（等价于 7 天全工作周）：显式写出这份日历，日期才能无损对应。
            ledger.record(
                field: "calendar.weekdays",
                kind: .converted,
                count: 1,
                detail: "Kaido 按日历天排期（一周 7 天）：导出写成 7 天全工作周日历，使一个自然日恰好等于"
                    + "一个工作日，日期往返不变。",
                sample: "周一至周日"
            )
            return ProjectDefaults(calendarUID: 1, hoursPerDay: 8, minutesPerDay: 480, minutesPerWeek: 3_360)
        }

        var index: Int?
        if let declared = document.metadata.defaultCalendarID {
            index = document.calendars.firstIndex { $0.id == declared }
            if index == nil {
                ledger.record(
                    field: "calendar.default",
                    kind: .derived,
                    count: 1,
                    detail: "声明的默认日历不在文档里，导出时改用第一个日历作为项目默认日历。",
                    sample: declared
                )
            }
        }
        let resolved = index ?? 0
        let calendar = document.calendars[resolved]
        let hours = calendar.hoursPerDay > 0 ? calendar.hoursPerDay : 8
        let days = calendar.workingWeekdays.isEmpty ? 7 : calendar.workingWeekdays.count
        let minutes = Int((hours * 60).rounded())
        return ProjectDefaults(
            calendarUID: calendarPlan.uid(at: resolved),
            hoursPerDay: hours,
            minutesPerDay: minutes,
            minutesPerWeek: minutes * days
        )
    }

    private func projectHeader(defaults: ProjectDefaults) -> [String] {
        var lines: [String] = []
        let title = document.metadata.title
        lines.append(element("SaveVersion", "14", 1))
        lines.append(element("Name", title, 1))
        lines.append(element("Title", title, 1))
        if let author = document.metadata.author, !author.isEmpty {
            lines.append(element("Author", author, 1))
        }
        if let createdAt = document.metadata.createdAt {
            lines.append(element("CreationDate", Self.dateTime(createdAt), 1))
        }
        if let lastSaved = document.metadata.lastSavedAt {
            lines.append(element("LastSaved", Self.dateTime(lastSaved), 1))
        }
        lines.append(element("ScheduleFromStart", document.metadata.direction == .forward ? "1" : "0", 1))
        if let start = document.metadata.plannedStart {
            lines.append(element("StartDate", Self.dateTime(start), 1))
        }
        if let finish = document.metadata.plannedFinish {
            lines.append(element("FinishDate", Self.dateTime(finish), 1))
        }
        lines.append(element("CalendarUID", String(defaults.calendarUID), 1))
        lines.append(element("DefaultStartTime", "08:00:00", 1))
        lines.append(element("DefaultFinishTime", Self.clock(defaults.hoursPerDay * 3_600), 1))
        lines.append(element("MinutesPerDay", String(defaults.minutesPerDay), 1))
        lines.append(element("MinutesPerWeek", String(defaults.minutesPerWeek), 1))
        lines.append(element("DaysPerMonth", "20", 1))
        lines.append(element("DurationFormat", "7", 1))
        lines.append(element("WeekStartDay", "1", 1))
        return lines
    }

    // MARK: 自定义域定义

    private func makeFieldIDs(ledger: inout FidelityLedger) -> [String: Int] {
        var map: [String: Int] = [:]
        var invalid = 0
        var samples: [String] = []
        for field in document.customFields {
            guard let id = Int(field.id) else {
                invalid += 1
                if samples.count < FidelityLedger.maxSamples {
                    samples.append("\(field.fieldName)=\(field.id)")
                }
                continue
            }
            if map[field.fieldName] == nil { map[field.fieldName] = id }
        }
        ledger.record(
            field: "customField",
            kind: .dropped,
            count: invalid,
            detail: "自定义域定义缺少整数 FieldID，无法写成 MSPDI 的 ExtendedAttribute；该域的值一并丢弃。",
            samples: samples
        )
        return map
    }

    private func extendedAttributeDefinitions(fields: [String: Int]) -> [String] {
        guard !document.customFields.isEmpty else { return [] }
        var lines = [indent(1) + "<ExtendedAttributes>"]
        for field in document.customFields {
            guard let fieldID = fields[field.fieldName] else { continue }
            lines.append(indent(2) + "<ExtendedAttribute>")
            lines.append(element("FieldID", String(fieldID), 3))
            lines.append(element("FieldName", field.fieldName, 3))
            if let alias = field.alias, !alias.isEmpty {
                lines.append(element("Alias", alias, 3))
            }
            lines.append(indent(2) + "</ExtendedAttribute>")
        }
        lines.append(indent(1) + "</ExtendedAttributes>")
        return lines
    }

    // MARK: 日历

    private func calendars(defaults: ProjectDefaults, ledger: inout FidelityLedger) -> [String] {
        var lines = [indent(1) + "<Calendars>"]
        if document.calendars.isEmpty {
            lines.append(contentsOf: calendarBlock(
                uid: defaults.calendarUID,
                name: "标准",
                weekdays: InteropCalendar.allWeekdays,
                hoursPerDay: defaults.hoursPerDay,
                exceptions: []
            ))
        } else {
            var restricted = 0
            var restrictedSamples: [String] = []
            for (index, calendar) in document.calendars.enumerated() {
                if !calendar.workingWeekdays.isEmpty && calendar.workingWeekdays.count < 7 {
                    restricted += 1
                    if restrictedSamples.count < FidelityLedger.maxSamples {
                        let label = calendar.name.isEmpty ? calendar.id : calendar.name
                        restrictedSamples.append("\(label)：\(describeWeek(calendar.workingWeekdays))")
                    }
                }
                lines.append(contentsOf: calendarBlock(
                    uid: calendarPlan.uid(at: index),
                    name: calendar.name,
                    weekdays: calendar.workingWeekdays,
                    hoursPerDay: calendar.hoursPerDay,
                    exceptions: calendar.exceptions
                ))
            }
            ledger.record(
                field: "calendar.workingWeekdays",
                kind: .converted,
                count: restricted,
                detail: "来源日历不是 7 天工作周：导出如实写出原日历，MSPDI 按工作日推进，"
                    + "同一批日期可能与 Kaido 里的原计划前后移动（周末与例外日不计入）。",
                samples: restrictedSamples
            )
        }
        lines.append(indent(1) + "</Calendars>")
        return lines
    }

    private func calendarBlock(
        uid: Int,
        name: String,
        weekdays: Set<Int>,
        hoursPerDay: Double,
        exceptions: [InteropCalendarException]
    ) -> [String] {
        var lines = [indent(2) + "<Calendar>"]
        lines.append(element("UID", String(uid), 3))
        lines.append(element("Name", name.isEmpty ? "日历 \(uid)" : name, 3))
        lines.append(element("IsBaseCalendar", "1", 3))
        lines.append(element("IsBaselineCalendar", "0", 3))
        lines.append(element("BaseCalendarUID", "-1", 3))

        // 空工作日集合在 IR 里表示「未声明 / 继承上级日历」：如实写成没有 WeekDays，
        // 让读回时仍是同一个语义（补一份 7 天日历会把「继承」偷换成「全周上班」）。
        if !weekdays.isEmpty {
            lines.append(indent(3) + "<WeekDays>")
            for dayType in 1...7 {
                let working = weekdays.contains(dayType)
                lines.append(indent(4) + "<WeekDay>")
                lines.append(element("DayType", String(dayType), 5))
                lines.append(element("DayWorking", working ? "1" : "0", 5))
                if working {
                    lines.append(contentsOf: workingTimes(hoursPerDay: hoursPerDay, level: 5))
                }
                lines.append(indent(4) + "</WeekDay>")
            }
            lines.append(indent(3) + "</WeekDays>")
        }

        if !exceptions.isEmpty {
            lines.append(indent(3) + "<Exceptions>")
            for exception in exceptions {
                lines.append(contentsOf: exceptionBlock(exception))
            }
            lines.append(indent(3) + "</Exceptions>")
        }
        lines.append(indent(2) + "</Calendar>")
        return lines
    }

    private func workingTimes(hoursPerDay: Double, level: Int) -> [String] {
        let hours = hoursPerDay > 0 ? hoursPerDay : 8
        var lines = [indent(level) + "<WorkingTimes>"]
        let slots: [(Double, Double)]
        if abs(hours - 8) < 0.001 {
            // 与 MS Project 常见作息一致：上午 4h + 下午 4h。
            slots = [(8 * 3_600, 12 * 3_600), (13 * 3_600, 17 * 3_600)]
        } else {
            slots = [(8 * 3_600, 8 * 3_600 + hours * 3_600)]
        }
        for (from, to) in slots {
            lines.append(indent(level + 1) + "<WorkingTime>")
            lines.append(element("FromTime", Self.clock(from), level + 2))
            lines.append(element("ToTime", Self.clock(to), level + 2))
            lines.append(indent(level + 1) + "</WorkingTime>")
        }
        lines.append(indent(level) + "</WorkingTimes>")
        return lines
    }

    private func exceptionBlock(_ exception: InteropCalendarException) -> [String] {
        let day = Self.day(exception.date)
        var lines = [indent(4) + "<Exception>"]
        lines.append(element("EnteredByOccurrences", "0", 5))
        lines.append(indent(5) + "<TimePeriod>")
        lines.append(element("FromDate", "\(day)T00:00:00", 6))
        lines.append(element("ToDate", "\(day)T23:59:59", 6))
        lines.append(indent(5) + "</TimePeriod>")
        lines.append(element("Occurrences", "1", 5))
        if let note = exception.note, !note.isEmpty {
            lines.append(element("Name", note, 5))
        }
        lines.append(element("Type", "1", 5))
        lines.append(element("DayWorking", exception.isWorking ? "1" : "0", 5))
        lines.append(indent(4) + "</Exception>")
        return lines
    }

    // MARK: 任务

    private struct BaselineSlot {
        let number: Int
        let start: Date
        let finish: Date
    }

    private func makeBaselineSlots(ledger: inout FidelityLedger) -> [String: [BaselineSlot]] {
        var map: [String: [BaselineSlot]] = [:]
        guard !document.baselines.isEmpty else { return map }

        let taskIDs = Set(document.tasks.map(\.id))
        var usedNumbers: Set<Int> = []
        var overflow = 0
        var overflowSamples: [String] = []
        var orphanEntries = 0
        var lostProgress = 0
        var lostNames = 0
        var lostCreatedAt = 0
        var written = 0

        for (index, baseline) in document.baselines.enumerated() {
            var number = Int(baseline.id) ?? (index + 1)
            if usedNumbers.contains(number) || !(0...10).contains(number) {
                // 槽位分配：编号缺失 / 重复 / 越界时找 0…10 里最小的空位。
                number = (0...10).first { !usedNumbers.contains($0) } ?? -1
            }
            guard number >= 0 else {
                overflow += 1
                if overflowSamples.count < FidelityLedger.maxSamples {
                    overflowSamples.append(baseline.name ?? "基线 \(baseline.id)")
                }
                continue
            }
            usedNumbers.insert(number)
            written += 1
            if baseline.name != nil { lostNames += 1 }
            if baseline.createdAt != nil { lostCreatedAt += 1 }
            for entry in baseline.entries {
                guard taskIDs.contains(entry.taskID) else {
                    orphanEntries += 1
                    continue
                }
                if entry.progress != nil { lostProgress += 1 }
                map[entry.taskID, default: []].append(
                    BaselineSlot(number: number, start: entry.start, finish: entry.finish)
                )
            }
        }

        ledger.record(
            field: "baseline.color",
            kind: .dropped,
            count: written,
            detail: "Kaido 的基线颜色索引（8 色）在 MSPDI 没有字段：对方按自己的基线配色显示，"
                + "回导后颜色按新建顺序重新分配。",
            samples: document.baselines.prefix(FidelityLedger.maxSamples).map { $0.name ?? "基线 \($0.id)" }
        )
        ledger.record(
            field: "baseline.slot",
            kind: .dropped,
            count: overflow,
            detail: "MSPDI 只有 BaselineNumber 0…10 共 11 个槽位：超出的基线无法写出，"
                + "需要旁注文件或拆成多次导出。",
            samples: overflowSamples
        )
        ledger.record(
            field: "baseline.entry",
            kind: .dropped,
            count: orphanEntries,
            detail: "基线条目指向的任务已不在计划中（孤儿条目），没有可写的 Task 行。"
        )
        ledger.record(
            field: "baseline.progress",
            kind: .dropped,
            count: lostProgress,
            detail: "MSPDI 的任务基线条目只有起止时间，没有完成度字段：进度的基线偏差无法带走。"
        )
        ledger.record(
            field: "baseline.name",
            kind: .dropped,
            count: lostNames,
            detail: "MSPDI 的基线只有编号（0…10），没有名称字段：基线名称只在旁注文件里保留。"
        )
        ledger.record(
            field: "baseline.createdAt",
            kind: .dropped,
            count: lostCreatedAt,
            detail: "MSPDI 的基线没有快照时刻：基线创建时间只在旁注文件里保留。"
        )
        return map
    }

    private func tasks(
        fields: [String: Int],
        baselines: [String: [BaselineSlot]],
        ledger: inout FidelityLedger
    ) -> [String] {
        var lines = [indent(1) + "<Tasks>"]
        var kaidoOnlyCounts: [String: Int] = [:]
        var kaidoOnlySamples: [String: [String]] = [:]
        var missingDependencies = 0
        var missingDependencySample: String?
        var missingCalendars = 0
        var roundedLags = 0
        var lagSamples: [String] = []
        var roundedProgress = 0
        var degradedConstraints = 0
        var constraintSamples: [String] = []
        var unknownCustomValues = 0
        var unknownCustomSamples: [String] = []

        for (index, task) in document.tasks.enumerated() {
            let uid = taskPlan.uid(at: index)
            // 手动排期：MS Project 用 XML 属性 Manual="1" 表示；自动任务不写该属性（缺省即自动）。
            lines.append(indent(2) + (task.isManuallyScheduled ? "<Task Manual=\"1\">" : "<Task>"))
            lines.append(element("UID", String(uid), 3))
            lines.append(element("ID", String(index + 1), 3))
            if !task.title.isEmpty {
                lines.append(element("Name", task.title, 3))
            }
            lines.append(element("IsNull", "0", 3))
            lines.append(element("OutlineLevel", String(max(task.outlineLevel, 0)), 3))
            lines.append(element("Summary", task.kind == .group ? "1" : "0", 3))
            lines.append(element("Milestone", task.kind == .milestone ? "1" : "0", 3))
            if let start = task.plannedStart {
                lines.append(element("Start", Self.dateTime(start), 3))
            }
            if let finish = task.plannedFinish {
                lines.append(element("Finish", Self.dateTime(finish), 3))
            }
            if let duration = durationText(for: task) {
                lines.append(element("Duration", duration, 3))
                lines.append(element("DurationFormat", "7", 3))
            }
            let percent = Int((task.progress * 100).rounded())
            lines.append(element("PercentComplete", String(percent), 3))
            if abs(task.progress * 100 - Double(percent)) > 0.0001 { roundedProgress += 1 }
            if let actualStart = task.actualStart {
                lines.append(element("ActualStart", Self.dateTime(actualStart), 3))
            }
            if let actualFinish = task.actualFinish {
                lines.append(element("ActualFinish", Self.dateTime(actualFinish), 3))
            }
            if let constraint = task.constraint {
                lines.append(element("ConstraintType", String(constraintCode(constraint)), 3))
                if let date = constraint.date {
                    lines.append(element("ConstraintDate", Self.dateTime(date), 3))
                    degradedConstraints += 1
                    if constraintSamples.count < FidelityLedger.maxSamples {
                        constraintSamples.append("\(constraintName(constraint)) \(Self.day(date))")
                    }
                }
            }
            if let calendarID = task.calendarID, let calendarUID = calendarPlan.uid(for: calendarID) {
                lines.append(element("CalendarUID", String(calendarUID), 3))
            } else {
                if task.calendarID != nil { missingCalendars += 1 }
                lines.append(element("CalendarUID", "-1", 3))
            }
            if !task.notes.isEmpty {
                // Notes 只放来源原文：Kaido 独有信息一律走 ledger，不在这里追加。
                lines.append(element("Notes", task.notes, 3))
            }
            if let effort = task.effortHours, effort > 0 {
                lines.append(element("Work", Self.isoDuration(effort * 3_600), 3))
            }
            for dependency in task.dependencies {
                guard let predecessor = taskPlan.uid(for: dependency.predecessorID) else {
                    missingDependencies += 1
                    if missingDependencySample == nil {
                        missingDependencySample = dependency.predecessorID
                    }
                    continue
                }
                let tenths = Int((dependency.lagSeconds / 6).rounded())
                if abs(Double(tenths) * 6 - dependency.lagSeconds) > 0.0001 {
                    roundedLags += 1
                    if lagSamples.count < FidelityLedger.maxSamples {
                        lagSamples.append("\(Self.trim(dependency.lagSeconds))s → \(tenths * 6)s")
                    }
                }
                lines.append(indent(3) + "<PredecessorLink>")
                lines.append(element("PredecessorUID", String(predecessor), 4))
                lines.append(element("Type", String(dependencyCode(dependency.type)), 4))
                lines.append(element("CrossProject", "0", 4))
                // LinkLag 的单位是十分之一分钟：1 分钟 = 10，1 天（8h）= 4800。
                lines.append(element("LinkLag", String(tenths), 4))
                lines.append(element("LagFormat", "7", 4))
                lines.append(indent(3) + "</PredecessorLink>")
            }
            for slot in baselines[task.id] ?? [] {
                lines.append(indent(3) + "<Baseline>")
                lines.append(element("Number", String(slot.number), 4))
                lines.append(element("Start", Self.dateTime(slot.start), 4))
                lines.append(element("Finish", Self.dateTime(slot.finish), 4))
                lines.append(indent(3) + "</Baseline>")
            }
            for key in task.attributes.keys.sorted() {
                let value = task.attributes[key] ?? ""
                if key.hasPrefix(KaidoOnlyKey.prefix) {
                    kaidoOnlyCounts[key, default: 0] += 1
                    var samples = kaidoOnlySamples[key] ?? []
                    if samples.count < FidelityLedger.maxSamples, !samples.contains(value) {
                        samples.append(value)
                    }
                    kaidoOnlySamples[key] = samples
                    continue
                }
                guard let fieldID = fields[key] else {
                    unknownCustomValues += 1
                    if unknownCustomSamples.count < FidelityLedger.maxSamples {
                        unknownCustomSamples.append("\(key)=\(value)")
                    }
                    continue
                }
                lines.append(indent(3) + "<ExtendedAttribute>")
                lines.append(element("FieldID", String(fieldID), 4))
                lines.append(element("Value", value, 4))
                lines.append(indent(3) + "</ExtendedAttribute>")
            }
            lines.append(indent(2) + "</Task>")
        }

        for key in kaidoOnlyCounts.keys.sorted() {
            let name = String(key.dropFirst(KaidoOnlyKey.prefix.count))
            ledger.record(
                field: name,
                kind: .dropped,
                count: kaidoOnlyCounts[key] ?? 0,
                detail: kaidoOnlyDetail(name),
                samples: kaidoOnlySamples[key] ?? []
            )
        }
        ledger.record(
            field: "dependency",
            kind: .dropped,
            count: missingDependencies,
            detail: "前驱任务不在本文档里（已删除或跨项目）：缺少 UID 无法写出相关性。",
            sample: missingDependencySample
        )
        ledger.record(
            field: "calendar.task",
            kind: .dropped,
            count: missingCalendars,
            detail: "任务声明的日历不在文档里，导出写成「继承项目默认日历」（CalendarUID=-1）。"
        )
        ledger.record(
            field: "dependency.lag",
            kind: .converted,
            count: roundedLags,
            detail: "MSPDI 的 LinkLag 以十分之一分钟为单位：前导时间按 6 秒取整，非 6 秒倍数的部分丢失。",
            samples: lagSamples
        )
        ledger.record(
            field: "task.progress",
            kind: .converted,
            count: roundedProgress,
            detail: "MSPDI 的 PercentComplete 是整数百分比：完成度的小数位按四舍五入取整。"
        )
        ledger.record(
            field: "constraint",
            kind: .degraded,
            count: degradedConstraints,
            detail: "Kaido 的时限是软约束（冲突只出违例、照常排期），MSPDI 的 SNET/SNLT/FNET/FNLT 是硬约束："
                + "对方打开后会据此改期或报冲突，回导也无法恢复「只报违例」的语义。",
            samples: constraintSamples
        )
        ledger.record(
            field: "customField.value",
            kind: .dropped,
            count: unknownCustomValues,
            detail: "任务的这个自定义域没有对应的 FieldID 定义，无法写出 ExtendedAttribute。",
            samples: unknownCustomSamples
        )
        lines.append(indent(1) + "</Tasks>")
        return lines
    }

    private func durationText(for task: InteropTask) -> String? {
        if task.kind == .milestone {
            // 里程碑的规范口径是零工期；但来源里确实存在 Milestone=1 却带正工期的行
            // （Project 允许标记与工期各自独立）。保住原值才不会让往返对拍出现假差异。
            if let seconds = task.durationSeconds, seconds > 0 { return Self.isoDuration(seconds) }
            return "PT0H0M0S"
        }
        guard let seconds = task.durationSeconds else { return nil }
        return Self.isoDuration(seconds)
    }

    private func constraintCode(_ constraint: InteropConstraint) -> Int {
        switch constraint {
        case .asSoonAsPossible: return 0
        case .asLateAsPossible: return 1
        case .startNoEarlierThan: return 4
        case .startNoLaterThan: return 5
        case .endNoEarlierThan: return 6
        case .endNoLaterThan: return 7
        }
    }

    private func constraintName(_ constraint: InteropConstraint) -> String {
        switch constraint {
        case .asSoonAsPossible: return "尽早开始"
        case .asLateAsPossible: return "尽晚开始"
        case .startNoEarlierThan: return "开始不早于"
        case .startNoLaterThan: return "开始不晚于"
        case .endNoEarlierThan: return "结束不早于"
        case .endNoLaterThan: return "结束不晚于"
        }
    }

    /// MSPDI 口径：0 = FF，1 = FS，2 = SF，3 = SS（与 IR 的枚举顺序不同）。
    private func dependencyCode(_ type: InteropDependencyType) -> Int {
        switch type {
        case .finishToFinish: return 0
        case .finishToStart: return 1
        case .startToFinish: return 2
        case .startToStart: return 3
        }
    }

    /// - Parameter name: **已去掉 `kaido.` 前缀**的字段名（`status` / `cancelReason`）。
    ///
    /// 比较时必须还原成原始键：直接拿 `status` 去比 `KaidoOnlyKey.status`（`kaido.status`）
    /// 永远不命中，两个专属说明就成了死分支，旁注只能看到兜底文案。
    private func kaidoOnlyDetail(_ name: String) -> String {
        switch "\(KaidoOnlyKey.prefix)\(name)" {
        case KaidoOnlyKey.status:
            return "Kaido 的五态（pending / in_progress / done / blocked / cancelled）在 MSPDI 没有对应字段："
                + "只保留完成度，状态本身丢弃；blocked / cancelled 的语义回导后不可恢复。"
        case KaidoOnlyKey.cancelReason:
            return "取消原因是 Kaido 独有的审计信息，MSPDI 无字段；按约定不写入 Notes（避免污染对方备注），"
                + "只登记到导出旁注。"
        default:
            return "Kaido 独有字段在 MSPDI 没有落点：已从任务属性中剥离并登记，回导后不会恢复。"
        }
    }

    // MARK: 资源与分配

    private func resources(ledger: inout FidelityLedger) -> [String] {
        var lines = [indent(1) + "<Resources>"]
        var unknownKinds = 0
        for (index, resource) in document.resources.enumerated() {
            lines.append(indent(2) + "<Resource>")
            lines.append(element("UID", String(resourcePlan.uid(at: index)), 3))
            lines.append(element("ID", String(index + 1), 3))
            if !resource.name.isEmpty {
                lines.append(element("Name", resource.name, 3))
            }
            let type: Int
            switch resource.kind {
            case .material: type = 0
            case .person: type = 1
            case .cost: type = 2
            case .unknown:
                type = 1
                unknownKinds += 1
            }
            lines.append(element("Type", String(type), 3))
            lines.append(element("MaxUnits", Self.number(resource.units), 3))
            if let calendarID = resource.calendarID, let calendarUID = calendarPlan.uid(for: calendarID) {
                lines.append(element("CalendarUID", String(calendarUID), 3))
            }
            lines.append(indent(2) + "</Resource>")
        }
        ledger.record(
            field: "resource.kind",
            kind: .derived,
            count: unknownKinds,
            detail: "来源资源种类未知，导出按人员（Type=1）写出。"
        )
        lines.append(indent(1) + "</Resources>")
        return lines
    }

    private func assignments(ledger: inout FidelityLedger) -> [String] {
        var lines = [indent(1) + "<Assignments>"]
        var dropped = 0
        var droppedSample: String?
        var dangling = 0
        var danglingSample: String?
        for (index, assignment) in document.assignments.enumerated() {
            guard let taskUID = taskPlan.uid(for: assignment.taskID) else {
                dropped += 1
                if droppedSample == nil {
                    droppedSample = "TaskUID \(assignment.taskID) → ResourceUID \(assignment.resourceID)"
                }
                continue
            }
            let resourceUID: Int
            if let known = resourcePlan.uid(for: assignment.resourceID) {
                resourceUID = known
            } else if let raw = Int(assignment.resourceID) {
                // Project 的「未分配」占位（-65535）就属于这种：整数可写，但资源表里没有它。
                resourceUID = raw
                dangling += 1
                if danglingSample == nil {
                    danglingSample = "TaskUID \(taskUID) → ResourceUID \(raw)"
                }
            } else {
                dropped += 1
                if droppedSample == nil {
                    droppedSample = "TaskUID \(assignment.taskID) → ResourceUID \(assignment.resourceID)"
                }
                continue
            }
            lines.append(indent(2) + "<Assignment>")
            lines.append(element("UID", String(index + 1), 3))
            lines.append(element("TaskUID", String(taskUID), 3))
            lines.append(element("ResourceUID", String(resourceUID), 3))
            lines.append(element("Units", Self.number(assignment.units), 3))
            lines.append(indent(2) + "</Assignment>")
        }
        ledger.record(
            field: "assignment",
            kind: .dropped,
            count: dropped,
            detail: "分配引用的任务或资源 id 既不是整数也不在文档里，无法写出。",
            sample: droppedSample
        )
        ledger.record(
            field: "assignment.resource",
            kind: .degraded,
            count: dangling,
            detail: "分配指向来源中不存在的资源（Project 的「未分配」占位）：MSPDI 允许写出，"
                + "对方打开时可能按未分配处理。",
            sample: danglingSample
        )
        lines.append(indent(1) + "</Assignments>")
        return lines
    }

    // MARK: 小工具

    private func describeWeek(_ weekdays: Set<Int>) -> String {
        let names = [1: "周日", 2: "周一", 3: "周二", 4: "周三", 5: "周四", 6: "周五", 7: "周六"]
        return weekdays.sorted().map { names[$0] ?? String($0) }.joined(separator: "、")
    }

    private func indent(_ level: Int) -> String {
        String(repeating: "    ", count: level)
    }

    private func element(_ name: String, _ text: String, _ level: Int) -> String {
        "\(indent(level))<\(name)>\(Self.escape(text))</\(name)>"
    }

    private static func escape(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default: result.append(character)
            }
        }
        return result
    }

    /// MSPDI 的日期口径：本地时区、秒精度（与读入端一致，才能原样往返）。
    static func dateTime(_ date: Date) -> String {
        dateTimeFormatter.string(from: date)
    }

    static func day(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded()) % 86_400
        return String(format: "%02d:%02d:%02d", total / 3_600, (total % 3_600) / 60, total % 60)
    }

    static func isoDuration(_ seconds: TimeInterval) -> String {
        let sign = seconds < 0 ? "-" : ""
        let total = Int(abs(seconds).rounded())
        return "\(sign)PT\(total / 3_600)H\((total % 3_600) / 60)M\(total % 60)S"
    }

    static func number(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 9e15 {
            return String(Int(value))
        }
        return trim(value)
    }

    static func trim(_ value: Double) -> String {
        var text = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// Kaido 独有信息在 IR 里的承载约定：InteropTask.attributes 的保留前缀。
///
/// IR 是供应商无关模型，不表达「五态状态 / 取消原因 / 基线颜色」这些 Kaido 概念；导出方向
/// （KaidoBridge）把它们放进带「kaido.」前缀的任务属性里，写出端**剥离**后登记到
/// FidelityLedger，绝不写进对方的 Notes。
enum KaidoOnlyKey {
    static let prefix = "kaido."
    static let status = "kaido.status"
    static let cancelReason = "kaido.cancelReason"
}
