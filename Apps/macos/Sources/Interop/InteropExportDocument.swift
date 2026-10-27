import Foundation
import KairoCore
import KairoInterop

/// Kairo → IR（导出方向）。
///
/// 与 `KairoBridge`（IR → Kairo）成镜像：那边把「来源工作日」折成 Kairo 的工作日数，这边把
/// Kairo 的工作日数折回来源的秒；两处都只读项目日历的 `hoursPerDay`，不做别的换算口径。
///
/// 只做「模型 → IR」，不写字节：写盘与格式细节属于适配器，旁注渲染属于 `InteropExportNotes`。
enum InteropExportDocument {
    /// 导出时项目日历的 IR id（MSPDI 侧会被重新编号成整数 UID）。
    static let calendarID = "kairo-calendar"

    /// Kairo 独有信息在 IR 里的承载约定。
    ///
    /// 契约由 `MSPDIWriter` 一侧定义（带 `kairo.` 前缀的任务属性会被剥离并登记），
    /// 这里只重复前缀与两个键名——IR 不表达五态状态，导出方向只能靠这条约定把它带出来。
    enum KairoOnlyKey {
        static let prefix = "kairo."
        static let status = "kairo.status"
        static let cancelReason = "kairo.cancelReason"
    }

    /// 把项目落成 IR。
    ///
    /// - Parameters:
    ///   - project: 待导出的项目值快照（不是活模型：导出期间用户仍可编辑）。
    ///   - scheduled: 当前排期结果，按任务 id 索引；nil = 排期算不出来（依赖环、会话未打开）。
    ///     缺失的任务按「无计划日期」导出——宁可少写日期，也不在这里现算一份排期，
    ///     免得导出与界面显示两个日期。
    /// - Returns: IR 文档；Kairo 独有信息的丢失已预置在 `document.ledger` 里。
    static func make(from project: Project, scheduled: [UUID: ScheduledTask]?) -> InteropDocument {
        let calendar = project.calendar ?? WorkCalendar()
        let hoursPerDay = calendar.effectiveHoursPerDay
        let tasksByID = Dictionary(project.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var ledger = FidelityLedger()
        var interopTasks: [InteropTask] = []
        var implicitDependencyCount = 0
        var implicitSamples: [String] = []
        var priorityCount = 0
        var tagCount = 0
        var assigneeCount = 0
        var dueDateCount = 0
        var dueDateSamples: [String] = []

        for (index, task) in project.tasks.enumerated() {
            let implicit = implicitDependencies(of: task, byID: tasksByID)
            implicitDependencyCount += implicit.count
            if implicitSamples.count < FidelityLedger.maxSamples, !implicit.isEmpty {
                implicitSamples.append(task.title)
            }
            if task.priority != .normal { priorityCount += 1 }
            if !task.tags.isEmpty { tagCount += 1 }
            if let assignee = task.assignee, !assignee.isEmpty { assigneeCount += 1 }
            if task.dueDate != nil {
                dueDateCount += 1
                if dueDateSamples.count < FidelityLedger.maxSamples {
                    dueDateSamples.append(task.title)
                }
            }

            let planned = scheduled?[task.id]
            interopTasks.append(
                InteropTask(
                    id: task.id.uuidString,
                    title: task.title,
                    notes: task.notes,
                    kind: interopKind(task.kind),
                    outlineLevel: outlineLevel(of: task, byID: tasksByID),
                    parentID: task.parentID?.uuidString,
                    sequence: index + 1,
                    plannedStart: planned?.scheduledStart,
                    plannedFinish: planned?.scheduledFinish,
                    durationSeconds: durationSeconds(for: task, hoursPerDay: hoursPerDay),
                    effortHours: task.effortHours,
                    progress: task.progress,
                    actualStart: task.actualStart,
                    actualFinish: task.completedAt,
                    dependencies: interopDependencies(of: task, implicit: implicit, hoursPerDay: hoursPerDay),
                    constraint: interopConstraint(task.constraint, policy: task.schedulingPolicy),
                    calendarID: nil,
                    attributes: kairoAttributes(of: task)
                )
            )
        }

        ledger.record(
            field: "dependency.effective",
            kind: .degraded,
            count: implicitDependencyCount,
            detail: I18n.t(
                "interop.export.detail.implicit_dependency",
                "Kairo pushes group dependencies down to every leaf in the subtree (effectiveDependencies). "
                    + "They are written as explicit links so the other tool schedules the same way, "
                    + "but those links no longer belong to a group: re-importing them turns them into the task's own dependencies."
            ),
            samples: implicitSamples
        )
        ledger.record(
            field: "task.priority",
            kind: .dropped,
            count: priorityCount,
            detail: I18n.t(
                "interop.export.detail.priority",
                "Kairo's four priority levels have no counterpart in the MSPDI writer: priority is dropped and the other tool shows its default."
            )
        )
        ledger.record(
            field: "task.tags",
            kind: .dropped,
            count: tagCount,
            detail: I18n.t(
                "interop.export.detail.tags",
                "Task tags are a Kairo-local classification and MSPDI has no field for them: tags are dropped."
            )
        )
        ledger.record(
            field: "task.assignee",
            kind: .dropped,
            count: assigneeCount,
            detail: I18n.t(
                "interop.export.detail.assignee",
                "Kairo's assignee is free text and does not point at the resource table, while MSPDI only has resource assignments. "
                    + "The assignee is dropped: use assignments, not the assignee, when the other side needs working hours."
            )
        )
        ledger.record(
            field: "task.plannedDates",
            kind: .dropped,
            count: scheduled == nil ? project.tasks.count : 0,
            detail: I18n.t(
                "interop.export.detail.planned_dates",
                "The schedule could not be computed (dependency cycle or no open session): planned dates were not written, "
                    + "so the other tool has to derive them from durations and links."
            )
        )
        ledger.record(
            field: "task.dueDate",
            kind: .dropped,
            count: dueDateCount,
            detail: I18n.t(
                "interop.export.detail.due_date",
                "Kairo's due date only drives overdue display and never touches scheduling, while MSPDI's Deadline does. "
                    + "Writing it across would look successful while changing what it means, so it is dropped."
            ),
            samples: dueDateSamples
        )

        return InteropDocument(
            metadata: InteropMetadata(
                title: project.metadata.title,
                createdAt: project.metadata.createdAt,
                lastSavedAt: project.metadata.updatedAt,
                plannedStart: project.metadata.projectStart,
                plannedFinish: project.metadata.projectEnd,
                defaultCalendarID: calendarID,
                direction: project.metadata.direction == .forward ? .forward : .backward
            ),
            tasks: interopTasks,
            resources: project.resources.map { resource in
                InteropResource(
                    id: resource.id.uuidString,
                    name: resource.name,
                    kind: resource.kind == .material ? .material : .person,
                    units: resource.units
                )
            },
            calendars: [interopCalendar(calendar)],
            assignments: project.tasks.flatMap { task in
                task.assignments.map { assignment in
                    InteropAssignment(
                        taskID: task.id.uuidString,
                        resourceID: assignment.resourceID.uuidString,
                        units: assignment.units
                    )
                }
            },
            baselines: project.baselines.enumerated().map { index, baseline in
                InteropBaseline(
                    // 槽位号写成下标：MSPDI 只有 0…10 共 11 个槽位，超出部分由写出端登记。
                    id: String(index),
                    name: baseline.name,
                    createdAt: baseline.createdAt,
                    entries: baseline.entries.map { entry in
                        InteropBaselineEntry(
                            taskID: entry.taskID.uuidString,
                            start: entry.start,
                            finish: entry.finish,
                            progress: entry.progress
                        )
                    }
                )
            },
            ledger: ledger
        )
    }

    // MARK: - 单项映射

    private static func interopCalendar(_ calendar: WorkCalendar) -> InteropCalendar {
        InteropCalendar(
            id: calendarID,
            workingWeekdays: calendar.workingWeekdays.isEmpty
                ? InteropCalendar.allWeekdays
                : calendar.workingWeekdays,
            hoursPerDay: calendar.effectiveHoursPerDay,
            exceptions: calendar.exceptions.map { exception in
                InteropCalendarException(
                    date: exception.date,
                    isWorking: exception.isWorking,
                    note: exception.note
                )
            }
        )
    }

    private static func interopKind(_ kind: TaskKind) -> InteropTaskKind {
        switch kind {
        case .task: return .task
        case .group: return .group
        case .milestone: return .milestone
        }
    }

    /// 工期按「工作日数 × 每日工时」折成秒；群组不排期（nil），里程碑零工期。
    private static func durationSeconds(for task: TaskItem, hoursPerDay: Double) -> TimeInterval? {
        switch task.kind {
        case .group: return nil
        case .milestone: return 0
        case .task:
            guard let days = task.durationDays, days.isFinite else { return nil }
            return days * max(hoursPerDay, 0.5) * 3600
        }
    }

    /// 大纲层级：祖先计数 + 1（1 起）；父子互指的脏数据靠 visited 兜底，不在这里判环。
    private static func outlineLevel(of task: TaskItem, byID: [UUID: TaskItem]) -> Int {
        var level = 1
        var visited: Set<UUID> = [task.id]
        var parentID = task.parentID
        while let id = parentID, let parent = byID[id], visited.insert(id).inserted {
            level += 1
            parentID = parent.parentID
        }
        return level
    }

    /// 祖先群组上的依赖（自身已有的前驱不重复列出）。
    ///
    /// 与 `ScheduleEngine.effectiveDependencies` 同一条规则：群组依赖下推到子树全部叶子
    /// （issue #16）。这里只取「自身之外」的那部分，用于登记导出后新增的显式边。
    private static func implicitDependencies(of task: TaskItem, byID: [UUID: TaskItem]) -> [TaskDependency] {
        var own = Set(task.dependencies.map(\.predecessorID))
        var result: [TaskDependency] = []
        var visited: Set<UUID> = [task.id]
        var parentID = task.parentID
        while let id = parentID, let parent = byID[id], visited.insert(id).inserted {
            for dependency in parent.dependencies where own.insert(dependency.predecessorID).inserted {
                result.append(dependency)
            }
            parentID = parent.parentID
        }
        return result
    }

    private static func interopDependencies(
        of task: TaskItem,
        implicit: [TaskDependency],
        hoursPerDay: Double
    ) -> [InteropDependency] {
        (task.dependencies + implicit).map { dependency in
            InteropDependency(
                predecessorID: dependency.predecessorID.uuidString,
                type: interopDependencyType(dependency.type),
                lagSeconds: dependency.lagDays * max(hoursPerDay, 0.5) * 3600
            )
        }
    }

    private static func interopDependencyType(
        _ type: TaskDependency.DependencyType
    ) -> InteropDependencyType {
        switch type {
        case .fs: return .finishToStart
        case .ff: return .finishToFinish
        case .ss: return .startToStart
        case .sf: return .startToFinish
        }
    }

    private static func interopConstraint(
        _ constraint: SchedulingConstraint?,
        policy: SchedulingPolicy
    ) -> InteropConstraint? {
        switch constraint {
        case .startNoEarlierThan(let date): return .startNoEarlierThan(date)
        case .startNoLaterThan(let date): return .startNoLaterThan(date)
        case .endNoEarlierThan(let date): return .endNoEarlierThan(date)
        case .endNoLaterThan(let date): return .endNoLaterThan(date)
        case nil: return policy == .alap ? .asLateAsPossible : nil
        }
    }

    /// 任务的 Kairo 独有状态：只带「对方表达不了」的那两态与取消原因。
    ///
    /// pending / in_progress / done 由完成度与起止日期即可还原，写进去只会把旁注清单撑长。
    private static func kairoAttributes(of task: TaskItem) -> [String: String] {
        var attributes: [String: String] = [:]
        if task.status == .blocked || task.status == .cancelled {
            attributes[KairoOnlyKey.status] = task.status.rawValue
        }
        if let reason = task.cancelReason, !reason.isEmpty {
            attributes[KairoOnlyKey.cancelReason] = reason
        }
        return attributes
    }
}
