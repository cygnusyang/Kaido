import Foundation
import ZenoInterop
#if canImport(FoundationXML)
import FoundationXML
#endif

/// MS Project XML（MSPDI）读取（docs/features/14-interop-architecture.md P0）。
///
/// 只负责「XML → IR」：不认识 Zeno 的任何业务模型，也不做工作日换算。
/// 读到未知 `SaveVersion` 一律拒绝（`unsupportedFormatVersion`），不做 best-effort。
struct MSPDIReader {
    /// MSPDI 的唯一合法命名空间。
    static let namespace = "http://schemas.microsoft.com/project"

    /// 支持的 `SaveVersion`。
    ///
    /// 12 = Project 2007 schema，14 = Project 2010 及之后的 MSPDI（真实样本即为 14）。
    /// 更高版本一律拒绝：宁可让用户「另存为受支持版本」，也不要读一半再错。
    static let supportedSaveVersions = Array(12...14)

    /// 异常日展开的上限（防止脏数据里一个十年区间把内存吃穿）。
    private static let maxExceptionDays = 3_660

    func read(_ data: Data) throws -> (document: InteropDocument, saveVersion: Int) {
        let root = try makeTree(from: data)
        let saveVersion = try validate(root: root)
        return (makeDocument(root: root), saveVersion)
    }

    // MARK: - 版本闸门

    private func makeTree(from data: Data) throws -> XMLNode {
        let builder = XMLTreeBuilder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = builder
        // Linux 的 FoundationXML（libxml2）带 recover 解析：截断文档的 `parse()` 仍返回 true，
        // 只在委托里报一条「Premature end of data」。所以不能只看返回值——委托记录的解析错误
        // 与返回值同等算失败，否则同一份坏文件在 Linux 会被读成「只有 SaveVersion 的空计划」。
        // 顺序要紧：必须先 `parse()`，`failure` 才是解析后的值。
        let parsed = parser.parse()
        guard parsed, builder.failure == nil, let root = builder.root else {
            throw InteropError.malformedDocument(builder.failure ?? "XML 无法解析（文件被截断或不是 XML）")
        }
        return root
    }

    private func validate(root: XMLNode) throws -> Int {
        guard root.name == "Project" else {
            throw InteropError.malformedDocument("根元素应为 Project，实际为 \(root.name)")
        }
        guard root.namespaceURI == Self.namespace else {
            throw InteropError.malformedDocument(
                "命名空间应为 \(Self.namespace)，实际为 \(root.namespaceURI ?? "（无）")"
            )
        }
        guard let versionText = root.child("SaveVersion")?.text, let version = Int(versionText) else {
            throw InteropError.malformedDocument("缺少 SaveVersion：无法确认文件版本，拒绝猜测")
        }
        guard Self.supportedSaveVersions.contains(version) else {
            throw InteropError.unsupportedFormatVersion(version: version, supported: Self.supportedSaveVersions)
        }
        return version
    }

    // MARK: - 文档装配

    private func makeDocument(root: XMLNode) -> InteropDocument {
        let dates = MSPDIDateParser()
        var ledger = FidelityLedger()
        let minutesPerDay = root.child("MinutesPerDay")?.doubleValue ?? 480

        let customFields = makeCustomFields(root)
        let fieldsByID = Dictionary(
            customFields.map { ($0.id, $0.fieldName) },
            uniquingKeysWith: { first, _ in first }
        )
        let calendars = makeCalendars(
            root,
            dates: dates,
            fallbackMinutesPerDay: minutesPerDay,
            ledger: &ledger
        )
        let tasks = makeTasks(
            root,
            dates: dates,
            fieldsByID: fieldsByID,
            ledger: &ledger
        )
        let resources = makeResources(root)
        let assignments = makeAssignments(root, ledger: &ledger)
        let baselines = makeBaselines(root, dates: dates, ledger: &ledger)

        let metadata = InteropMetadata(
            title: root.child("Title")?.text ?? root.child("Name")?.text ?? "",
            author: root.child("Author").flatMap { $0.text.nilIfEmpty },
            createdAt: dates.date(root.child("CreationDate")),
            lastSavedAt: dates.date(root.child("LastSaved")),
            plannedStart: dates.date(root.child("StartDate")),
            plannedFinish: dates.date(root.child("FinishDate")),
            defaultCalendarID: calendarID(root.child("CalendarUID")),
            direction: root.child("ScheduleFromStart")?.boolValue == false ? .backward : .forward
        )

        return InteropDocument(
            metadata: metadata,
            tasks: tasks,
            resources: resources,
            calendars: calendars,
            assignments: assignments,
            baselines: baselines,
            customFields: customFields,
            ledger: ledger
        )
    }

    // MARK: - 自定义域定义

    private func makeCustomFields(_ root: XMLNode) -> [InteropCustomFieldDefinition] {
        guard let container = root.child("ExtendedAttributes") else { return [] }
        return container.children(named: "ExtendedAttribute").compactMap { node in
            guard let fieldID = node.child("FieldID")?.text, !fieldID.isEmpty else { return nil }
            return InteropCustomFieldDefinition(
                id: fieldID,
                fieldName: node.child("FieldName")?.text ?? fieldID,
                alias: node.child("Alias").flatMap { $0.text.nilIfEmpty }
            )
        }
    }

    // MARK: - 日历

    private func makeCalendars(
        _ root: XMLNode,
        dates: MSPDIDateParser,
        fallbackMinutesPerDay: Double,
        ledger: inout FidelityLedger
    ) -> [InteropCalendar] {
        guard let container = root.child("Calendars") else { return [] }
        var result: [InteropCalendar] = []
        for node in container.children(named: "Calendar") {
            guard let uid = node.child("UID")?.text, !uid.isEmpty else { continue }
            var weekdays: Set<Int> = []
            var hoursPerDay: Double = 0
            for weekday in node.child("WeekDays")?.children(named: "WeekDay") ?? [] {
                guard let dayType = weekday.child("DayType")?.intValue,
                      MSPDIValue.isValidWeekday(dayType),
                      weekday.child("DayWorking")?.boolValue == true else { continue }
                weekdays.insert(dayType)
                let minutes = workingMinutes(of: weekday)
                if minutes > hoursPerDay * 60 { hoursPerDay = minutes / 60 }
            }
            if weekdays.isEmpty {
                ledger.record(
                    field: "calendar.weekdays",
                    kind: .derived,
                    count: 1,
                    detail: "来源日历没有自己的周设置（在 Project 里表示继承基准日历），IR 不表达继承链，"
                        + "导入时只按「未声明」处理。",
                    sample: node.child("Name")?.text
                )
            }
            let fallback = fallbackMinutesPerDay > 0 ? fallbackMinutesPerDay / 60 : 8
            result.append(
                InteropCalendar(
                    id: uid,
                    name: node.child("Name")?.text ?? "",
                    workingWeekdays: weekdays,
                    hoursPerDay: hoursPerDay > 0 ? hoursPerDay : fallback,
                    exceptions: makeExceptions(node, dates: dates)
                )
            )
        }
        return result
    }

    /// 一个 `WeekDay` 的工作时段合计分钟数。
    private func workingMinutes(of weekday: XMLNode) -> Double {
        var minutes: Double = 0
        for slot in weekday.child("WorkingTimes")?.children(named: "WorkingTime") ?? [] {
            guard let from = MSPDIValue.secondsOfDay(slot.child("FromTime")?.text ?? ""),
                  let to = MSPDIValue.secondsOfDay(slot.child("ToTime")?.text ?? ""),
                  to > from else { continue }
            minutes += (to - from) / 60
        }
        return minutes
    }

    private func makeExceptions(_ calendar: XMLNode, dates: MSPDIDateParser) -> [InteropCalendarException] {
        guard let container = calendar.child("Exceptions") else { return [] }
        var result: [InteropCalendarException] = []
        for node in container.children(named: "Exception") {
            let period = node.child("TimePeriod")
            guard let from = dates.date(period?.child("FromDate")) else { continue }
            let to = dates.date(period?.child("ToDate")) ?? from
            let isWorking = node.child("DayWorking")?.boolValue ?? false
            let note = node.child("Name").flatMap { $0.text.nilIfEmpty }
            var cursor = CalendarDayMathStart.startOfDay(from)
            let end = CalendarDayMathStart.startOfDay(to)
            var scanned = 0
            while cursor <= end && scanned < Self.maxExceptionDays {
                result.append(InteropCalendarException(date: cursor, isWorking: isWorking, note: note))
                guard let next = CalendarDayMathStart.adding(days: 1, to: cursor) else { break }
                cursor = next
                scanned += 1
            }
        }
        return result
    }

    // MARK: - 任务

    private func makeTasks(
        _ root: XMLNode,
        dates: MSPDIDateParser,
        fieldsByID: [String: String],
        ledger: inout FidelityLedger
    ) -> [InteropTask] {
        guard let container = root.child("Tasks") else { return [] }
        var tasks: [InteropTask] = []
        var stack: [(level: Int, id: String)] = []
        var skipped = 0
        var droppedDependencies = 0
        var droppedDependencySample: String?
        var hardPins = 0
        var hardPinSamples: [String] = []
        var datelessConstraints = 0
        var costTasks = 0
        var deadlines = 0
        var recurring = 0
        var subprojects = 0

        for node in container.children(named: "Task") {
            if node.child("IsNull")?.boolValue == true {
                skipped += 1
                continue
            }
            guard let uid = node.child("UID")?.text, !uid.isEmpty else {
                skipped += 1
                continue
            }
            let outlineLevel = node.child("OutlineLevel")?.intValue ?? 0
            while let last = stack.last, last.level >= outlineLevel { stack.removeLast() }
            let parentID = stack.last?.id
            stack.append((outlineLevel, uid))

            if node.child("Recurring")?.boolValue == true { recurring += 1 }
            if node.child("IsSubproject")?.boolValue == true { subprojects += 1 }
            if node.child("Deadline") != nil { deadlines += 1 }
            if let cost = node.child("Cost")?.doubleValue, cost != 0 { costTasks += 1 }
            if let fixedCost = node.child("FixedCost")?.doubleValue, fixedCost != 0 { costTasks += 1 }

            let constraint = makeConstraint(
                node,
                dates: dates,
                hardPins: &hardPins,
                hardPinSamples: &hardPinSamples,
                dateless: &datelessConstraints
            )
            let duration = node.child("Duration").flatMap { MSPDIValue.seconds(fromISODuration: $0.text) }
            let effortSeconds = node.child("Work").flatMap { MSPDIValue.seconds(fromISODuration: $0.text) }

            tasks.append(
                InteropTask(
                    id: uid,
                    title: node.child("Name")?.text ?? "",
                    notes: node.child("Notes")?.text ?? "",
                    kind: makeKind(node),
                    outlineLevel: outlineLevel,
                    parentID: parentID,
                    sequence: tasks.count,
                    plannedStart: dates.date(node.child("Start")),
                    plannedFinish: dates.date(node.child("Finish")),
                    durationSeconds: duration,
                    effortHours: effortSeconds.map { $0 / 3_600 },
                    progress: (node.child("PercentComplete")?.doubleValue ?? 0) / 100,
                    actualStart: dates.date(node.child("ActualStart")),
                    actualFinish: dates.date(node.child("ActualFinish")),
                    dependencies: makeDependencies(
                        node,
                        dropped: &droppedDependencies,
                        droppedSample: &droppedDependencySample
                    ),
                    constraint: constraint,
                    calendarID: calendarID(node.child("CalendarUID")),
                    // 手动排期：MS Project 写在元素属性上（Manual="1"）。
                    isManuallyScheduled: node.attributes["Manual"] == "1",
                    attributes: makeAttributes(node, fieldsByID: fieldsByID)
                )
            )
        }

        if skipped > 0 {
            ledger.record(
                field: "task",
                kind: .dropped,
                count: skipped,
                detail: "占位任务（IsNull=1）或缺少 UID 的任务被跳过：它们不参与排期，也没有稳定身份。"
            )
        }
        if droppedDependencies > 0 {
            ledger.record(
                field: "dependency",
                kind: .dropped,
                count: droppedDependencies,
                detail: "跨项目相关性（CrossProject=1）或类型非法的相关性被丢弃：Zeno 没有跨项目依赖。",
                sample: droppedDependencySample
            )
        }
        if hardPins > 0 {
            ledger.record(
                field: "constraint.type",
                kind: .dropped,
                count: hardPins,
                detail: "Must Start On / Must Finish On（ConstraintType 2/3）在 Zeno 没有对应物：既不能钉死日期也不产生违例，只能丢弃。",
                samples: hardPinSamples
            )
        }
        if datelessConstraints > 0 {
            ledger.record(
                field: "constraint.date",
                kind: .dropped,
                count: datelessConstraints,
                detail: "声明了时限类型却没有 ConstraintDate，无法还原意图，已按无时限处理。"
            )
        }
        if costTasks > 0 {
            ledger.record(
                field: "cost",
                kind: .dropped,
                count: costTasks,
                detail: "Zeno 没有成本与挣值（固定成本 / 成本 / BCWS / BCWP）：这些数值全部丢弃。"
            )
        }
        if deadlines > 0 {
            ledger.record(
                field: "deadline",
                kind: .dropped,
                count: deadlines,
                detail: "Deadline 与 Zeno 的 dueDate 不等价（dueDate 不参与排期）：按 C 级策略丢弃，不塞进 dueDate。"
            )
        }
        if recurring > 0 {
            ledger.record(
                field: "recurring",
                kind: .dropped,
                count: recurring,
                detail: "循环任务在 Zeno 没有对应物，按单次任务导入（重复规则丢失）。"
            )
        }
        if subprojects > 0 {
            ledger.record(
                field: "subproject",
                kind: .dropped,
                count: subprojects,
                detail: "子项目引用的外部计划内容不会被展开，只保留占位行。"
            )
        }
        return tasks
    }

    private func makeKind(_ node: XMLNode) -> InteropTaskKind {
        if node.child("Summary")?.boolValue == true { return .group }
        if node.child("Milestone")?.boolValue == true { return .milestone }
        return .task
    }

    private func makeConstraint(
        _ node: XMLNode,
        dates: MSPDIDateParser,
        hardPins: inout Int,
        hardPinSamples: inout [String],
        dateless: inout Int
    ) -> InteropConstraint? {
        guard let raw = node.child("ConstraintType")?.intValue else { return nil }
        let date = dates.date(node.child("ConstraintDate"))
        switch raw {
        case 0: return .asSoonAsPossible
        case 1: return .asLateAsPossible
        case 2, 3:
            hardPins += 1
            if hardPinSamples.count < FidelityLedger.maxSamples {
                hardPinSamples.append(raw == 2 ? "Must Start On" : "Must Finish On")
            }
            return nil
        case 4, 5, 6, 7:
            guard let date else {
                dateless += 1
                return nil
            }
            switch raw {
            case 4: return .startNoEarlierThan(date)
            case 5: return .startNoLaterThan(date)
            case 6: return .endNoEarlierThan(date)
            default: return .endNoLaterThan(date)
            }
        default:
            return nil
        }
    }

    private func makeDependencies(
        _ node: XMLNode,
        dropped: inout Int,
        droppedSample: inout String?
    ) -> [InteropDependency] {
        var result: [InteropDependency] = []
        for link in node.children(named: "PredecessorLink") {
            guard link.child("CrossProject")?.boolValue != true,
                  let predecessorUID = link.child("PredecessorUID")?.text, !predecessorUID.isEmpty else {
                dropped += 1
                if droppedSample == nil { droppedSample = "CrossProject / 缺 PredecessorUID" }
                continue
            }
            // MSPDI 口径：0 = FF，1 = FS，2 = SF，3 = SS（与 Zeno 的枚举顺序不同）。
            let type: InteropDependencyType
            switch link.child("Type")?.intValue ?? 1 {
            case 0: type = .finishToFinish
            case 1: type = .finishToStart
            case 2: type = .startToFinish
            case 3: type = .startToStart
            default:
                dropped += 1
                if droppedSample == nil { droppedSample = "前置类型 \(link.child("Type")?.text ?? "")" }
                continue
            }
            let lag = MSPDIValue.seconds(fromTenthsOfMinutes: link.child("LinkLag")?.doubleValue ?? 0)
            result.append(InteropDependency(predecessorID: predecessorUID, type: type, lagSeconds: lag))
        }
        return result
    }

    private func makeAttributes(_ node: XMLNode, fieldsByID: [String: String]) -> [String: String] {
        var attributes: [String: String] = [:]
        for field in node.children(named: "ExtendedAttribute") {
            guard let fieldID = field.child("FieldID")?.text,
                  let value = field.child("Value")?.text, !value.isEmpty else { continue }
            let name = fieldsByID[fieldID] ?? "Field\(fieldID)"
            attributes[name] = value
        }
        return attributes
    }

    // MARK: - 资源与分配

    private func makeResources(_ root: XMLNode) -> [InteropResource] {
        guard let container = root.child("Resources") else { return [] }
        var result: [InteropResource] = []
        for node in container.children(named: "Resource") {
            guard let uid = node.child("UID")?.text, !uid.isEmpty else { continue }
            let kind: InteropResourceKind
            switch node.child("Type")?.intValue {
            case 0: kind = .material
            case 1: kind = .person
            case 2: kind = .cost
            default: kind = .unknown
            }
            result.append(
                InteropResource(
                    id: uid,
                    name: node.child("Name")?.text ?? "",
                    kind: kind,
                    units: node.child("MaxUnits")?.doubleValue ?? 1,
                    calendarID: calendarID(node.child("CalendarUID"))
                )
            )
        }
        return result
    }

    private func makeAssignments(_ root: XMLNode, ledger: inout FidelityLedger) -> [InteropAssignment] {
        guard let container = root.child("Assignments") else { return [] }
        var result: [InteropAssignment] = []
        var droppedBaselines = 0
        for node in container.children(named: "Assignment") {
            guard let taskUID = node.child("TaskUID")?.text, !taskUID.isEmpty,
                  let resourceUID = node.child("ResourceUID")?.text, !resourceUID.isEmpty else { continue }
            result.append(
                InteropAssignment(
                    taskID: taskUID,
                    resourceID: resourceUID,
                    units: node.child("Units")?.doubleValue ?? 1
                )
            )
            droppedBaselines += node.children(named: "Baseline").count
        }
        if droppedBaselines > 0 {
            ledger.record(
                field: "baseline.assignment",
                kind: .dropped,
                count: droppedBaselines,
                detail: "分配级基线（每条分配的工作/成本/日期快照）在 Zeno 没有落点：只保留任务级基线。"
            )
        }
        return result
    }

    // MARK: - 基线

    private func makeBaselines(
        _ root: XMLNode,
        dates: MSPDIDateParser,
        ledger: inout FidelityLedger
    ) -> [InteropBaseline] {
        guard let container = root.child("Tasks") else { return [] }
        var entriesByNumber: [Int: [InteropBaselineEntry]] = [:]
        var incomplete = 0
        for task in container.children(named: "Task") {
            guard let taskUID = task.child("UID")?.text, !taskUID.isEmpty,
                  task.child("IsNull")?.boolValue != true else { continue }
            for baseline in task.children(named: "Baseline") {
                guard let number = baseline.child("Number")?.intValue,
                      let start = dates.date(baseline.child("Start")),
                      let finish = dates.date(baseline.child("Finish")) else {
                    incomplete += 1
                    continue
                }
                entriesByNumber[number, default: []].append(
                    InteropBaselineEntry(taskID: taskUID, start: start, finish: finish)
                )
            }
        }
        if incomplete > 0 {
            ledger.record(
                field: "baseline.entry",
                kind: .dropped,
                count: incomplete,
                detail: "基线记录缺编号或起止时间（Project 里常见于「只存了部分字段」的基线），无法还原。"
            )
        }
        return entriesByNumber.keys.sorted().map { number in
            InteropBaseline(id: String(number), entries: entriesByNumber[number] ?? [])
        }
    }

    // MARK: - 小工具

    /// 任务/项目级的 `CalendarUID`：`-1` 与缺失都表示「继承上级日历」。
    private func calendarID(_ node: XMLNode?) -> String? {
        guard let value = node?.intValue, value > 0 else { return nil }
        return String(value)
    }
}

/// 只在异常日展开里用到的整日算术（避免与 Zeno 的工作日口径混淆）。
private enum CalendarDayMathStart {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    static func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    static func adding(days: Int, to date: Date) -> Date? {
        calendar.date(byAdding: .day, value: days, to: startOfDay(date))
    }
}

private extension String {
    /// 空白串视为「没有值」，避免把 `<Name></Name>` 变成有值的空名字。
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
