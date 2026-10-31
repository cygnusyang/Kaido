import Foundation
import Testing
import KaidoCore
import KaidoPresentation
@testable import KaidoMacApp

// F-14-09 画布拖拽状态机单测（引用语义直驱，GUIRenderTests 无法模拟手势事件的替代载体）。
//
// 覆盖点：拖条改期 / 拖端点改持续的提交值与节流、finish 必提交末值（设计稿 R-02 同源）、
// cancel 零提交、连线方向语义与自连拒绝、duration ≥ 1 天夹取、预览态一致性。

@MainActor
@Suite struct CanvasDragSessionTests {
    private let sourceID = UUID()
    private let targetID = UUID()
    private let windowStart = makeFixtureDate(2025, 3, 1)

    private func makeAnchor(
        id: UUID? = nil,
        x: Double = 100,
        duration: Double = 5,
        kind: GanttBar.Kind = .task
    ) -> CanvasDragSession.Anchor {
        CanvasDragSession.Anchor(
            bar: GanttBar(taskID: id ?? sourceID, rowIndex: 0, x: x, width: duration * 10, kind: kind),
            durationDays: duration,
            windowStart: windowStart,
            dayWidth: 10
        )
    }

    /// 提交收集盒：数组是值类型，必须经引用盒子才能在闭包外读到后续 append。
    private final class CommitBox {
        var commits: [CanvasDragSession.Commit] = []
        var count: Int { commits.count }
        subscript(_ index: Int) -> CanvasDragSession.Commit { commits[index] }
    }

    private func makeSession() -> (CanvasDragSession, CommitBox) {
        let box = CommitBox()
        let session = CanvasDragSession { box.commits.append($0) }
        return (session, box)
    }

    // 注：节流实现不含延迟任务（D-020），全部用例同步断言，不依赖真实时钟。

    // MARK: - 拖条改期

    @Test func moveCommitsStartDate() {
        let (session, box) = makeSession()
        session.begin(target: .body(sourceID), anchor: makeAnchor())
        session.update(translationX: 50, pointX: 0, pointY: 0, canvasOffset: 0, targetID: nil)
        // 起点 day 10 + 位移 5 天。
        #expect(box.commits == [.move(id: sourceID, startDate: makeFixtureDate(2025, 3, 16))])
    }

    @Test func movePreviewMatchesOffset() {
        let (session, _) = makeSession()
        let anchor = makeAnchor()
        session.begin(target: .body(sourceID), anchor: anchor)
        session.update(translationX: 30, pointX: 0, pointY: 0, canvasOffset: 0, targetID: nil)
        #expect(session.preview == .bar(CanvasDragSession.BarPreview(
            bar: anchor.bar, startDay: 13, durationDays: 5
        )))
    }

    @Test func negativeTranslationMovesEarlier() {
        let (session, box) = makeSession()
        session.begin(target: .body(sourceID), anchor: makeAnchor())
        session.update(translationX: -30, pointX: 0, pointY: 0, canvasOffset: 0, targetID: nil)
        #expect(box.commits == [.move(id: sourceID, startDate: makeFixtureDate(2025, 3, 8))])
    }

    // MARK: - 节流与收尾

    @Test func throttleSkipsWithinWindowThenFinishCommitsTrailingValue() {
        let (session, box) = makeSession()
        session.begin(target: .body(sourceID), anchor: makeAnchor())
        session.update(translationX: 10, pointX: 0, pointY: 0, canvasOffset: 0, targetID: nil)
        // 节流窗口内的第二笔跳过（不提交），预览仍跟进。
        session.update(translationX: 20, pointX: 0, pointY: 0, canvasOffset: 0, targetID: nil)
        #expect(box.count == 1)
        #expect(box.commits.last == .move(id: sourceID, startDate: makeFixtureDate(2025, 3, 12)))
        session.finish()
        // 松手必提交末值（R-02 / D-010 同源纪律）。
        #expect(box.count == 2)
        #expect(box.commits.last == .move(id: sourceID, startDate: makeFixtureDate(2025, 3, 13)))
    }

    @Test func duplicateValuesAreSkipped() {
        let (session, box) = makeSession()
        session.begin(target: .body(sourceID), anchor: makeAnchor())
        session.update(translationX: 50, pointX: 0, pointY: 0, canvasOffset: 0, targetID: nil)
        session.update(translationX: 51, pointX: 0, pointY: 0, canvasOffset: 0, targetID: nil)
        // 51/10 → 5.1 → 5 天，与首笔同值，跳过。
        session.finish()
        #expect(box.count == 1)
    }

    @Test func finishCommitsFinalValueWithinThrottleWindow() {
        let (session, box) = makeSession()
        session.begin(target: .body(sourceID), anchor: makeAnchor())
        session.update(translationX: 50, pointX: 0, pointY: 0, canvasOffset: 0, targetID: nil)
        // 仍在节流窗口内的最后一笔：松手必须立即提交，不能丢（同 R-02/D-010）。
        session.update(translationX: 70, pointX: 0, pointY: 0, canvasOffset: 0, targetID: nil)
        session.finish()
        #expect(box.commits.last == .move(id: sourceID, startDate: makeFixtureDate(2025, 3, 18)))
        #expect(session.preview == nil)
    }

    @Test func cancelProducesNoFurtherCommits() {
        let (session, box) = makeSession()
        session.begin(target: .body(sourceID), anchor: makeAnchor())
        session.update(translationX: 10, pointX: 0, pointY: 0, canvasOffset: 0, targetID: nil)
        #expect(box.count == 1)
        session.cancel()
        #expect(box.count == 1)
        #expect(session.preview == nil)
    }

    // MARK: - 拖端点改持续

    @Test func resizeEndChangesDurationOnly() {
        let (session, box) = makeSession()
        session.begin(target: .endHandle(sourceID), anchor: makeAnchor())
        session.update(translationX: 30, pointX: 0, pointY: 0, canvasOffset: 0, targetID: nil)
        #expect(box.commits == [.resize(id: sourceID, startDate: nil, durationDays: 8)])
    }

    @Test func resizeStartKeepsFinishDate() {
        let (session, box) = makeSession()
        session.begin(target: .startHandle(sourceID), anchor: makeAnchor())
        session.update(translationX: 20, pointX: 0, pointY: 0, canvasOffset: 0, targetID: nil)
        // start +2 天、duration −2：end 不变（day 15 = 2025-03-16）。
        #expect(box.commits == [.resize(id: sourceID, startDate: makeFixtureDate(2025, 3, 13), durationDays: 3)])
    }

    @Test func resizeStartClampsToMinimumDuration() {
        let (session, box) = makeSession()
        session.begin(target: .startHandle(sourceID), anchor: makeAnchor(duration: 3))
        session.update(translationX: 100, pointX: 0, pointY: 0, canvasOffset: 0, targetID: nil)
        // 位移 10 天超出 duration−1=2：夹取后 start +2、duration 1。
        #expect(box.commits == [.resize(id: sourceID, startDate: makeFixtureDate(2025, 3, 13), durationDays: 1)])
    }

    @Test func resizeEndClampsToMinimumDuration() {
        let (session, box) = makeSession()
        session.begin(target: .endHandle(sourceID), anchor: makeAnchor(duration: 3))
        session.update(translationX: -100, pointX: 0, pointY: 0, canvasOffset: 0, targetID: nil)
        #expect(box.commits == [.resize(id: sourceID, startDate: nil, durationDays: 1)])
    }

    // MARK: - 建依赖

    @Test func linkFromEndMakesSourcePredecessor() {
        let (session, box) = makeSession()
        session.begin(target: .dependencyEnd(sourceID), anchor: makeAnchor())
        session.update(translationX: 0, pointX: 300, pointY: 60, canvasOffset: 0, targetID: targetID)
        session.finish()
        #expect(box.commits == [.link(taskID: targetID, predecessorID: sourceID)])
    }

    @Test func linkFromStartMakesTargetPredecessor() {
        let (session, box) = makeSession()
        session.begin(target: .dependencyStart(sourceID), anchor: makeAnchor())
        session.update(translationX: 0, pointX: 300, pointY: 60, canvasOffset: 0, targetID: targetID)
        session.finish()
        #expect(box.commits == [.link(taskID: sourceID, predecessorID: targetID)])
    }

    @Test func linkWithoutTargetDoesNotCommit() {
        let (session, box) = makeSession()
        session.begin(target: .dependencyEnd(sourceID), anchor: makeAnchor())
        session.update(translationX: 0, pointX: 300, pointY: 60, canvasOffset: 0, targetID: nil)
        session.finish()
        #expect(box.commits.isEmpty)
    }

    @Test func linkToSelfDoesNotCommit() {
        let (session, box) = makeSession()
        session.begin(target: .dependencyEnd(sourceID), anchor: makeAnchor())
        session.update(translationX: 0, pointX: 300, pointY: 0, canvasOffset: 0, targetID: sourceID)
        session.finish()
        #expect(box.commits.isEmpty)
    }

    // MARK: - 非拖拽命中

    @Test func beginOnLineOrEmptyIsNoOp() {
        let (session, box) = makeSession()
        session.begin(target: .dependencyLine(0), anchor: makeAnchor())
        session.update(translationX: 50, pointX: 0, pointY: 0, canvasOffset: 0, targetID: nil)
        session.finish()
        #expect(session.preview == nil)
        #expect(box.commits.isEmpty)

        session.begin(target: .none, anchor: makeAnchor())
        session.update(translationX: 50, pointX: 0, pointY: 0, canvasOffset: 0, targetID: nil)
        session.finish()
        #expect(box.commits.isEmpty)
    }
}

private func makeFixtureDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    return Calendar.current.startOfDay(for: Calendar.current.date(from: components)!)
}
