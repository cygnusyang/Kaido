import AppKit
import Foundation
import SwiftUI
import Testing
import KaidoCore
import KaidoPresentation
@testable import KaidoMacApp

/// D-050 验收：横向滚动承接层必须与内容处在**同一位移单元**里。
///
/// 现象（v1.3.7 用户反馈）：甘特画布内纵向滚一段之后，左右滑动完全不动；滚回顶部又恢复。
/// 根因：承接层挂在 `.offset(y:)` **外面**（`Canvas.offset(y:).background(Surface)`）——
/// 位移只作用在内容上，承接层留在未位移的布局位置，纵向滚过一屏后它整条移出视口，
/// `ScrollSurfaceView.cursorInsideBounds()` 因此恒为 false，横向事件全被放行。
///
/// 两套件分工：
/// - 套件 A（placement 不变量，不需要真滚动）：承接层与内容在宿主坐标里重合，并随之越过一屏；
/// - 套件 B（端到端复现）：真 `ScrollView` + 真 `TimelineBody`，滚到 2×viewportHeight 后
///   命中判定必须仍为 true、横向滚轮必须真的推进窗口起点 —— 修复前这两条必红。
/// `.serialized`：本套件的夹具要在 main runloop 上做**条件等待**（离屏窗口没有 display link 驱动，
/// 布局是异步落下来的），并共享离屏窗口与主 runloop 夹具；并行跑会互相抢窗口与监听（v1.4.0 起
/// `ScrollSurfaceView` 已无 `static active`，监听按视图各装一条，抢的是窗口与 runloop 而非仲裁点）。
///
/// **同步口径（本文件不使用固定睡眠）**：每个断言的等待条件都是它自己的前提——
/// 套件 A 等「内容已随 offset 位移、承接层已有非零尺寸」且连续两轮采样一致；
/// 套件 B 等「承接层的窗口坐标矩形已覆盖视口」。固定睡眠在 2 核 runner 上要么白等要么踩空（#26/#27）。
@Suite(.serialized)
@MainActor
struct TimelineCanvasViewportTests {

    // MARK: - 夹具：探针内容与视图树搜索

    /// 把 SwiftUI 造出来的 NSView 交回测试侧（`Canvas` 没有可供断言的 frame）。
    private final class ProbeBox {
        var view: NSView?
    }

    /// 探针内容：真实 NSView，`convert(bounds, to:)` 才有意义。
    private struct ProbeContent: NSViewRepresentable {
        let box: ProbeBox

        func makeNSView(context: Context) -> NSView {
            let view = NSView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            box.view = view
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    /// 一次排布的结果：宿主、内容探针、承接层。
    private struct Placement {
        /// 窗口必须一起持有：窗口释放会把视图从层级里摘下来，坐标换算就不再是「排布后」的现场。
        let window: NSWindow
        let host: NSHostingView<AnyView>
        let content: NSView
        let surface: GanttScrollSurface.ScrollSurfaceView
    }

    /// 端到端夹具：真滚动容器 + 真画布。
    private struct ScrolledFixture {
        let window: NSWindow
        let scrollView: NSScrollView
        let surface: GanttScrollSurface.ScrollSurfaceView
        let store: WorkspaceStore
        let canvasWidth: CGFloat
        let viewportHeight: CGFloat
    }

    /// 离屏窗口：不进窗口的话 SwiftUI 不会实例化平台视图，坐标换算也无从谈起。
    /// 不 `makeKeyAndOrderFront`，不抢焦点。
    private func makeWindow(width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        return window
    }

    /// 套件 A 与漂移反证的共同断言前提：**排布落定**。
    ///
    /// 判据 = 谓词成立 且 **连续两轮 runloop 采样一致**。离屏窗口没有 display link 驱动，
    /// 布局是异步落下来的；固定睡眠在 2 核 runner 上要么白等要么踩空（本仓 #26/#27 的假红即此类）。
    /// 超时返回 false，由调用方的 `#expect` 带着实测矩形变红 —— 这样「夹具没排布」与「实现真错」
    /// 在失败信息上能分开，而不是都表现成一个含义不明的等待。
    private func waitForStableLayout(
        _ placement: Placement,
        timeout: TimeInterval = 5,
        matching predicate: (CGRect, CGRect) -> Bool
    ) -> Bool {
        func sample() -> (content: CGRect, surface: CGRect) {
            (
                placement.content.convert(placement.content.bounds, to: placement.host),
                placement.surface.convert(placement.surface.bounds, to: placement.host)
            )
        }

        let deadline = Date().addingTimeInterval(timeout)
        var previous: (content: CGRect, surface: CGRect)?
        while Date() < deadline {
            let current = sample()
            if predicate(current.content, current.surface),
               let previous,
               rectsMatch(previous.content, current.content, tolerance: 0.01),
               rectsMatch(previous.surface, current.surface, tolerance: 0.01) {
                return true
            }
            previous = current
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        let last = sample()
        return predicate(last.content, last.surface)
    }

    private func findSurface(in view: NSView) -> GanttScrollSurface.ScrollSurfaceView? {
        if let surface = view as? GanttScrollSurface.ScrollSurfaceView { return surface }
        for subview in view.subviews {
            if let found = findSurface(in: subview) { return found }
        }
        return nil
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = findScrollView(in: subview) { return found }
        }
        return nil
    }

    /// 轮询直到条件成立：SwiftUI 的平台视图实例化与重排是异步的，固定 sleep 要么慢要么脆。
    @discardableResult
    private func waitFor(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    /// 矩形比对容差：坐标转换 + 布局取整，0.5pt 足够严（D-050 的偏差是一整屏）。
    private func rectsMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    // MARK: - 套件 A：placement 不变量

    /// 在指定 offset 下把 `TimelineCanvasViewport` 装进离屏窗口并完成一次布局。
    private func makePlacement(
        offset: CGFloat,
        width: CGFloat = 600,
        viewportHeight: CGFloat = 400
    ) throws -> Placement {
        let window = makeWindow(width: width, height: viewportHeight)
        let box = ProbeBox()
        let root = TimelineCanvasViewport(
            offset: offset,
            width: width,
            viewportHeight: viewportHeight,
            dayWidth: 10,
            onDays: { _ in },
            content: { ProbeContent(box: box) }
        )
        let host = NSHostingView(rootView: AnyView(root))
        host.frame = CGRect(x: 0, y: 0, width: width, height: viewportHeight)
        window.contentView?.addSubview(host)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        waitFor { findSurface(in: host) != nil && box.view != nil }

        let surface = try #require(
            findSurface(in: host),
            "承接层未进入视图树：TimelineCanvasViewport 必须把 GanttScrollSurface 也装进去"
        )
        let content = try #require(
            box.view,
            "内容探针未创建：viewport 必须挂载 content"
        )
        let placement = Placement(window: window, host: host, content: content, surface: surface)

        // 断言前提：排布落定 —— 内容已随 offset 位移、承接层已拿到非零尺寸、两轮采样一致。
        // 不满足时后面的矩形比对读到的是半截排布，任何结论都不可信。
        let settled = waitForStableLayout(placement) { contentRect, surfaceRect in
            abs(contentRect.minY - offset) <= 1
                && contentRect.width > 1 && contentRect.height > 1
                && surfaceRect.width > 1 && surfaceRect.height > 1
        }
        #expect(
            settled,
            "排布未在 5s 内落定（夹具问题优先排查）：content=\(content.convert(content.bounds, to: host)) surface=\(surface.convert(surface.bounds, to: host)) offset=\(offset)"
        )
        return placement
    }

    /// offset = 0：承接层与内容重合。夹具自检项——这条在任何实现下都该绿。
    @Test func surfaceCoincidesWithContentAtZeroOffset() throws {
        let width: CGFloat = 600
        let viewportHeight: CGFloat = 400
        let placement = try makePlacement(offset: 0, width: width, viewportHeight: viewportHeight)
        defer { placement.surface.stopMonitoring() }

        let contentRect = placement.content.convert(placement.content.bounds, to: placement.host)
        let surfaceRect = placement.surface.convert(placement.surface.bounds, to: placement.host)

        // 夹具口径（dev-coder-gantt 提醒）：content 矩形以 wrapper 的 .frame 为准，即 probe 必须撑满
        // width × viewportHeight。裸 NSView 返回 NoIntrinsicMetric 会撑满；日后若给 probe 加了尺寸、
        // 被 .frame 的默认居中对齐缩成小矩形，这里先红 —— 那是夹具问题，不是 D-050 复现。
        #expect(
            abs(contentRect.width - width) <= 0.5 && abs(contentRect.height - viewportHeight) <= 0.5,
            "夹具口径失效：probe 未撑满 wrapper（content=\(contentRect)，期望 \(width)×\(viewportHeight)）"
        )
        #expect(surfaceRect.width > 1 && surfaceRect.height > 1, "承接层塌成零尺寸，命中判定永远 false：\(surfaceRect)")
        #expect(
            rectsMatch(surfaceRect, contentRect),
            "offset = 0 时承接层必须与内容重合：surface=\(surfaceRect) content=\(contentRect)"
        )
        #expect(abs(surfaceRect.minY) <= 0.5, "offset = 0 时承接层应贴在宿主顶部，实测 \(surfaceRect)")
    }

    /// offset = 300（半屏）：承接层必须跟着内容一起下移，不能留在顶部。
    @Test func surfaceFollowsContentWhenOffset() throws {
        let offset: CGFloat = 300
        let placement = try makePlacement(offset: offset)
        defer { placement.surface.stopMonitoring() }

        let contentRect = placement.content.convert(placement.content.bounds, to: placement.host)
        let surfaceRect = placement.surface.convert(placement.surface.bounds, to: placement.host)

        // 夹具假设：content 顶格、offset 就是位移量。若不是（实现改用了别的排布手段），
        // 这条会先红，提示契约需要重新对齐，而不是让后面的断言变成空断言。
        #expect(
            abs(contentRect.minY - offset) <= 1,
            "内容没有随 offset 位移，夹具假设不成立：content=\(contentRect) offset=\(offset)"
        )
        #expect(
            rectsMatch(surfaceRect, contentRect),
            "承接层没有跟着内容走（D-050 根因）：surface=\(surfaceRect) content=\(contentRect)"
        )
    }

    /// offset = 1200（远超一屏）：正是 D-050 里「滚过一屏、承接层整条出视口」的位置。
    @Test func surfaceStaysWithContentBeyondOneViewport() throws {
        let offset: CGFloat = 1200
        let placement = try makePlacement(offset: offset)
        defer { placement.surface.stopMonitoring() }

        let contentRect = placement.content.convert(placement.content.bounds, to: placement.host)
        let surfaceRect = placement.surface.convert(placement.surface.bounds, to: placement.host)

        #expect(
            abs(contentRect.minY - offset) <= 1,
            "内容没有随 offset 位移，夹具假设不成立：content=\(contentRect) offset=\(offset)"
        )
        #expect(
            rectsMatch(surfaceRect, contentRect),
            "越过一屏后承接层仍在内容上（D-050 判据）：surface=\(surfaceRect) content=\(contentRect)"
        )
        #expect(
            surfaceRect.minY > 1000,
            "承接层没有越过一屏位移（minY=\(surfaceRect.minY)）：旧排布下它停在这里，纵向滚动一屏后即出视口"
        )
    }

    /// 反证（negative control）：按修改前的排布（`.offset` 写在 `.background` **之前**）搭一遍，
    /// 承接层必须**不**与内容重合 —— 这条用来证明上面三条断言不是空断言，而是真能抓住 D-050。
    /// 它哪天红了，说明 SwiftUI 的 offset/background 语义变了，D-050 的根因描述需要重新核对。
    @Test func legacyOffsetBeforeBackgroundLeavesSurfaceBehind() throws {
        let offset: CGFloat = 300
        let width: CGFloat = 600
        let viewportHeight: CGFloat = 400
        let window = makeWindow(width: width, height: viewportHeight)
        let box = ProbeBox()

        // 修改前的写法，原样复刻：位移只作用在内容上，承接层贴在未位移的布局位置。
        let legacy = ProbeContent(box: box)
            .frame(width: width, height: viewportHeight)
            .offset(y: offset)
            .background(GanttScrollSurface(dayWidth: 10) { _ in })

        let host = NSHostingView(rootView: AnyView(legacy))
        host.frame = CGRect(x: 0, y: 0, width: width, height: viewportHeight)
        window.contentView?.addSubview(host)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        waitFor { findSurface(in: host) != nil && box.view != nil }

        let content = try #require(box.view, "内容探针未创建")
        let surface = try #require(findSurface(in: host), "承接层未进入视图树")
        defer { surface.stopMonitoring() }

        // 断言前提：反证也必须在落定的排布上取样 —— 半截排布下的「不重合」是假绿。
        let placement = Placement(window: window, host: host, content: content, surface: surface)
        let settled = waitForStableLayout(placement) { contentRect, surfaceRect in
            abs(contentRect.minY - offset) <= 1
                && contentRect.width > 1 && contentRect.height > 1
                && surfaceRect.width > 1 && surfaceRect.height > 1
        }
        #expect(
            settled,
            "反证夹具未在 5s 内落定（夹具问题优先排查）：content=\(content.convert(content.bounds, to: host)) surface=\(surface.convert(surface.bounds, to: host))"
        )

        let contentRect = content.convert(content.bounds, to: host)
        let surfaceRect = surface.convert(surface.bounds, to: host)

        // 先钉住「承接层真的被排布过」：零尺寸的视图和任何矩形都不重合，会让下面这条变成假绿。
        #expect(
            surfaceRect.width > 1 && surfaceRect.height > 1,
            "反证夹具无效：承接层塌成零尺寸 \(surfaceRect)"
        )
        #expect(abs(contentRect.minY - offset) <= 1, "内容应随 offset 位移：content=\(contentRect)")
        #expect(
            !rectsMatch(surfaceRect, contentRect),
            "修改前的排布竟然也重合了 —— 反证失效，D-050 的根因描述需重新核对：surface=\(surfaceRect) content=\(contentRect)"
        )
        #expect(
            abs(surfaceRect.minY) <= 0.5,
            "旧排布下承接层应停在未位移的布局位置（minY≈0），实测 \(surfaceRect.minY)"
        )
    }

    /// 按调用方给的容器形态排一遍，返回内容与承接层在宿主坐标里的矩形。
    /// 与 `makePlacement` 共用同一套「离屏窗口 + 条件等待」口径，反证与正证因此可比。
    private func driftedRects(
        width: CGFloat,
        viewportHeight: CGFloat,
        _ build: (ProbeContent) -> AnyView
    ) throws -> (content: CGRect, surface: CGRect) {
        let window = makeWindow(width: width, height: viewportHeight)
        let box = ProbeBox()
        let host = NSHostingView(rootView: build(ProbeContent(box: box)))
        host.frame = CGRect(x: 0, y: 0, width: width, height: viewportHeight)
        window.contentView?.addSubview(host)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        waitFor { findSurface(in: host) != nil && box.view != nil }

        let surface = try #require(findSurface(in: host), "承接层未进入视图树")
        defer { surface.stopMonitoring() }
        let content = try #require(box.view, "内容探针未创建")

        // 断言前提：两者都排布出非零尺寸且两轮采样一致。零尺寸矩形与任何矩形都不重合，
        // 不钉住这点，下面的「必须不重合」会因为夹具没排布而变成假绿。
        let placement = Placement(window: window, host: host, content: content, surface: surface)
        let settled = waitForStableLayout(placement) { contentRect, surfaceRect in
            contentRect.width > 1 && contentRect.height > 1
                && surfaceRect.width > 1 && surfaceRect.height > 1
        }
        #expect(
            settled,
            "漂移夹具未在 5s 内完成排布（夹具问题优先排查）：content=\(content.convert(content.bounds, to: host)) surface=\(surface.convert(surface.bounds, to: host))"
        )

        return (
            content: content.convert(content.bounds, to: host),
            surface: surface.convert(surface.bounds, to: host)
        )
    }

    /// 结构漂移反证（对应 `TimelineCanvasViewport.swift:15-19` 的承重不变量：
    /// 「`.offset` 只有一个出口，且位于 `.background` 之后」）。
    ///
    /// 在 content 与 `GanttScrollSurface` 之间多套一层可位移 / 可裁切的容器，
    /// 「承接层矩形 == 内容矩形」这条判据必须为**假**。
    /// 为什么需要它：套件 A 的三条断言全是「两矩形重合」，一旦重合判据因 SwiftUI 语义变化退化成
    /// 永远成立的空断言，它们会一起变绿而 D-050 再也复现不出来。本用例把两种真实会出现的漂移形态
    /// （再叠一层 `.offset`；用 `padding` 撑开一层容器）钉死为「必须不重合」。生产侧若真被加进
    /// 这样一层 wrapper，红的是套件 A 的重合用例 —— 两者互为对照。
    @Test func wrapperDriftBetweenContentAndSurfaceBreaksCoincidence() throws {
        let width: CGFloat = 600
        let viewportHeight: CGFloat = 400

        // 形态一：内层再多一层位移 —— 内容被推走 40pt，承接层留在未位移的布局位置。
        let shifted = try driftedRects(width: width, viewportHeight: viewportHeight) { probe in
            AnyView(
                probe
                    .frame(width: width, height: viewportHeight)
                    .offset(y: 40)
                    .background(GanttScrollSurface(dayWidth: 10) { _ in })
            )
        }
        #expect(
            abs(shifted.content.minY - 40) <= 1,
            "漂移夹具无效：内容未随内层 offset 位移，反证会变成假绿：content=\(shifted.content)"
        )
        #expect(
            shifted.surface.width > 1 && shifted.surface.height > 1,
            "漂移夹具无效：承接层塌成零尺寸 \(shifted.surface)（零尺寸与任何矩形都不重合）"
        )
        #expect(
            !rectsMatch(shifted.surface, shifted.content),
            "多一层 offset 后仍判定重合 —— 套件 A 的重合判据已失效：surface=\(shifted.surface) content=\(shifted.content)"
        )

        // 形态二：内层再多一层 padding 容器 —— 500×300 的内容 + 50pt padding = 600×400 的承接层，
        // 尺寸与原点同时分叉（内容缩进 50pt），即「把内容包进内边距/裁切容器」的漂移形态。
        let padded = try driftedRects(width: width, viewportHeight: viewportHeight) { probe in
            AnyView(
                probe
                    .frame(width: width - 100, height: viewportHeight - 100)
                    .padding(50)
                    .background(GanttScrollSurface(dayWidth: 10) { _ in })
            )
        }
        #expect(
            abs(padded.surface.width - width) <= 0.5 && abs(padded.surface.height - viewportHeight) <= 0.5,
            "漂移夹具无效：padding 容器未撑成视口尺寸，反证会变成假绿：surface=\(padded.surface)"
        )
        #expect(
            !rectsMatch(padded.surface, padded.content),
            "多一层 padding 容器后仍判定重合 —— 套件 A 的重合判据已失效：surface=\(padded.surface) content=\(padded.content)"
        )
    }

    // MARK: - 套件 B：真 ScrollView 端到端复现（修复前必红）

    private func makeStore() -> WorkspaceStore {
        let suite = "kaido.viewport.d050.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return WorkspaceStore(
            defaults: defaults,
            seedsDemoData: true,
            projectLoader: { try KaidoFile.read(from: $0) }
        )
    }

    /// 合成一条精确滚动事件（`wheel2` = 横向像素位移，与 `scrollingDeltaX` 一一对应）。
    private func makeScrollEvent(deltaX: Int32 = 0, deltaY: Int32 = 0, shift: Bool = false) -> NSEvent {
        let cg = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        )!
        if shift { cg.flags = .maskShift }
        return NSEvent(cgEvent: cg)!
    }

    /// 端到端断言的共同前提：承接层在**窗口坐标**里的矩形已经覆盖视口矩形。
    ///
    /// 抽出来是为了让夹具能做条件等待而不是固定睡眠：离屏窗口没有 display link，
    /// 「滚动 → offset 重算 → 重排」之间没有任何可以踩的固定时间点。
    private func surfaceCoversViewport(
        _ surface: GanttScrollSurface.ScrollSurfaceView,
        scrollView: NSScrollView,
        viewportHeight: CGFloat
    ) -> Bool {
        // 不在窗口里时 `convert(_:to:)` 没有意义（也会打 AppKit 警告）。
        guard surface.window != nil else { return false }
        let surfaceRect = surface.convert(surface.bounds, to: nil)
        let viewportRect = scrollView.contentView.convert(scrollView.contentView.bounds, to: nil)
        return viewportRect.intersection(surfaceRect).height >= viewportHeight - 1
    }

    /// 真 `ScrollView` + 真 `TimelineBody`，滚到 `2 × viewportHeight`。
    ///
    /// 坐标空间名必须与 `WorkspaceView` 一致：`TimelineBody` 的 `GeometryReader`
    /// 靠 `.named(WorkspaceScrollSpace.name)` 读纵向位移，换了名字 offset 恒为 0，
    /// 这条用例就不再是 D-050 的场景。
    private func makeScrolledFixture() throws -> ScrolledFixture {
        let viewportHeight: CGFloat = 160
        let canvasWidth: CGFloat = 600
        let target = viewportHeight * 2

        let store = makeStore()
        // 演示项目只有 10 行（280pt），滚不到两屏；补 20 行把内容抬到 840pt，
        // 保证 `target` 没被内容高度截断——否则测的是「滚不动」而不是 D-050。
        for _ in 0..<20 {
            store.dispatch(.createTask(parentID: nil, kind: .task))
        }
        let snapshot = store.snapshot
        let body = TimelineBody(
            store: store,
            rows: snapshot.outline.rows,
            gantt: snapshot.gantt,
            width: canvasWidth,
            viewportHeight: viewportHeight
        )
        let root = ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                body
            }
            .frame(width: canvasWidth, alignment: .topLeading)
        }
        .coordinateSpace(name: WorkspaceScrollSpace.name)

        let window = makeWindow(width: canvasWidth, height: viewportHeight)
        let host = NSHostingView(rootView: AnyView(root))
        host.frame = CGRect(x: 0, y: 0, width: canvasWidth, height: viewportHeight)
        window.contentView?.addSubview(host)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        waitFor { findScrollView(in: host) != nil && findSurface(in: host) != nil }

        let scrollView = try #require(
            findScrollView(in: host),
            "SwiftUI ScrollView 未落成 NSScrollView，端到端夹具无法滚动"
        )
        let surface = try #require(
            findSurface(in: host),
            "承接层未进入视图树"
        )

        // 断言前提：监听在岗。D-028 的真实故障面正是「视图在窗口里、监听却被摘掉或被抢走」，
        // 那时 `handle()` 根本走不到，端到端判据会以错误的理由给出结论。
        let monitoringUp = waitFor(timeout: 5) { surface.isMonitoring }
        #expect(
            monitoringUp,
            "承接层 5s 内未进入监听（isMonitoring == false）：D-028 的失效面，端到端判据不成立"
        )

        // 断言前提：内容已排布到「能滚过两屏」的高度，否则测的是「滚不动」而不是 D-050。
        let contentLaidOut = waitFor(timeout: 5) {
            (scrollView.documentView?.frame.height ?? 0) > viewportHeight * 2
        }
        let contentHeight = scrollView.documentView?.frame.height ?? 0
        #expect(
            contentLaidOut,
            "夹具内容高 \(contentHeight) 在 5s 内未超过两屏（\(viewportHeight * 2)pt），D-050 场景不成立"
        )

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        // 滚动 → SwiftUI 重算 offset → 重新排布，是异步链路：先等 AppKit 落位（条件等待），
        // 再等承接层的新矩形覆盖视口（下一条），全程不用固定睡眠。
        waitFor(timeout: 5) { abs(scrollView.contentView.bounds.origin.y - target) <= 1 }

        let landed = scrollView.contentView.bounds.origin.y
        #expect(
            abs(landed - target) <= 1,
            "夹具未滚到位：期望 \(target)，实际 \(landed)"
        )

        // 断言前提：承接层的窗口坐标矩形已覆盖视口 —— 这就是 D-050 的判据本体。
        // 各用例仍会显式复核：这里红 = 夹具没等到重排，那里红 = 实现真错。
        let covering = waitFor(timeout: 5) {
            surfaceCoversViewport(surface, scrollView: scrollView, viewportHeight: viewportHeight)
        }
        #expect(
            covering,
            "承接层 5s 内未覆盖视口：surface=\(surface.convert(surface.bounds, to: nil)) viewport=\(scrollView.contentView.convert(scrollView.contentView.bounds, to: nil))"
        )

        return ScrolledFixture(
            window: window,
            scrollView: scrollView,
            surface: surface,
            store: store,
            canvasWidth: canvasWidth,
            viewportHeight: viewportHeight
        )
    }

    /// 光标放在视口中心（窗口内容视图顶格，窗口坐标即内容坐标）。
    private func pointCursorAtViewportCenter(_ fixture: ScrolledFixture) {
        let center = CGPoint(x: fixture.canvasWidth / 2, y: fixture.viewportHeight / 2)
        fixture.surface.cursorInScreen = { fixture.window.convertPoint(toScreen: center) }
    }

    /// D-050 的判据本体：纵向滚过两屏后，光标在视口内时命中判定必须为 true。
    /// 修复前承接层随内容一起被滚出视口 ⇒ 这里为 false ⇒ 横向滑动整段失效。
    @Test func surfaceCoversViewportAfterDeepScroll() throws {
        let fixture = try makeScrolledFixture()
        defer { fixture.surface.stopMonitoring() }

        #expect(fixture.surface.window === fixture.window, "承接层不在窗口里：命中判定必然 false，夹具无效")
        pointCursorAtViewportCenter(fixture)

        let surfaceRect = fixture.surface.convert(fixture.surface.bounds, to: nil)
        let viewportRect = fixture.scrollView.contentView.convert(fixture.scrollView.contentView.bounds, to: nil)
        #expect(
            surfaceRect.height >= fixture.viewportHeight - 1,
            "承接层高度 \(surfaceRect.height) 未覆盖视口高 \(fixture.viewportHeight)"
        )
        #expect(
            viewportRect.intersection(surfaceRect).height >= fixture.viewportHeight - 1,
            "承接层已移出视口：surface=\(surfaceRect) viewport=\(viewportRect)"
        )
        #expect(
            fixture.surface.cursorInsideBounds(),
            "D-050：滚过两屏后光标在视口内，cursorInsideBounds() 必须为 true"
        )
    }

    /// 端到端：深滚动后一条横向滚轮既要被消费，也要真的推进窗口起点（内容跟手）。
    @Test func horizontalWheelPansAfterDeepScroll() throws {
        let fixture = try makeScrolledFixture()
        defer { fixture.surface.stopMonitoring() }

        pointCursorAtViewportCenter(fixture)

        let dayWidth = fixture.store.snapshot.gantt.dayWidth
        #expect(dayWidth > 1, "夹具日宽异常：\(dayWidth)pt/天")
        let before = fixture.store.snapshot.gantt.windowStart
        let event = makeScrollEvent(deltaX: 30)

        #expect(
            fixture.surface.handle(event) == nil,
            "视口内的横向滚动必须被消费（返回 nil）；原样返回 = 横向平移失效（D-050）"
        )

        let after = fixture.store.snapshot.gantt.windowStart
        // 正位移 = 看更早日期 = 窗口起点向过去推进（WorkspaceStore.panWindow 口径）。
        let movedDays = before.timeIntervalSince(after) / 86_400
        let expectedDays = 30 / dayWidth
        #expect(
            abs(movedDays - expectedDays) < 0.01,
            "窗口起点应前移 \(expectedDays) 天，实测 \(movedDays) 天"
        )
    }
}
