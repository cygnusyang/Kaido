import Foundation
import Testing
@testable import KairoUpdater

/// 端点白名单（强制 HTTPS + host 白名单，大小写不敏感）。
@Suite("OTA 端点白名单")
struct EndpointPolicyTests {
    private let policy = UpdateEndpointPolicy(allowedHosts: [
        "github.com", "objects.githubusercontent.com",
    ])

    @Test func httpsAndWhitelistEnforced() {
        #expect(policy.isAllowedURL(URL(string: "https://github.com/x/y")!))
        #expect(!policy.isAllowedURL(URL(string: "http://github.com/x/y")!))
        #expect(!policy.isAllowedURL(URL(string: "https://evil.example.com/x")!))
        #expect(!policy.isAllowedURL(URL(string: "https://github.com.evil.com/x")!))
    }

    @Test func hostCaseInsensitive() {
        #expect(policy.isAllowedHost("GitHub.COM"))
        #expect(!policy.isAllowedHost("notgithub.com"))
    }

    @Test func validateThrowsOnViolation() {
        #expect(throws: UpdateEndpointPolicy.PolicyError.self) {
            try policy.validate(URL(string: "http://github.com/x")!)
        }
        #expect(throws: UpdateEndpointPolicy.PolicyError.self) {
            try policy.validate(URL(string: "https://evil.example.com/x")!)
        }
    }
}

/// SHA256 完整性校验（流式）。
@Suite("OTA 下载校验和")
struct UpdateChecksumTests {
    @Test func sha256KnownVector() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kairo-ota-test-\(UUID().uuidString).bin")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        // SHA256("abc") 标准测试向量
        #expect(try UpdateChecksum.sha256Hex(of: url)
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func unreadableFileFailsClosed() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("kairo-ota-missing-\(UUID().uuidString)")
        #expect(throws: UpdateChecksumError.self) {
            _ = try UpdateChecksum.sha256Hex(of: missing)
        }
    }
}
