import Foundation
import Testing
@testable import KaidoMacApp

/// DEBUG 下的本地 OTA 覆盖（tools/ota-local-verify.sh 注入的环境变量）。
///
/// 判据：不设清单地址即完全走生产常量（零影响）；设了则五个变量各自生效，
/// 且缺省值不得放宽生产口径（公钥 / 安装目标仍是生产值）。
@Suite("OTA 本地验证覆盖")
struct OTALocalOverrideTests {
    @Test func absentManifestURLMeansProduction() {
        #expect(UpdaterConfiguration.localOverride(environment: [:]) == nil)
        #expect(UpdaterConfiguration.localOverride(
            environment: ["KAIDO_OTA_APP_PATH": "/tmp/Kaido.app"]) == nil)
    }

    @Test func manifestURLHostBecomesSoleAllowedHost() throws {
        let override = try #require(UpdaterConfiguration.localOverride(environment: [
            "KAIDO_OTA_MANIFEST_URL": "http://127.0.0.1:8123/update-manifest.json",
        ]))
        #expect(override.manifestURL.port == 8123)
        #expect(override.allowedHosts == ["127.0.0.1"])
        #expect(override.publicKeyBase64 == UpdaterConfiguration.updatePublicKeyBase64)
        #expect(override.appPath == "/Applications/Kaido.app")
        #expect(override.allowsInsecureHTTP == false)
    }

    @Test func everyVariableCanBeOverridden() throws {
        let override = try #require(UpdaterConfiguration.localOverride(environment: [
            "KAIDO_OTA_MANIFEST_URL": "http://127.0.0.1:8123/update-manifest.json",
            "KAIDO_OTA_ALLOWED_HOSTS": " localhost , 127.0.0.1 ",
            "KAIDO_OTA_PUBKEY_BASE64": "ZOTsUKf4mYKjsqDbfeINxcOtsyZa7rQYu9QT85IP2AE=",
            "KAIDO_OTA_APP_PATH": "/tmp/kaido-ota-verify/Kaido.app",
            "KAIDO_OTA_ALLOW_HTTP": "1",
        ]))
        #expect(override.allowedHosts == ["localhost", "127.0.0.1"])
        #expect(override.publicKeyBase64 == "ZOTsUKf4mYKjsqDbfeINxcOtsyZa7rQYu9QT85IP2AE=")
        #expect(override.appPath == "/tmp/kaido-ota-verify/Kaido.app")
        #expect(override.allowsInsecureHTTP)
    }

    @Test func hostlessURLIsIgnored() {
        #expect(UpdaterConfiguration.localOverride(environment: [
            "KAIDO_OTA_MANIFEST_URL": "not a url",
        ]) == nil)
    }
}
