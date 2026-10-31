import Foundation
import Network
import KaidoMCPCore

/// App Store 版的 MCP 传输：本地回环 HTTP（`POST /mcp`）。
///
/// 为什么不用 stdio：沙盒里由外部客户端 spawn 的子进程读不到容器外文件，
/// MCP 全部工具都按绝对路径工作，那条路必然失败。服务改由 app 进程自己托管，
/// 工具继承 app 的安全作用域授权，客户端只连回环地址。
///
/// 安全：只绑 127.0.0.1（非 `all`），并且每个请求都要带 token；
/// token 由 app 生成、可在设置面板查看与重置。
final class MCPHTTPServer {
    enum StartFailure: Error, CustomStringConvertible {
        case bind(String)

        var description: String {
            switch self {
            case .bind(let detail): return detail
            }
        }
    }

    /// 单条请求上限：MCP 工具参数都是小 JSON，超过这个量级基本是误连或攻击。
    private static let maxRequestBytes = 8 * 1024 * 1024

    private let server: MCPServer
    private let token: String
    private let queue = DispatchQueue(label: "top.cygnusyang.kaido.mcp.http")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private(set) var port: UInt16 = 0

    init(token: String, server: MCPServer) {
        self.token = token
        self.server = server
    }

    /// 启动监听。`requestedPort` 为 0 时由系统分配，实际端口用回调带回。
    func start(requestedPort: UInt16, onReady: @escaping (UInt16) -> Void, onFailure: @escaping (String) -> Void) {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: requestedPort) ?? .any
        )
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            onFailure("Cannot create listener: \(error.localizedDescription)")
            return
        }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let actual = listener.port?.rawValue ?? 0
                self.port = actual
                onReady(actual)
            case .failed(let error):
                onFailure("Failed to listen: \(error.localizedDescription)")
                self.stop()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
    }

    // MARK: - 连接

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.queue.async { self?.connections[id] = nil }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }
            if buffer.count > Self.maxRequestBytes {
                self.respond(connection, status: 413, body: Data("{\"error\":\"request_too_large\"}".utf8))
                return
            }
            if let request = HTTPRequest.parse(buffer) {
                self.handle(request, on: connection)
                return
            }
            if error != nil || isComplete {
                connection.cancel()
                self.connections[ObjectIdentifier(connection)] = nil
                return
            }
            self.receive(connection, buffer: buffer)
        }
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) {
        guard request.path == "/mcp" else {
            respond(connection, status: 404, body: Data("{\"error\":\"not_found\"}".utf8))
            return
        }
        guard request.method == "POST" else {
            respond(connection, status: 405, body: Data("{\"error\":\"method_not_allowed\"}".utf8), extraHeaders: ["Allow" : "POST"])
            return
        }
        guard request.token == token else {
            respond(connection, status: 401, body: Data("{\"error\":\"unauthorized\"}".utf8), extraHeaders: ["WWW-Authenticate" : "Bearer"])
            return
        }
        guard let text = String(data: request.body, encoding: .utf8) else {
            respond(connection, status: 400, body: Data("{\"error\":\"invalid_encoding\"}".utf8))
            return
        }
        // 通知没有响应体：MCP 规定返回 202 且空 body。
        guard let response = server.handle(requestJSON: text) else {
            respond(connection, status: 202, body: Data())
            return
        }
        respond(connection, status: 200, body: Data(response.utf8))
    }

    private func respond(
        _ connection: NWConnection,
        status: Int,
        body: Data,
        extraHeaders: [String: String] = [:]
    ) {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        for (key, value) in extraHeaders {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            self?.connections[ObjectIdentifier(connection)] = nil
        })
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        default: return "Error"
        }
    }
}

/// 最小 HTTP/1.1 请求解析：够 MCP 客户端用即可（单请求、Content-Length、无 chunked）。
struct HTTPRequest {
    let method: String
    let path: String
    let token: String?
    let body: Data

    /// 解析未完成（头部不全或 body 未到齐）时返回 nil，调用方继续收。
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        let method = String(requestLine[0])
        let target = String(requestLine[1])
        let path = target.split(separator: "?").first.map(String.init) ?? target

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.count >= bodyStart + length else { return nil }
        let body = data.subdata(in: bodyStart..<(bodyStart + length))

        var token = headers["x-kaido-token"]
        if token == nil, let auth = headers["authorization"] {
            let parts = auth.split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "bearer" {
                token = String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        return HTTPRequest(method: method, path: path, token: token, body: body)
    }
}
