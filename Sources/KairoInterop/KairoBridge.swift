import Foundation
import KairoCore

/// IR ↔ Kairo 模型桥接（14 §2 硬规则 2）。
///
/// **一切语义换算只在这里**：工作日 ↔ 日历天、工期秒 → 工作日数、前导秒 → 前导天、
/// Summary → 群组、硬约束 → 软时限。适配器不许自己算，否则每加一个格式就多一份口径。
///
/// 本版本只实现 **导入方向**（IR → Kairo）；导出方向随 MSPDI 写（P1）落地，
/// 届时同样在本类型内补齐，避免两处换算漂移。
///
/// 产出两样东西：
/// - `project`：可直接交给 `KairoSession` / `.kairo` 存储的 Kairo 项目；
/// - `ledger`：**IR 侧 + Kairo 侧合并**后的有损登记，预检报告直接渲染它。
public struct KairoBridge: Sendable {
    /// 桥接结果。
    public struct Result {
        public var project: Project
        /// 合并后的有损登记（来源读到 IR 时的损失 + IR 落到 Kairo 时的损失）。
        public var ledger: FidelityLedger
        /// 本次桥接**追加**的登记（只含 IR → Kairo 阶段，不含 IR 侧已有的条目）。
        ///
        /// 预检报告要按「适配器层 / 桥接层」分别交代来源时用这一份；
        /// `ledger` 始终是它与 `document.ledger` 的合并，渲染清单只认 `ledger`。
        public var bridgeLedger: FidelityLedger

        public init(project: Project, ledger: FidelityLedger, bridgeLedger: FidelityLedger = FidelityLedger()) {
            self.project = project
            self.ledger = ledger
            self.bridgeLedger = bridgeLedger
        }
    }

    public init() {}

    /// 把 IR 文档落成 Kairo 项目。
    ///
    /// 幂等性与身份：每次调用都会生成新的任务 UUID（来源 id 无法在 Kairo 中保留，
    /// 见 `taskUID` 登记）；重复导入同一文件会得到两份互不相干的任务。
    public func makeProject(from document: InteropDocument) -> Result {
        // 桥接层只往这一份里记：最后再与 IR 侧登记合并，报告才能区分「谁丢的」。
        var bridgeLedger = FidelityLedger()

        // 1. 日历：先把每个来源日历换算成 Kairo 的工作日历（唯一换算点）。
        let calendarsByID = makeCalendars(document.calendars)
        let projectCalendar = calendarsByID[document.metadata.defaultCalendarID ?? ""]
            ?? document.calendars.first.flatMap { calendarsByID[$0.id] }
        let defaultHoursPerDay = projectCalendar?.effectiveHoursPerDay ?? 8

        // 2. 大纲：任务身份与父子关系。
        let taskIDs = makeTaskIDs(document.tasks)
        let parents = deriveParents(document.tasks)

        // 3. 资源与分配。
        let resources = makeResources(document.resources)
        let resourceIDs = Dictionary(uniqueKeysWithValues: resources.map { ($0.sourceID, $0.entry.id) })
        var assignmentsByTask: [String: [TaskAssignment]] = [:]
        var droppedAssignments = 0
        var droppedAssignmentSample: String?
        for assignment in document.assignments {
            guard taskIDs[assignment.taskID] != nil,
                  let resourceID = resourceIDs[assignment.resourceID] else {
                droppedAssignments += 1
                if droppedAssignmentSample == nil {
                    droppedAssignmentSample = "TaskUID \(assignment.taskID) → ResourceUID \(assignment.resourceID)"
                }
                continue
            }
            let units = assignment.units > 0 ? assignment.units : 1
            assignmentsByTask[assignment.taskID, default: []].append(
                TaskAssignment(resourceID: resourceID, units: units)
            )
        }

        // 4. 任务。
        var tasks: [TaskItem] = []
        var degradedConstraints = 0
        var constraintSamples: [String] = []
        var unnamedTasks = 0
        var customValueCount = 0

        for interop in document.tasks {
            guard let id = taskIDs[interop.id] else { continue }
            if interop.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                unnamedTasks += 1
            }
            customValueCount += interop.attributes.count

            let hoursPerDay = hoursPerDay(for: interop, calendarsByID: calendarsByID, fallback: defaultHoursPerDay)
            let constraint = mapConstraint(interop.constraint)
            if let raw = interop.constraint, raw.date != nil {
                degradedConstraints += 1
                if constraintSamples.count < FidelityLedger.maxSamples {
                    constraintSamples.append(describe(raw))
                }
            }

            let task = TaskItem(
                id: id,
                title: interop.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "未命名任务（\(interop.id)）"
                    : interop.title,
                notes: interop.notes,
                priority: .normal,
                status: deriveStatus(
                    progress: interop.progress,
                    actualStart: interop.actualStart,
                    actualFinish: interop.actualFinish
                ),
                kind: mapKind(interop.kind),
                parentID: parents[interop.id].flatMap { taskIDs[$0] },
                effortHours: interop.effortHours,
                durationDays: durationDays(for: interop, hoursPerDay: hoursPerDay),
                dependencies: makeDependencies(
                    interop.dependencies,
                    taskIDs: taskIDs,
                    hoursPerDay: hoursPerDay,
                    ledger: &bridgeLedger
                ),
                progress: interop.progress,
                constraint: constraint,
                schedulingPolicy: mapPolicy(interop.constraint),
                // 手目标记（MS Project Manual="1" / 互操作 IR）→ 手动排期。
                schedulingMode: interop.isManuallyScheduled ? .manual : .auto,
                completedAt: interop.actualFinish,
                assignments: assignmentsByTask[interop.id] ?? [],
                actualStart: interop.actualStart
            )
            tasks.append(task)
        }

        // 5. 基线。
        let milestoneIDs = Set(document.tasks.filter { $0.kind == .milestone }.map(\.id))
        let baselines = makeBaselines(
            document.baselines,
            taskIDs: taskIDs,
            milestoneIDs: milestoneIDs,
            ledger: &bridgeLedger
        )

        // 6. 项目元数据。
        let createdAt = document.metadata.createdAt ?? document.metadata.lastSavedAt ?? Date()
        let metadata = ProjectMetadata(
            title: document.metadata.title.isEmpty ? "未命名项目" : document.metadata.title,
            createdAt: createdAt,
            updatedAt: document.metadata.lastSavedAt ?? createdAt,
            projectStart: document.metadata.plannedStart,
            projectEnd: document.metadata.plannedFinish,
            direction: document.metadata.direction == .forward ? .forward : .backward,
            calendar: projectCalendar
        )

        let project = Project(metadata: metadata)
        project.tasks = tasks
        project.resources = resources.map(\.entry)
        project.baselines = baselines

        recordCalendarConversions(document: document, calendarsByID: calendarsByID, ledger: &bridgeLedger)
        if degradedConstraints > 0 {
            bridgeLedger.record(
                field: "constraint",
                kind: .degraded,
                count: degradedConstraints,
                detail: "来源的硬约束（开始/结束不早于、不晚于）降级为 Kairo 软时限：导入后只产生违例，不再自动改期。",
                samples: constraintSamples
            )
        }
        if !document.customFields.isEmpty {
            let samples = document.customFields.map { field in
                field.alias.map { "\(field.fieldName)=\($0)" } ?? field.fieldName
            }
            bridgeLedger.record(
                field: "customField",
                kind: .dropped,
                count: document.customFields.count,
                detail: "Kairo 没有自定义域（本计划 \(customValueCount) 个值）：自定义域定义与值随导入丢弃，需要请回源文件核对。",
                samples: samples
            )
        }
        if !document.tasks.isEmpty {
            bridgeLedger.record(
                field: "taskID",
                kind: .dropped,
                count: document.tasks.count,
                detail: "来源的任务 id 无法在 Kairo 中保留：任务身份改用新 UUID，回写源格式需要旁路映射表。",
                sample: document.tasks.first?.id
            )
        }
        if droppedAssignments > 0 {
            bridgeLedger.record(
                field: "assignment",
                kind: .dropped,
                count: droppedAssignments,
                detail: "分配到未分配资源（资源 id 在来源中不存在或为占位）的记录无法落地：Kairo 的分配必须指向真实资源。",
                sample: droppedAssignmentSample
            )
        }
        if unnamedTasks > 0 {
            bridgeLedger.record(
                field: "task.title",
                kind: .derived,
                count: unnamedTasks,
                detail: "来源任务没有标题，已用「未命名任务（id）」占位，便于回源核对。"
            )
        }
        if resources.contains(where: { $0.wasUnnamed }) {
            bridgeLedger.record(
                field: "resource.name",
                kind: .derived,
                count: resources.filter { $0.wasUnnamed }.count,
                detail: "来源资源没有名称，已用「未命名资源」占位。"
            )
        }
        if resources.contains(where: { $0.wasCost }) {
            bridgeLedger.record(
                field: "resource.kind",
                kind: .degraded,
                count: resources.filter { $0.wasCost }.count,
                detail: "成本类资源在 Kairo 没有对应种类，已降级为素材资源；费率与成本信息全部丢弃。"
            )
        }

        return Result(project: project, ledger: document.ledger.merging(bridgeLedger), bridgeLedger: bridgeLedger)
    }

    // MARK: - 日历换算

    /// 来源日历 → Kairo 工作日历。
    private func makeCalendars(_ calendars: [InteropCalendar]) -> [String: WorkCalendar] {
        var result: [String: WorkCalendar] = [:]
        for calendar in calendars {
            let weekdays = calendar.workingWeekdays.filter { (1...7).contains($0) }
            result[calendar.id] = WorkCalendar(
                workingWeekdays: weekdays.isEmpty ? WorkCalendar.allWeekdays : weekdays,
                exceptions: calendar.exceptions.map {
                    CalendarException(date: $0.date, isWorking: $0.isWorking, note: $0.note)
                },
                hoursPerDay: calendar.hoursPerDay > 0 ? calendar.hoursPerDay : 8
            )
        }
        return result
    }

    /// 任务换算工期时使用的小时基准：任务自己的日历优先，其次项目默认。
    private func hoursPerDay(
        for task: InteropTask,
        calendarsByID: [String: WorkCalendar],
        fallback: Double
    ) -> Double {
        guard let id = task.calendarID, let calendar = calendarsByID[id] else { return fallback }
        return calendar.effectiveHoursPerDay
    }

    /// 来源工时 → Kairo 工作日数（含小数）；「工作日 ↔ 日历天」的换算只此一处。
    private func durationDays(for task: InteropTask, hoursPerDay: Double) -> Double? {
        if task.kind == .milestone { return 0 }
        if task.kind == .group { return nil }
        guard let seconds = task.durationSeconds else { return nil }
        return seconds / (max(hoursPerDay, 0.5) * 3600)
    }

    /// 把每个来源日历「与 Kairo 默认口径不同」这件事登记成换算项。
    private func recordCalendarConversions(
        document: InteropDocument,
        calendarsByID: [String: WorkCalendar],
        ledger: inout FidelityLedger
    ) {
        guard !document.calendars.isEmpty else { return }
        for calendar in document.calendars {
            let weekdays = calendar.workingWeekdays.filter { (1...7).contains($0) }
            let isKairoDefault = weekdays.count == 7 && calendar.exceptions.isEmpty
            guard !weekdays.isEmpty, !isKairoDefault, calendarsByID[calendar.id] != nil else { continue }
            let affected = document.tasks.filter { task in
                calendar.id == document.metadata.defaultCalendarID || task.calendarID == calendar.id
            }.count
            // 没有任何任务使用的日历不产生实际影响，不占报告的篇幅。
            guard affected > 0 else { continue }
            ledger.record(
                field: "calendar.workingWeekdays",
                kind: .converted,
                count: affected,
                detail: "按来源工作日历换算工期与前导时间：Kairo 侧建立等价 WorkCalendar（\(describeHours(calendar))），"
                    + "工作日与来源一致，不再每周错位；例外日 \(calendar.exceptions.count) 条一并带入。",
                sample: describeWorkingWeek(calendar)
            )
        }
    }

    /// 「周一至周五」这样的工作周描述。
    private func describeWorkingWeek(_ calendar: InteropCalendar) -> String {
        let names = [1: "周日", 2: "周一", 3: "周二", 4: "周三", 5: "周四", 6: "周五", 7: "周六"]
        let working = calendar.workingWeekdays.filter { (1...7).contains($0) }.sorted()
        guard !working.isEmpty else { return "未声明工作周（按全周 7 天）" }
        // 连续区间压缩：2,3,4,5,6 → 「周一至周五」。
        var parts: [String] = []
        var start = working[0]
        var previous = working[0]
        for day in working.dropFirst() {
            if day == previous + 1 {
                previous = day
                continue
            }
            parts.append(rangeText(start, previous, names: names))
            start = day
            previous = day
        }
        parts.append(rangeText(start, previous, names: names))
        return parts.joined(separator: "、")
    }

    private func rangeText(_ start: Int, _ end: Int, names: [Int: String]) -> String {
        let startName = names[start] ?? String(start)
        guard start != end else { return startName }
        return "\(startName)至\(names[end] ?? String(end))"
    }

    private func describeHours(_ calendar: InteropCalendar) -> String {
        let hours = calendar.hoursPerDay > 0 ? calendar.hoursPerDay : 8
        return "\(hours)h/日"
    }

    private func describe(_ constraint: InteropConstraint) -> String {
        let date = constraint.date.map { Self.sampleFormatter.string(from: $0) } ?? "—"
        switch constraint {
        case .startNoEarlierThan: return "开始不早于 \(date)"
        case .startNoLaterThan: return "开始不晚于 \(date)"
        case .endNoEarlierThan: return "结束不早于 \(date)"
        case .endNoLaterThan: return "结束不晚于 \(date)"
        case .asSoonAsPossible: return "尽早开始"
        case .asLateAsPossible: return "尽晚开始"
        }
    }

    /// 样例里的日期格式（只用于人读的登记文本）。
    private static let sampleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: - 结构与映射

    private func makeTaskIDs(_ tasks: [InteropTask]) -> [String: UUID] {
        var ids: [String: UUID] = [:]
        for task in tasks where ids[task.id] == nil {
            ids[task.id] = UUID()
        }
        return ids
    }

    /// 由 `outlineLevel` 推导父节点：来源已给 `parentID` 且确实存在时以来源为准。
    ///
    /// 用大纲层级推导而不是只信 `parentID`：`.oplx` 的父子关系藏在大纲里，
    /// 靠层级推导是所有格式都能走通的最小共同面。
    private func deriveParents(_ tasks: [InteropTask]) -> [String: String] {
        let known = Set(tasks.map(\.id))
        var parents: [String: String] = [:]
        var stack: [(level: Int, id: String)] = []
        for task in tasks {
            while let last = stack.last, last.level >= task.outlineLevel {
                stack.removeLast()
            }
            if let declared = task.parentID, known.contains(declared) {
                parents[task.id] = declared
            } else if let parent = stack.last {
                parents[task.id] = parent.id
            }
            stack.append((task.outlineLevel, task.id))
        }
        return parents
    }

    private func makeDependencies(
        _ dependencies: [InteropDependency],
        taskIDs: [String: UUID],
        hoursPerDay: Double,
        ledger: inout FidelityLedger
    ) -> [TaskDependency] {
        var result: [TaskDependency] = []
        var missing = 0
        var missingSample: String?
        for dependency in dependencies {
            guard let predecessorID = taskIDs[dependency.predecessorID] else {
                missing += 1
                if missingSample == nil { missingSample = dependency.predecessorID }
                continue
            }
            result.append(
                TaskDependency(
                    predecessorID: predecessorID,
                    type: mapDependencyType(dependency.type),
                    lagDays: dependency.lagSeconds / (max(hoursPerDay, 0.5) * 3600)
                )
            )
        }
        if missing > 0 {
            ledger.record(
                field: "dependency",
                kind: .dropped,
                count: missing,
                detail: "前驱任务不存在的相关性会被忽略（来源里常见于已删除或跨项目任务）。",
                sample: missingSample
            )
        }
        return result
    }

    private func mapKind(_ kind: InteropTaskKind) -> TaskKind {
        switch kind {
        case .task: return .task
        case .group: return .group
        case .milestone: return .milestone
        }
    }

    private func mapDependencyType(_ type: InteropDependencyType) -> TaskDependency.DependencyType {
        switch type {
        case .finishToStart: return .fs
        case .finishToFinish: return .ff
        case .startToStart: return .ss
        case .startToFinish: return .sf
        }
    }

    private func mapConstraint(_ constraint: InteropConstraint?) -> SchedulingConstraint? {
        switch constraint {
        case .startNoEarlierThan(let date): return .startNoEarlierThan(date)
        case .startNoLaterThan(let date): return .startNoLaterThan(date)
        case .endNoEarlierThan(let date): return .endNoEarlierThan(date)
        case .endNoLaterThan(let date): return .endNoLaterThan(date)
        case .asSoonAsPossible, .asLateAsPossible, nil: return nil
        }
    }

    private func mapPolicy(_ constraint: InteropConstraint?) -> SchedulingPolicy {
        if case .asLateAsPossible = constraint { return .alap }
        return .asap
    }

    /// 状态是派生量：来源只有完成度与实际日期，没有 Kairo 的五态。
    private func deriveStatus(progress: Double, actualStart: Date?, actualFinish: Date?) -> TaskStatus {
        if actualFinish != nil || progress >= 1 { return .done }
        if actualStart != nil || progress > 0 { return .inProgress }
        return .pending
    }

    // MARK: - 资源与基线

    private struct BridgeResource {
        var sourceID: String
        var entry: Resource
        var wasUnnamed: Bool
        var wasCost: Bool
    }

    private func makeResources(_ resources: [InteropResource]) -> [BridgeResource] {
        resources.map { resource in
            let unnamed = resource.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let kind: ResourceKind
            var wasCost = false
            switch resource.kind {
            case .person, .unknown: kind = .person
            case .material: kind = .material
            case .cost:
                kind = .material
                wasCost = true
            }
            return BridgeResource(
                sourceID: resource.id,
                entry: Resource(
                    id: UUID(),
                    name: unnamed ? "未命名资源" : resource.name,
                    kind: kind,
                    units: resource.units > 0 ? resource.units : 1
                ),
                wasUnnamed: unnamed,
                wasCost: wasCost
            )
        }
    }

    private func makeBaselines(
        _ baselines: [InteropBaseline],
        taskIDs: [String: UUID],
        milestoneIDs: Set<String>,
        ledger: inout FidelityLedger
    ) -> [Baseline] {
        guard !baselines.isEmpty else { return [] }
        var result: [Baseline] = []
        var droppedEntries = 0
        var progressDerived = 0
        var createdAtDerived = 0
        for (index, baseline) in baselines.enumerated() {
            if baseline.createdAt == nil { createdAtDerived += 1 }
            var entries: [BaselineEntry] = []
            for entry in baseline.entries {
                guard let taskID = taskIDs[entry.taskID] else {
                    droppedEntries += 1
                    continue
                }
                if entry.progress == nil { progressDerived += 1 }
                entries.append(
                    BaselineEntry(
                        taskID: taskID,
                        start: entry.start,
                        finish: entry.finish,
                        progress: entry.progress ?? 0,
                        isMilestone: milestoneIDs.contains(entry.taskID)
                    )
                )
            }
            result.append(
                Baseline(
                    id: UUID(),
                    name: baseline.name ?? "基线 \(index + 1)",
                    createdAt: baseline.createdAt ?? Date(timeIntervalSince1970: 0),
                    entries: entries
                )
            )
        }
        if droppedEntries > 0 {
            ledger.record(
                field: "baseline.entry",
                kind: .dropped,
                count: droppedEntries,
                detail: "基线条目指向的任务已不在计划中（来源里的孤儿条目），无法落到 Kairo 的任务身份上。"
            )
        }
        if progressDerived > 0 {
            ledger.record(
                field: "baseline.progress",
                kind: .derived,
                count: progressDerived,
                detail: "来源基线只有起止时间、没有快照完成度，Kairo 的基线条目按 0 补全（偏差对比里进度一列不可信）。"
            )
        }
        if createdAtDerived > 0 {
            ledger.record(
                field: "baseline.createdAt",
                kind: .derived,
                count: createdAtDerived,
                detail: "来源基线没有快照时刻，Kairo 侧按 1970-01-01 占位；基线名与顺序保留。"
            )
        }
        return result
    }
}
