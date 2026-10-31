import Foundation

/// 一次「安全作用域」访问授权。
///
/// App Store 版跑在沙盒里：文件选择面板给的授权只在本会话有效，跨启动要靠
/// security-scoped bookmark 重新换取。持有本对象期间该 URL 可读写；对象释放
/// 即归还授权（`deinit` 里配对 `stopAccessingSecurityScopedResource()`）。
///
/// 站外 Developer ID 版没有沙盒，`startAccessingSecurityScopedResource()`
/// 返回 false，本类退化成空壳——调用方不用区分两种构建。
final class ProjectScope {
    /// 解析后的真实文件 URL（书签指向的位置；无书签时就是原路径）。
    let url: URL
    private let started: Bool

    init(url: URL) {
        self.url = url
        self.started = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if started {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
