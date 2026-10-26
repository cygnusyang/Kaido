import Foundation

/// 调度引擎（ADR-007：调度为纯函数，无副作用，只依赖 Foundation）。
///
/// 输入任务清单与项目边界，输出每任务的最早/最晚可行窗口与选定安排；
/// 不改写 TaskItem 的原始字段（startDate/dueDate 是用户输入意图，调度结果是另一张表）。
/// `startDate` 作为「开始不早于」下界参与前向传播（S8 / D-021）：不驱动提前，
/// 但排期结果不得早于该日；群组忽略自身 `startDate`，里程碑同样适用。
///
/// 日历（F-22-06）：工期单位是**工作日**，所有日期推进经 `WorkDayResolver`（按 Calendar
/// 整日加减，跨夏令时切换仍落在本地零点，不按 86 400 秒折算）。`workCalendar` 为 nil 时
/// 全周 7 天上班，工作日 == 日历日，排期结果与 v1.0.x 逐位相同（D1 兼容红线）。
/// 输入日期落在非工作日时向后吸附，并由 `ScheduleResult.calendarAdjustments` 留痕（D3）。
///
/// 已取消任务（`status == .cancelled`）不参与排期：终态「决定不做」既不占工期，
/// 也不该把后继或群组窗口顶到后面（v0.16）。
///
/// 相关性传播（F-22-07）：FS/FF/SS/SF 四型不等式 + lagDays（天，可正负）：
///   FS：后继开始 ≥ 前驱结束 + lag
///   FF：后继结束 ≥ 前驱结束 + lag
///   SS：后继开始 ≥ 前驱开始 + lag
///   SF：后继结束 ≥ 前驱开始 + lag
public enum ScheduleEngine {
    public static func compute(
        tasks inputTasks: [TaskItem],
        resources: [Resource] = [],
        projectStart: Date? = nil,
        projectEnd: Date? = nil,
        direction: ScheduleDirection = .forward,
        calendar: Calendar = Calendar(identifier: .gregorian),
        now: Date = Date(),
        createdAt: Date? = nil,
        workCalendar: WorkCalendar? = nil
    ) -> ScheduleResult {
        // 已取消（v0.16）是「决定不做」的终态：不占工期、不参与前后向传播、
        // 不聚合进群组窗口，也不出排期条目（因此不出甘特条、不进关键路径）。
        // 一处过滤即覆盖全部派生：以它为前驱的相关性自然成为悬空边而被忽略。
        let tasks = inputTasks.filter { $0.status != .cancelled }
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        let resourceByID = Dictionary(uniqueKeysWithValues: resources.map { ($0.id, $0) })
        // 未设项目开始日期时按「最早任务 startDate → 今天」推导，禁止 1970 起排（D-003）。
        let scheduleAnchor = ScheduleAnchor.derive(
            tasks: tasks, projectStart: projectStart, now: now,
            calendar: calendar, createdAt: createdAt
        )
        let startAnchor: Date? = scheduleAnchor.date
        let endAnchor = projectEnd.map { calendar.startOfDay(for: $0) }
        let dayZero = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))

        // 工作日历（F-22-06）：入口归一化一次，全程复用；nil = 全周 7 天 = 与 v1.0.x 等价。
        let workDays = WorkDayResolver(workCalendar: workCalendar, calendar: calendar)
        let hoursPerDay = (workCalendar ?? WorkCalendar()).effectiveHoursPerDay
        let (lowerBounds, adjustments) = taskLowerBounds(
            tasks: tasks, workDays: workDays, calendar: calendar
        )

        let durations = durationsByTask(
            tasks, resourceByID: resourceByID, hoursPerDay: hoursPerDay
        )
        let cycleIDs = cycleTaskIDs(tasks, byID: byID)
        let cycleSet = Set(cycleIDs)
        let successorMap = successorMap(of: tasks, byID: byID)

        let earliest = forwardPass(
            tasks: tasks, byID: byID, durations: durations, lowerBounds: lowerBounds,
            startAnchor: startAnchor, dayZero: dayZero, cycleSet: cycleSet, workDays: workDays
        )
        let anchor = endAnchor ?? (earliest.values.map(\.finish).max() ?? dayZero)
        let latest = backwardPass(
            tasks: tasks, byID: byID, durations: durations, successorMap: successorMap,
            anchor: anchor, cycleSet: cycleSet, workDays: workDays
        )

        let rawScheduled = scheduledTasks(
            tasks: tasks, byID: byID, durations: durations, lowerBounds: lowerBounds,
            earliest: earliest, latest: latest, successorMap: successorMap, workDays: workDays
        )
        // 群组自带排期无意义：改为子树聚合（issue #16），让 CLI 与甘特同一口径。
        let scheduled = aggregateGroupWindows(rawScheduled, tasks: tasks, workDays: workDays)

        // 无法排期：环上任务与空群组。其余任务均有调度条目。
        let parentIDs = Set(tasks.compactMap(\.parentID))
        let unscheduledIDs = tasks.compactMap { task -> UUID? in
            if cycleSet.contains(task.id) { return task.id }
            if task.kind == .group && !parentIDs.contains(task.id) { return task.id }
            return nil
        }

        return ScheduleResult(
            tasks: scheduled,
            projectStart: startAnchor,
            projectEnd: endAnchor,
            direction: direction,
            cycleTaskIDs: cycleIDs,
            projectStartDerived: scheduleAnchor.isDerived,
            projectStartSource: scheduleAnchor.source,
            unscheduledTaskIDs: unscheduledIDs,
            calendarAdjustments: calendarAdjustmentList(
                adjustments, degenerate: workDays.isDegenerate,
                startupDay: startAnchor ?? dayZero
            )
        )
    }

    // MARK: - 持续时间

    /// 每任务持续时间（**工作日**）：里程碑恒为 0；有 durationDays 用之；有投入时
    /// 按 duration = effort / (hoursPerDay × Σ(units × efficiency)) 换算（F-22-03 / F-22-06）。
    /// 无分配资源时按 1 个 100% 单位换算（US-E1-05 验收 1）；`hoursPerDay` 默认 8。
    private static func durationsByTask(
        _ tasks: [TaskItem],
        resourceByID: [UUID: Resource],
        hoursPerDay: Double
    ) -> [UUID: Double] {
        var result: [UUID: Double] = [:]
        for task in tasks {
            result[task.id] = duration(of: task, resourceByID: resourceByID, hoursPerDay: hoursPerDay)
        }
        return result
    }

    private static func duration(
        of task: TaskItem,
        resourceByID: [UUID: Resource],
        hoursPerDay: Double
    ) -> Double {
        if task.kind == .milestone { return 0 }
        if let d = task.durationDays, d > 0 { return d }
        if let effort = task.effortHours, effort > 0 {
            let capacity = task.assignments.isEmpty ? 1 : capacity(of: task, resourceByID: resourceByID)
            if capacity > 0 { return effort / hoursPerDay / capacity }
        }
        return 1 // 无 duration 的叶子任务默认 1 个工作日
    }

    /// 分配容量 Σ(units × efficiency)；未命中的资源按效率 1 计。
    private static func capacity(of task: TaskItem, resourceByID: [UUID: Resource]) -> Double {
        task.assignments.reduce(0) { sum, a in
            let efficiency = resourceByID[a.resourceID]?.efficiency ?? 1
            return sum + a.units * efficiency
        }
    }

    // MARK: - 有效前驱（群组依赖下推 / issue #16）

    /// 有效前驱：任务自身依赖 **∪ 所有祖先群组的依赖**。
    ///
    /// 为什么需要：群组（阶段）本身没有排期，用户最自然的建模是「v1.0 接在 v0.17 之后」。
    /// 若只认叶子自身的依赖，群组依赖既不下推也看不到效果（issue #16）。
    /// 同一前驱在自身与祖先重复出现时只保留第一次，避免入度重复计数。
    /// 祖先链按 parentID 上溯并用集合防环（脏数据里父子互指不得死循环）。
    static func effectiveDependencies(of task: TaskItem, byID: [UUID: TaskItem]) -> [TaskDependency] {
        var deps: [TaskDependency] = []
        var seen = Set<UUID>()
        var visitedGroups = Set<UUID>()
        var node: TaskItem? = task
        while let current = node {
            for dep in current.dependencies where seen.insert(dep.predecessorID).inserted {
                deps.append(dep)
            }
            guard let pid = current.parentID,
                  let parent = byID[pid],
                  visitedGroups.insert(pid).inserted else { break }
            node = parent
        }
        return deps
    }

    // MARK: - 环检测（F-30-08）

    /// 找出所有处于相关性环中的任务（三色 DFS）。环上任务不参与拓扑传播。
    private static func cycleTaskIDs(_ tasks: [TaskItem], byID: [UUID: TaskItem]) -> [UUID] {
        var successors: [UUID: [UUID]] = [:]
        for task in tasks {
            for dep in effectiveDependencies(of: task, byID: byID) where byID[dep.predecessorID] != nil {
                successors[dep.predecessorID, default: []].append(task.id)
            }
        }
        enum Color { case white, gray, black }
        var color: [UUID: Color] = [:]
        var inCycle = Set<UUID>()
        var stack: [UUID] = []

        func visit(_ id: UUID) {
            color[id] = .gray
            stack.append(id)
            for next in successors[id] ?? [] {
                guard color[next] != .black else { continue }
                if color[next] == .gray, let idx = stack.firstIndex(of: next) {
                    for node in stack[idx...] { inCycle.insert(node) }
                } else {
                    visit(next)
                }
            }
            stack.removeLast()
            color[id] = .black
        }

        for task in tasks where color[task.id] == nil {
            visit(task.id)
        }
        // 保持输入顺序输出。
        return tasks.compactMap { inCycle.contains($0.id) ? $0.id : nil }
    }

    /// 后继邻接表：predecessor → [依赖它的任务]。悬空相关性（前驱不存在）被忽略。
    private static func successorMap(of tasks: [TaskItem], byID: [UUID: TaskItem]) -> [UUID: [TaskItem]] {
        var map: [UUID: [TaskItem]] = [:]
        for task in tasks {
            for dep in effectiveDependencies(of: task, byID: byID) where byID[dep.predecessorID] != nil {
                map[dep.predecessorID, default: []].append(task)
            }
        }
        return map
    }

    /// Kahn 拓扑序（仅非环任务；环任务不入序）。依赖计数只算有效前驱。
    private static func topologicalOrder(_ tasks: [TaskItem], byID: [UUID: TaskItem]) -> [UUID] {
        // 群组前驱要展开到叶子（issue #16）：阶段门的语义是「前一阶段所有叶子做完」。
        // 只保留「群组节点 → 任务」一条边时，群组节点在拓扑序里很早就出队，
        // 下游任务会在前驱子树还没排完时就被计算，表现为「只顺延了一部分」。
        var children: [UUID: [UUID]] = [:]
        for task in tasks { if let parent = task.parentID { children[parent, default: []].append(task.id) } }
        func leaves(_ id: UUID) -> [UUID] {
            guard let kids = children[id], !kids.isEmpty else { return [id] }
            return kids.flatMap { leaves($0) }
        }

        var inDegree: [UUID: Int] = [:]
        var successors: [UUID: [UUID]] = [:]
        for task in tasks {
            var predecessors = Set<UUID>()
            for dep in effectiveDependencies(of: task, byID: byID) {
                guard let pred = byID[dep.predecessorID] else { continue }
                let nodes = pred.kind == .group ? leaves(pred.id) : [pred.id]
                for node in nodes where node != task.id { predecessors.insert(node) }
            }
            inDegree[task.id] = predecessors.count
            for node in predecessors { successors[node, default: []].append(task.id) }
        }
        var queue: [UUID] = tasks.filter { inDegree[$0.id] == 0 }.map(\.id)
        var order: [UUID] = []
        while !queue.isEmpty {
            let id = queue.removeFirst()
            order.append(id)
            for succ in successors[id] ?? [] {
                inDegree[succ]? -= 1
                if inDegree[succ] == 0 { queue.append(succ) }
            }
        }
        return order
    }

    // MARK: - 前向传播（最早窗口 / ASAP）

    private static func forwardPass(
        tasks: [TaskItem],
        byID: [UUID: TaskItem],
        durations: [UUID: Double],
        lowerBounds: [UUID: Date],
        startAnchor: Date?,
        dayZero: Date,
        cycleSet: Set<UUID>,
        workDays: WorkDayResolver
    ) -> [UUID: Window] {
        let order = topologicalOrder(tasks, byID: byID)
        let base = startAnchor ?? dayZero
        var earliest: [UUID: Window] = [:]

        // 群组作为前驱时，要用「子树聚合窗口」而不是它自己的占位窗口（issue #16）。
        var children: [UUID: [UUID]] = [:]
        for task in tasks { if let parent = task.parentID { children[parent, default: []].append(task.id) } }
        func subtreeWindow(_ id: UUID) -> Window? {
            if let kids = children[id], !kids.isEmpty {
                let windows: [Window] = kids.compactMap { subtreeWindow($0) }
                guard let start = windows.map({ $0.start }).min(),
                      let finish = windows.map({ $0.finish }).max() else { return nil }
                return Window(start: start, finish: finish)
            }
            return earliest[id]
        }

        // 环上任务先定基值，供其后继（非环任务）正常推导。
        for id in cycleSet {
            let duration = durations[id] ?? 1
            let start = workDays.snapping(
                max(base, lowerBounds[id] ?? ScheduleBounds.noLowerBound)
            )
            earliest[id] = Window(start: start, finish: workDays.addingWorkDays(duration, to: start))
        }

        // 两遍：第一遍推出叶子窗口，第二遍让「以群组为前驱」的任务吃到子树聚合窗口。
        // 群组自身窗口的最终值由 aggregateGroupWindows 统一改写（与这里同口径）。
        for pass in 0..<2 {
            for id in order {
                let task = byID[id]!
                let duration = durations[id] ?? 1
                var start = max(base, lowerBounds[id] ?? ScheduleBounds.noLowerBound)
                for dep in effectiveDependencies(of: task, byID: byID) {
                    guard let pred = byID[dep.predecessorID] else { continue }
                    let pw: Window?
                    if pred.kind == .group, let aggregated = subtreeWindow(pred.id) {
                        pw = aggregated
                    } else {
                        pw = earliest[pred.id]
                    }
                    guard let window = pw else { continue }
                    start = max(start, forwardStartLowerBound(
                        type: dep.type, lag: dep.lagDays, pred: window, duration: duration,
                        workDays: workDays
                    ))
                }
                // D3：起算日落在非工作日时向后吸附（里程碑同样适用），不拒绝、不跳过。
                start = workDays.snapping(start)
                let next = Window(start: start, finish: workDays.addingWorkDays(duration, to: start))
                if pass == 1 || earliest[id] == nil { earliest[id] = next }
            }
        }
        return earliest
    }

    /// 由一条相关性推出的后继「最早开始」下界（前向传播不等式反解）。
    private static func forwardStartLowerBound(
        type: TaskDependency.DependencyType, lag: Double, pred: Window, duration: Double,
        workDays: WorkDayResolver
    ) -> Date {
        switch type {
        case .fs: return workDays.addingWorkDays(lag, to: pred.finish)
        case .ss: return workDays.addingWorkDays(lag, to: pred.start)
        case .ff: return workDays.addingWorkDays(lag - duration, to: pred.finish)
        case .sf: return workDays.addingWorkDays(lag - duration, to: pred.start)
        }
    }

    // MARK: - 后向传播（最晚窗口 / ALAP）

    private static func backwardPass(
        tasks: [TaskItem],
        byID: [UUID: TaskItem],
        durations: [UUID: Double],
        successorMap: [UUID: [TaskItem]],
        anchor: Date,
        cycleSet: Set<UUID>,
        workDays: WorkDayResolver
    ) -> [UUID: Window] {
        let order = topologicalOrder(tasks, byID: byID)
        var latest: [UUID: Window] = [:]

        for id in cycleSet {
            let task = byID[id]!
            let duration = durations[id] ?? 1
            let finish = workDays.snappingBackward(
                min(anchor, constraintEndUpperBound(task, duration: duration, workDays: workDays))
            )
            latest[id] = Window(start: workDays.addingWorkDays(-duration, to: finish), finish: finish)
        }

        for id in order.reversed() {
            let task = byID[id]!
            let duration = durations[id] ?? 1
            var finish = min(anchor, constraintEndUpperBound(task, duration: duration, workDays: workDays))
            for succ in successorMap[id] ?? [] {
                guard let sw = latest[succ.id] else { continue }
                for dep in effectiveDependencies(of: succ, byID: byID) where dep.predecessorID == id {
                    finish = min(finish, backwardFinishUpperBound(
                        type: dep.type, lag: dep.lagDays, succ: sw, duration: duration, workDays: workDays
                    ))
                }
            }
            // 最晚结束同样吸附到工作日：非工作日结束意味着「那天要上班」，与日历矛盾。
            finish = workDays.snappingBackward(finish)
            latest[id] = Window(start: workDays.addingWorkDays(-duration, to: finish), finish: finish)
        }
        return latest
    }

    /// 本任务作为前驱时，由后继相关性反解出的本任务「最晚结束」上界。
    private static func backwardFinishUpperBound(
        type: TaskDependency.DependencyType, lag: Double, succ: Window, duration: Double,
        workDays: WorkDayResolver
    ) -> Date {
        switch type {
        case .fs: return workDays.addingWorkDays(-lag, to: succ.start)
        case .ff: return workDays.addingWorkDays(-lag, to: succ.finish)
        case .ss: return workDays.addingWorkDays(-lag + duration, to: succ.start)
        case .sf: return workDays.addingWorkDays(-lag + duration, to: succ.finish)
        }
    }

    // MARK: - 选定安排与宽延

    private static func scheduledTasks(
        tasks: [TaskItem],
        byID: [UUID: TaskItem],
        durations: [UUID: Double],
        lowerBounds: [UUID: Date],
        earliest: [UUID: Window],
        latest: [UUID: Window],
        successorMap: [UUID: [TaskItem]],
        workDays: WorkDayResolver
    ) -> [ScheduledTask] {
        tasks.map { task in
            let duration = durations[task.id] ?? 1
            let e = earliest[task.id] ?? Window(start: Date(timeIntervalSince1970: 0), finish: Date(timeIntervalSince1970: 0))
            let l = latest[task.id] ?? e
            let useLatest = task.schedulingPolicy == .alap
            let totalSlack = workDays.workDaysBetween(e.start, l.start)
            let free = freeSlack(
                of: task.id, byID: byID, earliest: earliest, successorMap: successorMap,
                totalSlack: totalSlack, workDays: workDays
            )
            // 选定安排统一收敛到 startDate 下界（S8 / D-021）：ASAP 已由前向传播保证，
            // ALAP 取最晚窗口时可能早于意图开始（后向传播不消费该下界），此处补齐，
            // 避免两条选定路径口径分叉。
            let selectedStart = workDays.snapping(max(
                useLatest ? l.start : e.start,
                lowerBounds[task.id] ?? ScheduleBounds.noLowerBound
            ))
            return ScheduledTask(
                taskID: task.id,
                durationDays: duration,
                earliestStart: e.start, earliestFinish: e.finish,
                latestStart: l.start, latestFinish: l.finish,
                scheduledStart: selectedStart,
                scheduledFinish: workDays.addingWorkDays(duration, to: selectedStart),
                totalSlackDays: totalSlack,
                freeSlackDays: free
            )
        }
    }

    /// 群组窗口聚合：群组的 scheduled/earliest/latest 统一改为子树聚合区间。
    ///
    /// 群组本身没有可执行工作，之前它被当成 1 天叶子单独排期，导致
    /// `schedule compute` 打印「群组 1 天」而甘特按子任务聚合画出另一跨度（issue #16）。
    private static func aggregateGroupWindows(
        _ scheduled: [ScheduledTask],
        tasks: [TaskItem],
        workDays: WorkDayResolver
    ) -> [ScheduledTask] {
        var children: [UUID: [UUID]] = [:]
        for task in tasks { if let parent = task.parentID { children[parent, default: []].append(task.id) } }
        guard !children.isEmpty else { return scheduled }
        let index = Dictionary(uniqueKeysWithValues: scheduled.enumerated().map { ($1.taskID, $0) })
        let kinds = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.kind) })
        var memo: [UUID: Window?] = [:]

        func subtreeWindow(_ id: UUID) -> Window? {
            if let cached = memo[id] { return cached }
            var value: Window?
            if let kids = children[id], !kids.isEmpty {
                let windows = kids.compactMap(subtreeWindow)
                if let start = windows.map(\.start).min(), let finish = windows.map(\.finish).max() {
                    value = Window(start: start, finish: finish)
                }
            } else if let idx = index[id] {
                value = Window(start: scheduled[idx].scheduledStart, finish: scheduled[idx].scheduledFinish)
            }
            memo[id] = value
            return value
        }

        var result = scheduled
        for (id, idx) in index where kinds[id] == .group {
            guard let window = subtreeWindow(id) else { continue }
            let duration = max(0, workDays.workDaysBetween(window.start, window.finish))
            result[idx].earliestStart = window.start
            result[idx].earliestFinish = window.finish
            result[idx].latestStart = window.start
            result[idx].latestFinish = window.finish
            result[idx].scheduledStart = window.start
            result[idx].scheduledFinish = window.finish
            result[idx].durationDays = duration
            result[idx].totalSlackDays = 0
            result[idx].freeSlackDays = 0
        }
        return result
    }

    /// 自由宽延：不推迟任何后继最早安排的最大推迟量（US-E2-03）。无后继时等于总宽延。
    private static func freeSlack(
        of id: UUID,
        byID: [UUID: TaskItem],
        earliest: [UUID: Window],
        successorMap: [UUID: [TaskItem]],
        totalSlack: Double,
        workDays: WorkDayResolver
    ) -> Double {
        let successors = successorMap[id] ?? []
        guard !successors.isEmpty, let ew = earliest[id] else { return totalSlack }
        var minGap = Double.greatestFiniteMagnitude
        for succ in successors {
            guard let sw = earliest[succ.id] else { continue }
            for dep in effectiveDependencies(of: succ, byID: byID) where dep.predecessorID == id {
                let gap: Double
                switch dep.type {
                case .fs: gap = workDays.workDaysBetween(workDays.addingWorkDays(dep.lagDays, to: ew.finish), sw.start)
                case .ff: gap = workDays.workDaysBetween(workDays.addingWorkDays(dep.lagDays, to: ew.finish), sw.finish)
                case .ss: gap = workDays.workDaysBetween(workDays.addingWorkDays(dep.lagDays, to: ew.start), sw.start)
                case .sf: gap = workDays.workDaysBetween(workDays.addingWorkDays(dep.lagDays, to: ew.start), sw.finish)
                }
                minGap = min(minGap, gap)
            }
        }
        return max(0, minGap)
    }

    // MARK: - 时限与开始日下界（含工作日吸附）

    /// 每任务的「开始不早于」下界：`startDate` 与 startNoEarlierThan 取较晚者，
    /// 再向后吸附到下一个工作日（F-22-06 / D3）。
    ///
    /// 下界缺失时保留 `ScheduleBounds.noLowerBound`（`.distantPast`）：它是「不存在下界」的
    /// 哨兵而非日期，不可落到排期里（与 `dayZero` 的纪元零点语义区分，M-7 / D-024）。
    /// 群组由子任务聚合，忽略自身 `startDate`。
    ///
    /// 吸附发生时记一条 `CalendarAdjustment`：排期继续，但不能静默改掉用户写的日期。
    private static func taskLowerBounds(
        tasks: [TaskItem],
        workDays: WorkDayResolver,
        calendar: Calendar
    ) -> (bounds: [UUID: Date], adjustments: [CalendarAdjustment]) {
        var bounds: [UUID: Date] = [:]
        var adjustments: [CalendarAdjustment] = []
        for task in tasks {
            let requested = requestedLowerBound(task, calendar: calendar)
            guard requested != ScheduleBounds.noLowerBound else {
                bounds[task.id] = ScheduleBounds.noLowerBound
                continue
            }
            let adjusted = workDays.snapping(requested)
            if adjusted != requested {
                adjustments.append(CalendarAdjustment(
                    taskID: task.id,
                    kind: .nonWorkingDay,
                    requested: requested,
                    adjusted: adjusted
                ))
            }
            bounds[task.id] = adjusted
        }
        return (bounds, adjustments)
    }

    /// 用户给出的开始下界（未吸附）：本任务 `startDate` 与 startNoEarlierThan 取较晚者。
    private static func requestedLowerBound(_ task: TaskItem, calendar: Calendar) -> Date {
        guard task.kind != .group else { return ScheduleBounds.noLowerBound }
        let startDate = task.startDate.map { calendar.startOfDay(for: $0) } ?? ScheduleBounds.noLowerBound
        let constraint: Date
        if case .startNoEarlierThan(let d) = task.constraint {
            constraint = calendar.startOfDay(for: d)
        } else {
            constraint = ScheduleBounds.noLowerBound
        }
        return max(startDate, constraint)
    }

    /// 时限对最晚结束的压制：endNoLaterThan 直接限结束；startNoLaterThan 限开始+持续（工作日）。
    private static func constraintEndUpperBound(
        _ task: TaskItem,
        duration: Double,
        workDays: WorkDayResolver
    ) -> Date {
        switch task.constraint {
        case .endNoLaterThan(let d):
            return workDays.snappingBackward(workDays.startOfDay(d))
        case .startNoLaterThan(let d):
            return workDays.addingWorkDays(duration, to: workDays.startOfDay(d))
        default:
            return .distantFuture
        }
    }

    /// 顺延记录 + （可选）工作周为空的退化说明，按任务顺序输出。
    private static func calendarAdjustmentList(
        _ adjustments: [CalendarAdjustment],
        degenerate: Bool,
        startupDay: Date
    ) -> [CalendarAdjustment] {
        guard degenerate else { return adjustments }
        // 退化是项目级事实：`requested == adjusted`（日期没变，变的是「怎么数工作日」）。
        let notice = CalendarAdjustment(
            taskID: nil, kind: .invalidWeekdays, requested: startupDay, adjusted: startupDay
        )
        return [notice] + adjustments
    }
}

/// 排期边界哨兵（F-0717 / D-024）。
///
/// 「无下界」在排期里只有一个取值：`.distantPast`。它与纪元零点（`dayZero`）语义不同——
/// 后者是真实日期，前者只作 `max` 的比较起点，绝不允许落进排期结果。同一语义两种写法
/// （1970 vs distantPast）会让后续改动者误以为二者可互换，故收敛为具名常量。
public enum ScheduleBounds {
    /// 「不存在下界」的哨兵值。
    public static let noLowerBound = Date.distantPast
}

/// 内部窗口（起止对）。
private struct Window {
    var start: Date
    var finish: Date
}
