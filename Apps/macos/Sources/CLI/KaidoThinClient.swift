import Foundation

/// 商店版的命令行入口：同一个可执行文件的 `--cli` 模式。
///
/// 沙盒里没有独立的 `kaido` 可执行文件可装（不能往 /usr/local/bin 写，也不许
/// 往 bundle 外下发可执行文件），而外部进程 spawn 子进程后读不到用户文件。
/// 因此 CLI 退化成瘦客户端：参数原样转成 MCP 请求，由运行中的 app 执行。
///
/// 用法：
///   Kaido --cli                         显示帮助
///   Kaido --cli tools                   列出工具（tools/list）
///   Kaido --cli call <tool> [json]      调用工具（tools/call），json 省略为 {}
enum KaidoThinClient {
    private static let newline = String(UnicodeScalar(10))

    /// 命中 `--cli` 时执行并返回退出码；未命中返回 nil（调用方继续正常启动 app）。
    static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Int32? {
        guard let index = arguments.firstIndex(of: "--cli") else { return nil }
        return run(Array(arguments.dropFirst(index + 1)))
    }

    private static func run(_ arguments: [String]) -> Int32 {
        guard let first = arguments.first else {
            print(usage)
            return 0
        }
        switch first {
        case "tools":
            return call(method: "tools/list", params: [String: Any]())
        case "call":
            guard arguments.count >= 2 else {
                FileHandle.standardError.write(Data(("missing tool name" + newline + usage + newline).utf8))
                return 2
            }
            let raw = arguments.count >= 3 ? arguments[2] : "{}"
            guard let data = raw.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                FileHandle.standardError.write(Data(("arguments are not valid JSON: " + raw + newline).utf8))
                return 2
            }
            return call(method: "tools/call", params: ["name": arguments[1], "arguments": parsed])
        default:
            FileHandle.standardError.write(Data(("unknown subcommand: " + first + newline + usage + newline).utf8))
            return 2
        }
    }

    private static var usage: String {
        [
            "Kaido CLI (App Store build: forwards to a running Kaido)",
            "",
            "  kaido --cli tools                     list tools available to AI clients",
            "  kaido --cli call <tool> ['<json>']    call a tool with a JSON object",
            "",
            "Requires Kaido to be running with the MCP service enabled",
            "(Project > MCP Service...). The direct-download build ships the full CLI.",
        ].joined(separator: newline)
    }

    private static func call(method: String, params: [String: Any]) -> Int32 {
        guard let connection = connection() else {
            FileHandle.standardError.write(Data(
                ("MCP service is off: enable it in Kaido > Project > MCP Service..." + newline).utf8
            ))
            return 3
        }
        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: envelope) else { return 1 }

        var request = URLRequest(url: connection.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + connection.token, forHTTPHeaderField: "Authorization")
        request.httpBody = body

        let semaphore = DispatchSemaphore(value: 0)
        var payload: Data?
        var failure: Error?
        URLSession.shared.dataTask(with: request) { data, _, error in
            payload = data
            failure = error
            semaphore.signal()
        }.resume()
        semaphore.wait()

        if let failure {
            FileHandle.standardError.write(Data(("connection failed: " + failure.localizedDescription + newline).utf8))
            return 3
        }
        guard let payload, let text = String(data: payload, encoding: .utf8) else {
            FileHandle.standardError.write(Data(("empty response" + newline).utf8))
            return 1
        }
        print(render(text))
        return text.contains("isError\":true") ? 1 : 0
    }

    /// 读 app 写下的端口与 token；读不到说明服务没开。
    private static func connection() -> (url: URL, token: String)? {
        let values = UserDefaults.standard.dictionary(forKey: "kaido.mcp.service.v1") ?? [:]
        guard let port = values["port"] as? Int, port > 0,
              let token = values["token"] as? String, !token.isEmpty,
              let url = URL(string: "http://127.0.0.1:" + String(port) + "/mcp") else {
            return nil
        }
        return (url, token)
    }

    /// 把 JSON-RPC 响应压成可读输出：工具结果取 content[].text，工具表列出名字，其余原样打印。
    private static func render(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? [String: Any] else {
            return text
        }
        if let content = result["content"] as? [[String: Any]] {
            let pieces = content.compactMap { $0["text"] as? String }
            if !pieces.isEmpty { return pieces.joined(separator: newline) }
        }
        if let tools = result["tools"] as? [[String: Any]] {
            return tools.compactMap { $0["name"] as? String }.map { "- " + $0 }.joined(separator: newline)
        }
        return text
    }
}
