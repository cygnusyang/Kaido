#!/usr/bin/env swift
// tools/ota_local_sign_manifest.swift -- 本地 OTA 验证用的清单签名 helper。
//
// 与 tools/sign_update_manifest.swift 的关系：**canonical JSON 契约完全相同**
// （JSONSerialization + .sortedKeys + .withoutEscapingSlashes，被签内容 = 去除
// signature 后的全字段），只有一条边界放宽：downloadUrl 允许 http 回环地址。
// 生产工具把 https 写死是有意的红线，本地验证不该去改它，于是单独放一个显式
// 受限的 helper，并在这里反过来锁死「只能签回环地址」。
//
// 输入的私钥必须是**本地现生成的丢弃密钥**（tools/ota-local-verify.sh 负责生成），
// 生产私钥（GitHub secret UPDATE_SIGNING_KEY_BASE64）绝不出现在本地验证流程里：
// 本地 App 通过 KAIDO_OTA_PUBKEY_BASE64 信任这把临时公钥。
//
// 输入（环境变量）：UPDATE_SIGNING_KEY_BASE64（本地临时私钥种子 base64）、
//   MF_VERSION / MF_MINIMUM_VERSION / MF_BUILD_TIME / MF_DOWNLOAD_URL / MF_CDHASH
//   必填；MF_SECURITY_CRITICAL / MF_NOTES / MF_SHA256 可选。
// 输出：完整清单 JSON（含 signature）到 stdout；错误走 stderr。
import Foundation
import CryptoKit

let env = ProcessInfo.processInfo.environment

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("ota_local_sign_manifest.swift: " + message + "\n").utf8))
    exit(1)
}

func required(_ name: String) -> String {
    guard let value = env[name], !value.isEmpty else {
        fail("缺少必填环境变量 \(name)")
    }
    return value
}

let privateKeyBase64 = required("UPDATE_SIGNING_KEY_BASE64")
let version = required("MF_VERSION")
let minimumVersion = required("MF_MINIMUM_VERSION")
let buildTime = required("MF_BUILD_TIME")
let downloadURL = required("MF_DOWNLOAD_URL")
let cdHash = required("MF_CDHASH").lowercased()

guard let url = URL(string: downloadURL), let host = url.host?.lowercased() else {
    fail("MF_DOWNLOAD_URL 不是合法 URL：\(downloadURL)")
}
// 只签回环地址：这个 helper 存在的唯一理由是本地验证，不能用来签任意 http 地址。
let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]
guard loopbackHosts.contains(host) else {
    fail("MF_DOWNLOAD_URL 必须是回环地址（127.0.0.1 / localhost / ::1），收到 host=\(host)")
}
guard url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https" else {
    fail("MF_DOWNLOAD_URL 只支持 http(s)，收到 scheme=\(url.scheme ?? "nil")")
}
guard cdHash.count == 40, cdHash.allSatisfy({ $0.isHexDigit }) else {
    fail("MF_CDHASH 必须为 40 位 hex（收到 \(cdHash.count) 字符）")
}

let securityCritical: Bool = {
    guard let raw = env["MF_SECURITY_CRITICAL"], !raw.isEmpty else { return false }
    guard let value = Bool(raw) else {
        fail("MF_SECURITY_CRITICAL 须为 true/false（收到 \(raw)）")
    }
    return value
}()

var fields: [String: Any] = [
    "schemaVersion": 1,
    "appId": "top.cygnusyang.kaido",
    "version": version,
    "minimumVersion": minimumVersion,
    "buildTime": buildTime,
    "downloadUrl": downloadURL,
    "cdHash": cdHash,
    "securityCritical": securityCritical,
]

if let notes = env["MF_NOTES"], !notes.isEmpty {
    fields["notes"] = notes
}
if let sha = env["MF_SHA256"], !sha.isEmpty {
    let lowered = sha.lowercased()
    guard lowered.count == 64, lowered.allSatisfy({ $0.isHexDigit }) else {
        fail("MF_SHA256 必须为 64 位 hex（收到 \(lowered.count) 字符）")
    }
    fields["sha256"] = lowered
}

func canonical(_ dict: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .withoutEscapingSlashes])
}

guard let keyData = Data(base64Encoded: privateKeyBase64) else {
    fail("UPDATE_SIGNING_KEY_BASE64 不是合法 base64")
}
guard let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else {
    fail("UPDATE_SIGNING_KEY_BASE64 不是合法的 Ed25519 原始种子（应为 32 字节）")
}

let signedBytes: Data
do {
    signedBytes = try canonical(fields)
} catch {
    fail("canonical 序列化失败：\(error)")
}
guard let signature = try? privateKey.signature(for: signedBytes) else {
    fail("Ed25519 签名失败")
}

var manifest = fields
manifest["signature"] = signature.base64EncodedString()
do {
    let output = try canonical(manifest)
    FileHandle.standardOutput.write(output)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    fail("清单序列化失败：\(error)")
}
