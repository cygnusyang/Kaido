import Foundation
import ZenoInterop

/// 写出结果：\`.oplx\` 字节 + 导出侧有损登记。
///
/// \`FormatAdapter.write\` 只能返回 Data，但「哪些 Zeno 独有信息带不走」必须能渲染成
/// 导出旁注（13-mapping §5），所以写出端另外暴露这份登记，与 \`MSPDIExport\` 同形。
public struct OmniPlanExport: Sendable, Equatable {
    /// 写出的 \`.oplx\` 容器（zip，含 \`__TOC.xml\` 与 \`Actual.xml\`）。
    public let data: Data
    /// 导出侧有损登记（已并入输入文档自带的登记）。
    public let ledger: FidelityLedger

    public init(data: Data, ledger: FidelityLedger) {
        self.data = data
        self.ledger = ledger
    }
}

/// OmniPlan \`.oplx\` 写出器（docs/features/11-interop-omniplan.md §7）。
///
/// 只做「IR ↔ \`.oplx\`」，不做任何「工作日 ↔ 日历天」换算（14 §2 硬规则 2）。
///
/// 容器按 §7 实测的最小必需集写：\`__TOC.xml\`（\`file-format-version="3"\` + project +
/// scenario 清单 + duration-format）与 \`Actual.xml\`（start-date + top-task + 任务 + 资源 + 日历）。
/// 不写 \`__changelog.xml\` / \`Preview.png\` / 原型任务 / 过滤器——那是样式与编辑流水，业务语义不需要。
///
/// 两条格式硬约束在这里被**显式**满足，代价写进 \`FidelityLedger\`：
/// - \`top-task\` 只能有一个：Zeno 的多个顶层任务（或空计划）会被包进一个空标题根群组，
///   回导时多出一个群组（登记 \`task.root\`）；
/// - 项目日历挂在项目资源（\`top-resource\`）的 \`schedule\` 上：文档没有资源时补一条
///   「项目」资源承载日历（登记 \`resource.project\`）。
public struct OmniPlanWriter {
    /// 场景 id：任意 token 即可（§7 实测），固定值保证产物可复现。
    public static let scenarioID = "zeno-actual"

    /// 没有日历时的人日折算基准。
    ///
    /// 11 §4：\`duration-format\` 的 \`hours-per-day\` 样本间 8 与 16 混存，用户样本是 16。
    /// 写出时必须落一个具体值（否则 OmniPlan 按自己的模板回填 8），而 Zeno 侧的工期按
    /// 项目日历折算；写 8 会让同一份工时读回后整体差一倍。
    public static let defaultHoursPerDay: Double = 16

    /// 日历例外的日号口径：自 2001-01-01Z 起的天数（11 §4）。
    private static let epoch2001 = Date(timeIntervalSince1970: 978_307_200)
    private static let secondsPerDay: Double = 86_400

    /// OmniPlan 的星期名，按 \`Calendar\` weekday 编号（1 = 周日）索引。
    private static let weekdayNames: [Int: String] = [
        1: "sunday", 2: "monday", 3: "tuesday", 4: "wednesday",
        5: "thursday", 6: "friday", 7: "saturday"
    ]

    public init() {}

    /// 把 IR 写成 \`.oplx\`，并返回导出侧有损登记。
    ///
    /// - Throws: \`InteropError.operationNotSupported\`（内容超出单卷 zip 上限，实际不可达）。
    public func write(_ document: InteropDocument) throws -> OmniPlanExport {
        var ledger = FidelityLedger()
        let taskIDs = IDPlan(ids: document.tasks.map(\.id), prefix: "t")
        let resourceIDs = IDPlan(ids: document.resources.map(\.id), prefix: "r")
        recordRenumbering(taskIDs, field: "task.id", noun: "任务", ledger: &ledger)
        recordRenumbering(resourceIDs, field: "resource.id", noun: "资源", ledger: &ledger)

        let calendar = resolveCalendar(document, ledger: &ledger)
        let needsSchedule = !calendar.weekdays.isEmpty || !calendar.exceptions.isEmpty
        let projectResource = resolveProjectResource(
            document,
            resourceIDs: resourceIDs,
            needsSchedule: needsSchedule,
            ledger: &ledger
        )
        let outline = makeOutline(document, taskIDs: taskIDs, ledger: &ledger)
        recordDocumentDrops(document, ledger: &ledger)

        var drops = DropCollector()
        let scenario = renderScenario(
            document,
            outline: outline,
            taskIDs: taskIDs,
            resourceIDs: resourceIDs,
            projectResource: projectResource,
            calendar: calendar,
            drops: &drops
        )
        drops.flush(into: &ledger)

        var usedTaskIDs = taskIDs.allIDs
        usedTaskIDs.append(outline.rootID)
        var usedResourceIDs = resourceIDs.allIDs
        if let synthetic = projectResource.syntheticID { usedResourceIDs.append(synthetic) }

        let toc = renderTOC(
            nextTaskID: Self.nextCounter(prefix: "t", ids: usedTaskIDs),
            nextResourceID: Self.nextCounter(prefix: "r", ids: usedResourceIDs),
            hoursPerDay: calendar.hoursPerDay
        )

        let data: Data
        do {
            data = try ZipArchiveWriter.archive([
                ZipArchiveWriter.Member(OmniPlanReader.tocMember, toc),
                ZipArchiveWriter.Member(OmniPlanReader.defaultScenarioMember, scenario)
            ])
        } catch let error as ZipArchiveWriter.ZipWriteError {
            throw InteropError.operationNotSupported("OmniPlan 容器写出失败：\(error.description)")
        }
        return OmniPlanExport(data: data, ledger: document.ledger.merging(ledger))
    }

    // MARK: - 大纲

    /// 大纲：根 + 父子关系；子下标已按大纲顺序排好。
    private struct Outline {
        /// \`top-task\` 指向的任务 id。
        let rootID: String
        /// 根对应文档里的任务下标（补出来的空群组为 nil）。
        let rootIndex: Int?
        /// 父下标 → 有序子下标；\`-1\` 表示顶层。
        let children: [Int: [Int]]
    }

    private func makeOutline(
        _ document: InteropDocument,
        taskIDs: IDPlan,
        ledger: inout FidelityLedger
    ) -> Outline {
        let tasks = document.tasks
        var indexByID: [String: Int] = [:]
        for (index, task) in tasks.enumerated() where indexByID[task.id] == nil {
            indexByID[task.id] = index
        }

        var children: [Int: [Int]] = [:]
        for (index, task) in tasks.enumerated() {
            var parent: Int?
            if let parentID = task.parentID, let resolved = indexByID[parentID], resolved != index {
                parent = resolved
            }
            children[parent ?? -1, default: []].append(index)
        }

        // 父引用成环的任务不会出现在任何根下：挂到根上（登记），不静默丢数据。
        var reachable: Set<Int> = []
        var queue = children[-1] ?? []
        var cursor = 0
        while cursor < queue.count {
            let index = queue[cursor]
            cursor += 1
            guard reachable.insert(index).inserted else { continue }
            queue.append(contentsOf: children[index] ?? [])
        }
        let unreachable = tasks.indices.filter { !reachable.contains($0) }
        if !unreachable.isEmpty {
            children[-1, default: []].append(contentsOf: unreachable)
            children[-1]?.sort()
            ledger.record(
                field: "task.orphan",
                kind: .degraded,
                count: unreachable.count,
                detail: "父引用互相指向（成环）的任务在 OmniPlan 大纲里没有位置：挂到根群组下保住内容，层级与原来不同。",
                samples: unreachable.prefix(FidelityLedger.maxSamples).map { Self.label(of: tasks[$0]) }
            )
        }

        let roots = children[-1] ?? []
        if roots.count == 1, let root = roots.first {
            return Outline(rootID: taskIDs.id(at: root), rootIndex: root, children: children)
        }
        if !roots.isEmpty {
            ledger.record(
                field: "task.root",
                kind: .derived,
                count: roots.count,
                detail: "OmniPlan 的大纲只能有一个 top-task：\(roots.count) 个顶层任务被包进一个空标题根群组，"
                    + "回导时会多出一个群组。",
                samples: roots.prefix(FidelityLedger.maxSamples).map { tasks[$0].title }
            )
        }
        var used = Set(taskIDs.allIDs)
        var rootID = "t-1"
        var suffix = 2
        while used.contains(rootID) {
            rootID = "t-root\(suffix)"
            suffix += 1
        }
        used.insert(rootID)
        return Outline(rootID: rootID, rootIndex: nil, children: children)
    }

    // MARK: - 日历

    private struct CalendarPlan {
        let hoursPerDay: Double
        let weekdays: Set<Int>
        let exceptions: [InteropCalendarException]
    }

    private func resolveCalendar(
        _ document: InteropDocument,
        ledger: inout FidelityLedger
    ) -> CalendarPlan {
        guard !document.calendars.isEmpty else {
            ledger.record(
                field: "calendar.hoursPerDay",
                kind: .derived,
                count: 1,
                detail: "文档没有日历：按 \(Self.number(Self.defaultHoursPerDay)) 小时/日 写 duration-format，"
                    + "作息表交给 OmniPlan 自己的默认日历。",
                sample: "hours-per-day=\(Self.number(Self.defaultHoursPerDay))"
            )
            return CalendarPlan(hoursPerDay: Self.defaultHoursPerDay, weekdays: [], exceptions: [])
        }

        var index = 0
        if let declared = document.metadata.defaultCalendarID {
            if let found = document.calendars.firstIndex(where: { $0.id == declared }) {
                index = found
            } else {
                ledger.record(
                    field: "calendar.default",
                    kind: .derived,
                    count: 1,
                    detail: "声明的默认日历不在文档里：改用第一个日历作为项目日历。",
                    sample: declared
                )
            }
        }
        if document.calendars.count > 1 {
            let others = document.calendars.enumerated()
                .filter { $0.offset != index }
                .map { $0.element.name.isEmpty ? $0.element.id : $0.element.name }
            ledger.record(
                field: "calendar.multi",
                kind: .dropped,
                count: document.calendars.count - 1,
                detail: "这份容器只写一个项目日历：其余日历丢弃，任务按项目日历排期。",
                samples: others
            )
        }

        let calendar = document.calendars[index]
        let hours = calendar.hoursPerDay > 0 ? calendar.hoursPerDay : Self.defaultHoursPerDay
        let noted = calendar.exceptions.filter { $0.note != nil }
        ledger.record(
            field: "calendar.exception.note",
            kind: .dropped,
            count: noted.count,
            detail: "例外日只写「整天上/下班」：备注文字在 OmniPlan 侧只是图层名，丢弃。",
            samples: noted.prefix(FidelityLedger.maxSamples).compactMap(\.note)
        )
        return CalendarPlan(
            hoursPerDay: hours,
            weekdays: calendar.workingWeekdays,
            exceptions: calendar.exceptions
        )
    }

    // MARK: - 项目资源

    /// 项目日历必须挂在 \`top-resource\` 的 \`schedule\` 上（11 §4）。
    private struct ProjectResourcePlan {
        /// 复用文档里第几条资源；补出来的资源为 nil。
        let index: Int?
        /// 补出来的资源 id（\`resource.project\` 登记时用）。
        let syntheticID: String?
    }

    private func resolveProjectResource(
        _ document: InteropDocument,
        resourceIDs: IDPlan,
        needsSchedule: Bool,
        ledger: inout FidelityLedger
    ) -> ProjectResourcePlan {
        // 优先挑容器型资源（\`Project\` / \`Group\` 读进 IR 是 unknown），与 OmniPlan 自己的文件一致。
        if let index = document.resources.firstIndex(where: { $0.kind == .unknown })
            ?? document.resources.indices.first {
            return ProjectResourcePlan(index: index, syntheticID: nil)
        }
        guard needsSchedule else {
            return ProjectResourcePlan(index: nil, syntheticID: nil)
        }
        var used = Set(resourceIDs.allIDs)
        var id = "r-1"
        var suffix = 2
        while used.contains(id) {
            id = "r-project\(suffix)"
            suffix += 1
        }
        used.insert(id)
        ledger.record(
            field: "resource.project",
            kind: .derived,
            count: 1,
            detail: "OmniPlan 的项目日历挂在项目资源（top-resource）上：文档没有资源时补一条「项目」资源承载日历，"
                + "回导会多出一条资源。",
            sample: id
        )
        return ProjectResourcePlan(index: nil, syntheticID: id)
    }

    // MARK: - 文档级有损

    private func recordDocumentDrops(_ document: InteropDocument, ledger: inout FidelityLedger) {
        ledger.record(
            field: "baseline",
            kind: .dropped,
            count: document.baselines.count,
            detail: "OmniPlan 的基线是独立的 scenario 文件 + changelog 流水：本期只写 Actual 场景，基线不进对方文件。",
            samples: document.baselines.prefix(FidelityLedger.maxSamples).map { $0.name ?? $0.id }
        )
        ledger.record(
            field: "customField",
            kind: .dropped,
            count: document.customFields.count,
            detail: "OmniPlan 的自定义字段（user-data）与 MSPDI 的 ExtendedAttribute 不是一一对应：映射未验证，定义与取值一起丢弃。",
            samples: document.customFields.prefix(FidelityLedger.maxSamples).map(\.fieldName)
        )
        if !document.metadata.title.isEmpty {
            ledger.record(
                field: "project.title",
                kind: .dropped,
                count: 1,
                detail: "OmniPlan 的项目名不写在 __TOC.xml 的 project 里（文件名即项目名）：标题丢弃，导出文件名请沿用项目名。",
                sample: document.metadata.title
            )
        }
        if document.metadata.author != nil || document.metadata.createdAt != nil
            || document.metadata.lastSavedAt != nil || document.metadata.plannedFinish != nil {
            ledger.record(
                field: "project.metadata",
                kind: .dropped,
                count: 1,
                detail: "作者 / 创建与保存时刻 / 计划终点由 OmniPlan 的文档外壳与排期推算：写入端不伪造，这些元数据丢弃。"
            )
        }
    }

    // MARK: - 场景

    private func renderScenario(
        _ document: InteropDocument,
        outline: Outline,
        taskIDs: IDPlan,
        resourceIDs: IDPlan,
        projectResource: ProjectResourcePlan,
        calendar: CalendarPlan,
        drops: inout DropCollector
    ) -> String {
        var lines: [String] = []
        lines.append(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        lines.append("<scenario xmlns=\"\(OmniPlanReader.namespace)\" id=\"\(Self.scenarioID)\">")
        if let start = document.metadata.plannedStart {
            lines.append(Self.element("start-date", Self.dateText(start), level: 1))
        }
        lines.append(Self.element("granularity", "days", level: 1))

        let scheduleOwnerID = projectResource.index.map { resourceIDs.id(at: $0) }
            ?? projectResource.syntheticID
        if let ownerID = scheduleOwnerID {
            lines.append(Self.indent(1) + "<top-resource idref=\"\(ownerID)\"/>")
        }
        lines.append(contentsOf: resourceLines(
            document,
            resourceIDs: resourceIDs,
            projectResource: projectResource,
            calendar: calendar,
            drops: &drops
        ))

        lines.append(Self.indent(1) + "<top-task idref=\"\(outline.rootID)\"/>")
        lines.append(contentsOf: taskLines(
            document,
            outline: outline,
            taskIDs: taskIDs,
            resourceIDs: resourceIDs,
            drops: &drops
        ))
        lines.append(Self.indent(1) + "<critical-path root=\"-1\" enabled=\"false\" resources=\"false\"/>")
        lines.append("</scenario>")
        return lines.joined(separator: "\n") + "\n"
    }

    private func resourceLines(
        _ document: InteropDocument,
        resourceIDs: IDPlan,
        projectResource: ProjectResourcePlan,
        calendar: CalendarPlan,
        drops: inout DropCollector
    ) -> [String] {
        var lines: [String] = []

        for (index, resource) in document.resources.enumerated() {
            let id = resourceIDs.id(at: index)
            let label = resource.name.isEmpty ? id : resource.name
            if abs(resource.units - 1) > 0.0001 {
                drops.resourceUnits += 1
                drops.resourceUnitSamples.append("\(label)=\(Self.number(resource.units))")
            }
            if resource.calendarID != nil { drops.resourceCalendar += 1 }
            if resource.kind == .cost { drops.costKind += 1 }

            lines.append(Self.indent(1) + "<resource id=\"\(id)\">")
            if !resource.name.isEmpty {
                lines.append(Self.element("name", resource.name, level: 2))
            }
            let isProject = projectResource.index == index
            lines.append(Self.element("type", Self.resourceType(resource, isProject: isProject), level: 2))
            if isProject {
                lines.append(contentsOf: scheduleLines(calendar, level: 2))
            }
            lines.append(Self.indent(1) + "</resource>")
        }

        if let syntheticID = projectResource.syntheticID {
            lines.append(Self.indent(1) + "<resource id=\"\(syntheticID)\">")
            lines.append(Self.element("name", "项目", level: 2))
            lines.append(Self.element("type", "Project", level: 2))
            lines.append(contentsOf: scheduleLines(calendar, level: 2))
            lines.append(Self.indent(1) + "</resource>")
        }
        return lines
    }

    /// 项目日历：\`schedule-day\` + 两个整日例外图层。
    ///
    /// \`time-span\` 只用来表达「这一天上班」（读取端按 > 0 判定），人日折算看 \`duration-format\`。
    private func scheduleLines(_ calendar: CalendarPlan, level: Int) -> [String] {
        guard !calendar.weekdays.isEmpty || !calendar.exceptions.isEmpty else { return [] }
        var lines: [String] = []
        lines.append(Self.indent(level) + "<schedule>")
        let hours = min(max(calendar.hoursPerDay, 0.5), 24)
        let startTime = 8 * 3_600.0
        let endTime = min(startTime + hours * 3_600, Self.secondsPerDay)
        for weekday in calendar.weekdays.sorted() {
            guard let name = Self.weekdayNames[weekday] else { continue }
            lines.append(Self.indent(level + 1) + "<schedule-day day-of-week=\"\(name)\">")
            lines.append(
                Self.indent(level + 2)
                    + "<time-span start-time=\"\(Self.number(startTime))\" end-time=\"\(Self.number(endTime))\"/>"
            )
            lines.append(Self.indent(level + 1) + "</schedule-day>")
        }
        let off = calendar.exceptions.filter { !$0.isWorking }
        let overtime = calendar.exceptions.filter(\.isWorking)
        lines.append(contentsOf: exceptionLayer(name: "Time Off", overtime: false, exceptions: off, level: level + 1))
        lines.append(contentsOf: exceptionLayer(name: "Overtime", overtime: true, exceptions: overtime, level: level + 1))
        lines.append(Self.indent(level) + "</schedule>")
        return lines
    }

    private func exceptionLayer(
        name: String,
        overtime: Bool,
        exceptions: [InteropCalendarException],
        level: Int
    ) -> [String] {
        guard !exceptions.isEmpty else { return [] }
        var lines: [String] = []
        lines.append(
            Self.indent(level)
                + "<calendar name=\"\(name)\" editable=\"yes\" overtime=\"\(overtime ? "yes" : "no")\">"
        )
        for exception in exceptions {
            let day = Self.dayNumber(exception.date)
            lines.append(
                Self.indent(level + 1)
                    + "<event sd=\"\(day)\" st=\"0\" ed=\"\(day)\" et=\"\(Self.number(Self.secondsPerDay))\"/>"
            )
        }
        lines.append(Self.indent(level) + "</calendar>")
        return lines
    }

    // MARK: - 任务

    private func taskLines(
        _ document: InteropDocument,
        outline: Outline,
        taskIDs: IDPlan,
        resourceIDs: IDPlan,
        drops: inout DropCollector
    ) -> [String] {
        var lines: [String] = []
        let tasks = document.tasks
        var assignmentsByTask: [String: [InteropAssignment]] = [:]
        for assignment in document.assignments {
            assignmentsByTask[assignment.taskID, default: []].append(assignment)
        }

        var emitted: Set<Int> = []
        var stack: [(index: Int, id: String)] = []

        if let rootIndex = outline.rootIndex {
            emitted.insert(rootIndex)
            lines.append(contentsOf: renderTask(
                tasks[rootIndex],
                id: outline.rootID,
                childIDs: (outline.children[rootIndex] ?? []).map { taskIDs.id(at: $0) },
                taskIDs: taskIDs,
                resourceIDs: resourceIDs,
                assignments: assignmentsByTask[tasks[rootIndex].id] ?? [],
                drops: &drops
            ))
            for child in (outline.children[rootIndex] ?? []).reversed() {
                stack.append((child, taskIDs.id(at: child)))
            }
        } else {
            lines.append(Self.indent(1) + "<task id=\"\(outline.rootID)\">")
            lines.append(Self.element("type", "group", level: 2))
            lines.append(Self.element("recalculate", "duration", level: 2))
            lines.append(Self.element("static-cost", "0", level: 2))
            for child in outline.children[-1] ?? [] {
                lines.append(Self.indent(2) + "<child-task idref=\"\(taskIDs.id(at: child))\"/>")
            }
            lines.append(Self.indent(1) + "</task>")
            for child in (outline.children[-1] ?? []).reversed() {
                stack.append((child, taskIDs.id(at: child)))
            }
        }

        while let next = stack.popLast() {
            guard !emitted.contains(next.index) else { continue }
            emitted.insert(next.index)
            lines.append(contentsOf: renderTask(
                tasks[next.index],
                id: next.id,
                childIDs: (outline.children[next.index] ?? []).map { taskIDs.id(at: $0) },
                taskIDs: taskIDs,
                resourceIDs: resourceIDs,
                assignments: assignmentsByTask[tasks[next.index].id] ?? [],
                drops: &drops
            ))
            for child in (outline.children[next.index] ?? []).reversed() {
                stack.append((child, taskIDs.id(at: child)))
            }
        }
        return lines
    }

    private func renderTask(
        _ task: InteropTask,
        id: String,
        childIDs: [String],
        taskIDs: IDPlan,
        resourceIDs: IDPlan,
        assignments: [InteropAssignment],
        drops: inout DropCollector
    ) -> [String] {
        var lines: [String] = []
        let base = 1
        let label = task.title.isEmpty ? id : task.title
        lines.append(Self.indent(base) + "<task id=\"\(id)\">")

        if !task.title.isEmpty {
            lines.append(Self.element("title", task.title, level: base + 1))
        }
        switch task.kind {
        case .group:
            lines.append(Self.element("type", "group", level: base + 1))
        case .milestone:
            lines.append(Self.element("type", "milestone", level: base + 1))
        case .task:
            break
        }

        if let effort = Self.effortSeconds(of: task) {
            lines.append(Self.element("effort", Self.number(effort), level: base + 1))
            if task.progress > 0 {
                lines.append(
                    Self.element("effort-done", Self.number(effort * min(max(task.progress, 0), 1)), level: base + 1)
                )
            }
        } else if task.progress > 0 {
            // 群组/里程碑没有 effort 字段，完成度写不进去。
            drops.progress += 1
            drops.progressSamples.append(label)
        }
        lines.append(Self.element("recalculate", "duration", level: base + 1))
        lines.append(Self.element("static-cost", "0", level: base + 1))

        if !task.notes.isEmpty {
            lines.append(contentsOf: Self.noteLines(task.notes, level: base + 1))
        }
        for childID in childIDs {
            lines.append(Self.indent(base + 1) + "<child-task idref=\"\(childID)\"/>")
        }
        for assignment in assignments {
            guard let resourceID = resourceIDs.id(for: assignment.resourceID) else {
                drops.assignment += 1
                drops.assignmentSamples.append("\(label) → \(assignment.resourceID)")
                continue
            }
            let units = assignment.units > 0 ? assignment.units : 1
            if abs(units - 1) > 0.0001 {
                lines.append(
                    Self.indent(base + 1) + "<assignment idref=\"\(resourceID)\" units=\"\(Self.number(units))\"/>"
                )
            } else {
                lines.append(Self.indent(base + 1) + "<assignment idref=\"\(resourceID)\"/>")
            }
        }
        for dependency in task.dependencies {
            guard let predecessor = taskIDs.id(for: dependency.predecessorID),
                  dependency.predecessorID != task.id else {
                drops.dependency += 1
                drops.dependencySamples.append("\(label) → \(dependency.predecessorID)")
                continue
            }
            // FS 是 OmniPlan 的缺省语义：原生写法省略 kind（11 §4）。
            var opening = "<prerequisite-task idref=\"\(predecessor)\""
            if dependency.type != .finishToStart {
                opening += " kind=\"\(dependency.type.rawValue)\""
            }
            if abs(dependency.lagSeconds) > 0.0001 {
                lines.append(Self.indent(base + 1) + opening + ">")
                lines.append(
                    Self.indent(base + 2)
                        + "<lead-time is-percentage=\"false\">\(Self.number(dependency.lagSeconds))</lead-time>"
                )
                lines.append(Self.indent(base + 1) + "</prerequisite-task>")
            } else {
                lines.append(Self.indent(base + 1) + opening + "/>")
            }
        }
        lines.append(contentsOf: Self.constraintLines(task.constraint, level: base + 1))

        if task.actualStart != nil || task.actualFinish != nil {
            drops.actual += 1
            drops.actualSamples.append(label)
        }
        if task.plannedStart != nil || task.plannedFinish != nil {
            drops.planned += 1
        }
        if task.calendarID != nil { drops.taskCalendar += 1 }
        for key in task.attributes.keys {
            if key.hasPrefix(OmniPlanWriter.zenoOnlyPrefix) {
                drops.zenoOnly += 1
                drops.zenoOnlySamples.append(key)
            } else {
                drops.attribute += 1
                drops.attributeSamples.append(key)
            }
        }

        lines.append(Self.indent(base) + "</task>")
        return lines
    }

    /// Zeno 独有信息在 IR 里的前缀（与 MSPDI 写出端同一约定）。
    static let zenoOnlyPrefix = "zeno."

    private static func constraintLines(_ constraint: InteropConstraint?, level: Int) -> [String] {
        switch constraint {
        case .startNoEarlierThan(let date):
            return [element("start-no-earlier-than", dateText(date), level: level)]
        case .startNoLaterThan(let date):
            return [element("start-no-later-than", dateText(date), level: level)]
        case .endNoEarlierThan(let date):
            return [element("end-no-earlier-than", dateText(date), level: level)]
        case .endNoLaterThan(let date):
            return [element("end-no-later-than", dateText(date), level: level)]
        case .asLateAsPossible:
            return [element("schedule-type", "alap", level: level)]
        case .asSoonAsPossible, .none:
            // ASAP 就是 OmniPlan 的缺省行为，不写元素。
            return []
        }
    }

    // MARK: - 有损登记

    /// 逐任务收集的丢弃项（渲染过程中累加，最后一次写进 ledger）。
    private struct DropCollector {
        var assignment = 0
        var assignmentSamples: [String] = []
        var dependency = 0
        var dependencySamples: [String] = []
        var progress = 0
        var progressSamples: [String] = []
        var actual = 0
        var actualSamples: [String] = []
        var planned = 0
        var zenoOnly = 0
        var zenoOnlySamples: [String] = []
        var attribute = 0
        var attributeSamples: [String] = []
        var taskCalendar = 0
        var resourceUnits = 0
        var resourceUnitSamples: [String] = []
        var resourceCalendar = 0
        var costKind = 0

        func flush(into ledger: inout FidelityLedger) {
            ledger.record(
                field: "assignment",
                kind: .dropped,
                count: assignment,
                detail: "分配指向的资源不在文档里：无法落到 OmniPlan 的 assignment，丢弃。",
                samples: assignmentSamples
            )
            ledger.record(
                field: "dependency",
                kind: .dropped,
                count: dependency,
                detail: "前置任务不在文档里（或指向自己）：无法写成 prerequisite-task，丢弃。",
                samples: dependencySamples
            )
            ledger.record(
                field: "task.progress",
                kind: .dropped,
                count: progress,
                detail: "群组与里程碑没有 effort，完成度写不进 OmniPlan：这些任务的完成度丢弃。",
                samples: progressSamples
            )
            ledger.record(
                field: "task.actual",
                kind: .dropped,
                count: actual,
                detail: "OmniPlan 的实际起止由完成度与排期推算，容器里的任务字段没有对应项：实际起止日期丢弃（完成度照写）。",
                samples: actualSamples
            )
            ledger.record(
                field: "task.plannedDates",
                kind: .dropped,
                count: planned,
                detail: "OmniPlan 按 effort + 相关性重新排期，不接受外部计划日期：计划起止丢弃（约束日期照写）。"
            )
            ledger.record(
                field: "task.zenoOnly",
                kind: .dropped,
                count: zenoOnly,
                detail: "Zeno 独有状态（blocked / cancelled 与取消原因）不写进对方字段，避免污染对方的备注与自定义域："
                    + "它们只出现在导出旁注里。",
                samples: zenoOnlySamples
            )
            ledger.record(
                field: "task.attribute",
                kind: .dropped,
                count: attribute,
                detail: "任务自定义域到 OmniPlan user-data 的映射未验证：这些属性丢弃。",
                samples: attributeSamples
            )
            ledger.record(
                field: "task.calendar",
                kind: .dropped,
                count: taskCalendar,
                detail: "这部分不写任务级日历（容器只带一个项目日历）：任务级日历引用丢弃。"
            )
            ledger.record(
                field: "resource.units",
                kind: .dropped,
                count: resourceUnits,
                detail: "OmniPlan 的资源没有「可用单位」原子字段：资源级单位丢弃，任务上的投入单位（assignment units）照写。",
                samples: resourceUnitSamples
            )
            ledger.record(
                field: "resource.calendar",
                kind: .dropped,
                count: resourceCalendar,
                detail: "写出只支持一个项目日历（挂在项目资源上）：资源级日历引用丢弃。"
            )
            ledger.record(
                field: "resource.kind",
                kind: .degraded,
                count: costKind,
                detail: "IR 的成本类资源在 OmniPlan 没有对应类型：写成 Material，回导会变成素材资源。"
            )
        }
    }

    private func recordRenumbering(
        _ plan: IDPlan,
        field: String,
        noun: String,
        ledger: inout FidelityLedger
    ) {
        guard !plan.renumberedIDs.isEmpty else { return }
        ledger.record(
            field: field,
            kind: .derived,
            count: plan.renumberedIDs.count,
            detail: "\(noun) id 不是 OmniPlan 可复用的局部 id（或与已用 id 冲突）：按出现顺序重新编号成 t/r 序号，"
                + "回导后 id 与来源不再对应。",
            samples: plan.renumberedIDs
        )
    }

    // MARK: - 文档外壳

    private func renderTOC(nextTaskID: Int, nextResourceID: Int, hoursPerDay: Double) -> String {
        let hours = hoursPerDay > 0 ? hoursPerDay : Self.defaultHoursPerDay
        let format = "<duration-format hours-per-day=\"\(Self.number(hours))\""
            + " hours-per-week=\"\(Self.number(hours * 5))\""
            + " hours-per-month=\"\(Self.number(hours * 20))\""
            + " hours-per-year=\"\(Self.number(hours * 240))\""
            + " hours=\"true\" days=\"true\" weeks=\"true\"/>"
        var lines: [String] = []
        lines.append(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        lines.append("<omniplan xmlns=\"\(OmniPlanReader.namespace)\" file-format-version=\"3\">")
        lines.append(Self.indent(1) + "<project>")
        lines.append(Self.element("next-task-id", String(nextTaskID), level: 2))
        lines.append(Self.element("next-resource-id", String(nextResourceID), level: 2))
        lines.append(
            Self.indent(2)
                + "<scenario id=\"\(Self.scenarioID)\" name=\"Actual\""
                + " filename=\"\(OmniPlanReader.defaultScenarioMember)\"/>"
        )
        lines.append(Self.indent(2) + format)
        lines.append(Self.indent(1) + "</project>")
        lines.append("</omniplan>")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - 取值与格式化

    /// 任务写出的 effort（秒）：IR 的工期本身就是秒；缺工期时退回投入小时。
    private static func effortSeconds(of task: InteropTask) -> Double? {
        guard task.kind == .task else { return nil }
        if let seconds = task.durationSeconds, seconds.isFinite, seconds >= 0 {
            return seconds
        }
        if let hours = task.effortHours, hours.isFinite, hours >= 0 {
            return hours * 3_600
        }
        return nil
    }

    private static func resourceType(_ resource: InteropResource, isProject: Bool) -> String {
        if isProject && resource.kind == .unknown { return "Project" }
        switch resource.kind {
        case .person: return "Staff"
        case .material: return "Equipment"
        case .cost: return "Material"
        case .unknown: return "Group"
        }
    }

    /// \`next-task-id\` / \`next-resource-id\`：已用编号的最大值 + 1（不低于 10，与样本一致）。
    private static func nextCounter(prefix: Character, ids: [String]) -> Int {
        var next = 10
        for id in ids {
            guard id.first == prefix else { continue }
            let digits = id.dropFirst()
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let value = Int(digits) else { continue }
            next = max(next, value + 1)
        }
        return next
    }

    private static func label(of task: InteropTask) -> String {
        task.title.isEmpty ? task.id : task.title
    }

    private static func dayNumber(_ date: Date) -> Int {
        Int(((date.timeIntervalSince1970 - epoch2001.timeIntervalSince1970) / secondsPerDay).rounded())
    }

    private static func dateText(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private static func number(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int(value))
        }
        var text = String(format: "%.3f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    private static func indent(_ level: Int) -> String {
        String(repeating: "  ", count: level)
    }

    private static func element(_ name: String, _ text: String, level: Int) -> String {
        indent(level) + "<\(name)>\(escape(text))</\(name)>"
    }

    private static func noteLines(_ text: String, level: Int) -> [String] {
        [
            indent(level) + "<note>",
            indent(level + 1) + "<text>",
            indent(level + 2) + "<p>",
            indent(level + 3) + "<run>",
            indent(level + 4) + "<lit>\(escape(text))</lit>",
            indent(level + 3) + "</run>",
            indent(level + 2) + "</p>",
            indent(level + 1) + "</text>",
            indent(level) + "</note>"
        ]
    }

    private static func escape(_ text: String) -> String {
        var escaped = text.replacingOccurrences(of: "&", with: "&amp;")
        escaped = escaped.replacingOccurrences(of: "<", with: "&lt;")
        escaped = escaped.replacingOccurrences(of: ">", with: "&gt;")
        escaped = escaped.replacingOccurrences(of: "\"", with: "&quot;")
        return escaped
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}

// MARK: - id 复用

/// IR 的字符串 id → OmniPlan 的局部 id。
///
/// 规则与 MSPDI 的 \`UIDPlan\` 同构、但更保守：只复用「像局部 id」的字符串
/// （字母开头、仅字母数字与 \`-_\`），其余（如 UUID）按出现顺序重新编号，保证同一输入
/// 得到同一份产物；被改号的 id 交给调用方登记。
struct IDPlan {
    private let ids: [String]
    private let byID: [String: String]
    /// 被重新编号的来源 id（按出现顺序，供登记样例）。
    let renumberedIDs: [String]

    init(ids: [String], prefix: String) {
        var used: Set<String> = []
        var assigned = [String?](repeating: nil, count: ids.count)
        var map: [String: String] = [:]
        for (index, id) in ids.enumerated() {
            guard Self.isReusable(id), !used.contains(id) else { continue }
            used.insert(id)
            assigned[index] = id
            if map[id] == nil { map[id] = id }
        }
        var next = 1
        var renumbered: [String] = []
        for index in ids.indices where assigned[index] == nil {
            var candidate = "\(prefix)\(next)"
            while used.contains(candidate) {
                next += 1
                candidate = "\(prefix)\(next)"
            }
            used.insert(candidate)
            assigned[index] = candidate
            next += 1
            renumbered.append(ids[index])
            if map[ids[index]] == nil { map[ids[index]] = candidate }
        }
        self.ids = assigned.map { $0 ?? "" }
        self.byID = map
        self.renumberedIDs = renumbered
    }

    /// 第 index 个对象写出的 id。
    func id(at index: Int) -> String { ids[index] }

    /// 来源 id 对应的写出 id；未知 id 返回 nil。
    func id(for source: String) -> String? { byID[source] }

    /// 已分配的写出 id（保持出现顺序）。
    var allIDs: [String] { ids }

    /// 只复用以字母开头、仅含字母数字与 \`-_\` 的 id：这类 id 在 OmniPlan 样本里就是全部形态
    /// （\`t-1\` / \`t369\` / \`r6\`），UUID 之类一律改号。
    static func isReusable(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first, first.properties.isAlphabetic else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "-" || scalar == "_"
        }
    }
}
