import Foundation
import Testing
@testable import KairoUpdater

/// 本地 OTA 验证留的 http 口子（tools/ota-local-verify.sh 专用）。
///
/// 判据：默认仍是「非 https 一律拒」；只有显式 `allowsInsecureHTTP` 的实例
/// 才放行 http，且白名单与 scheme 两条校验都不得因此松动。
@Suite("OTA 端点白名单：本地验证的 http 例外")
struct EndpointPolicyInsecureHTTPTests {
    private let localhost = URL(string: "http://127.0.0.1:8123/update-manifest.json")!

    @Test func defaultPolicyStillRejectsHTTP() {
        let policy = UpdateEndpointPolicy(allowedHosts: ["127.0.0.1"])
        #expect(!policy.isAllowedURL(localhost))
        #expect(throws: UpdateEndpointPolicy.PolicyError.self) {
            try policy.validate(localhost)
        }
    }

    @Test func insecureHTTPAllowsOnlyListedHost() {
        let policy = UpdateEndpointPolicy(allowedHosts: ["127.0.0.1"], allowsInsecureHTTP: true)
        #expect(policy.isAllowedURL(localhost))
        try? policy.validate(localhost)
        #expect(!policy.isAllowedURL(URL(string: "http://evil.example.com/x")!))
        #expect(throws: UpdateEndpointPolicy.PolicyError.self) {
            try policy.validate(URL(string: "http://evil.example.com/x")!)
        }
    }

    @Test func insecureHTTPDoesNotRelaxHTTPSOnlyHosts() {
        let policy = UpdateEndpointPolicy(allowedHosts: ["github.com"], allowsInsecureHTTP: true)
        #expect(!policy.isAllowedURL(URL(string: "https://evil.example.com/x")!))
        #expect(policy.isAllowedURL(URL(string: "https://github.com/x")!))
    }

    @Test func nonHTTPSchemesStayRejected() {
        let policy = UpdateEndpointPolicy(allowedHosts: ["127.0.0.1"], allowsInsecureHTTP: true)
        #expect(!policy.isAllowedURL(URL(string: "ftp://127.0.0.1/x")!))
        #expect(!policy.isAllowedURL(URL(string: "file:///tmp/x")!))
    }
}
