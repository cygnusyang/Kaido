import Foundation
import Testing
@testable import KaidoUpdater

/// 清单解析（schema / appId fail-closed）。
@Suite("OTA 清单解析")
struct UpdateManifestTests {
    @Test func parseValidManifest() throws {
        let keys = TestKeys.makeKeyPair()
        let data = try TestKeys.signedManifest(
            dict: TestKeys.manifestDict(), privateKeyBase64: keys.privateKeyBase64)
        let manifest = try UpdateManifest.parse(data, expectedAppId: "app.kaido.test")
        #expect(manifest.version == "1.1.0")
        #expect(manifest.appId == "app.kaido.test")
        #expect(manifest.sha256?.count == 64)
    }

    @Test func wrongAppIdRejected() throws {
        let keys = TestKeys.makeKeyPair()
        let data = try TestKeys.signedManifest(
            dict: TestKeys.manifestDict(), privateKeyBase64: keys.privateKeyBase64)
        #expect(throws: UpdateManifest.ParseError.wrongAppId("app.kaido.test")) {
            _ = try UpdateManifest.parse(data, expectedAppId: "app.kaido.other")
        }
    }

    @Test func unsupportedSchemaRejected() throws {
        let keys = TestKeys.makeKeyPair()
        var dict = TestKeys.manifestDict()
        dict["schemaVersion"] = 99
        let data = try TestKeys.signedManifest(dict: dict, privateKeyBase64: keys.privateKeyBase64)
        #expect(throws: UpdateManifest.ParseError.self) {
            _ = try UpdateManifest.parse(data, expectedAppId: "app.kaido.test")
        }
    }

    @Test func missingFieldRejected() throws {
        let keys = TestKeys.makeKeyPair()
        var dict = TestKeys.manifestDict()
        dict.removeValue(forKey: "cdHash")
        let data = try TestKeys.signedManifest(dict: dict, privateKeyBase64: keys.privateKeyBase64)
        #expect(throws: UpdateManifest.ParseError.self) {
            _ = try UpdateManifest.parse(data, expectedAppId: "app.kaido.test")
        }
    }
}

/// 清单验签（canonical JSON + Ed25519，签名/验签双侧同实现）。
@Suite("OTA 清单验签")
struct ManifestVerifierTests {
    @Test func signAndVerifyRoundtrip() throws {
        let keys = TestKeys.makeKeyPair()
        let dict = TestKeys.manifestDict()
        let signed = try TestKeys.signedManifest(dict: dict, privateKeyBase64: keys.privateKeyBase64)
        #expect(try ManifestVerifier.verify(manifestJSONData: signed, publicKeyBase64: keys.publicKeyBase64))
    }

    @Test func tamperedManifestRejected() throws {
        let keys = TestKeys.makeKeyPair()
        let signed = try TestKeys.signedManifest(
            dict: TestKeys.manifestDict(), privateKeyBase64: keys.privateKeyBase64)
        // 从已签名 JSON 解出完整 dict（含 signature），篡改版本号后验签必须失败
        var dict = try JSONSerialization.jsonObject(with: signed) as! [String: Any]
        dict["version"] = "9.9.9"
        let tampered = try ManifestVerifier.canonicalJSONData(dict)
        #expect(throws: ManifestVerifier.VerificationError.signatureMismatch) {
            _ = try ManifestVerifier.verify(manifestJSONData: tampered, publicKeyBase64: keys.publicKeyBase64)
        }
    }

    @Test func missingSignatureRejected() throws {
        let keys = TestKeys.makeKeyPair()
        let unsigned = try ManifestVerifier.canonicalJSONData(TestKeys.manifestDict())
        #expect(throws: ManifestVerifier.VerificationError.missingSignature) {
            _ = try ManifestVerifier.verify(manifestJSONData: unsigned, publicKeyBase64: keys.publicKeyBase64)
        }
    }

    @Test func wrongKeyRejected() throws {
        let keys = TestKeys.makeKeyPair()
        let other = TestKeys.makeKeyPair()
        let signed = try TestKeys.signedManifest(
            dict: TestKeys.manifestDict(), privateKeyBase64: keys.privateKeyBase64)
        #expect(throws: ManifestVerifier.VerificationError.self) {
            _ = try ManifestVerifier.verify(manifestJSONData: signed, publicKeyBase64: other.publicKeyBase64)
        }
    }
}
