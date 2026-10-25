import Foundation
import Testing
import KairoCore
import KairoPresentation

// F-0719「实际开始 / 实际结束」（docs/features/07-actual-dates.md §5、§6、判据 11/12）。
//
// 大纲两个实际列是**可选列**：默认隐藏，用户显式打开后才进入列集合；
// 显隐状态独立于 hiddenOutlineColumns——旧用户存过隐藏偏好，若把新列默认值塞进
// 隐藏集合，升级后会凭空多出两列（design §5）。因此断言只锁定三件事：
// ① 缺省列集合逐位不变；② 显式启用后按契约位置插入；③ 聚焦模式忽略用户配置。

@Suite("大纲实际列（F-0719）")
struct ActualDatesPresentationTests {
    // MARK: - 可选列集合

    /// 可选列包含这两个实际列（v0.13 起另含基线四列），且与固定列/可隐藏列互不重叠。
    @Test func optionalContainsActualStartAndFinish() {
        #expect(OutlineColumnPreferences.optional.isSuperset(of: [.actualStart, .actualFinish]))
        #expect(OutlineColumnPreferences.optional.isDisjoint(with: OutlineColumnPreferences.alwaysVisible))
        #expect(Set(OutlineColumnPreferences.configurable).isDisjoint(with: OutlineColumnPreferences.optional))
    }

    /// 列宽与既有日期列同口径：13pt 正文下 78pt，随字号等比放大。
    @Test func optionalColumnWidthMatchesDateColumns() {
        #expect(OutlineColumn.actualStart.width(bodyFontSize: 13) == 78)
        #expect(OutlineColumn.actualFinish.width(bodyFontSize: 13) == 78)
        #expect(OutlineColumn.actualStart.width(bodyFontSize: 26) == OutlineColumn.finish.width(bodyFontSize: 26))
        #expect(OutlineColumn.actualFinish.width(bodyFontSize: 26) == OutlineColumn.finish.width(bodyFontSize: 26))
    }

    // MARK: - 默认隐藏

    /// 未启用时列集合与引入可选列之前逐位一致（各宽度档位都不得凭空多列）。
    @Test(arguments: [180.0, 340.0, 376.0, 454.0, 510.0, 586.0, 600.0, 640.0])
    func optionalColumnsAreHiddenByDefault(width: Double) {
        let actualColumns = OutlineColumnPreferences.visibleColumns(
            outlineWidth: width, hidden: [], focused: false
        )
        #expect(!actualColumns.contains(.actualStart))
        #expect(!actualColumns.contains(.actualFinish))
        #expect(actualColumns == OutlineColumn.visibleColumns(outlineWidth: width))
    }

    /// 旧用户的隐藏偏好里没有这两个键时同样不出现：默认值不落在 hiddenOutlineColumns。
    @Test func defaultVisibilityIsIndependentOfHiddenSet() {
        let columns = OutlineColumnPreferences.visibleColumns(
            outlineWidth: 600, hidden: [.duration], focused: false
        )
        #expect(!columns.contains(.actualStart))
        #expect(!columns.contains(.actualFinish))
    }

    // MARK: - 显式启用后的位置与顺序

    /// 启用后紧随 .finish，且顺序恒为「实际开始 → 实际结束」（与传入顺序无关）。
    @Test func enabledOptionalColumnsFollowFinishInCanonicalOrder() {
        let columns = OutlineColumnPreferences.visibleColumns(
            outlineWidth: 600, hidden: [], focused: false,
            shownOptional: [.actualFinish, .actualStart]
        )
        #expect(columns == [
            .status, .violation, .number, .title, .predecessors,
            .start, .finish, .actualStart, .actualFinish,
            .duration, .assignee, .progress
        ])
    }

    /// 只开一列时另一列不跟着出现。
    @Test func enablingSingleOptionalColumnDoesNotRevealTheOther() {
        let columns = OutlineColumnPreferences.visibleColumns(
            outlineWidth: 600, hidden: [], focused: false, shownOptional: [.actualFinish]
        )
        #expect(columns.contains(.actualFinish))
        #expect(!columns.contains(.actualStart))
        #expect(columns.firstIndex(of: .actualFinish) == columns.firstIndex(of: .finish).map { $0 + 1 })
    }

    /// 基准列里没有 .finish（用户隐藏或宽度降级）时追加到末尾，不凭空插在中间。
    @Test func optionalColumnsAppendWhenFinishAbsent() {
        let hiddenFinish = OutlineColumnPreferences.visibleColumns(
            outlineWidth: 600, hidden: [.finish], focused: false,
            shownOptional: [.actualStart, .actualFinish]
        )
        #expect(hiddenFinish.last == .actualFinish)
        #expect(hiddenFinish.dropLast().last == .actualStart)
        #expect(!hiddenFinish.contains(.finish))

        let narrow = OutlineColumnPreferences.visibleColumns(
            outlineWidth: 340, hidden: [], focused: false, shownOptional: [.actualStart]
        )
        #expect(narrow.last == .actualStart)
    }

    /// 显式启用是用户的明确意图：窄窗下也照样出现（否则开关点了「没反应」）。
    @Test func explicitlyEnabledOptionalColumnsIgnoreWidthThreshold() {
        let narrow = OutlineColumnPreferences.visibleColumns(
            outlineWidth: 180, hidden: [], focused: false,
            shownOptional: [.actualStart, .actualFinish]
        )
        #expect(narrow.contains(.actualStart))
        #expect(narrow.contains(.actualFinish))
    }

    /// 隐藏集合只作用于阈值内的基准列：actualStart 落在隐藏集合里也不改变启用结果
    /// （它的显隐权威是 shownOptional，单一事实来源）。
    @Test func hiddenSetDoesNotOverrideShownOptional() {
        let columns = OutlineColumnPreferences.visibleColumns(
            outlineWidth: 600, hidden: [.actualStart], focused: false,
            shownOptional: [.actualStart]
        )
        #expect(columns.contains(.actualStart))
    }

    /// 聚焦模式忽略用户配置（含可选列）：标签栏恒为三列。
    @Test func focusedModeIgnoresShownOptional() {
        #expect(OutlineColumnPreferences.visibleColumns(
            outlineWidth: 600, hidden: [], focused: true,
            shownOptional: [.actualStart, .actualFinish]
        ) == [.status, .violation, .title])
    }

    // MARK: - 开关入口

    /// 显隐菜单/命令面板的列清单 = 固定列之外的全部列，且不重复不遗漏。
    @Test func toggleableCoversConfigurableAndOptional() {
        let toggleable = OutlineColumnPreferences.toggleable
        #expect(Set(toggleable) == Set(OutlineColumnPreferences.configurable)
            .union(OutlineColumnPreferences.optional))
        #expect(Set(toggleable).union(OutlineColumnPreferences.alwaysVisible).count
            == OutlineColumn.allCases.count)
        #expect(toggleable.contains(.actualStart))
        #expect(toggleable.contains(.actualFinish))
        // 可拖宽：实际列与既有日期列同处理（判据 11「列宽可拖」）。
        #expect(OutlineColumnPreferences.isResizable(.actualStart))
        #expect(OutlineColumnPreferences.isResizable(.actualFinish))
    }

    // MARK: - 视图状态与动作

    /// 视图状态默认不启用任何可选列（= 默认隐藏），键用 rawValue 以便持久化。
    @Test func viewStateHasNoOptionalColumnsByDefault() {
        let state = WorkspaceViewState()
        #expect(state.visibleOptionalColumns.isEmpty)
    }

    /// 两个写实际时间的动作按值比较（视图可安全去重）。
    @Test func actualDateActionsCompareByValue() {
        let id = UUID()
        let date = makeDate(2025, 10, 20)
        #expect(WorkspaceAction.setActualStart(id, date) == .setActualStart(id, date))
        #expect(WorkspaceAction.setActualStart(id, nil) != .setActualStart(id, date))
        #expect(WorkspaceAction.setActualFinish(id, date) != .setActualStart(id, date))
    }

    // MARK: - 群组抑制（判据 12）

    /// 群组任务即便在模型里带着实际时间（命令层不拦截写入，文件可以被手改脏），
    /// 呈现层也必须抑制：PlanRow 与 TaskInspector 都出 nil。
    ///
    /// 这里直接构造脏模型而不是经由会话——会话不保证拦截，脏数据只能靠呈现层兜住。
    @Test func groupSnapshotsSuppressDirtyActualDates() throws {
        let group = TaskItem(
            title: "阶段一",
            kind: .group,
            completedAt: makeDate(2025, 10, 20),
            actualStart: makeDate(2025, 10, 18)
        )
        let child = TaskItem(title: "子任务", parentID: group.id, durationDays: 2)
        // 脏数据确实在模型上：先证明输入非空，断言才有意义。
        #expect(group.actualStart != nil)
        #expect(group.completedAt != nil)

        let state = makeState(
            [group, child],
            projectStart: makeDate(2025, 10, 1)
        )
        let snapshot = makeSnapshot(
            state: state,
            schedule: makeSchedule(state.tasks, projectStart: state.metadata.projectStart, now: makeDate(2025, 10, 25)),
            // 展开群组：否则子任务行被折叠，断言取不到行。
            viewState: WorkspaceViewState(
                expandedTaskIDs: [group.id],
                selectedTaskID: group.id
            ),
            now: makeDate(2025, 10, 25)
        )

        let row = try #require(snapshot.outline.rows.first { $0.id == group.id })
        #expect(row.isAggregate)
        #expect(row.actualStart == nil, "群组行不聚合实际开始")
        #expect(row.actualFinish == nil, "群组行不聚合实际结束")

        let childRow = try #require(snapshot.outline.rows.first { $0.id == child.id })
        #expect(childRow.actualStart == nil, "子任务本身没有实际时间，也不得从父行继承")

        guard case .task(let inspector) = snapshot.inspector.content else {
            Issue.record("选中群组时应为任务检查器页")
            return
        }
        #expect(inspector.isAggregate)
        #expect(inspector.actualStart == nil)
        #expect(inspector.completedAt == nil)
    }
}
