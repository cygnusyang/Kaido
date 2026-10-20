import Foundation
import Testing
import CryptoKit
import KairoUpdater
@testable import KairoMacApp

/// OTA 配置完整性（公钥/feed/白名单/appId 自洽）。
@Suite("OTA 配置")
struct UpdaterConfigurationTests {
    @Test func publicKeyIsWellFormedEd25519() throws {
        let data = try #require(Data(base64Encoded: UpdaterConfiguration.updatePublicKeyBase64))
        #expect(data.count == 32)
        _ = try Curve25519.Signing.PublicKey(rawRepresentation: data)
    }

    @Test func appIdMatchesBundleAndFeed() {
        #expect(UpdaterConfiguration.appId == "app.kairo.macos")
        #expect(UpdaterConfiguration.manifestURL.scheme == "https")
        #expect(
            UpdaterConfiguration.manifestURL.absoluteString.hasSuffix(
                "/releases/latest/download/update-manifest.json"))
    }

    @Test func feedIsInsideWhitelist() throws {
        let policy = UpdateEndpointPolicy(allowedHosts: UpdaterConfiguration.allowedHosts)
        try policy.validate(UpdaterConfiguration.manifestURL)
        // OTA 产物下载 URL（GitHub release asset）也必须在白名单内（同源 host 集）
        let sample = URL(string: "https://github.com/cygnusyang/Kairo/releases/download/v0.3.0/Kairo-v0.3.0.zip")!
        try policy.validate(sample)
    }
}
