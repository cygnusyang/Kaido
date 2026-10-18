import Foundation
import Testing
@testable import KairoCore

// 大纲层级编辑纯函数测试（US-E4-03 / F-14-02）。

private func task(_ title: String, kind: TaskKind = .task, parent: UUID? = nil) -> TaskItem {
    TaskItem(title: title, kind: kind, parentID: parent)
}

struct OutlineEditingTests {
    @Test func indentBecomesChildOfPreviousSibling() throws {
        let a = task("A")
        let b = task("B")
        let c = task("C")
        let updated = try #require(OutlineEditor.indent(c.id, in: [a, b, c]))
        #expect(updated.first { $0.id == c.id }?.parentID == b.id)
        #expect(updated.first { $0.id == a.id }?.parentID == nil)
    }

    @Test func indentFirstSiblingIsNoOp() {
        let a = task("A")
        let b = task("B")
        #expect(OutlineEditor.indent(a.id, in: [a, b]) == nil)
    }

    @Test func indentDoesNotCrossParentGroups() {
        let p = task("P", kind: .group)
        let a = task("A", parent: p.id)
        let q = task("Q", kind: .group)
        let c = task("C", parent: q.id)
        #expect(OutlineEditor.indent(c.id, in: [p, a, q, c]) == nil)
    }

    @Test func indentUsesPreviousSiblingWithinGroup() throws {
        let p = task("P", kind: .group)
        let a = task("A", parent: p.id)
        let b = task("B", parent: p.id)
        let updated = try #require(OutlineEditor.indent(b.id, in: [p, a, b]))
        #expect(updated.first { $0.id == b.id }?.parentID == a.id)
    }

    @Test func outdentMovesSubtreeAfterParentSubtree() throws {
        let p = task("P", kind: .group)
        let a = task("A", parent: p.id)
        let a1 = task("A1", parent: a.id)
        let b = task("B", parent: p.id)
        let d = task("D")
        let updated = try #require(OutlineEditor.outdent(a.id, in: [p, a, a1, b, d]))
        #expect(updated.map(\.title) == ["P", "B", "A", "A1", "D"])
        #expect(updated.first { $0.id == a.id }?.parentID == nil)
        #expect(updated.first { $0.id == a1.id }?.parentID == a.id)
    }

    @Test func outdentNestedBecomesSiblingOfParent() throws {
        let p = task("P", kind: .group)
        let q = task("Q", kind: .group, parent: p.id)
        let a = task("A", parent: q.id)
        let updated = try #require(OutlineEditor.outdent(a.id, in: [p, q, a]))
        #expect(updated.map(\.title) == ["P", "Q", "A"])
        #expect(updated.first { $0.id == a.id }?.parentID == p.id)
    }

    @Test func outdentTopLevelIsNoOp() {
        let a = task("A")
        let b = task("B")
        #expect(OutlineEditor.outdent(a.id, in: [a, b]) == nil)
    }

    @Test func siblingParentDependsOnKind() {
        let group = task("G", kind: .group)
        let child = task("C", parent: group.id)
        let root = task("R")
        let tasks = [group, child, root]
        #expect(OutlineEditor.siblingParent(for: group.id, in: tasks) == group.id)
        #expect(OutlineEditor.siblingParent(for: child.id, in: tasks) == group.id)
        #expect(OutlineEditor.siblingParent(for: root.id, in: tasks) == nil)
    }

    @Test func subtreeIncludesDescendantsAndGuardsCycles() {
        let a = task("A")
        let b = task("B", parent: a.id)
        let c = task("C", parent: b.id)
        let loop = TaskItem(title: "环", parentID: UUID())
        let selfParent = TaskItem(id: loop.id, title: "自环", parentID: loop.id)
        #expect(OutlineEditor.subtreeIDs(of: a.id, in: [a, b, c]) == Set([a.id, b.id, c.id]))
        #expect(OutlineEditor.subtreeIDs(of: loop.id, in: [selfParent]) == Set([loop.id]))
    }

    @Test func projectInsertPlacesAfterSibling() {
        let a = task("A")
        let c = task("C")
        let project = Project()
        project.add(a)
        project.add(c)
        let b = task("B")
        project.insert(b, after: a.id)
        #expect(project.tasks.map(\.title) == ["A", "B", "C"])
    }
}
