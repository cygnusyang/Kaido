import Foundation
import KairoCore
import KairoCommands

/// 工具层错误：非法参数（架构 §3.1 错误契约的 argument 类）。
enum ToolError: Error, Equatable, CustomStringConvertible {
    case invalidArgument(String)

    var description: String {
        switch self {
        case .invalidArgument(let message): return message
        }
    }
}

/// 结构化工具失败（架构 §3.1：{code, message, taskID?}）。
struct ToolFailure: Encodable {
    var code: String
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
        ]
    }

    // MARK: project

    private static let projectCreate = MCPTool(
        name: "project_create",
        description: "新建项目并打开（US-E1-01）",
        inputSchema: Schema.object(properties: ["title": Schema.string()], required: ["title"])
    ) { args, session in
        let a = try ToolArgs(args)
        let meta = try session.createProject(title: a.string("title"))
        return try ProjectResults.metadata(meta)
    }

    private static let projectOpen = MCPTool(
        name: "project_open",
        description: "打开 .kairo 项目文件（US-E6-01）",
        inputSchema: Schema.object(properties: ["path": Schema.string()], required: ["path"])
    ) { args, session in
        let a = try ToolArgs(args)
        let meta = try session.openProject(at: URL(fileURLWithPath: a.string("path")))
        return try ProjectResults.metadata(meta)
    }

    private static let projectSave = MCPTool(
        name: "project_save",
        description: "保存当前项目为 .kairo（未指定路径时保存到已打开文件）",
        inputSchema: Schema.object(properties: ["path": Schema.string()])
    ) { args, session in
        let a = try ToolArgs(args)
        let target = a.optionalString("path").map { URL(fileURLWithPath: $0) }
        let meta = try session.saveProject(to: target)
        let path = session.projectURL?.path ?? ""
        return .object([
            "savedAt": .string(ISO8601DateFormatter().string(from: meta.updatedAt)),
            "path": .string(path),
        ])
    }

    // MARK: task

    private static let taskAdd = MCPTool(
        name: "task_add",
        description: "创建任务（US-E1-02）",
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
            tags: a.stringArray("tags")
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
        description: "更新任务字段（US-E1-02）",
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
            tags: a.optionalStringArray("tags")
        )
        return try JSONValue.json(task)
    }

    private static let taskDelete = MCPTool(
        name: "task_delete",
        description: "删除任务并移除指向它的相关性（US-E1-02）",
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
            throw ToolError.invalidArgument("缺少参数 nodes")
        }
        let nodes = try JSONValue.decode([WBSNode].self, from: nodesValue)
        let result = try session.importWBS(nodes: nodes)
        return .object([
            "rootIDs": .array(result.rootIDs.map { .string($0.uuidString) }),
            "total": .number(Double(result.total)),
            "warnings": .array(result.warnings.map { .string($0) }),
        ])
    }
}

/// 项目工具结果组装。
private enum ProjectResults {
    static func metadata(_ meta: ProjectMetadata) throws -> JSONValue {
        .object([
            "projectID": .string(meta.id.uuidString),
            "title": .string(meta.title),
        ])
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
            throw ToolError.invalidArgument("参数必须是 JSON 对象")
        }
        dict = object
    }

    func string(_ key: String) throws -> String {
        guard let value = dict[key]?.stringValue, !value.isEmpty else {
            throw ToolError.invalidArgument("缺少参数 \(key)")
        }
        return value
    }

    func uuid(_ key: String) throws -> UUID {
        guard let uuid = try optionalUUID(key) else {
            throw ToolError.invalidArgument("缺少参数 \(key)")
        }
        return uuid
    }

    func optionalString(_ key: String) -> String? {
        dict[key]?.stringValue
    }

    func optionalDouble(_ key: String) -> Double? {
        dict[key]?.doubleValue
    }

    func optionalUUID(_ key: String) throws -> UUID? {
        guard let raw = dict[key]?.stringValue else { return nil }
        guard let uuid = UUID(uuidString: raw) else {
            throw ToolError.invalidArgument("参数 \(key) 不是合法 UUID：\(raw)")
        }
        return uuid
    }

    func optionalKind(_ key: String) throws -> TaskKind? {
        guard let raw = dict[key]?.stringValue else { return nil }
        guard let kind = TaskKind(rawValue: raw) else {
            throw ToolError.invalidArgument("参数 \(key) 非法：\(raw)（task/group/milestone）")
        }
        return kind
    }

    func optionalPriority(_ key: String) throws -> TaskPriority? {
        guard let raw = dict[key]?.stringValue else { return nil }
        guard let priority = TaskPriority(rawValue: raw) else {
            throw ToolError.invalidArgument("参数 \(key) 非法：\(raw)（low/normal/high/critical）")
        }
        return priority
    }

    func optionalStatus(_ key: String) throws -> TaskStatus? {
        guard let raw = dict[key]?.stringValue else { return nil }
        guard let status = TaskStatus(rawValue: raw) else {
            throw ToolError.invalidArgument("参数 \(key) 非法：\(raw)（pending/in_progress/done/blocked）")
        }
        return status
    }

    func stringArray(_ key: String) -> [String] {
        dict[key]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    func optionalStringArray(_ key: String) -> [String]? {
        guard let value = dict[key] else { return nil }
        return value.arrayValue?.compactMap(\.stringValue)
    }
}
