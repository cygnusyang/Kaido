import Foundation
import KaidoCore
import KaidoCommands

/// MCP 服务核心：逐行 JSON-RPC 2.0 传输（ADR-010 零第三方依赖）。
/// 方法面：initialize / tools/list / tools/call / ping + 通知（不响应）。
/// 与工具层（Tools.swift）分离，可单测。
public final class MCPServer {
    static let protocolVersion = "2024-11-05"
    static let serverInfo: [String: String] = ["name": "kaido", "version": "2.1.0"]

    private let registry: ToolRegistry
    private let session: KaidoSession
    private let pathPolicy: MCPPathPolicy
    private var negotiatedProtocolVersion: String?

    /// 默认装配：内置工具表 + 独立会话 + 不限制路径（官网版）。
    public convenience init() {
        self.init(pathPolicy: AllowAllPaths())
    }

    /// App Store 版装配：路径按用户授权目录白名单校验。
    public init(pathPolicy: MCPPathPolicy) {
        self.registry = ToolRegistry()
        self.session = KaidoSession()
        self.pathPolicy = pathPolicy
    }

    /// 测试注入缝：复用调用方准备好的会话（如已 adopt 旧格式的会话）。
    init(session: KaidoSession, pathPolicy: MCPPathPolicy = AllowAllPaths()) {
        self.registry = ToolRegistry()
        self.session = session
        self.pathPolicy = pathPolicy
    }

    /// 处理一行请求 JSON，返回一行响应 JSON；通知返回 nil。
    public func handle(requestJSON: String) -> String? {
        guard let request = try? JSONDecoder().decode(JSONRPCRequest.self, from: Data(requestJSON.utf8)) else {
            return encode(.failure(
                JSONRPCErrorObject(
                    code: JSONRPCErrorCode.parseError,
                    reason: KaidoErrorCode.mcpParseError.rawValue,
                    message: "解析失败：无效的 JSON-RPC"
                ),
                id: extractID(from: requestJSON)
            ))
        }
        if request.isNotification {
            handleNotification(request)
            return nil
        }
        return encode(dispatch(request))
    }

    private func dispatch(_ request: JSONRPCRequest) -> JSONRPCResponse {
        switch request.method {
        case "initialize":
            return .ok(initializeResult(request), id: request.id)
        case "tools/list":
            return .ok(toolsListResult(), id: request.id)
        case "tools/call":
            return callTool(request)
        case "ping":
            return .ok(.object([:]), id: request.id)
        default:
            return .failure(
                JSONRPCErrorObject(
                    code: JSONRPCErrorCode.methodNotFound,
                    reason: KaidoErrorCode.mcpMethodNotFound.rawValue,
                    message: "未知方法：\(request.method)"
                ),
                id: request.id
            )
        }
    }

    private func handleNotification(_ request: JSONRPCRequest) {
        // 当前仅接收 notifications/initialized；无需动作。
        _ = request
    }

    private func initializeResult(_ request: JSONRPCRequest) -> JSONValue {
        if let version = request.params?.objectValue?["protocolVersion"]?.stringValue {
            negotiatedProtocolVersion = version
        }
        return .object([
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": .object(["tools": .object([:])]),
            "serverInfo": .object(Self.serverInfo.mapValues { .string($0) }),
        ])
    }

    private func toolsListResult() -> JSONValue {
        let tools: [JSONValue] = registry.tools.map { tool in
            .object([
                "name": .string(tool.name),
                "description": .string(tool.description),
                "inputSchema": tool.inputSchema,
            ])
        }
        return .object(["tools": .array(tools)])
    }

    private func callTool(_ request: JSONRPCRequest) -> JSONRPCResponse {
        let params = request.params?.objectValue ?? [:]
        guard let name = params["name"]?.stringValue else {
            return .failure(
                JSONRPCErrorObject(
                    code: JSONRPCErrorCode.invalidParams,
                    reason: KaidoErrorCode.mcpMissingToolName.rawValue,
                    message: "tools/call 缺少 name"
                ),
                id: request.id
            )
        }
        guard let tool = registry.find(name) else {
            return .failure(
                JSONRPCErrorObject(
                    code: JSONRPCErrorCode.methodNotFound,
                    reason: KaidoErrorCode.mcpUnknownTool.rawValue,
                    message: "未知工具：\(name)"
                ),
                id: request.id
            )
        }
        let arguments = params["arguments"]
        do {
            // 路径准入：只有 project_open / project_save 收路径参数，统一在这里拦。
            // 拦在调用前，避免半途写出半个文件、也避免把「未授权」误报成「文件不存在」。
            if let raw = arguments?.objectValue?["path"]?.stringValue,
               !pathPolicy.allows(URL(fileURLWithPath: raw)) {
                throw ToolError.invalidArgument(
                    reason: .mcpPathNotAuthorized,
                    message: "路径不在已授权目录内：\(raw)"
                )
            }
            let result = try tool.handler(arguments, session)
            let text = try encodeText(result)
            return .ok(
                .object([
                    "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                    "isError": .bool(false),
                ]),
                id: request.id
            )
        } catch {
            let failure = self.failure(from: error)
            let text = (try? encodeText(.json(failure))) ?? "{\"code\":\"internal_error\",\"reason\":\"internal_error\"}"
            return .ok(
                .object([
                    "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                    "isError": .bool(true),
                ]),
                id: request.id
            )
        }
    }

    /// 映射错误为结构化失败（架构 §3.1 错误契约）。
    ///
    /// `code` 是冻结的粗粒度分类（不改取值），`reason` 是本版新增的细粒度稳定码；
    /// `message` 阶段一保持中文原样（设计 §6：先给码，v0.10.0 再切英文）。
    private func failure(from error: Error) -> ToolFailure {
        switch error {
        case let sessionError as SessionError:
            return ToolFailure(
                code: sessionError.code.rawValue,
                reason: sessionError.reason.rawValue,
                message: sessionError.message,
                taskID: sessionError.taskID?.uuidString
            )
        case let toolError as ToolError:
            return ToolFailure(
                code: "invalid_argument",
                reason: toolError.reason.rawValue,
                message: toolError.description,
                taskID: nil
            )
        default:
            return ToolFailure(
                code: "internal_error",
                reason: KaidoErrorCode.internalError.rawValue,
                message: "\(error)",
                taskID: nil
            )
        }
    }

    private func encode(_ response: JSONRPCResponse) -> String? {
        guard let data = try? makeEncoder().encode(response) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func encodeText(_ value: JSONValue) throws -> String {
        let data = try makeEncoder().encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// 统一的响应编码器：键序固定为字典序。
    ///
    /// 为什么必须排序：`JSONValue` 用 Swift `Dictionary` 承载对象，遍历顺序随进程种子变化，
    /// 同一请求两次运行的字节可能不同——「任意 LANG 下输出逐字节一致」无法成立，
    /// 日志 diff 与首轮提示词缓存也会无谓抖动。`.sortedKeys` 作用在 keyed container 的
    /// 输出阶段，字典插入顺序被覆盖，`JSONValue.encode` 无需改动。
    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// 从无法反序列化的文本里尽力取出 id（parse error 响应用）。
    private func extractID(from raw: String) -> JSONValue? {
        guard let object = (try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)))?.objectValue else {
            return nil
        }
        return object["id"]
    }
}
