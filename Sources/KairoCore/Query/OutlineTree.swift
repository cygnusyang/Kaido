import Foundation

/// 大纲行（ADR-013）：可见树的一行，携带层级与群组聚合。
public struct OutlineRow: Identifiable, Hashable, Sendable {
    public var task: TaskItem
    /// 0 为顶层。
    public var depth: Int
    public var hasChildren: Bool
    public var isExpanded: Bool
    /// 自身有效排期（任务与未收合群组均可能为 nil）。
    public var scheduledStart: Date?
    public var scheduledFinish: Date?
    /// 群组按全部后代聚合；非群组为 nil。
    public var aggregateStart: Date?
    public var aggregateFinish: Date?
    public var aggregateDurationDays: Double?
    /// 叶子任务为自身进度；群组按后代叶子加权。
    public var aggregateProgress: Double
    public var aggregateStatus: TaskStatus
    /// 群组为子树内违例总数；叶子为自身违例数。
    public var violationCount: Int

    public var id: UUID { task.id }

    public init(
        task: TaskItem,
        depth: Int,
        hasChildren: Bool,
        isExpanded: Bool,
        scheduledStart: Date? = nil,
        scheduledFinish: Date? = nil,
        aggregateStart: Date? = nil,
        aggregateFinish: Date? = nil,
        aggregateDurationDays: Double? = nil,
        aggregateProgress: Double = 0,
        aggregateStatus: TaskStatus = .pending,
        violationCount: Int = 0
    ) {
        self.task = task
        self.depth = depth
        self.hasChildren = hasChildren
        self.isExpanded = isExpanded
        self.scheduledStart = scheduledStart
        self.scheduledFinish = scheduledFinish
        self.aggregateStart = aggregateStart
        self.aggregateFinish = aggregateFinish
        self.aggregateDurationDays = aggregateDurationDays
        self.aggregateProgress = aggregateProgress
        self.aggregateStatus = aggregateStatus
        self.violationCount = violationCount
    }
}

/// 可见大纲树（F-14 / ADR-013）：过滤 + 展开 + 同级排序 + 祖先保留 + 群组聚合。
///
/// - 行序沿用 `tasks` 的大纲顺序；同父任务保持输入顺序。
/// - 聚合始终基于全量子树，过滤与收合只影响可见性。
/// - 过滤激活时，命中任务的祖先链强制可见并展开。
/// - 群组唯一判据为 `kind == .group`。
public struct OutlineTree: Hashable, Sendable {
    public var rows: [OutlineRow]
    /// 因祖先收合而隐藏的任务数（仅统计过滤可见范围内）。
    public var hiddenByCollapseCount: Int
    /// 因过滤而不显示的任务数。
    public var hiddenByFilterCount: Int

    public init(
        tasks: [TaskItem],
        schedule: ScheduleResult? = nil,
        expanded: Set<UUID> = [],
        matchedIDs: Set<UUID>? = nil,
        violations: [Violation] = [],
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) {
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        var childrenByParent: [UUID: [UUID]] = [:]
        for task in tasks {
            if let parent = task.parentID, byID[parent] != nil {
                childrenByParent[parent, default: []].append(task.id)
            }
        }

        // 过滤可见集合：命中任务 + 祖先链。
        let unmatchedAncestors: Set<UUID>
        let filterSet: Set<UUID>?
        if let matchedIDs {
            var visible = matchedIDs.filter { byID[$0] != nil }
            var ancestors: Set<UUID> = []
            for id in visible {
                var parent = byID[id]?.parentID
                var hops = 0
                while let current = parent, byID[current] != nil, hops <= tasks.count {
                    visible.insert(current)
                    ancestors.insert(current)
                    parent = byID[current]?.parentID
                    hops += 1
                }
            }
            filterSet = visible
            unmatchedAncestors = ancestors
        } else {
            filterSet = nil
            unmatchedAncestors = []
        }

        let effectiveExpanded = expanded.union(unmatchedAncestors)
        let violationCountByTask = Dictionary(
            grouping: violations.compactMap(\.taskID), by: { $0 }
        ).mapValues(\.count)

        // 先建索引：`ScheduleResult.scheduled(_:)` 为线性查找，逐任务调用会退化为 O(n²)。
        let scheduledByID = Dictionary(
            uniqueKeysWithValues: (schedule?.tasks ?? []).map { ($0.taskID, $0) }
        )
        let unscheduledIDs = Set(schedule?.unscheduledTaskIDs ?? [])
        func scheduled(_ id: UUID) -> ScheduledTask? {
            guard schedule != nil, !unscheduledIDs.contains(id) else { return nil }
            return scheduledByID[id]
        }

        // 聚合结果（按任务缓存）。
        struct Aggregate {
            var progress: Double = 0
            var status: TaskStatus = .pending
            var start: Date?
            var finish: Date?
            var violations: Int = 0
        }
        var aggregateCache: [UUID: Aggregate] = [:]
        var visiting: Set<UUID> = []

        func ownViolations(_ id: UUID) -> Int { violationCountByTask[id] ?? 0 }

        // 后代叶子任务的加权进度；无叶子返回 nil。
        // 已取消的叶子不进加权（v0.16）：终态「决定不做」不拖低群组完成度。
        func leafProgress(_ id: UUID, seen: inout Set<UUID>) -> (weighted: Double, weight: Double)? {
            guard seen.insert(id).inserted, let task = byID[id] else { return nil }
            if task.kind != .group && (childrenByParent[id] ?? []).isEmpty {
                guard task.status != .cancelled else { return nil }
                let weight = max(task.effortHours ?? 1, 0)
                return (weight * task.progress, weight)
            }
            var sum = 0.0
            var weight = 0.0
            var found = false
            for child in childrenByParent[id] ?? [] {
                if let part = leafProgress(child, seen: &seen) {
                    sum += part.weighted
                    weight += part.weight
                    found = true
                }
            }
            return found ? (sum, weight) : nil
        }

        func aggregate(_ id: UUID) -> Aggregate {
            if let cached = aggregateCache[id] { return cached }
            guard let task = byID[id], visiting.insert(id).inserted else {
                return Aggregate(violations: ownViolations(id))
            }
            defer { visiting.remove(id) }

            var result: Aggregate
            let children = childrenByParent[id] ?? []
            if task.kind == .group {
                var seen: Set<UUID> = []
                let progress = leafProgress(id, seen: &seen)
                let childAggregates = children.map(aggregate)
                let starts = childAggregates.compactMap(\.start)
                let finishes = childAggregates.compactMap(\.finish)
                // 已取消的子任务不参与群组状态判定（v0.16）：否则「其余都做完」永远聚合不成 done。
                let considered = children.filter { byID[$0]?.status != .cancelled }.map(aggregate)
                var status = TaskStatus.pending
                if !considered.isEmpty {
                    if considered.allSatisfy({ $0.status == .done }) {
                        status = .done
                    } else if considered.contains(where: { $0.status == .inProgress }) {
                        status = .inProgress
                    } else if considered.contains(where: { $0.status == .blocked }) {
                        status = .blocked
                    }
                }
                result = Aggregate(
                    progress: progress.map { $0.weight > 0 ? $0.weighted / $0.weight : 0 } ?? 0,
                    status: status,
                    start: starts.min(),
                    finish: finishes.max(),
                    violations: ownViolations(id) + childAggregates.reduce(0) { $0 + $1.violations }
                )
            } else {
                result = Aggregate(
                    progress: task.progress,
                    status: task.status,
                    start: scheduled(id)?.scheduledStart,
                    finish: scheduled(id)?.scheduledFinish,
                    violations: ownViolations(id)
                )
            }
            aggregateCache[id] = result
            return result
        }

        func isFilterVisible(_ id: UUID) -> Bool {
            filterSet?.contains(id) ?? true
        }

        func ancestorsAreExpanded(_ id: UUID) -> Bool {
            var parent = byID[id]?.parentID
            var hops = 0
            while let current = parent, byID[current] != nil, hops <= tasks.count {
                if !(childrenByParent[current] ?? []).isEmpty,
                   !effectiveExpanded.contains(current) {
                    return false
                }
                parent = byID[current]?.parentID
                hops += 1
            }
            return true
        }

        var rows: [OutlineRow] = []
        var visited: Set<UUID> = []

        func append(_ id: UUID, depth: Int) {
            guard !visited.contains(id), let task = byID[id] else { return }
            visited.insert(id)
            let children = childrenByParent[id] ?? []
            let agg = aggregate(id)
            let own = scheduled(id)
            let isExpanded = !children.isEmpty && effectiveExpanded.contains(id)
            let duration: Double? = {
                guard let start = agg.start, let finish = agg.finish else { return nil }
                return Double(calendar.dateComponents(
                    [.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: finish)
                ).day ?? 0)
            }()
            rows.append(OutlineRow(
                task: task,
                depth: depth,
                hasChildren: !children.isEmpty,
                isExpanded: isExpanded,
                scheduledStart: own?.scheduledStart,
                scheduledFinish: own?.scheduledFinish,
                aggregateStart: task.kind == .group ? agg.start : nil,
                aggregateFinish: task.kind == .group ? agg.finish : nil,
                aggregateDurationDays: task.kind == .group ? duration : nil,
                aggregateProgress: agg.progress,
                aggregateStatus: agg.status,
                violationCount: agg.violations
            ))
            guard !children.isEmpty, isExpanded else { return }
            for child in children where isFilterVisible(child) {
                append(child, depth: depth + 1)
            }
        }

        // 根 = 无父或父不存在。
        for task in tasks where task.parentID == nil || byID[task.parentID!] == nil {
            guard isFilterVisible(task.id) else { continue }
            append(task.id, depth: 0)
        }

        // 父链成环的任务没有根，按根兜底，避免整棵子树丢失；
        // 收合或过滤隐藏的任务不在此列。
        func isInParentCycle(_ id: UUID) -> Bool {
            var current = id
            var seen: Set<UUID> = []
            while let parent = byID[current]?.parentID, byID[parent] != nil {
                if parent == id || !seen.insert(parent).inserted { return true }
                current = parent
            }
            return false
        }
        for task in tasks
        where !visited.contains(task.id) && isFilterVisible(task.id) && isInParentCycle(task.id) {
            append(task.id, depth: 0)
        }

        var hiddenByCollapse = 0
        var hiddenByFilter = 0
        for task in tasks {
            if !isFilterVisible(task.id) {
                hiddenByFilter += 1
            } else if !ancestorsAreExpanded(task.id) {
                hiddenByCollapse += 1
            }
        }

        self.rows = rows
        self.hiddenByCollapseCount = hiddenByCollapse
        self.hiddenByFilterCount = hiddenByFilter
    }
}
