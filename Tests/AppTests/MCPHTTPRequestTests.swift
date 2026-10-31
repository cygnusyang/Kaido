import Foundation
import Testing
@testable import KaidoMacApp

/// 回环 HTTP 请求解析：MCP 客户端只发单请求 + Content-Length + Bearer。
@Suite("MCP HTTP 请求解析")
struct MCPHTTPRequestTests {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    @Test func parsesHeadersBodyAndBearerToken() throws {
        let raw = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer abc123\r\nContent-Length: 11\r\n\r\n{\"id\":1234}"
        let request = try #require(HTTPRequest.parse(data(raw)))
        #expect(request.method == "POST")
        #expect(request.path == "/mcp")
        #expect(request.token == "abc123")
        #expect(request.body.count == 11)
    }

    @Test func acceptsCustomTokenHeader() throws {
        let raw = "POST /mcp HTTP/1.1\r\nX-Kaido-Token: t0ken\r\nContent-Length: 2\r\n\r\n{}"
        let request = try #require(HTTPRequest.parse(data(raw)))
        #expect(request.token == "t0ken")
    }

    @Test func waitsForFullBody() {
        let partial = "POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}"
        #expect(HTTPRequest.parse(data(partial)) == nil)
    }

    @Test func waitsForHeaders() {
        #expect(HTTPRequest.parse(data("POST /mcp HTTP/1.1\r\nHost: x")) == nil)
    }

    @Test func stripsQueryFromPath() throws {
        let raw = "POST /mcp?session=1 HTTP/1.1\r\nContent-Length: 0\r\n\r\n"
        let request = try #require(HTTPRequest.parse(data(raw)))
        #expect(request.path == "/mcp")
    }
}
