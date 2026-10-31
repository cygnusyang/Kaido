import Foundation
import Testing
import CryptoKit
@testable import ZenoUpdater

/// 测试夹具：临时 Ed25519 密钥对与签名清单构造（与 CI 签名工具同契约）。
enum TestKeys {
    static func makeKeyPair() -> (privateKeyBase64: String, publicKeyBase64: String) {
        let key = Curve25519.Signing.PrivateKey()
        return (
            Data(key.rawRepresentation).base64EncodedString(),
            Data(key.publicKey.rawRepresentation).base64EncodedString()
        )
    }

    /// 构造带签名的清单 JSON（去除 signature 后 canonical，Ed25519 签名）。
    static func signedManifest(
        dict: [String: Any], privateKeyBase64: String
    ) throws -> Data {
        var signing = dict
        signing["signature"] = try ManifestVerifier.sign(canonicalDict: dict, privateKeyBase64: privateKeyBase64)
        return try ManifestVerifier.canonicalJSONData(signing)
    }

    /// 合法清单字典（字段与 schema v1 一致）。
    static func manifestDict(
        appId: String = "app.zeno.test",
        version: String = "1.1.0",
        minimumVersion: String = "1.0.0"
    ) -> [String: Any] {
        [
            "schemaVersion": 1,
            "appId": appId,
            "version": version,
            "minimumVersion": minimumVersion,
            "buildTime": "2026-10-20T08:00:00Z",
            "downloadUrl": "https://github.com/example/test/releases/download/v1.1.0/Test-1.1.0.zip",
            "cdHash": String(repeating: "a", count: 40),
            "securityCritical": false,
            "sha256": String(repeating: "b", count: 64),
        ]
    }
}
