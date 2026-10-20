// UpdaterConfiguration.swift —— Kairo 的 OTA 配置（模块通用化的 App 侧绑定）。
//
// 密钥纪律（与 COFFER 一致）：私钥只存 GitHub secret UPDATE_SIGNING_KEY_BASE64，
// 永不进仓库；公钥硬编码于此，CI 有派生比对门禁防漂移。

import Foundation
import KairoUpdater

/// Kairo OTA 配置常量与生产装配。
enum UpdaterConfiguration {
    /// 应用 bundle identifier（与 build.sh 的 CFBundleIdentifier 一致）。
    static let appId = "app.kairo.macos"
    /// 更新验签公钥（Ed25519 raw 32 字节 base64；由 CI 私钥派生，勿手改）。
    static let updatePublicKeyBase64 = "ZOTsUKf4mYKjsqDbfeINxcOtsyZa7rQYu9QT85IP2AE="
    /// 更新清单 feed：GitHub Releases latest 永久链接（manifest 随每个 release
    /// 重传即完成 feed 更新，无独立 appcast 服务）。
    static let manifestURL = URL(
        string: "https://github.com/cygnusyang/Kairo/releases/latest/download/update-manifest.json")!
    /// 更新期允许的 host（GitHub Releases 域；与 COFFER 同集）。
    static let allowedHosts: Set<String> = [
        "api.github.com",
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
    ]
    /// 安装目标（替换路径）。
    static var installedAppURL: URL {
        URL(fileURLWithPath: "/Applications/Kairo.app")
    }

    /// 生产装配：真实网络层 / 安装器 / 验签器。
    @MainActor
    static func makeUpdater() -> UpdaterManager {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        return UpdaterManager(
            manifestURL: manifestURL,
            expectedAppId: appId,
            currentVersion: version,
            currentAppURL: installedAppURL,
            publicKeyBase64: updatePublicKeyBase64,
            policy: UpdateEndpointPolicy(allowedHosts: allowedHosts),
            fetcher: OTANetworkSession(policy: UpdateEndpointPolicy(allowedHosts: allowedHosts)),
            downloader: OTANetworkSession(policy: UpdateEndpointPolicy(allowedHosts: allowedHosts)),
            installer: ZipAppInstaller(),
            verifier: AppProductVerifier(expectedIdentifier: appId)
        )
    }
}
