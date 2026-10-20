#!/usr/bin/env swift
// tools/verify_update_manifest.swift —— OTA 清单只读验签（CI 门禁 + 本地探针）。
//
// 用法：verify_update_manifest.swift <update-manifest.json> <公钥base64>
//
// 公钥来源纪律（CI 门禁）：从 Apps/macos/Sources/Updater/UpdaterConfiguration.swift
// 的 `updatePublicKeyBase64 = "..."` 常量行提取（单一事实源），与签名私钥派生
// 公钥比对——两者漂移即 fail，杜绝「签了名 App 却验不过」的发版。
//
// 退出码：0 = VALID；1 = 验签或格式失败；2 = 用法错误。
import Foundation

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("verify_update_manifest.swift: " + message + "\n").utf8))
    exit(code)
}

guard CommandLine.arguments.count == 3 else {
    fail("用法：verify_update_manifest.swift <manifest.json> <公钥base64>", code: 2)
}
let manifestURL = URL(fileURLWithPath: CommandLine.arguments[1])
let publicKeyBase64 = CommandLine.arguments[2]

guard let data = try? Data(contentsOf: manifestURL) else {
    fail("无法读取清单文件：\(manifestURL.path)")
}

// --- 验签（与 App 侧 ManifestVerifier 同契约：canonical(去 signature) + Ed25519）---
import CryptoKit

guard let raw = try? JSONSerialization.jsonObject(with: data),
      var dict = raw as? [String: Any] else {
    fail("清单非 JSON 对象")
}
guard let signatureBase64 = dict["signature"] as? String, !signatureBase64.isEmpty else {
    fail("清单缺少 signature 字段")
}
dict.removeValue(forKey: "signature")
guard let canonical = try? JSONSerialization.data(
    withJSONObject: dict, options: [.sortedKeys, .withoutEscapingSlashes]) else {
    fail("canonical 序列化失败")
}
guard let publicKeyData = Data(base64Encoded: publicKeyBase64),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
    fail("公钥 base64 非法（须 Ed25519 raw 32 字节）")
}
guard let signature = Data(base64Encoded: signatureBase64),
      publicKey.isValidSignature(signature, for: canonical) else {
    fail("验签失败（清单被篡改或私钥/公钥不配对）")
}

// --- 字段形状复核（cdHash 40 位 hex；sha256 若存在须 64 位小写 hex）---
guard let cdHash = dict["cdHash"] as? String, cdHash.count == 40,
      cdHash.allSatisfy({ $0.isHexDigit }) else {
    fail("cdHash 缺失或非 40 位 hex")
}
if let sha256 = dict["sha256"] as? String, !sha256.isEmpty {
    guard sha256.count == 64, sha256 == sha256.lowercased(),
          sha256.allSatisfy({ $0.isHexDigit }) else {
        fail("sha256 须为 64 位小写 hex")
    }
}
print("VALID")
