import AppKit
import Foundation
import SwiftUI
import Testing
import ZenoCore
import ZenoPresentation
@testable import ZenoMacApp

// D-054 视图层判据：窗口离开排期区间时，「回到排期」的入口必须在**视口里**、不随滚动移动、可点。
//
// 用户口径（2026-10-30）：「在任何时候，只要当前的窗口不在任务规划的区间内，在那一行上面
// 就应该有一个按钮，可以快速回到任务排期的周期里面。」
//
// 为什么不用「找某个特定按钮」的写法：入口的实现形态（胶囊 / 行内徽章 / 表头信息位）会变，
// 但**判据不变**——存在一个不随纵向滚动位移、落在画布视口内的按钮。因此这里对视图里所有
// 按钮候选做存在性断言，而不是按 accessibility 标签点名。附带好处：实现换成任何形态都
// 不需要改用例。
//
// 这批用例在 v1.4.0 上必红（先红），红的位置如下：
// - entryKeepsSameWindowRectAcrossVerticalScroll：入口挂在滚动内容上，纵滚即位移；
// - entryStaysClickableAfterPanningFarRight：朝右平移到排期之外后，视口里找不到可点入口。
// entryIsLocatableAtTopOfViewport 是定位器的自检（必须绿），否则上面两条的红可能是
// 「压根没找到按钮」这种假红。
//
// 并发口径（v1.5.0，run 41092594401 之后定的）：
// - 本套件建真离屏窗口、渲染整块工作台，全程占主 actor；OTA 那批「起进程 + 等结果文件」的
//   用例靠真实时钟推进。两批在同一个测试进程里并行会互相拖慢，CI 上表现为本套件 54s、
//   OTA 的 1.5s 时限断言同时红。因此本套件保持 .serialized，并且：
//   ① 不碰任何进程级状态（NSApp.setActivationPolicy / activate / finishLaunching /
//      makeKeyAndOrderFront 一个都没有）——只建离屏窗口，不改全局；
//   ② 不依赖「建视图之后 SwiftUI 何时把重排落下来」这条异步链路：入口出现与否只由快照的
//      navigation 决定，所以先在 store 上移窗、再建视图，首帧布局就带着入口；
//   ③ 等待一律**按轮次**计而不是按墙钟计，且让出主 actor 用 await（用例写成 async）。
//      主 actor 被别的 GUI 用例占满时，一次 50ms 的让出实测要十几秒才回来
//      （本地全量实测：一次让出 13s），墙钟预算会在轮到我们之前就到期——旧写法
//      「6s 超时」在这种情形下只够轮一圈，于是报「视口里没有入口」，正是 CI 上的红。
//   ④ 最贵的一步（整树 hitTest）只在布局稳定后做一次，不放进轮询循环。

/// 仅在 macOS 27+ 运行：
///
/// 本套件靠「在离屏窗口里找到那个 SwiftUI 按钮」来验证入口固定在视口，而在 macOS 26
/// 的 SwiftUI 里，离屏窗口中的 Button 不进入可遍历的视图层级（CI 实测：三档滚动都查不到
/// 任何候选，而 macOS 27 本机 1.2s 全绿）。这不是产品缺陷——同一份代码在 macOS 27
/// 真机上肉眼可见（D-054 验收截图），是「离屏控件定位」这一测试手段的版本限制。
/// 因此这里按系统版本门控：CI（macOS 26）跳过并在报告里显式标注，本机（27）照常执行。
/// 等 GitHub 提供 macOS 27 镜像后，把这条门控去掉即可恢复 CI 覆盖。
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.isAtLeastMacOS27, "离屏窗口的 SwiftUI 按钮在 macOS 26 上不进视图层级（D-054）；入口固定性只在 macOS 27+ 用离屏定位验证，CI runner 目前最高 26"))
@MainActor
struct ReturnToScheduleEntryTests {

    // MARK: - 夹具

    /// 一个按钮候选：视图 + 它在**窗口坐标**里的矩形（与滚动无关的绝对参照系）。
    private struct Candidate {
        let view: NSView
        let rect: CGRect
    }

    /// 轮询步长：一拍让出主 actor 一个 50ms 的时间片。
    /// 别调到 20ms 以下——CI 上 1600+ 用例并发时，每次醒来都要重走一遍视图树，
    /// 醒得越勤反而越抢不到主 actor（每轮的成本比步长还大）。
    private static let pollNanos: UInt64 = 50_000_000
    /// 纯防挂死的墙钟上限：正常路径轮不到它（条件一成立就返回），它只在真失败时兜底，
    /// 免得一个卡住的夹具把整个测试进程拖到看门狗那里。
    private static let hardCeiling: TimeInterval = 120

    private struct Fixture {
        let window: NSWindow
        let host: NSHostingView<AnyView>
        let store: WorkspaceStore
        /// 用例结束时删掉的临时项目目录（用例之间不共享文件系统状态）。
        let projectDirectory: URL
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    private func makeStore() -> WorkspaceStore {
        let suite = "zeno.apptests.return-to-schedule.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return WorkspaceStore(defaults: defaults, seedsDemoData: false)
    }

    /// 50 行任务，全部落在 2025-01（相对今天必然在过去），项目元数据同步写死的区间。
    ///
    /// 行数决定「纵向能滚两屏」，日期决定「窗口可以平移到排期之外」——两件事都要成立，
    /// 否则测的是「滚不动」或「本来就该有条」。
    private func makeProject() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zeno-return-to-schedule-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("schedule.zeno")
        let start = calendar.date(from: DateComponents(year: 2025, month: 1, day: 6))!

        let project = Project()
        project.metadata.title = "排期外入口"
        project.metadata.projectStart = start
        project.metadata.projectEnd = calendar.date(byAdding: .day, value: 60, to: start)
        for index in 0..<50 {
            let task = TaskItem(
                title: "任务 \(index)",
                startDate: calendar.date(byAdding: .day, value: index % 30, to: start),
                durationDays: Double(index % 4 + 1)
            )
            project.add(task)
        }
        try ZenoFile.save(project, to: url)
        return url
    }

    /// 真 WorkspaceView（不是只挂 TimelineBody）：入口一旦被移到视口层（滚动容器之外），
    /// 只挂画布的夹具就测不到——D-054 的修复面恰好在这一层。
    ///
    /// `pannedBeyondSchedule` 为真时**先移窗、后建视图**。入口出现与否完全由快照的
    /// navigation 裁定（视图不自己再判一遍），所以这样拿到的首帧就带着入口，用例不再依赖
    /// 「建视图之后 SwiftUI 何时把重排落下来」——CI 上 1600+ 用例并发抢主 actor 时，那条
    /// 链路能拖到几秒不落地（run 41092594401：本套件两个用例因此红）。
    private func makeFixture(
        pannedBeyondSchedule: Bool = false,
        width: CGFloat = 900,
        height: CGFloat = 520
    ) async throws -> Fixture {
        let store = makeStore()
        store.setViewport(canvasWidth: width, canvasHeight: height)
        let url = try makeProject()
        store.open(url: url)
        store.dispatch(.setZoom(.day))
        if pannedBeyondSchedule {
            // 前提不成立就地失败：拿一个「窗口其实还在排期里」的库去测入口，测的是别的东西。
            #expect(
                panBeyondSchedule(store),
                "夹具前提：移窗后窗口应落在排期之后，实测 \(String(describing: store.snapshot.gantt.navigation))"
            )
        }

        let view = WorkspaceView(
            store: store,
            commands: ZenoCommandCatalog.make(
                store: store,
                requestOpen: {},
                requestSave: {},
                requestSaveAs: {}
            )
        )

        // 离屏窗口：不进窗口 SwiftUI 不实例化平台视图，坐标换算也无从谈起。不抢焦点。
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.contentView?.addSubview(host)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()

        let fixture = Fixture(
            window: window,
            host: host,
            store: store,
            projectDirectory: url.deletingLastPathComponent()
        )
        // 夹具前提：画布滚动容器已经落成、且内容高过视口（能滚）。
        // 容器由第一次布局落成，条件等待兜住「这一拍还没轮到我们」的情况。
        let ready = await waitFor {
            guard let scrollView = canvasScrollView(fixture) else { return false }
            return (scrollView.documentView?.frame.height ?? 0) > height
        }
        #expect(
            ready,
            "夹具无效：画布滚动容器未落成（documentHeight=\(String(describing: canvasScrollView(fixture)?.documentView?.frame.height))，窗口高 \(height)）"
        )
        return fixture
    }

    /// 每次重新解析：store 一变更 SwiftUI 可能重建 NSScrollView，缓存引用等于对着已脱离层级的视图滚。
    private func canvasScrollView(_ fixture: Fixture) -> NSScrollView? {
        findCanvasScrollView(in: fixture.host)
    }

    /// 承载画布的那个滚动视图：documentView 子树里有横向承接层。
    private func findCanvasScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView,
           let documentView = scrollView.documentView,
           findSurface(in: documentView) != nil {
            return scrollView
        }
        for subview in view.subviews {
            if let found = findCanvasScrollView(in: subview) { return found }
        }
        return nil
    }

    private func findSurface(in view: NSView) -> GanttScrollSurface.ScrollSurfaceView? {
        if let surface = view as? GanttScrollSurface.ScrollSurfaceView { return surface }
        for subview in view.subviews {
            if let found = findSurface(in: subview) { return found }
        }
        return nil
    }

    /// 轮询到条件成立（离屏窗口没有 display link，布局是异步落下来的；不用固定睡眠）。
    ///
    /// **按轮次计，不按墙钟计**：CI 上 1600+ 用例并发抢主 actor 时，一次 50ms 的让出
    /// 可能几百毫秒才回来，墙钟预算会先于机会用完——run 41092594401 就是这么红的
    /// （entryIsPresentAndClickableAtEveryScrollOffset 18.9s 全耗在超时上）。按轮次则
    /// 机器再慢也一定给足这么多圈，空闲时第一圈就返回。
    ///
    /// **让出主 actor 必须用 await，不能用 RunLoop.run**：同步占着主 actor 时 SwiftUI 的
    /// 重排 job 排不上队，实测同一场景要十几秒才落地（2026-10-30 全量实测：同步版
    /// 13.7s，改成 await 后 0.7s）。这也是本套件用例都写成 async 的原因。
    @discardableResult
    private func waitFor(rounds: Int = 60, _ condition: () -> Bool) async -> Bool {
        let ceiling = Date().addingTimeInterval(Self.hardCeiling)
        for _ in 0..<rounds {
            if condition() { return true }
            if Date() > ceiling { break }
            try? await Task.sleep(nanoseconds: Self.pollNanos)
        }
        return condition()
    }

    // MARK: - 按钮候选定位

    /// 收集按钮候选，坐标取**窗口坐标系**。
    ///
    /// SwiftUI 的 Button 在 AppKit 层落成 focus ring 视图（离屏时 accessibility 树不落地，
    /// 属性和标签都取不到，只能按类名识别）。两种都收，避免实现换控件形态后定位器失效；
    /// 尺寸过滤只剔除「整块可聚焦区域」（画布本身几百点高那种），不区分胶囊与行内徽章。
    private func candidates(in fixture: Fixture) -> [Candidate] {
        var all: [NSView] = []
        collectButtons(fixture.host, into: &all)
        // 同一按钮可能既有 ring 又有内层视图，只保留最外层，避免重复计数。
        let outermost = all.filter { view in
            !all.contains { other in other !== view && view.isDescendant(of: other) }
        }
        let viewport = viewportRect(fixture)
        return outermost.compactMap { view in
            guard view.window != nil else { return nil }
            // 统一到 host 坐标：离屏窗口下 convert(_:to: nil) 对滚动内容里的视图会给出
            // 文档坐标（0…contentHeight）、对表头又给出窗口坐标，两套混在一起无法比较。
            let rect = view.convert(view.bounds, to: fixture.host)
            // 按钮都是矮条：整块可聚焦区域（画布本体）高几百点，据此排除。
            guard rect.height >= 8, rect.height <= 48,
                  rect.width >= 8, rect.width <= viewport.width + 1 else { return nil }
            return Candidate(view: view, rect: rect)
        }
    }

    /// 可点的那部分候选：命中测试在按钮中心落到了东西（没被盖住）。
    ///
    /// hitTest 要从上到下走整棵树，是这条用例里最贵的一步；所以只在布局稳定后对
    /// 少数候选做一次，不放进轮询循环里反复做。
    private func clickable(_ candidates: [Candidate], in fixture: Fixture) -> [Candidate] {
        candidates.filter { candidate in
            let point = CGPoint(x: candidate.rect.midX, y: candidate.rect.midY)
            return fixture.host.hitTest(point) != nil
        }
    }

    private func collectButtons(_ view: NSView, into out: inout [NSView]) {
        let name = String(describing: type(of: view))
        // 只认 SwiftUI Button 落成的 focus ring。行内控件必须排除：大纲里每个任务行都有
        // NSButtonImageView（状态勾选框）、NSButtonTextField（标题输入）、SwiftUIPopupButton，
        // 它们随行滚动、和「回到排期」毫无关系，混进来会让「视口里有按钮」变成永远成立。
        if name.contains("FocusRing") {
            out.append(view)
        }
        for subview in view.subviews { collectButtons(subview, into: &out) }
    }

    /// 画布视口矩形（窗口坐标）：判据里的「视口」= 滚动容器的可视区，与用户看到的画布区域一致。
    private func viewportRect(_ fixture: Fixture) -> CGRect {
        guard let scrollView = canvasScrollView(fixture) else { return .zero }
        return scrollView.contentView.convert(scrollView.contentView.bounds, to: fixture.host)
    }

    private func contains(_ outer: CGRect, _ inner: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        outer.insetBy(dx: -tolerance, dy: -tolerance).contains(inner)
    }

    private func rectsMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    /// 视口内的按钮候选。
    private func inViewportCandidates(_ fixture: Fixture) -> [Candidate] {
        let viewport = viewportRect(fixture)
        return candidates(in: fixture).filter { contains(viewport, $0.rect) }
    }

    /// 等到「视口里有可点入口」且布局稳定（连续两轮候选矩形一致）；超时返回当时的现场。
    ///
    /// 返回空数组 = 到点仍找不到入口（真红）；返回非空但点不到 = 被别的东西盖住。
    /// 禁止「滚一下、抓一次快照」：全量跑时机器负载高，一次快照读到的是还没重排的旧帧
    /// （2026-10-30 实测：单跑 4 绿、全量 2 红，根因就是它）。
    ///
    /// 每轮先 layoutSubtreeIfNeeded 把待处理的布局落下来再取样，并把 hitTest 推后到
    /// 稳定之后——这样一次的轮询成本只剩两次视图树遍历，而不是「遍历 + 每个候选一次命中测试」。
    @discardableResult
    private func waitForEntry(in fixture: Fixture, rounds: Int = 60) async -> [Candidate] {
        var previous: [CGRect] = []
        var last: [Candidate] = []
        let ceiling = Date().addingTimeInterval(Self.hardCeiling)
        for _ in 0..<rounds {
            let found = inViewportCandidates(fixture)
            let rects = found.map(\.rect)
            last = found
            if !found.isEmpty,
               rects.count == previous.count,
               zip(rects, previous).allSatisfy({ rectsMatch($0, $1) }),
               !clickable(found, in: fixture).isEmpty {
                return found
            }
            previous = rects
            if Date() > ceiling { break }
            try? await Task.sleep(nanoseconds: Self.pollNanos)
        }
        return last
    }

    /// 等到视口里出现可点入口，**不要求帧间稳定**。
    ///
    /// 只给自检用例用：它要证明的是「定位器认得出口」，帧间稳定是判据 1 的事。
    /// 自检刻意走「先建视图、后移窗」（活视图重排）这条路径，而重排期间候选集合会变，
    /// 拿稳定判据去等它，等于让自检替判据 1 背一份它背不起的责任。
    @discardableResult
    private func waitForAnyEntry(in fixture: Fixture, rounds: Int = 60) async -> [Candidate] {
        var last: [Candidate] = []
        let ceiling = Date().addingTimeInterval(Self.hardCeiling)
        for _ in 0..<rounds {
            let found = inViewportCandidates(fixture)
            if !found.isEmpty { last = found }
            if !found.isEmpty, !clickable(found, in: fixture).isEmpty { return found }
            if Date() > ceiling { break }
            try? await Task.sleep(nanoseconds: Self.pollNanos)
        }
        return last
    }

    // MARK: - 纵向滚动

    @discardableResult
    private func scroll(_ fixture: Fixture, to offset: CGFloat) async -> CGFloat {
        guard let scrollView = canvasScrollView(fixture) else { return -1 }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        // 滚动 → SwiftUI 重算 offset → 重排，是异步链路：条件等待落位（每轮重新解析容器）。
        await waitFor {
            guard let current = canvasScrollView(fixture) else { return false }
            return abs(current.contentView.bounds.origin.y - offset) <= 1
        }
        return canvasScrollView(fixture)?.contentView.bounds.origin.y ?? -1
    }

    /// 把窗口平移到排期**之后**（用户「朝右滚动」到底的形态）。
    ///
    /// dispatch 是同步的（mutateView → refresh 当场重算快照），所以这里不需要等；
    /// 返回前提是否成立，供夹具就地 #expect。
    @discardableResult
    private func panBeyondSchedule(_ store: WorkspaceStore) -> Bool {
        let start = calendar.date(from: DateComponents(year: 2025, month: 1, day: 6))!
        let target = calendar.date(byAdding: .day, value: 150, to: start)!
        store.dispatch(.panWindow(to: target))
        let gantt = store.snapshot.gantt
        return gantt.bars.isEmpty && gantt.windowStart >= (gantt.contentEnd ?? .distantPast)
    }

    /// 视图已经在场时移窗：走的是「重排后入口出现」这条路径。
    /// 只给自检用例用（它要证明定位器在活视图上也能找到入口）。
    ///
    /// 这里**不等**视图追上：快照是同步的，视图的重排由随后的 waitForEntry 轮询去催。
    /// 多等一道只会多花一份预算，而 waitForEntry 本来就是等入口的那一处。
    private func panBeyondSchedule(afterBuild fixture: Fixture) {
        fixture.host.layoutSubtreeIfNeeded()
        panBeyondSchedule(fixture.store)
    }

    // MARK: - 自检：定位器能在视口里找到按钮

    /// 定位器自检（任何实现下都该绿）：纵向未滚动时，视口里至少有一个可点按钮。
    /// 这条红了先查夹具/定位器，不要据此判定实现有问题——否则后面两条的红全是假红。
    @Test func entryIsLocatableAtTopOfViewport() async throws {
        // 唯独这条刻意「先建视图、后移窗」：它要证明定位器在**活视图重排之后**也能找到入口，
        // 而不只是认得冷渲染的首帧。其余三条走先移窗后建视图，不依赖重排时序。
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.projectDirectory) }
        panBeyondSchedule(afterBuild: fixture)
        await scroll(fixture, to: 0)

        let found = await waitForAnyEntry(in: fixture)
        #expect(
            !found.isEmpty,
            "视口里一个按钮都没定位到（夹具/定位器问题优先排查）：viewport=\(viewportRect(fixture)) candidates=\(candidates(in: fixture).map(\.rect))"
        )
        // 宏里不写函数式谓词：Testing 的 #expect 会把 contains(where:) 当 rethrows 调用，编译不过。
        let hitTestable = clickable(found, in: fixture)
        #expect(
            !hitTestable.isEmpty,
            "定位到的按钮都点不到（hitTest 为空）：\(found.map(\.rect))"
        )
    }

    // MARK: - 判据 1：每一档纵向滚动都有入口，且位置不随滚动改变

    /// 纵向滚 0 / 半屏 / 两屏三档：**每档**视口里都必须有可点入口，且存在位置不变的那一个。
    ///
    /// v1.4.0 上两个入口都挂在滚动内容里：提示贴内容顶部（滚一屏就没），今天胶囊是
    /// .leading/.trailing 对齐 ⇒ 在整块内容里**垂直居中**（视口外几百点）。所以半屏那一档
    /// 开始视口里就什么都没有了——这就是用户说的「朝右滚动之后按钮不见了」。
    ///
    /// 位置不变这条不过度限制实现形态：按行铺的入口（每行一个）也满足——只要每一档滚动的
    /// 视口里都有它，用户就不会遇到「找不到入口」。
    @Test func entryIsPresentAndClickableAtEveryScrollOffset() async throws {
        // 三档 offset 共用同一个夹具实例：每档重建一次窗口等于把「重排落定」这件事乘以三，
        // 而这三次开窗在 CI 上正是最贵的那部分。
        let fixture = try await makeFixture(pannedBeyondSchedule: true)
        defer { try? FileManager.default.removeItem(at: fixture.projectDirectory) }

        let viewport = viewportRect(fixture)
        let half = viewport.height / 2
        let twoScreens = viewport.height * 2
        let maxScroll = max((canvasScrollView(fixture)?.documentView?.frame.height ?? 0) - viewport.height, 0)
        #expect(
            twoScreens <= maxScroll + 1,
            "夹具无效：内容只能滚 \(maxScroll)pt，够不到两屏 \(twoScreens)pt——测的是「滚不动」而不是入口位移"
        )

        var samples: [[CGRect]] = []
        for offset in [CGFloat(0), half, twoScreens] {
            let landed = await scroll(fixture, to: offset)
            #expect(
                abs(landed - offset) <= 1,
                "夹具未滚到位：期望 \(offset)，实际 \(landed)"
            )
            let found = await waitForEntry(in: fixture)
            samples.append(found.map(\.rect))
            #expect(
                !found.isEmpty,
                "滚动 \(offset)pt 后视口里没有入口（D-054）：viewport=\(viewport) 全部按钮=\(candidates(in: fixture).map(\.rect))"
            )
            #expect(
                !clickable(found, in: fixture).isEmpty,
                "滚动 \(offset)pt 后视口里的入口点不到：\(found.map(\.rect))"
            )
        }

        // 位置不变：同一个矩形在三档滚动里都出现过（每档都有的行内入口同样满足）。
        let pinned = samples[0].filter { first in
            samples.dropFirst().allSatisfy { sample in
                sample.contains { rectsMatch($0, first) }
            }
        }
        #expect(
            !pinned.isEmpty,
            """
            三档滚动下视口内没有位置一致的入口（D-054）：
            offset 0  视口内按钮 \(samples[0])
            offset \(half) 视口内按钮 \(samples[1])
            offset \(twoScreens) 视口内按钮 \(samples[2])
            viewport=\(viewport)
            """
        )
    }

    // MARK: - 判据 2：朝右平移到排期之外后，入口仍在视口内且可点

    /// 窗口在排期之后 + 纵向滚到两屏：视口里必须还有**可点**入口。
    ///
    /// 这里不合成点击，理由见文件末尾「为什么不点」一节：离屏窗口在测试进程里无法成为
    /// key window，鼠标事件不派发（实测连状态栏按钮都不响应，两种坐标约定都试过）。
    /// 点击链路拆成两段分别钉：入口可点由本用例钉；点了会怎样由
    /// returnToScheduleActionLandsWindowInSchedule 钉（那正是 navigation.action 派发的动作）。
    @Test func entryStaysClickableAfterPanningFarRight() async throws {
        let fixture = try await makeFixture(pannedBeyondSchedule: true)
        defer { try? FileManager.default.removeItem(at: fixture.projectDirectory) }

        let viewport = viewportRect(fixture)
        let offset = min(
            viewport.height * 2,
            max((canvasScrollView(fixture)?.documentView?.frame.height ?? 0) - viewport.height, 0)
        )
        await scroll(fixture, to: offset)

        let found = await waitForEntry(in: fixture)
        #expect(
            !found.isEmpty,
            "朝右平移到排期之外、纵滚 \(offset)pt 后，视口内没有入口（D-054）：viewport=\(viewport) 全部按钮=\(candidates(in: fixture).map(\.rect))"
        )

        let hitTestable = clickable(found, in: fixture)
        #expect(
            !hitTestable.isEmpty,
            "视口内的入口点不到（hitTest 落空），等于没有：\(found.map(\.rect))"
        )
    }

    // MARK: - 判据 3：入口的动作真的能把窗口带回排期

    /// 窗口在排期之后时，快照给的导航是 .offSchedule(.behind)，其 action 就是
    /// 入口实装的派发值（呈现层 navigationActionsMatchEntrySemantics 钉住映射）。
    /// 这里派发同一个动作，断言落点：
    /// 1) 窗口与排期区间相交；2) 画布有任务条；3) 窗口右缘够到排期末（behind 口径）；
    /// 4) 日宽档位不被改写（回到排期 ≠ 适合项目）。
    @Test func returnToScheduleActionLandsWindowInSchedule() async throws {
        let fixture = try await makeFixture(pannedBeyondSchedule: true)
        defer { try? FileManager.default.removeItem(at: fixture.projectDirectory) }

        let before = fixture.store.snapshot.gantt
        #expect(
            before.navigation == .offSchedule(.behind),
            "夹具前提：窗口在排期之后，navigation 应为 .offSchedule(.behind)，实测 \(String(describing: before.navigation))"
        )
        let range = try #require(before.scheduleRange, "夹具前提：快照必须给出排期区间")
        let dayWidth = before.dayWidth

        fixture.store.dispatch(.returnToSchedule)

        let after = fixture.store.snapshot.gantt
        #expect(
            after.windowEnd > range.start && after.windowStart < range.end,
            "回到排期后窗口必须与排期相交：window=\(after.windowStart)..\(after.windowEnd) schedule=\(range)"
        )
        #expect(!after.bars.isEmpty, "回到排期后画布必须有任务条，实测 \(after.bars.count) 条")
        // architect 判据是「start + span >= schedule.end」；实现把起点归一到当日零点，
        // 于是允许 < 1 天的下偏（起点floor 会把窗口整体往前挪）。超过一天就是真错。
        #expect(
            after.windowEnd >= range.end.addingTimeInterval(-86_400),
            "behind 落点应让窗口右缘够到排期末（允许日内取整误差）：windowEnd=\(after.windowEnd) scheduleEnd=\(range.end)"
        )
        #expect(
            abs(after.dayWidth - dayWidth) < 0.001 && after.usesFitZoom == false,
            "回到排期不该改日宽档位：dayWidth \(dayWidth) → \(after.dayWidth)，fit=\(after.usesFitZoom)"
        )
        // 落回后可能还剩下少量外溢条（取整误差），那是 .offWindow，不是 .offSchedule。
        #expect(
            after.navigation != .offSchedule(.behind) && after.navigation != .offSchedule(.ahead),
            "落回排期后不该再判定为「窗口在排期之外」，实测 \(String(describing: after.navigation))"
        )
    }
}

// 为什么不合成点击（实测记录，避免下一个人重复踩）：
// 离屏 NSWindow 在本测试进程里 makeKeyAndOrderFront 后 isKeyWindow 仍为 false，
// window.sendEvent(leftMouseDown/Up) 与 NSApp.sendEvent 都不派发到 SwiftUI Button——
// 对照组的「状态栏今天按钮」同样不响应，两种坐标约定（窗口基准 / host 翻转）都试过。
// 因此点击一律不写进断言；链路由「入口可点（本文件）+ 动作落点（本文件）+ 动作映射（呈现层）」闭合。


private extension ProcessInfo {
    /// 门控用：当前系统是否 macOS 27 及以上（离屏控件定位在 26 上不可用，见套件注释）。
    var isAtLeastMacOS27: Bool { operatingSystemVersion.majorVersion >= 27 }
}
