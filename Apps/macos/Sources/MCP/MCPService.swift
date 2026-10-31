import Foundation
import KaidoMCPCore

/// 应用内 MCP 服务（App Store 版）：开关、端点、token、客户端配置片段。
///
/// 商店版必须自带 MCP——外部客户端自己 spawn 子进程的方案在沙盒里读不到用户文件。
/// 服务默认关闭：监听端口是敏感能力，由用户显式打开，开关状态与 token 都存在本机。
@MainActor
final class MCPService: ObservableObject {
    enum Status: Equatable {
        case stopped
        case starting
        case running(port: UInt16)
        case failed(String)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    /// `UserDefaults` 键；改结构时递增版本后缀。
    static let defaultsKey = "kaido.mcp.service.v1"

    @Published private(set) var status: Status = .stopped
    /// 最近一次成功监听的端口。持久化给 `--cli` 瘦客户端读（它拿不到内存状态）。
    @Published private(set) var port: UInt16?
    /// 服务开关。改动立即生效并持久化。
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            persist()
            isEnabled ? start() : stop()
        }
    }
    /// 访问 token。每位用户一份，可重置（重置会让旧配置片段立刻失效）。
    @Published private(set) var token: String

    /// 授权目录（MCP 可读写的路径白名单）。
    let authorization: MCPAuthorizationStore

    private let defaults: UserDefaults
    private var server: MCPHTTPServer?

    init(defaults: UserDefaults = .standard, authorization: MCPAuthorizationStore? = nil) {
        self.defaults = defaults
        self.authorization = authorization ?? MCPAuthorizationStore(defaults: defaults)
        let stored = defaults.dictionary(forKey: Self.defaultsKey) ?? [:]
        self.token = stored["token"] as? String ?? Self.makeToken()
        self.isEnabled = stored["enabled"] as? Bool ?? false
        persist()
        // 上次退出时是开着的，就恢复监听（端口重新分配，配置片段里的端口会变）。
        if isEnabled {
            start()
        }
    }

    deinit {
        server?.stop()
    }

    /// 当前端点；未运行时为 nil。
    var endpoint: String? {
        guard case .running(let port) = status else { return nil }
        return "http://127.0.0.1:\(port)/mcp"
    }

    /// 给客户端粘贴的 JSON 片段（Claude Desktop / Claude Code 的 `mcpServers` 结构）。
    var clientConfiguration: String {
        let url = endpoint ?? "http://127.0.0.1:<port>/mcp (start the service first)"
        return """
        {
          "mcpServers": {
            "kaido": {
              "url": "\(url)",
              "headers": { "Authorization": "Bearer \(token)" }
            }
          }
        }
        """
    }

    func start() {
        guard server == nil else { return }
        let http = MCPHTTPServer(
            token: token,
            server: MCPServer(pathPolicy: authorization)
        )
        server = http
        status = .starting
        http.start(requestedPort: 0, onReady: { [weak self] port in
            Task { @MainActor in
                self?.status = .running(port: port)
                self?.port = port
                self?.persist()
            }
        }, onFailure: { [weak self] message in
            Task { @MainActor in
                self?.status = .failed(message)
                self?.server = nil
            }
        })
    }

    func stop() {
        server?.stop()
        server = nil
        status = .stopped
    }

    /// 换一份 token：旧配置片段立刻失效，服务已在运行时按新 token 重建监听。
    func regenerateToken() {
        token = Self.makeToken()
        persist()
        if isEnabled {
            stop()
            start()
        }
    }

    private func persist() {
        var values: [String: Any] = ["enabled": isEnabled, "token": token]
        if let port { values["port"] = Int(port) }
        defaults.set(values, forKey: Self.defaultsKey)
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
