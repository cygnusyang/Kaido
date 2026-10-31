import Foundation

/// 分发渠道差异开关（编译期常量，零运行时状态）。
///
/// 商店版与官网直装版共用一份代码，只在「商店明令禁止的能力」上分叉：
/// 自更新（KaidoUpdater 会起子进程替换 /Applications 里的 .app，商店必拒）。
enum KaidoDistribution {
    #if KAIDO_MAS
    /// App Store 构建：由 `tools/build-mas.sh` 传 `-Xswiftc -DKAIDO_MAS`。
    static let isAppStoreBuild = true
    #else
    static let isAppStoreBuild = false
    #endif
}
