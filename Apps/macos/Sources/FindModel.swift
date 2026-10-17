import Foundation
import KairoCore

/// 应用层可观察门面：包装纯逻辑的 KairoCore `FindController`（ADR-004）。
/// 核心控制器负责查找逻辑；本门面镜像 SwiftUI 需要绑定的几个属性，
/// 并在每次核心操作后从控制器回读结果。
@MainActor
final class FindModel: ObservableObject {
    @Published var lastFindString: String {
        didSet { controller.lastFindString = lastFindString }
    }
    @Published var regexMode: Bool {
        didSet { controller.regexMode = regexMode }
    }
    @Published var matchCount: Int
    @Published var currentIndex: Int?
    @Published var invalidRegex: Bool

    private let controller: FindController

    init() {
        let controller = FindController()
        self.controller = controller
        self.lastFindString = controller.lastFindString
        self.regexMode = controller.regexMode
        self.matchCount = controller.matchCount
        self.currentIndex = controller.currentIndex
        self.invalidRegex = controller.invalidRegex
    }

    /// 把控制器最新结果回读为可发布属性。
    private func sync() {
        matchCount = controller.matchCount
        currentIndex = controller.currentIndex
        invalidRegex = controller.invalidRegex
    }

    func attach(target: (any FindTarget)?) {
        controller.attach(target: target)
        sync()
    }

    func rescan() {
        controller.lastFindString = lastFindString
        controller.regexMode = regexMode
        controller.rescan()
        sync()
    }

    func findNext() {
        controller.findNext()
        sync()
    }

    func findPrevious() {
        controller.findPrevious()
        sync()
    }
}
