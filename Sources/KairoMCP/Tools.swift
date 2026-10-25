import Foundation
import KairoCore
import KairoCommands

/// 工具层错误：非法参数（架构 §3.1 错误契约的 argument 类）。
///
/// `reason` 是细粒度稳定码（`KairoErrorCode`）：对外的 `code` 仍冻结为
/// `invalid_argument`，消费者改按 `reason` 区分参数错误，不必再匹配中文文本（F-0708 阶段一）。
enum ToolError: Error, Equatable, CustomStringConvertible {
    case invalidArgument(reason: KairoErrorCode, message: String)

    /// 细粒度稳定码。
    var reason: KairoErrorCode {
        switch self {
        case .invalidArgument(let reason, _): return reason
        }
    }

    var description: String {
        switch self {
        case .invalidArgument(_, let message): return message
        }
    }
}

/// 结构化工具失败（架构 §3.1：{code, message, reason?, taskID?}）。
///
/// `code` 是冻结的粗粒度分类（5 值 + `internal_error`），不改取值——按它匹配的既有
/// 消费者不能静默失效；`reason` 是本版新增的细粒度稳定码。`message` 阶段一保持中文
/// 原样（设计 §6：先给码、下一个版本再切文案）。
struct ToolFailure: Encodable {
    var code: String
    var reason: String?
    var message: String
    var taskID: String?
}

/// MCP 工具定义：名称 / 描述 / 输入 schema / 处理函数。
struct MCPTool {
    let name: String
    let description: String
    let inputSchema: JSONValue
    let handler: (JSONValue?, KairoSession) throws -> JSONValue
}

/// 工具清单（Sprint 1 子集，与架构文档 §3.1 草案对齐）。
/// 接口事实源（ADR-005）：CLI 从同一命令层派生。
struct ToolRegistry {
    private(set) var tools: [MCPTool]

    init() {
        tools = Self.makeTools()
    }

    func find(_ name: String) -> MCPTool? {
        tools.first { $0.name == name }
    }

    // MARK: - 工具定义

    private static func makeTools() -> [MCPTool] {
        [
            projectCreate,
            projectOpen,
            projectSave,
            taskAdd,
            taskList,
            taskGet,
            taskUpdate,
            taskDelete,
            wbsImport,
            scheduleCompute,
            scheduleCriticalPath,
            violationsList,
            statusUpdate,
            statusBatchUpdate,
            resourceAdd,
            resourceList,
            baselineCreate,
            baselineList,
            baselineDelete,
            baselineVariance,
            baselineSetColor,
        ]
    }

    // MARK: project

    private static let projectCreate = MCPTool(
        name: "project_create",
        description: "新建项目并打开（US-E1-01）；可带项目时间线 projectStart/projectEnd（ISO8601），作为排期与违例的默认边界",
        inputSchema: Schema.object(properties: [
            "title": Schema.string(),
            "projectStart": Schema.string(),
            "projectEnd": Schema.string(),
        ], required: ["title"])
    ) { args, session in
        let a = try ToolArgs(args)
        let meta = try session.createProject(
            title: a.string("title"),
            projectStart: try a.optionalISODate("projectStart"),
            projectEnd: try a.optionalISODate("projectEnd")
        )
        return ProjectResults.created(meta)
    }

    private static let projectOpen = MCPTool(
        name: "project_open",
        description: "打开 .kairo 项目文件（US-E6-01）；formatVersion 为磁盘文件版本，needsUpgrade 表示保存后会升级",
        inputSchema: Schema.object(properties: ["path": Schema.string()], required: ["path"])
    ) { args, session in
        let a = try ToolArgs(args)
        let meta = try session.openProject(at: URL(fileURLWithPath: a.string("path")))
        return ProjectResults.opened(meta, sourceFormatVersion: session.sourceFormatVersion)
    }

    private static let projectSave = MCPTool(
        name: "project_save",
        description: "保存当前项目为 .kairo（未指定路径时保存到已打开文件）；formatVersion 为写出文件的版本",
        inputSchema: Schema.object(properties: ["path": Schema.string()])
    ) { args, session in
        let a = try ToolArgs(args)
        let target = a.optionalString("path").map { URL(fileURLWithPath: $0) }
        // 保存会把来源版本置为 current，必须先捕获；否则 upgradedFrom 永远丢失。
        let upgradedFrom = session.sourceFormatVersion
        let meta = try session.saveProject(to: target)
        return ProjectResults.saved(
            updatedAt: meta.updatedAt,
            path: session.projectURL?.path ?? "",
            upgradedFrom: upgradedFrom
        )
    }

    // MARK: task

    private static let taskAdd = MCPTool(
        name: "task_add",
        description: "创建任务（US-E1-02；assignee 为负责人；constraint 格式 type:ISO8601，如 startNoLaterThan:2026-11-05T00:00:00Z；dependencies 元素 {\"predecessorID\":\"UUID\",\"type\":\"fs\",\"lagDays\":0}）",
        inputSchema: Schema.object(
            properties: [
                "title": Schema.string(),
                "kind": Schema.string(enumValues: ["task", "group", "milestone"]),
                "parentID": Schema.string(),
                "effortHours": Schema.number(),
                "durationDays": Schema.number(),
                "notes": Schema.string(),
                "priority": Schema.string(enumValues: ["low", "normal", "high", "critical"]),
                "status": Schema.string(enumValues: ["pending", "in_progress", "done", "blocked"]),
                "tags": Schema.arrayOf(Schema.string()),
                "dependencies": Schema.arrayOf(Schema.object(properties: [
                    "predecessorID": Schema.string(),
                    "type": Schema.string(enumValues: ["fs", "ff", "ss", "sf"]),
                    "lagDays": Schema.number(),
                ])),
                "constraint": Schema.string(),
                "schedulingPolicy": Schema.string(enumValues: ["asap", "alap"]),
                "assignments": Schema.arrayOf(Schema.object(properties: [
                    "resourceID": Schema.string(),
                    "units": Schema.number(),
                ], required: ["resourceID"])),
                "assignee": Schema.string(),
            ],
            required: ["title"]
        )
    ) { args, session in
        let a = try ToolArgs(args)
        let id = try session.addTask(
            title: a.string("title"),
            kind: a.optionalKind("kind") ?? .task,
            parentID: a.optionalUUID("parentID"),
            effortHours: a.optionalDouble("effortHours"),
            durationDays: a.optionalDouble("durationDays"),
            notes: a.optionalString("notes") ?? "",
            priority: a.optionalPriority("priority") ?? .normal,
            status: a.optionalStatus("status") ?? .pending,
            tags: a.stringArray("tags"),
            dependencies: try a.optionalDependencies("dependencies") ?? [],
            constraint: try a.optionalConstraint("constraint"),
            schedulingPolicy: try a.optionalSchedulingPolicy("schedulingPolicy") ?? .asap,
            assignments: try a.optionalAssignments("assignments") ?? [],
            // 负责人（US-E1-02）：不传或空串 = nil（默认无负责人）；否则设置。
            assignee: a.optionalString("assignee").flatMap { $0.isEmpty ? nil : $0 }
        )
        return .object(["taskID": .string(id.uuidString)])
    }

    private static let taskList = MCPTool(
        name: "task_list",
        description: "列出任务（可按父任务过滤 / 自然语言过滤，US-E4-01）",
        inputSchema: Schema.object(properties: ["parentID": Schema.string(), "filter": Schema.string()])
    ) { args, session in
        let a = try ToolArgs(args)
        let tasks = try session.listTasks(
            parentID: a.optionalUUID("parentID"),
            filter: a.optionalString("filter") ?? ""
        )
        return .object(["tasks": .array(try tasks.map { try JSONValue.json($0) })])
    }

    private static let taskGet = MCPTool(
        name: "task_get",
        description: "获取单个任务（US-E4-01）",
        inputSchema: Schema.object(properties: ["taskID": Schema.string()], required: ["taskID"])
    ) { args, session in
        let a = try ToolArgs(args)
        let task = try session.getTask(id: a.uuid("taskID"))
        return try JSONValue.json(task)
    }

    private static let taskUpdate = MCPTool(
        name: "task_update",
        description: "更新任务字段（US-E1-02；assignee 传空串可清空负责人）",
        inputSchema: Schema.object(
            properties: [
                "taskID": Schema.string(),
                "title": Schema.string(),
                "kind": Schema.string(enumValues: ["task", "group", "milestone"]),
                "parentID": Schema.string(),
                "effortHours": Schema.number(),
                "durationDays": Schema.number(),
                "notes": Schema.string(),
                "priority": Schema.string(enumValues: ["low", "normal", "high", "critical"]),
                "status": Schema.string(enumValues: ["pending", "in_progress", "done", "blocked"]),
                "progress": Schema.number(),
                "tags": Schema.arrayOf(Schema.string()),
                "dependencies": Schema.arrayOf(Schema.object(properties: [
                    "predecessorID": Schema.string(),
                    "type": Schema.string(enumValues: ["fs", "ff", "ss", "sf"]),
                    "lagDays": Schema.number(),
                ])),
                "constraint": Schema.string(),
                "schedulingPolicy": Schema.string(enumValues: ["asap", "alap"]),
                "assignments": Schema.arrayOf(Schema.object(properties: [
                    "resourceID": Schema.string(),
                    "units": Schema.number(),
                ], required: ["resourceID"])),
                "assignee": Schema.string(),
            ],
            required: ["taskID"]
        )
    ) { args, session in
        let a = try ToolArgs(args)
        let task = try session.updateTask(
            id: a.uuid("taskID"),
            title: a.optionalString("title"),
            kind: a.optionalKind("kind"),
            parentID: a.optionalUUID("parentID"),
            effortHours: a.optionalDouble("effortHours"),
            durationDays: a.optionalDouble("durationDays"),
            notes: a.optionalString("notes"),
            priority: a.optionalPriority("priority"),
            status: a.optionalStatus("status"),
            progress: a.optionalDouble("progress"),
            tags: a.optionalStringArray("tags"),
            dependencies: try a.optionalDependencies("dependencies"),
            constraint: try a.optionalConstraint("constraint"),
            schedulingPolicy: try a.optionalSchedulingPolicy("schedulingPolicy"),
            assignments: try a.optionalAssignments("assignments"),
            // 负责人（US-E1-02）：nil = 不改；空串 = 清空（清空在共享层 updateTask 统一处理）。
            assignee: a.optionalString("assignee")
        )
        return try JSONValue.json(task)
    }

    private static let taskDelete = MCPTool(
        name: "task_delete",
        description: "删除任务及其全部子任务，并移除指向它们的相关性（US-E1-02）",
        inputSchema: Schema.object(properties: ["taskID": Schema.string()], required: ["taskID"])
    ) { args, session in
        let a = try ToolArgs(args)
        _ = try session.deleteTask(id: a.uuid("taskID"))
        return .object(["ok": .bool(true)])
    }

    // MARK: wbs

    private static let wbsImport = MCPTool(
        name: "wbs_import",
        description: "批量导入 WBS 嵌套任务树（US-E1-04）",
        inputSchema: Schema.object(properties: ["nodes": Schema.arrayOf(Schema.object(properties: [:]))])
    ) { args, session in
        let a = try ToolArgs(args)
        guard let nodesValue = args?.objectValue?["nodes"] else {
            throw ToolError.invalidArgument(reason: .mcpMissingParam, message: "缺少参数 nodes")
        }
        let nodes = try JSONValue.decode([WBSNode].self, from: nodesValue)
        let result = try session.importWBS(nodes: nodes)
        return .object([
            "rootIDs": .array(result.rootIDs.map { .string($0.uuidString) }),
            "total": .number(Double(result.total)),
            "warnings": .array(result.warnings.map { .string($0) }),
        ])
    }

    // MARK: schedule / violations / status（Sprint 2）

    private static let scheduleCompute = MCPTool(
        name: "schedule_compute",
        description: "计算排期（US-E2-02）：相关性传播 + ASAP/ALAP，返回每任务最早/最晚与选定安排",
        inputSchema: Schema.object(properties: [
            "projectStart": Schema.string(),
            "projectEnd": Schema.string(),
        ])
    ) { args, session in
        let a = try ToolArgs(args)
        let start = try a.optionalISODate("projectStart")
        let end = try a.optionalISODate("projectEnd")
        let result = try session.computeSchedule(projectStart: start, projectEnd: end)
        return try JSONValue.json(result)
    }

    private static let scheduleCriticalPath = MCPTool(
        name: "schedule_critical_path",
        description: "重要路径与宽延（US-E2-03）：总宽延 ≤ slackLimit 的任务集",
        inputSchema: Schema.object(properties: ["slackLimit": Schema.number()])
    ) { args, session in
        let a = try ToolArgs(args)
        let entries = try session.criticalPath(slackLimit: a.optionalDouble("slackLimit"))
        return .object(["criticalPath": .array(try entries.map { try JSONValue.json($0) })])
    }

    private static let violationsList = MCPTool(
        name: "violations_list",
        description: "列出排期违例（US-E2-05）：环、时限冲突、超项目范围等",
        inputSchema: Schema.object(properties: [:])
    ) { _, session in
        let vs = try session.violations()
        // 接口契约（设计 §B）：违例必须带稳定 `code`。`Violation.code` 是由 `reason` 推导的
        // 计算属性，合成编码不会包含它，故在接口层显式投影，避免消费者只能读语义枚举。
        let rows = try vs.map { violation -> JSONValue in
            var object = try JSONValue.json(violation).objectValue ?? [:]
            object["code"] = .string(violation.code.rawValue)
            // 阶段一保持 v0.8.5 的 message（中文），渲染器与 CLI 共用 ViolationText，避免两套文案漂移；
            // 阶段二切英文时只改渲染器语言参数，接口形状不变。
            object["message"] = .string(ViolationText.text(violation, language: .zhHans))
            return .object(object)
        }
        return .object(["violations": .array(rows)])
    }

    private static let statusUpdate = MCPTool(
        name: "status_update",
        description: "单任务状态/进度回写（US-E3-01/02）；状态置 done 记录完成时间，返回群组聚合完成度",
        inputSchema: Schema.object(
            properties: [
                "taskID": Schema.string(),
                "status": Schema.string(enumValues: ["pending", "in_progress", "done", "blocked"]),
                "progress": Schema.number(),
            ],
            required: ["taskID"]
        )
    ) { args, session in
        let a = try ToolArgs(args)
        let task = try session.statusUpdate(
            id: a.uuid("taskID"),
            status: a.optionalStatus("status"),
            progress: a.optionalDouble("progress")
        )
        let group = try session.groupProgress(id: task.id)
        var result = try JSONValue.json(task).objectValue ?? [:]
        result["groupProgress"] = .number(group)
        return .object(result)
    }

    private static let statusBatchUpdate = MCPTool(
        name: "status_batch_update",
        description: "批量回写任务状态/进度（US-E3-02）：返回逐条成功与失败明细，失败项不中断后续条目",
        inputSchema: Schema.object(
            properties: [
                "tasks": Schema.arrayOf(Schema.object(properties: [
                    "taskID": Schema.string(),
                    "status": Schema.string(enumValues: ["pending", "in_progress", "done", "blocked"]),
                    "progress": Schema.number(),
                ], required: ["taskID"])),
            ],
            required: ["tasks"]
        )
    ) { args, session in
        let a = try ToolArgs(args)
        let result = try session.statusBatch(a.statusUpdates("tasks"))
        return try JSONValue.json(result)
    }

    // MARK: resource（US-E1-05）

    private static let resourceAdd = MCPTool(
        name: "resource_add",
        description: "添加资源（US-E1-05）：人员/设备/素材，单位与效率参与投入换算",
        inputSchema: Schema.object(
            properties: [
                "name": Schema.string(),
                "kind": Schema.string(enumValues: ["person", "equipment", "material", "group"]),
                "units": Schema.number(),
                "efficiency": Schema.number(),
            ],
            required: ["name"]
        )
    ) { args, session in
        let a = try ToolArgs(args)
        let id = try session.resourceAdd(
            name: a.string("name"),
            kind: a.optionalResourceKind("kind") ?? .person,
            units: a.optionalDouble("units") ?? 1,
            efficiency: a.optionalDouble("efficiency") ?? 1
        )
        return .object(["resourceID": .string(id.uuidString)])
    }

    private static let resourceList = MCPTool(
        name: "resource_list",
        description: "列出项目资源（US-E1-05）",
        inputSchema: Schema.object(properties: [:])
    ) { _, session in
        let resources = try session.resourceList()
        return .object(["resources": .array(try resources.map { try JSONValue.json($0) })])
    }

    // MARK: baseline（v0.13 / 08-baselines §8）

    private static let baselineCreate = MCPTool(
        name: "baseline_create",
        description: "对当前排期拍一次不可变快照（冻结计划起止与完成度），返回 baselineID/name/colorIndex/createdAt/entryCount；省略 name 用默认名「基线 N · yyyy-MM-dd」，空名报 model_baseline_name_empty（08-baselines §8、10-multi-baseline-gantt §4）",
        inputSchema: Schema.object(properties: ["name": Schema.string()])
    ) { args, session in
        let a = try ToolArgs(args)
        let baseline = try session.createBaseline(name: a.optionalString("name"))
        return BaselineResults.created(baseline, among: try session.baselines())
    }

    private static let baselineList = MCPTool(
        name: "baseline_list",
        description: "按创建顺序（早→晚）列出基线；每项含 baselineID/name/colorIndex/createdAt/entryCount，快照时无排期锚点则不返回 anchor；colorIndex 为 0…7 的调色板索引，旧文件缺该字段时按创建顺序派生（08-baselines §8、10-multi-baseline-gantt §4）",
        inputSchema: Schema.object(properties: [:])
    ) { _, session in
        BaselineResults.list(try session.baselines())
    }

    private static let baselineDelete = MCPTool(
        name: "baseline_delete",
        description: "按 baselineID 删除一条基线，其余基线与任务本身不受影响；返回 ok 与被删基线的 baselineID/name/colorIndex/createdAt，未知 ID 报 model_baseline_not_found（08-baselines §8）",
        inputSchema: Schema.object(properties: ["baselineID": Schema.string()], required: ["baselineID"])
    ) { args, session in
        let a = try ToolArgs(args)
        let id = try a.uuid("baselineID")
        // 回执要带身份三字段：删除后就查不到了，先取（判据 6）。颜色索引同理。
        let baselines = try session.baselines()
        guard let removed = baselines.first(where: { $0.id == id }) else {
            throw ToolError.invalidArgument(
                reason: .baselineNotFound,
                message: "基线不存在：\(id.uuidString)"
            )
        }
        let colorIndex = BaselineResults.colorIndex(of: id, in: baselines)
        try session.deleteBaseline(id: id)
        return .object([
            "ok": .bool(true),
            "baselineID": .string(id.uuidString),
            "name": .string(removed.name),
            "colorIndex": .number(Double(colorIndex)),
            "createdAt": .string(ISO8601DateFormatter().string(from: removed.createdAt)),
        ])
    }

    private static let baselineVariance = MCPTool(
        name: "baseline_variance",
        description: "把当前计划与实际时间分别同基线比较（省略 baselineID = 最新一条）；必带 baselineID/baselineName/colorIndex/baselineCreatedAt；偏差为带符号日历天（正数 = 比承诺晚），空值省略键而不写 0；taskID 只收窄任务行，项目级聚合仍按全项目（08-baselines §4/§8）",
        inputSchema: Schema.object(properties: [
            "baselineID": Schema.string(),
            "taskID": Schema.string(),
        ])
    ) { args, session in
        let a = try ToolArgs(args)
        let report = try session.baselineVariance(baselineID: try a.optionalUUID("baselineID"))
        var taskIDs = BaselineResults.orderedTaskIDs(report, taskOrder: (session.project?.tasks ?? []).map(\.id))
        if let taskID = try a.optionalUUID("taskID") {
            // 未知任务直接报 model_task_not_found：静默返回空数组会让调用方以为「该任务没有偏差」。
            _ = try session.getTask(id: taskID)
            taskIDs = taskIDs.filter { $0 == taskID }
        }
        let colorIndex = BaselineResults.colorIndex(of: report.baselineID, in: try session.baselines())
        return try BaselineResults.variance(report, taskIDs: taskIDs, colorIndex: colorIndex)
    }

    private static let baselineSetColor = MCPTool(
        name: "baseline_set_color",
        description: "给一条基线换调色板颜色（只改颜色索引，不动快照条目与创建时刻）；参数 baselineID 为基线 UUID，colorIndex 为 0…7 的整数，越界或非整数分别报 model_baseline_color_index_invalid / mcp_wrong_type；返回 baselineID/name/colorIndex（10-multi-baseline-gantt §4）",
        inputSchema: Schema.object(
            properties: [
                "baselineID": Schema.string(),
                "colorIndex": Schema.number(),
            ],
            required: ["baselineID", "colorIndex"]
        )
    ) { args, session in
        let a = try ToolArgs(args)
        let id = try a.uuid("baselineID")
        let updated = try session.setBaselineColor(id: id, colorIndex: try a.int("colorIndex"))
        // 回报「会被画出来的那一色」：与 baseline_list / baseline_variance 同口径（整组归一）。
        let colorIndex = BaselineResults.colorIndex(of: id, in: try session.baselines())
        return BaselineResults.recolored(updated, colorIndex: colorIndex)
    }
}

/// 项目工具结果组装（FR-KAIRO-FMT-6）。
enum ProjectResults {
    /// `project_create`：新建项目恒以当前版本落盘，无来源版本。
    static func created(_ meta: ProjectMetadata) -> JSONValue {
        var result = metadataFields(meta)
        result["formatVersion"] = .number(Double(KairoFile.currentFormatVersion))
        return .object(result)
    }

    /// `project_open`：`formatVersion` 为磁盘文件版本；
    /// `currentFormatVersion` / `needsUpgrade` 说明当前目标版本与保存后是否升级。
    /// 打开不改写磁盘，故不报告 `upgradedFrom`。
    static func opened(_ meta: ProjectMetadata, sourceFormatVersion: Int?) -> JSONValue {
        let source = sourceFormatVersion ?? KairoFile.currentFormatVersion
        var result = metadataFields(meta)
        result["formatVersion"] = .number(Double(source))
        result["currentFormatVersion"] = .number(Double(KairoFile.currentFormatVersion))
        result["needsUpgrade"] = .bool(source < KairoFile.currentFormatVersion)
        return .object(result)
    }

    /// `project_save`：`formatVersion` 为写出文件的版本（恒为当前版本）。
    /// `upgradedFrom` 描述写出文件的来源版本，仅当来源早于当前版本时出现；
    /// 目标路径与原路径不同时不改动原文件。
    static func saved(updatedAt: Date, path: String, upgradedFrom: Int?) -> JSONValue {
        var result: [String: JSONValue] = [
            "formatVersion": .number(Double(KairoFile.currentFormatVersion)),
            "savedAt": .string(ISO8601DateFormatter().string(from: updatedAt)),
            "path": .string(path),
        ]
        if let upgradedFrom, upgradedFrom < KairoFile.currentFormatVersion {
            result["upgradedFrom"] = .number(Double(upgradedFrom))
        }
        return .object(result)
    }

    private static func metadataFields(_ meta: ProjectMetadata) -> [String: JSONValue] {
        var result: [String: JSONValue] = [
            "projectID": .string(meta.id.uuidString),
            "title": .string(meta.title),
        ]
        let formatter = ISO8601DateFormatter()
        if let start = meta.projectStart { result["projectStart"] = .string(formatter.string(from: start)) }
        if let end = meta.projectEnd { result["projectEnd"] = .string(formatter.string(from: end)) }
        return result
    }
}

/// 基线工具结果组装（v0.13 / 08-baselines §8）。
///
/// 与 CLI `baseline list|variance --json` 字段名逐字一致：两条出口共用同一组契约名。
/// 偏差数值全部来自 `BaselineEngine`、颜色索引全部来自 `BaselinePalette`，
/// 接口层不自行算偏差、也不自行分配颜色（对等性门禁，判据 12）。
enum BaselineResults {
    /// `baseline_create`：身份 + 颜色索引 + 条目数（条目数决定这次快照覆盖了多少任务）。
    ///
    /// - Parameter baselines: 创建后的整组快照（颜色索引要按整组派生，与 list 同口径）。
    static func created(_ baseline: Baseline, among baselines: [Baseline]) -> JSONValue {
        .object([
            "baselineID": .string(baseline.id.uuidString),
            "name": .string(baseline.name),
            "colorIndex": .number(Double(colorIndex(of: baseline.id, in: baselines))),
            "createdAt": .string(ISO8601DateFormatter().string(from: baseline.createdAt)),
            "entryCount": .number(Double(baseline.entries.count)),
        ])
    }

    /// `baseline_set_color`：改色回执（名称 + 新颜色索引，身份字段便于脚本核对改到了哪条）。
    static func recolored(_ baseline: Baseline, colorIndex: Int) -> JSONValue {
        .object([
            "baselineID": .string(baseline.id.uuidString),
            "name": .string(baseline.name),
            "colorIndex": .number(Double(colorIndex)),
        ])
    }

    /// 指定基线的读路径颜色索引：整组交给 `BaselinePalette.resolve` 归一
    /// （nil / 越界 / 重复都派生），不写死 0 冒充「第 1 色」。
    ///
    /// - Parameter id: 目标基线；不在 `baselines` 里时（调用方传错了快照）按
    ///   「如新建一条」的最小未用索引给出合法值。
    static func colorIndex(of id: UUID, in baselines: [Baseline]) -> Int {
        let colors = BaselinePalette.resolve(baselines.map(\.colorIndex))
        if let position = baselines.firstIndex(where: { $0.id == id }) {
            return colors[position]
        }
        return BaselinePalette.colorIndex(for: baselines)
    }

    /// `baseline_list`：按创建顺序；`anchor` 缺失不写键。
    static func list(_ baselines: [Baseline]) -> JSONValue {
        let formatter = ISO8601DateFormatter()
        let colors = BaselinePalette.resolve(baselines.map(\.colorIndex))
        let rows = zip(baselines, colors).map { baseline, colorIndex -> JSONValue in
            var fields: [String: JSONValue] = [
                "baselineID": .string(baseline.id.uuidString),
                "name": .string(baseline.name),
                "colorIndex": .number(Double(colorIndex)),
                "createdAt": .string(formatter.string(from: baseline.createdAt)),
                "entryCount": .number(Double(baseline.entries.count)),
            ]
            if let anchor = baseline.anchor {
                fields["anchor"] = .string(formatter.string(from: anchor))
            }
            return .object(fields)
        }
        return .object(["baselines": .array(rows)])
    }

    /// `baseline_variance`：字段与 `BaselineVarianceReport` / `TaskVariance` 同名同义。
    ///
    /// - 空值（`nil`）**不写键**：写 0 会把「没有数据」冒充成「准时」（§4.1）；
    /// - 偏差是整数天，负数原样带 `-`；
    /// - 需按 `taskIDs` 的行序输出（调用方按大纲顺序给出），字典键序不稳定。
    /// - Parameter colorIndex: 该基线在整组里的调色板索引（调用方用 `colorIndex(of:in:)` 派生）。
    static func variance(
        _ report: BaselineVarianceReport,
        taskIDs: [UUID],
        colorIndex: Int
    ) throws -> JSONValue {
        let formatter = ISO8601DateFormatter()
        var fields: [String: JSONValue] = [
            "baselineID": .string(report.baselineID.uuidString),
            "baselineName": .string(report.baselineName),
            "colorIndex": .number(Double(colorIndex)),
            "baselineCreatedAt": .string(formatter.string(from: report.baselineCreatedAt)),
            "lateTaskCount": .number(Double(report.lateTaskCount)),
            "overdueOpenCount": .number(Double(report.overdueOpenCount)),
            "tasksWithoutBaseline": .number(Double(report.tasksWithoutBaseline)),
            "predictedTaskCount": .number(Double(report.predictedTaskCount)),
            "tasks": .array(taskIDs.compactMap { id in report.tasks[id].map(taskRow) }),
            "orphans": .array(try report.orphans.map { try JSONValue.json($0) }),
        ]
        if let projectFinishVariance = report.projectFinishVariance {
            fields["projectFinishVariance"] = .number(Double(projectFinishVariance))
        }
        return .object(fields)
    }

    /// 偏差行的稳定顺序：先按项目大纲顺序，报告里多出的任务按 UUID 排序兜底。
    static func orderedTaskIDs(_ report: BaselineVarianceReport, taskOrder: [UUID]) -> [UUID] {
        var seen: Set<UUID> = []
        var result: [UUID] = []
        for id in taskOrder where report.tasks[id] != nil {
            if seen.insert(id).inserted { result.append(id) }
        }
        result.append(contentsOf: report.tasks.keys.filter { !seen.contains($0) }.sorted { $0.uuidString < $1.uuidString })
        return result
    }

    /// 单任务偏差：空值省略键，正负号原样保留。
    private static func taskRow(_ variance: TaskVariance) -> JSONValue {
        let formatter = ISO8601DateFormatter()
        var fields: [String: JSONValue] = [
            "taskID": .string(variance.taskID.uuidString),
            "hasBaseline": .bool(variance.hasBaseline),
            "isForecast": .bool(variance.isForecast),
        ]
        if let start = variance.baselineStart {
            fields["baselineStart"] = .string(formatter.string(from: start))
        }
        if let finish = variance.baselineFinish {
            fields["baselineFinish"] = .string(formatter.string(from: finish))
        }
        let days: [(String, Int?)] = [
            ("planStartVariance", variance.planStartVariance),
            ("planFinishVariance", variance.planFinishVariance),
            ("actualStartVariance", variance.actualStartVariance),
            ("actualFinishVariance", variance.actualFinishVariance),
            ("overdueDays", variance.overdueDays),
            ("durationVariance", variance.durationVariance),
        ]
        for (key, value) in days {
            if let value { fields[key] = .number(Double(value)) }
        }
        return .object(fields)
    }
}

// MARK: - JSON Schema 构造

private enum Schema {
    static func object(properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        return .object(schema)
    }

    static func string(enumValues: [String]? = nil) -> JSONValue {
        guard let enumValues else { return .object(["type": .string("string")]) }
        return .object([
            "type": .string("string"),
            "enum": .array(enumValues.map { .string($0) }),
        ])
    }

    static func number() -> JSONValue {
        .object(["type": .string("number")])
    }

    static func arrayOf(_ item: JSONValue) -> JSONValue {
        .object(["type": .string("array"), "items": item])
    }
}

// MARK: - 参数解析

private struct ToolArgs {
    private let dict: [String: JSONValue]

    init(_ value: JSONValue?) throws {
        guard let object = value?.objectValue else {
            throw ToolError.invalidArgument(reason: .mcpWrongType, message: "参数必须是 JSON 对象")
        }
        dict = object
    }

    func string(_ key: String) throws -> String {
        guard let value = dict[key]?.stringValue, !value.isEmpty else {
            throw ToolError.invalidArgument(reason: .mcpMissingParam, message: "缺少参数 \(key)")
        }
        return value
    }

    func uuid(_ key: String) throws -> UUID {
        guard let uuid = try optionalUUID(key) else {
            throw ToolError.invalidArgument(reason: .mcpMissingParam, message: "缺少参数 \(key)")
        }
        return uuid
    }

    func optionalString(_ key: String) -> String? {
        dict[key]?.stringValue
    }

    func optionalDouble(_ key: String) -> Double? {
        dict[key]?.doubleValue
    }

    /// 整数参数（如调色板索引）：缺失报 mcp_missing_param；带小数或非数字报 mcp_wrong_type。
    ///
    /// 不静默截断 3.5 → 3：截断会让调用方以为改成了自己请求的颜色。
    /// 范围校验不在这里做——0…7 由会话层统一拒绝（一个地方判范围）。
    func int(_ key: String) throws -> Int {
        guard let raw = dict[key] else {
            throw ToolError.invalidArgument(reason: .mcpMissingParam, message: "缺少参数 \(key)")
        }
        guard let number = raw.doubleValue, let value = Int(exactly: number) else {
            throw ToolError.invalidArgument(reason: .mcpWrongType, message: "参数 \(key) 必须是整数")
        }
        return value
    }

    func optionalUUID(_ key: String) throws -> UUID? {
        guard let raw = dict[key]?.stringValue else { return nil }
        guard let uuid = UUID(uuidString: raw) else {
            throw ToolError.invalidArgument(reason: .mcpMalformedUUID, message: "参数 \(key) 不是合法 UUID：\(raw)")
        }
        return uuid
    }

    func optionalISODate(_ key: String) throws -> Date? {
        guard let raw = dict[key]?.stringValue else { return nil }
        guard let date = ISO8601DateFormatter().date(from: raw) else {
            throw ToolError.invalidArgument(reason: .mcpMalformedDate, message: "参数 \(key) 不是合法 ISO8601 日期：\(raw)")
        }
        return date
    }

    /// 时限规格：type:ISO8601（如 startNoLaterThan:2026-11-05T00:00:00Z）。
    /// 相关性数组：元素 {"predecessorID":"UUID","type":"fs","lagDays":0}，type/lagDays 可省略。
    func optionalDependencies(_ key: String) throws -> [TaskDependency]? {
        guard let value = dict[key] else { return nil }
        guard let array = value.arrayValue else {
            throw ToolError.invalidArgument(reason: .mcpWrongType, message: "参数 \(key) 必须是数组")
        }
        return try array.map { item in
            guard let obj = item.objectValue,
                  let rawID = obj["predecessorID"]?.stringValue,
                  let uuid = UUID(uuidString: rawID) else {
                throw ToolError.invalidArgument(
                    reason: .mcpMalformedDependency,
                    message: "参数 \(key) 的元素格式应为 {\"predecessorID\":\"UUID\",\"type\":\"fs\",\"lagDays\":0}"
                )
            }
            let type: TaskDependency.DependencyType
            if let rawType = obj["type"]?.stringValue {
                guard let parsed = TaskDependency.DependencyType(rawValue: rawType) else {
                    throw ToolError.invalidArgument(
                    reason: .mcpMalformedDependency,
                    message: "参数 \(key) 的相关性类型非法：\(rawType)（fs/ff/ss/sf）"
                )
                }
                type = parsed
            } else {
                type = .fs
            }
            return TaskDependency(
                predecessorID: uuid,
                type: type,
                lagDays: obj["lagDays"]?.doubleValue ?? 0
            )
        }
    }

    /// 分配数组：元素 {"resourceID":"UUID","units":1}，units 可省略（默认 1）。
    func optionalAssignments(_ key: String) throws -> [TaskAssignment]? {
        guard let value = dict[key] else { return nil }
        guard let array = value.arrayValue else {
            throw ToolError.invalidArgument(reason: .mcpWrongType, message: "参数 \(key) 必须是数组")
        }
        return try array.map { item in
            guard let obj = item.objectValue,
                  let rawID = obj["resourceID"]?.stringValue,
                  let uuid = UUID(uuidString: rawID) else {
                throw ToolError.invalidArgument(
                    reason: .mcpMalformedAssignment,
                    message: "参数 \(key) 的元素格式应为 {\"resourceID\":\"UUID\",\"units\":1}"
                )
            }
            return TaskAssignment(resourceID: uuid, units: obj["units"]?.doubleValue ?? 1)
        }
    }

    func optionalConstraint(_ key: String) throws -> SchedulingConstraint? {
        guard let raw = dict[key]?.stringValue else { return nil }
        let parts = raw.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let date = ISO8601DateFormatter().date(from: String(parts[1])) else {
            throw ToolError.invalidArgument(
                reason: .mcpMalformedConstraint,
                message: "参数 \(key) 格式应为 type:ISO8601（如 startNoLaterThan:2026-11-05T00:00:00Z）"
            )
        }
        switch String(parts[0]) {
        case "startNoEarlierThan": return .startNoEarlierThan(date)
        case "startNoLaterThan": return .startNoLaterThan(date)
        case "endNoEarlierThan": return .endNoEarlierThan(date)
        case "endNoLaterThan": return .endNoLaterThan(date)
        default:
            throw ToolError.invalidArgument(reason: .mcpMalformedConstraint, message: "参数 \(key) 非法时限类型：\(parts[0])")
        }
    }

    func optionalSchedulingPolicy(_ key: String) throws -> SchedulingPolicy? {
        guard let raw = dict[key]?.stringValue else { return nil }
        guard let policy = SchedulingPolicy(rawValue: raw) else {
            throw ToolError.invalidArgument(reason: .mcpInvalidEnum, message: "参数 \(key) 非法：\(raw)（asap/alap）")
        }
        return policy
    }

    func optionalKind(_ key: String) throws -> TaskKind? {
        guard let raw = dict[key]?.stringValue else { return nil }
        guard let kind = TaskKind(rawValue: raw) else {
            throw ToolError.invalidArgument(reason: .mcpInvalidEnum, message: "参数 \(key) 非法：\(raw)（task/group/milestone）")
        }
        return kind
    }

    func optionalPriority(_ key: String) throws -> TaskPriority? {
        guard let raw = dict[key]?.stringValue else { return nil }
        guard let priority = TaskPriority(rawValue: raw) else {
            throw ToolError.invalidArgument(reason: .mcpInvalidEnum, message: "参数 \(key) 非法：\(raw)（low/normal/high/critical）")
        }
        return priority
    }

    func optionalStatus(_ key: String) throws -> TaskStatus? {
        guard let raw = dict[key]?.stringValue else { return nil }
        guard let status = TaskStatus(rawValue: raw) else {
            throw ToolError.invalidArgument(reason: .mcpInvalidEnum, message: "参数 \(key) 非法：\(raw)（pending/in_progress/done/blocked）")
        }
        return status
    }

    func optionalResourceKind(_ key: String) throws -> ResourceKind? {
        guard let raw = dict[key]?.stringValue else { return nil }
        guard let kind = ResourceKind(rawValue: raw) else {
            throw ToolError.invalidArgument(reason: .mcpInvalidEnum, message: "参数 \(key) 非法：\(raw)（person/equipment/material/group）")
        }
        return kind
    }

    /// 批量回写清单：[{"taskID":"UUID","status":"done","progress":1}]。
    func statusUpdates(_ key: String) throws -> [KairoSession.StatusUpdateInput] {
        guard let array = dict[key]?.arrayValue else {
            throw ToolError.invalidArgument(reason: .mcpWrongType, message: "参数 \(key) 必须是数组")
        }
        return try array.map { item in
            guard let obj = item.objectValue,
                  let rawID = obj["taskID"]?.stringValue,
                  let uuid = UUID(uuidString: rawID) else {
                throw ToolError.invalidArgument(
                    reason: .mcpMalformedBatchItem,
                    message: "参数 \(key) 的元素格式应为 {\"taskID\":\"UUID\",\"status\":\"done\",\"progress\":1}"
                )
            }
            let status: TaskStatus?
            if let rawStatus = obj["status"]?.stringValue {
                guard let parsed = TaskStatus(rawValue: rawStatus) else {
                    throw ToolError.invalidArgument(
                        reason: .mcpMalformedBatchItem,
                        message: "参数 \(key) 的状态非法：\(rawStatus)（pending/in_progress/done/blocked）"
                    )
                }
                status = parsed
            } else {
                status = nil
            }
            return KairoSession.StatusUpdateInput(
                taskID: uuid,
                status: status,
                progress: obj["progress"]?.doubleValue
            )
        }
    }

    func stringArray(_ key: String) -> [String] {
        dict[key]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    func optionalStringArray(_ key: String) -> [String]? {
        guard let value = dict[key] else { return nil }
        return value.arrayValue?.compactMap(\.stringValue)
    }
}
