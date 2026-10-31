import Foundation
import KaidoInterop

/// OmniPlan \`.oplx\` 读入器（docs/features/11-interop-omniplan.md §4）。
///
/// 只做「\`.oplx\` ↔ IR」：层级、依赖四型、前导时间、分配、日历、约束。
/// 任何「工作日 ↔ 日历天」「effort 秒 ↔ 人日」的换算都不在这里——统一在 \`KaidoBridge\`
/// （14 §2 硬规则 2），这里只把来源原值（秒、日号）换成 IR 口径并登记换算。
///
/// 版本前置（硬规则 3）：\`__TOC.xml\` 的 \`file-format-version\` 不在支持范围即抛
/// \`unsupportedFormatVersion\`，不尝试解析已知字段后「看起来成功」。
public struct OmniPlanReader {
    /// 支持的 \`file-format-version\`（OmniPlan 4.x 目前恒为 3）。
    public static let supportedFormatVersions = [3]

    /// 命名空间常量（仅用于注释与嗅探说明；解析按元素名，与命名空间前缀无关）。
    public static let namespace = "http://www.omnigroup.com/namespace/OmniPlan/v2"
    /// 文档外壳成员。
    public static let tocMember = "__TOC.xml"
    /// 业务数据成员（默认场景）。
    public static let defaultScenarioMember = "Actual.xml"
    /// 项目日历在 IR 中的 id。
    public static let projectCalendarID = "calendar.project"

    /// 读入结果：IR + 来源格式版本（预检报告要显示版本）。
    public struct Result {
        public let document: InteropDocument
        public let formatVersion: Int

        public init(document: InteropDocument, formatVersion: Int) {
            self.document = document
            self.formatVersion = formatVersion
        }
    }

    /// 2001-01-01T00:00:00Z：日历例外的 \`sd\`/\`ed\` 是「自该日起的天数」。
    private static let epoch2001 = Date(timeIntervalSince1970: 978_307_200)
    /// 一天的秒数（日历例外的 \`st\`/\`et\` 是当日秒偏移）。
    private static let secondsPerDay: Double = 86_400

    /// OmniPlan 的星期名 → \`Calendar\` weekday 编号（1 = 周日）。
    private static let weekdayNumbers: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
        "thursday": 5, "friday": 6, "saturday": 7
    ]

    public init() {}

    /// 读入整份 \`.oplx\`。
    ///
    /// - Parameter data: zip 容器的原始字节。
    /// - Throws: \`InteropError.unsupportedFormatVersion\`（版本未知）或
    ///   \`InteropError.malformedDocument\`（容器/XML/必需元素不合法）。
    public func read(_ data: Data) throws -> Result {
        let archive = try makeArchive(data)
        let toc = try parseXML(try memberData(archive, named: Self.tocMember), member: Self.tocMember)
        let version = try formatVersion(of: toc)
        let project = toc.child("project")
        let scenarios = project?.children(named: "scenario") ?? []
        let scenarioMember = try scenarioFilename(scenarios)
        let scenario = try parseXML(try memberData(archive, named: scenarioMember), member: scenarioMember)

        var ledger = FidelityLedger()
        let calendar = makeCalendar(toc: toc, scenario: scenario, ledger: &ledger)
        let resources = makeResources(scenario: scenario, ledger: &ledger)
        let resourceIDs = Set(resources.map(\.id))
        let (tasks, assignments) = try makeTasks(
            scenario: scenario,
            resourceIDs: resourceIDs,
            ledger: &ledger
        )
        recordBaselineScenarios(scenarios, ledger: &ledger)
        recordEffortConversion(tasks: tasks, calendar: calendar, ledger: &ledger)

        let metadata = InteropMetadata(
            title: "",
            createdAt: nil,
            lastSavedAt: nil,
            plannedStart: parseDate(scenario.childText("start-date")),
            plannedFinish: nil,
            defaultCalendarID: calendar.id,
            direction: .forward
        )
        let document = InteropDocument(
            metadata: metadata,
            tasks: tasks,
            resources: resources,
            calendars: [calendar],
            assignments: assignments,
            baselines: [],
            customFields: [],
            ledger: ledger
        )
        return Result(document: document, formatVersion: version)
    }

    // MARK: - 容器与版本闸门

    private func makeArchive(_ data: Data) throws -> ZipArchive {
        do {
            return try ZipArchive(data: data)
        } catch let error as ZipArchive.ZipError {
            throw InteropError.malformedDocument(error.description)
        }
    }

    private func memberData(_ archive: ZipArchive, named name: String) throws -> Data {
        do {
            return try archive.requiredData(named: name)
        } catch let error as ZipArchive.ZipError {
            throw InteropError.malformedDocument(error.description)
        }
    }

    private func parseXML(_ data: Data, member: String) throws -> OmniPlanXMLNode {
        let builder = OmniPlanXMLTreeBuilder()
        guard let root = builder.parse(data) else {
            let reason = builder.failure ?? "内容为空"
            throw InteropError.malformedDocument("\(member) 不是合法 XML：\(reason)")
        }
        return root
    }

    /// 版本闸门：只有 \`file-format-version\` 命中支持范围才继续解析。
    private func formatVersion(of toc: OmniPlanXMLNode) throws -> Int {
        guard toc.name == "omniplan" else {
            throw InteropError.malformedDocument(
                "\(Self.tocMember) 的根元素应为 omniplan，实际为 \(toc.name)"
            )
        }
        guard let raw = toc.attribute("file-format-version") else {
            throw InteropError.malformedDocument(
                "\(Self.tocMember) 缺少 file-format-version 属性：无法判定版本，拒绝按当前版本解析"
            )
        }
        guard let version = Int(raw) else {
            throw InteropError.malformedDocument("file-format-version 不是整数：\(raw)")
        }
        guard Self.supportedFormatVersions.contains(version) else {
            throw InteropError.unsupportedFormatVersion(
                version: version,
                supported: Self.supportedFormatVersions
            )
        }
        return version
    }

    /// 业务数据成员名：TOC 声明的 Actual 场景优先，否则退回 \`Actual.xml\`。
    private func scenarioFilename(_ scenarios: [OmniPlanXMLNode]) throws -> String {
        let declared = scenarios.first { $0.attribute("name") == "Actual" }
            ?? scenarios.first { $0.attribute("filename") == Self.defaultScenarioMember }
        if let filename = declared?.attribute("filename"), !filename.isEmpty {
            return filename
        }
        return Self.defaultScenarioMember
    }

    /// 基线快照是**独立 scenario 文件**，本期不导入，只登记（11 §7）。
    private func recordBaselineScenarios(
        _ scenarios: [OmniPlanXMLNode],
        ledger: inout FidelityLedger
    ) {
        let baselines = scenarios.filter { $0.attribute("name") != "Actual" }
        guard !baselines.isEmpty else { return }
        ledger.record(
            field: "baseline",
            kind: .dropped,
            count: baselines.count,
            detail: "基线快照存放在独立的 scenario 文件里，导入只取 Actual 场景：基线需要回到来源文件里看。",
            samples: baselines.map { $0.attribute("name") ?? "未命名基线" }
        )
    }

    /// \`effort\` 秒 ↔ 人日的换算基准登记（11 §4：用户样本 hours-per-day 是 16，不是 8）。
    private func recordEffortConversion(
        tasks: [InteropTask],
        calendar: InteropCalendar,
        ledger: inout FidelityLedger
    ) {
        let withEffort = tasks.filter { $0.effortHours != nil }
        guard let sample = withEffort.first?.effortHours else { return }
        ledger.record(
            field: "task.duration",
            kind: .converted,
            count: withEffort.count,
            detail: "OmniPlan 不存独立工期，只存 effort（工时）：工期按 effort 记，"
                + "折算人日一律用 duration-format 的 hours-per-day=\(Self.hoursText(calendar.hoursPerDay))。",
            sample: "effort=\(Self.secondsText(sample * 3600))s → \(Self.hoursText(sample))h"
        )
    }

    // MARK: - 日历

    /// 项目日历：工作周取项目资源（\`top-resource\`）的 \`schedule\`，例外取其中的
    /// \`Time Off\` / \`Overtime\` 图层事件。
    ///
    /// \`hourPerDay\` 用 \`duration-format\` 的 \`hours-per-day\`：这是 OmniPlan 自己折算人日的口径，
    /// 与 \`schedule-day\` 的作息时长（样本是 08:00–22:00）不是一回事。
    private func makeCalendar(
        toc: OmniPlanXMLNode,
        scenario: OmniPlanXMLNode,
        ledger: inout FidelityLedger
    ) -> InteropCalendar {
        var hoursPerDay = 8.0
        if let declared = toc.child("project")?.child("duration-format")?
            .attribute("hours-per-day").flatMap(Double.init), declared > 0 {
            hoursPerDay = declared
            ledger.record(
                field: "calendar.hoursPerDay",
                kind: .converted,
                count: 1,
                detail: "来源以 hours-per-day=\(Self.hoursText(declared)) 折算人日（Kaido 默认 8）："
                    + "写死 8 会让所有工期整体差约 \(Self.hoursText(declared / 8)) 倍。",
                sample: "hours-per-day=\(Self.hoursText(declared))"
            )
        } else {
            ledger.record(
                field: "calendar.hoursPerDay",
                kind: .derived,
                count: 1,
                detail: "来源没有 duration-format，工时按 Kaido 默认 8h/日 折算。"
            )
        }

        let resourceNodes = scenario.children(named: "resource")
        let rootResourceID = scenario.child("top-resource")?.attribute("idref")
        let rootResource = rootResourceID.flatMap { id in
            resourceNodes.first { $0.attribute("id") == id }
        }
        let scheduleSource = rootResource?.child("schedule") != nil
            ? rootResource
            : resourceNodes.first { $0.child("schedule") != nil }
        let schedule = scheduleSource?.child("schedule")

        var workingWeekdays: Set<Int> = []
        var exceptions: [InteropCalendarException] = []
        var partialEvents = 0
        var partialSample: String?

        if let schedule {
            for day in schedule.children(named: "schedule-day") {
                guard let raw = day.attribute("day-of-week")?.lowercased(),
                      let weekday = Self.weekdayNumbers[raw] else { continue }
                let worked = day.children(named: "time-span").reduce(0.0) { total, span in
                    let start = span.attribute("start-time").flatMap(Double.init) ?? 0
                    let end = span.attribute("end-time").flatMap(Double.init) ?? 0
                    return total + max(0, end - start)
                }
                if worked > 0 { workingWeekdays.insert(weekday) }
            }

            for layer in schedule.children(named: "calendar") {
                let isOvertime = layer.attribute("overtime") == "yes"
                    || layer.attribute("name") == "Overtime"
                for event in layer.children(named: "event") {
                    guard let dayNumber = event.attribute("sd").flatMap(Int.init) else {
                        partialEvents += 1
                        if partialSample == nil { partialSample = "\(layer.attribute("name") ?? "例外") 事件缺少 sd" }
                        continue
                    }
                    let date = Self.epoch2001.addingTimeInterval(Double(dayNumber) * Self.secondsPerDay)
                    let start = event.attribute("st").flatMap(Double.init) ?? 0
                    let end = event.attribute("et").flatMap(Double.init) ?? 0
                    let isFullDay = start <= 0 && end >= Self.secondsPerDay
                    if isOvertime {
                        // 加班：Kaido 的例外只有「整天上班/不上班」，半天加班表达不了。
                        if isFullDay {
                            exceptions.append(InteropCalendarException(date: date, isWorking: true))
                        } else {
                            partialEvents += 1
                            if partialSample == nil { partialSample = "加班 \(Self.secondsText(end - start))s" }
                        }
                    } else {
                        exceptions.append(
                            InteropCalendarException(date: date, isWorking: false, note: layer.attribute("name"))
                        )
                        if !isFullDay {
                            partialEvents += 1
                            if partialSample == nil { partialSample = "请假 \(Self.secondsText(end - start))s" }
                        }
                    }
                }
            }
        }

        if workingWeekdays.isEmpty {
            ledger.record(
                field: "calendar.workingWeekdays",
                kind: .derived,
                count: 1,
                detail: "来源没有可用的 schedule-day，工作日历按全周 7 天（Kaido 默认）处理。"
            )
        }
        if !exceptions.isEmpty {
            ledger.record(
                field: "calendar.exception",
                kind: .converted,
                count: exceptions.count,
                detail: "Time Off / Overtime 事件按整天落到 Kaido 节假日："
                    + "日号（自 2001-01-01 起的天数）按 UTC 日换算，时间偏移丢弃。",
                samples: exceptions.prefix(2).map { Self.dayText($0.date) + ($0.isWorking ? "（加班）" : "（停工）") }
            )
        }
        if partialEvents > 0 {
            ledger.record(
                field: "calendar.exception.partial",
                kind: .degraded,
                count: partialEvents,
                detail: "半天请假/加班在 Kaido 没有落点（例外只有整天粒度），这些时段仍按全天上/下班处理。",
                sample: partialSample
            )
        }

        recordResourceSchedules(
            resourceNodes,
            calendarSourceID: scheduleSource?.attribute("id"),
            ledger: &ledger
        )

        return InteropCalendar(
            id: Self.projectCalendarID,
            name: "OmniPlan 项目日历",
            workingWeekdays: workingWeekdays,
            hoursPerDay: hoursPerDay,
            exceptions: exceptions
        )
    }

    /// 资源自己的作息表（样本里设备是 0:00–23:59、群组是 24/7）：Kaido 没有资源日历，登记丢弃。
    ///
    /// 已被当作项目日历来源的那条资源不算丢弃。
    private func recordResourceSchedules(
        _ nodes: [OmniPlanXMLNode],
        calendarSourceID: String?,
        ledger: inout FidelityLedger
    ) {
        let withSchedule = nodes.filter { node in
            node.attribute("id") != calendarSourceID && node.child("schedule") != nil
        }
        guard !withSchedule.isEmpty else { return }
        ledger.record(
            field: "resource.calendar",
            kind: .dropped,
            count: withSchedule.count,
            detail: "Kaido 没有资源日历（只有项目日历）：资源级作息表丢弃，资源按项目日历参与排期。",
            samples: withSchedule.map { $0.childText("name") ?? ($0.attribute("id") ?? "未命名资源") }
        )
    }

    // MARK: - 资源

    /// 资源：\`Staff\` / \`Equipment\` / \`Material\` / \`Group\` / \`Project\`。
    ///
    /// IR 只区分人员/素材/成本，OmniPlan 的 Equipment 归素材、Group 与 Project 容器归未知，
    /// 降级一律登记，不静默改写。
    private func makeResources(
        scenario: OmniPlanXMLNode,
        ledger: inout FidelityLedger
    ) -> [InteropResource] {
        var result: [InteropResource] = []
        var degradedSamples: [String] = []
        for node in scenario.children(named: "resource") {
            guard let id = node.attribute("id") else { continue }
            let name = node.childText("name") ?? ""
            let rawType = node.childText("type") ?? "Staff"
            let kind: InteropResourceKind
            switch rawType.lowercased() {
            case "staff":
                kind = .person
            case "equipment", "material":
                kind = .material
            default:
                kind = .unknown
            }
            if rawType.lowercased() != "staff" {
                degradedSamples.append("\(rawType)→\(kind.rawValue)")
            }
            if node.child("note") != nil {
                ledger.record(
                    field: "resource.notes",
                    kind: .dropped,
                    count: 1,
                    detail: "Kaido 的资源没有备注字段：来源资源备注（含预设计划表说明）丢弃。",
                    sample: name
                )
            }
            if let efficiency = node.child("efficiency")?.doubleValue, abs(efficiency - 1) > 0.0001 {
                ledger.record(
                    field: "resource.efficiency",
                    kind: .dropped,
                    count: 1,
                    detail: "Kaido 的效率字段未参与导入：来源资源的效率被忽略，投入↔工期换算按 100% 处理。",
                    sample: "\(name) efficiency=\(efficiency)"
                )
            }
            result.append(InteropResource(id: id, name: name, kind: kind, units: 1))
        }
        if !degradedSamples.isEmpty {
            ledger.record(
                field: "resource.kind",
                kind: .degraded,
                count: degradedSamples.count,
                detail: "IR 只有人员/素材/成本三种资源种类：设备归素材，群组与项目容器归未知（Kaido 侧落为人员）。",
                samples: degradedSamples
            )
        }
        return result
    }

    // MARK: - 任务

    /// 任务树：从 \`top-task\` 起按 \`child-task\` 深度优先展开，顺序即大纲顺序。
    private func makeTasks(
        scenario: OmniPlanXMLNode,
        resourceIDs: Set<String>,
        ledger: inout FidelityLedger
    ) throws -> ([InteropTask], [InteropAssignment]) {
        var nodesByID: [String: OmniPlanXMLNode] = [:]
        for node in scenario.children(named: "task") {
            guard let id = node.attribute("id") else { continue }
            if nodesByID[id] == nil {
                nodesByID[id] = node
            } else {
                throw InteropError.malformedDocument("任务 id 重复：\(id)")
            }
        }
        guard let topID = scenario.child("top-task")?.attribute("idref") else {
            throw InteropError.malformedDocument("场景缺少 top-task：无法确定大纲根节点")
        }
        guard nodesByID[topID] != nil else {
            throw InteropError.malformedDocument("top-task 指向不存在的任务 \(topID)")
        }

        // 显式栈做深度优先：顺序即大纲顺序（父在子前，兄弟按 child-task 声明顺序）。
        var order: [(id: String, level: Int, parentID: String?)] = []
        var visited: Set<String> = []
        var stack: [(id: String, level: Int, parentID: String?)] = [(topID, 0, nil)]
        while let next = stack.popLast() {
            guard !visited.contains(next.id) else {
                throw InteropError.malformedDocument("任务层级存在环或重复引用：\(next.id)")
            }
            guard let node = nodesByID[next.id] else {
                throw InteropError.malformedDocument("child-task 指向不存在的任务 \(next.id)")
            }
            visited.insert(next.id)
            order.append(next)
            let children = node.children(named: "child-task").compactMap { $0.attribute("idref") }
            for childID in children.reversed() {
                stack.append((childID, next.level + 1, next.id))
            }
        }

        // OmniPlan 文档必然带一个大纲根容器：只有一个无标题根、没有任何子任务时，
        // 它就是「空计划」（与 MSPDI 的零任务空计划等价），不往 Kaido 里塞一个幻影任务。
        if order.count == 1, let only = order.first,
           nodesByID[only.id]?.childText("title") == nil {
            return ([], [])
        }

        var tasks: [InteropTask] = []
        var assignments: [InteropAssignment] = []
        for step in order {
            guard let node = nodesByID[step.id] else {
                throw InteropError.malformedDocument("child-task 指向不存在的任务 \(step.id)")
            }
            let (task, taskAssignments) = makeTask(
                node,
                id: step.id,
                level: step.level,
                parentID: step.parentID,
                sequence: tasks.count,
                resourceIDs: resourceIDs,
                ledger: &ledger
            )
            tasks.append(task)
            assignments.append(contentsOf: taskAssignments)
        }

        let orphans = nodesByID.keys.filter { !visited.contains($0) }
        if !orphans.isEmpty {
            ledger.record(
                field: "task.orphan",
                kind: .dropped,
                count: orphans.count,
                detail: "不在大纲树上的任务（没有父节点引用）无法定位层级，导入时跳过。",
                samples: orphans.sorted().prefix(3).map { id in
                    nodesByID[id]?.childText("title") ?? id
                }
            )
        }
        return (tasks, assignments)
    }

    private func makeTask(
        _ node: OmniPlanXMLNode,
        id: String,
        level: Int,
        parentID: String?,
        sequence: Int,
        resourceIDs: Set<String>,
        ledger: inout FidelityLedger
    ) -> (InteropTask, [InteropAssignment]) {
        let title = node.childText("title") ?? ""
        let rawType = node.childText("type")?.lowercased()
        let kind: InteropTaskKind
        switch rawType {
        case "group": kind = .group
        case "milestone": kind = .milestone
        default: kind = .task
        }

        let effortSeconds = node.child("effort")?.doubleValue
        let effortDone = node.child("effort-done")?.doubleValue ?? 0
        var progress: Double = 0
        if let effortSeconds, effortSeconds > 0 {
            progress = min(max(effortDone / effortSeconds, 0), 1)
        }

        let notes = noteText(node.child("note"), ledger: &ledger)

        var dependencies: [InteropDependency] = []
        for prerequisite in node.children(named: "prerequisite-task") {
            guard let predecessorID = prerequisite.attribute("idref") else {
                ledger.record(
                    field: "dependency",
                    kind: .dropped,
                    count: 1,
                    detail: "prerequisite-task 缺少 idref，无法定位前驱任务。",
                    sample: title
                )
                continue
            }
            let type: InteropDependencyType
            switch prerequisite.attribute("kind")?.uppercased() {
            case nil, "FS": type = .finishToStart
            case "SS": type = .startToStart
            case "FF": type = .finishToFinish
            case "SF": type = .startToFinish
            default:
                ledger.record(
                    field: "dependency.type",
                    kind: .dropped,
                    count: 1,
                    detail: "未知的相关性类型，无法映射到四类标准关系。",
                    sample: prerequisite.attribute("kind") ?? ""
                )
                continue
            }
            var lagSeconds: TimeInterval = 0
            if let lead = prerequisite.child("lead-time") {
                if lead.attribute("is-percentage") == "true" {
                    ledger.record(
                        field: "dependency.lag",
                        kind: .degraded,
                        count: 1,
                        detail: "百分比前导时间要按前驱工期换算，本期按 0 处理（关系类型与前驱仍保留）。",
                        sample: "\(title) \(lead.text)%"
                    )
                } else {
                    lagSeconds = lead.doubleValue ?? 0
                }
            }
            dependencies.append(
                InteropDependency(predecessorID: predecessorID, type: type, lagSeconds: lagSeconds)
            )
        }

        var assignments: [InteropAssignment] = []
        for assignment in node.children(named: "assignment") {
            guard let resourceID = assignment.attribute("idref") else { continue }
            guard resourceIDs.contains(resourceID) else {
                ledger.record(
                    field: "assignment",
                    kind: .dropped,
                    count: 1,
                    detail: "分配指向不存在的资源，无法落地。",
                    sample: "\(title) → \(resourceID)"
                )
                continue
            }
            let units = assignment.attribute("units").flatMap(Double.init) ?? 1
            assignments.append(
                InteropAssignment(taskID: id, resourceID: resourceID, units: units > 0 ? units : 1)
            )
        }

        recordCostIfPresent(node, title: title, ledger: &ledger)

        return (
            InteropTask(
                id: id,
                title: title,
                notes: notes,
                kind: kind,
                outlineLevel: level,
                parentID: parentID,
                sequence: sequence,
                plannedStart: nil,
                plannedFinish: nil,
                durationSeconds: kind == .task ? effortSeconds : nil,
                effortHours: kind == .task ? effortSeconds.map { $0 / 3600 } : nil,
                progress: progress,
                actualStart: nil,
                actualFinish: nil,
                dependencies: dependencies,
                constraint: constraint(of: node, title: title, ledger: &ledger),
                calendarID: nil,
                attributes: [:]
            ),
            assignments
        )
    }

    /// 约束：四个「不早于/不晚于」优先，\`locked-*\` 是硬钉、降级为同时刻的软约束。
    private func constraint(
        of node: OmniPlanXMLNode,
        title: String,
        ledger: inout FidelityLedger
    ) -> InteropConstraint? {
        var result: InteropConstraint?
        if let date = parseDate(node.childText("start-no-earlier-than")) {
            result = .startNoEarlierThan(date)
        } else if let date = parseDate(node.childText("start-no-later-than")) {
            result = .startNoLaterThan(date)
        } else if let date = parseDate(node.childText("end-no-earlier-than")) {
            result = .endNoEarlierThan(date)
        } else if let date = parseDate(node.childText("end-no-later-than")) {
            result = .endNoLaterThan(date)
        }

        let lockedStart = parseDate(node.childText("locked-start-date"))
        let lockedEnd = parseDate(node.childText("locked-end-date"))
        if lockedStart != nil || lockedEnd != nil {
            ledger.record(
                field: "constraint.locked",
                kind: .degraded,
                count: 1,
                detail: "锁定日期（locked-start-date / locked-end-date）是硬钉，Kaido 只有软时限："
                    + "降级为同时刻的「不早于 / 不晚于」，导入后可被拖动。",
                sample: title
            )
        }
        if result == nil, let lockedStart { result = .startNoEarlierThan(lockedStart) }
        if result == nil, let lockedEnd { result = .endNoLaterThan(lockedEnd) }

        if result == nil, node.childText("schedule-type")?.lowercased() == "alap" {
            result = .asLateAsPossible
        }
        return result
    }

    /// 备注：取富文本树里所有 \`<lit>\` 的文本；样式（对齐/字体）无落点，登记降级。
    private func noteText(_ note: OmniPlanXMLNode?, ledger: inout FidelityLedger) -> String {
        guard let note else { return "" }
        var pieces: [String] = []
        var hasStyle = false
        collectNote(note, pieces: &pieces, hasStyle: &hasStyle)
        let text = pieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        if hasStyle, !text.isEmpty {
            ledger.record(
                field: "task.notes",
                kind: .degraded,
                count: 1,
                detail: "OmniPlan 备注是富文本树：只保留文字，段落对齐与字体样式丢弃。",
                sample: String(text.prefix(20))
            )
        }
        return text
    }

    private func collectNote(_ node: OmniPlanXMLNode, pieces: inout [String], hasStyle: inout Bool) {
        if node.name == "style" || node.name == "value" { hasStyle = true }
        if node.name == "lit" { pieces.append(node.text) }
        for child in node.children { collectNote(child, pieces: &pieces, hasStyle: &hasStyle) }
    }

    /// 成本：Kaido 无费率/成本，非零即登记丢弃（样本里全是 0，不制造假损失）。
    private func recordCostIfPresent(
        _ node: OmniPlanXMLNode,
        title: String,
        ledger: inout FidelityLedger
    ) {
        let staticCost = node.child("static-cost")?.doubleValue ?? 0
        let rate = node.child("cost-per-hour")?.doubleValue ?? 0
        guard abs(staticCost) > 0 || abs(rate) > 0 else { return }
        ledger.record(
            field: "cost",
            kind: .dropped,
            count: 1,
            detail: "Kaido 没有成本/费率：任务的静态成本与小时费率丢弃。",
            sample: "\(title) 固定成本=\(staticCost) 费率=\(rate)"
        )
    }

    // MARK: - 取值与格式化

    /// ISO-8601（带毫秒优先，退回不带毫秒）；OmniPlan 也可能写 \`+08:00\` 偏移。
    private func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return Self.dateFormatter.date(from: raw) ?? Self.fallbackDateFormatter.date(from: raw)
    }

    /// 只用于人读登记的日期文本（UTC 日）。
    private static func dayText(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private static func hoursText(_ hours: Double) -> String {
        hours == hours.rounded() ? String(Int(hours)) : String(format: "%.1f", hours)
    }

    private static func secondsText(_ seconds: Double) -> String {
        seconds == seconds.rounded() ? String(Int(seconds)) : String(format: "%.0f", seconds)
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let fallbackDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
