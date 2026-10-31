// UpdaterConfiguration.swift —— Kaido 的 OTA 配置（模块通用化的 App 侧绑定）。
//
// 密钥纪律（与 COFFER 一致）：私钥只存 GitHub secret UPDATE_SIGNING_KEY_BASE64，
// 永不进仓库；公钥硬编码于此，CI 有派生比对门禁防漂移。

import Foundation
import KaidoUpdater

/// Kaido OTA 配置常量与生产装配。
enum UpdaterConfiguration {
    /// 应用 bundle identifier（与 build.sh 的 CFBundleIdentifier 一致）。
    static let appId = "app.kaido.macos"
    /// 更新验签公钥（Ed25519 raw 32 字节 base64；由 CI 私钥派生，勿手改）。
    static let updatePublicKeyBase64 = "ZOTsUKf4mYKjsqDbfeINxcOtsyZa7rQYu9QT85IP2AE="
    /// 更新清单 feed：GitHub Releases latest 永久链接（manifest 随每个 release
    /// 重传即完成 feed 更新，无独立 appcast 服务）。
    static let manifestURL = URL(
        string: "https://github.com/cygnusyang/Kaido/releases/latest/download/update-manifest.json")!
    /// 更新期允许的 host（GitHub Releases 域；与 COFFER 同集）。
    static let allowedHosts: Set<String> = [
        "api.github.com",
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
    ]
    /// 安装目标（替换路径）。
    static var installedAppURL: URL {
        URL(fileURLWithPath: "/Applications/Kaido.app")
    }

    /// 自动检查：启动后首次静默检查延迟（避开启动成本窗口）。
    static let autoCheckInitialDelayNanoseconds: UInt64 = 5_000_000_000
    /// 自动检查：运行期周期（4 小时）。
    static let autoCheckIntervalNanoseconds: UInt64 = 4 * 3_600 * 1_000_000_000

    /// 生产装配：真实网络层 / 安装器 / 验签器。
    ///
    /// DEBUG 构建下可被 `LocalOverride`（环境变量）整体替换端点，供
    /// tools/ota-local-verify.sh 跑完整 OTA；release 构建里那段分支不存在，
    /// 装配结果与常量逐字相同。
    @MainActor
    static func makeUpdater() -> UpdaterManager {
        #if DEBUG
        if let override = localOverride() {
            return makeUpdater(
                manifestURL: override.manifestURL,
                allowedHosts: override.allowedHosts,
                publicKeyBase64: override.publicKeyBase64,
                currentAppURL: URL(fileURLWithPath: override.appPath),
                allowsInsecureHTTP: override.allowsInsecureHTTP
            )
        }
        #endif
        return makeUpdater(
            manifestURL: manifestURL,
            allowedHosts: allowedHosts,
            publicKeyBase64: updatePublicKeyBase64,
            currentAppURL: installedAppURL,
            allowsInsecureHTTP: false
        )
    }

    /// 装配本体（端点参数化：生产常量或 DEBUG 覆盖）。
    @MainActor
    private static func makeUpdater(
        manifestURL: URL,
        allowedHosts: Set<String>,
        publicKeyBase64: String,
        currentAppURL: URL,
        allowsInsecureHTTP: Bool
    ) -> UpdaterManager {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let policy = UpdateEndpointPolicy(
            allowedHosts: allowedHosts, allowsInsecureHTTP: allowsInsecureHTTP)
        return UpdaterManager(
            manifestURL: manifestURL,
            expectedAppId: appId,
            currentVersion: version,
            currentAppURL: currentAppURL,
            publicKeyBase64: publicKeyBase64,
            policy: policy,
            fetcher: OTANetworkSession(policy: policy),
            downloader: OTANetworkSession(policy: policy),
            installer: ZipAppInstaller(),
            verifier: AppProductVerifier(expectedIdentifier: appId)
        )
    }

    #if DEBUG
    /// 本地 OTA 验证的环境变量覆盖（仅 DEBUG 编译存在）。
    ///
    /// 五个变量都可由 tools/ota-local-verify.sh 注入，缺省即生产值：
    /// - `KAIDO_OTA_MANIFEST_URL`：清单地址。**设了它才启用覆盖**，未设一律走生产常量。
    /// - `KAIDO_OTA_ALLOWED_HOSTS`：逗号分隔白名单；缺省 = 清单 URL 的 host。
    ///   放宽白名单必须显式列出，不做「生产集 ∪ 本次 host」的隐式合并。
    /// - `KAIDO_OTA_PUBKEY_BASE64`：验签公钥（本地密钥对由脚本现生成，绝不碰生产私钥）。
    /// - `KAIDO_OTA_APP_PATH`：安装目标 .app。**本地验证必须指向临时副本**，
    ///   否则替换脚本会就地覆盖 /Applications/Kaido.app。
    /// - `KAIDO_OTA_ALLOW_HTTP=1`：放行 http（回环服务没有可信证书）。
    struct LocalOverride: Equatable {
        let manifestURL: URL
        let allowedHosts: Set<String>
        let publicKeyBase64: String
        let appPath: String
        let allowsInsecureHTTP: Bool
    }

    /// 读取环境变量；未设清单地址或地址无 host 时返回 nil（= 用生产常量）。
    static func localOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LocalOverride? {
        guard let raw = environment["KAIDO_OTA_MANIFEST_URL"],
              let url = URL(string: raw),
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        let listed = (environment["KAIDO_OTA_ALLOWED_HOSTS"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return LocalOverride(
            manifestURL: url,
            allowedHosts: Set(listed.isEmpty ? [host] : listed),
            publicKeyBase64: environment["KAIDO_OTA_PUBKEY_BASE64"] ?? updatePublicKeyBase64,
            appPath: environment["KAIDO_OTA_APP_PATH"] ?? installedAppURL.path,
            allowsInsecureHTTP: environment["KAIDO_OTA_ALLOW_HTTP"] == "1"
        )
    }
    #endif
}
