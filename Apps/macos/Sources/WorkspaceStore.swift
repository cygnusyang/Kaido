import AppKit
import Foundation
import SwiftUI
import KairoCommands
import KairoCore
import KairoPresentation

/// 应用适配层（ADR-013）：持有会话、视图状态与撤销栈，输出平台中立快照。
///
/// 所有变更经 `KairoSession`；视图只发 `WorkspaceAction`，不读写 `Project`。
@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var snapshot: WorkspaceSnapshot
    @Published private(set) var viewState: WorkspaceViewState
    @Published private(set) var viewport: WorkspaceViewport
    @Published private(set) var saveState: SaveState = .saved
    /// 上次载入产生的警告（语义）：文案由视图按码渲染，Store 不拼自然语言（F-0705）。
    @Published private(set) var loadWarnings: [LoadWarning] = []
    /// 错误提示（会话拒绝、文件读写失败）。
    @Published var alertMessage: String?
    /// 非模态提示（揭示结果、保存失败等）。
    @Published private(set) var notice: String?

    // 壳层共享状态（命令面板 / 查找栏由命令注册表驱动）。
    @Published var showCommandPalette = false
    @Published var showFindBar = false
    @Published var findFocusToken = 0
    @Published var filterBarVisible = true

    @ObservedObject private(set) var find = FindModel()

    /// 锁定检查器时冻结的任务；删除后保留快照用于提示。
    @Published private(set) var lockedTaskID: UUID?
    @Published private(set) var lockedTaskTitle: String?

    /// 删除确认（群组或含子项的任务）。
    struct PendingDeletion: Identifiable {
        var id: UUID { taskID }
        var taskID: UUID
        var title: String
        var affectedCount: Int
    }

    @Published var pendingDeletion: PendingDeletion?

    /// 基线删除确认（08-baselines §11：允许删除，但必须二次确认；无软删除）。
    struct PendingBaselineDeletion: Identifiable {
        var id: UUID
        var name: String
    }

    @Published var pendingBaselineDeletion: PendingBaselineDeletion?

    /// 打开的磁盘文件早于当前格式；保存/另存为后升级并清除（FR-KAIRO-FMT）。
    @Published private(set) var needsFormatUpgrade = false
    /// 磁盘文件已被外部修改且本地存在未保存修改。
    @Published private(set) var externalUpdatePending = false
    /// 有待打开的项目，但当前项目存在未保存修改；等待用户选择保存/丢弃/取消。
    @Published private(set) var pendingOpenURL: URL?
    /// 异步打开进行中；超过 150ms 才显示骨架屏，避免闪烁。
    @Published private(set) var isLoading = false
    @Published private(set) var showsLoadingSkeleton = false

    /// 被「揭示目标」临时挂起的筛选文本。
    private var suspendedFilterText: String?

    /// 最近打开的项目文件（最新在前，最多 5 条）；「最近打开」菜单与命令面板消费。
    @Published private(set) var recentProjects: [URL] = []

    private let session: KairoSession
    private let calendar: Calendar
    private let defaults: UserDefaults
    private let recentStore: RecentProjects
    /// 本次启动是否已收到显式打开请求（双击 `.kairo`、深链、菜单选择）。
    /// 置位后启动时的「默认打开最近项目」让位，避免抢走用户明确要打开的文件。
    private var didReceiveExplicitOpen = false
    /// 启动默认打开只尝试一次：文件不可用后不再反复试探。
    private var didAttemptLaunchOpen = false
    /// 项目文件解码入口；测试可注入受控加载以覆盖载入期间的编辑竞争。
    private let projectLoader: @Sendable (URL) throws -> DecodedProject
    private var monitorTimer: Timer?
    private var knownDiskMtime: Date?
    private var pendingExternalMtime: Date?
    private var acknowledgedMtime: Date?
    /// 外部文件读取失败时的 mtime；相同版本不重复重试与弹窗。
    private var failedExternalMtime: Date?
    private var loadingToken: UUID?
    /// 等待「异步打开收尾」的测试回执（D-030）：用完成通知替代墙钟轮询。
    private var pendingOpenWaiters: [CheckedContinuation<Void, Never>] = []
    private var dropExpandTask: Task<Void, Never>?
    private var dropExpandTargetID: UUID?
    /// 打开另存为面板时的会话版本；用于判断导出期间是否又有新修改。
    private var exportRevision: UInt64?
    /// 「保存并打开」触发的升级提示；finishOpen 重置 notice 后恢复一次。
    private var pendingUpgradeNoticeAfterOpen: String?

    /// 文件导出的值快照：随每次刷新更新，避免 SwiftUI body 每次求值都重建。
    private(set) var exportState = ProjectState(
        metadata: ProjectMetadata(), tasks: [], resources: []
    )

    /// 视图偏好在 `UserDefaults` 中的键名；测试按此键读写偏好 JSON。
    static let preferencesKey = "kairo.workspace.preferences.v1"
    // 时刻（外部更新提示）判定为展示格式：走 `Display.time`（本地化），不在这里固定 `HH:mm`（F-0712）。

    /// 持久化的视图偏好；视图模式与筛选不写入（启动固定计划模式）。
    /// 逐字段容错解码（D-016）：任一字段缺失/类型不符只回落该字段默认值，
    /// 不再整体解码失败导致全部偏好回落。
    private struct StoredPreferences: Codable {
        var outlineWidth: Double
        var outlineVisible: Bool?
        var expandedTaskIDs: [UUID]
        var zoom: GanttZoom
        var usesFitZoom: Bool
        /// 自定义日宽（点/天）；旧数据缺省时为 nil，回落档位默认宽度。
        var customDayWidth: Double?
        var windowStart: Date?
        var inspectorWidth: Double
        var inspectorTab: InspectorTab
        /// 大纲列宽覆盖（键 = 列 rawValue）；旧数据缺省时为 nil，全部列用默认宽。
        var outlineColumnWidths: [String: Double]?
        /// 隐藏的大纲列（列 rawValue）；旧数据缺省时为 nil，全部列显示。
        var hiddenOutlineColumns: [String]?
        /// 显式打开的可选列（列 rawValue，F-0719）；旧数据缺省时为 nil，可选列全隐藏。
        var visibleOptionalColumns: [String]?
        /// 列顺序（列 rawValue，v0.16 / #12）；旧数据缺省时为 nil，回落 `allCases` 顺序。
        var outlineColumnOrder: [String]?
        /// 是否标出非工作日；旧数据缺省 → false（一周 7 天，与排期口径一致）。
        var showsNonWorkingDays: Bool?
        /// 当前对比基线（v0.13）；旧数据缺省 → nil（不比较，基线列隐藏）。
        var selectedBaselineID: UUID?
        /// 甘特图上画哪些基线（v0.14 §6）；旧数据缺省 → nil（一条都不画，N=0）。
        var visibleBaselineIDs: [UUID]?

        /// 字段默认值 = `WorkspaceViewState()` 初值（与新建会话一致）。
        init(
            outlineWidth: Double,
            outlineVisible: Bool?,
            expandedTaskIDs: [UUID],
            zoom: GanttZoom,
            usesFitZoom: Bool,
            customDayWidth: Double?,
            windowStart: Date?,
            inspectorWidth: Double,
            inspectorTab: InspectorTab,
            outlineColumnWidths: [String: Double]?,
            hiddenOutlineColumns: [String]?,
            visibleOptionalColumns: [String]?,
            outlineColumnOrder: [String]?,
            showsNonWorkingDays: Bool?,
            selectedBaselineID: UUID?,
            visibleBaselineIDs: [UUID]?
        ) {
            self.outlineWidth = outlineWidth
            self.outlineVisible = outlineVisible
            self.expandedTaskIDs = expandedTaskIDs
            self.zoom = zoom
            self.usesFitZoom = usesFitZoom
            self.customDayWidth = customDayWidth
            self.windowStart = windowStart
            self.inspectorWidth = inspectorWidth
            self.inspectorTab = inspectorTab
            self.outlineColumnWidths = outlineColumnWidths
            self.hiddenOutlineColumns = hiddenOutlineColumns
            self.visibleOptionalColumns = visibleOptionalColumns
            self.outlineColumnOrder = outlineColumnOrder
            self.showsNonWorkingDays = showsNonWorkingDays
            self.selectedBaselineID = selectedBaselineID
            self.visibleBaselineIDs = visibleBaselineIDs
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // decodeIfPresent：字段缺失 → 默认值；类型不符（typeMismatch）也按
            // 缺失处理（该字段回落，其余保留）——不让单字段污染整个偏好。
            outlineWidth = (try? container.decodeIfPresent(Double.self, forKey: .outlineWidth))
                ?? WorkspaceViewState().outlineWidth
            outlineVisible = try? container.decodeIfPresent(Bool.self, forKey: .outlineVisible)
            expandedTaskIDs = (try? container.decodeIfPresent([UUID].self, forKey: .expandedTaskIDs))
                ?? []
            zoom = (try? container.decodeIfPresent(GanttZoom.self, forKey: .zoom))
                ?? WorkspaceViewState().zoom
            usesFitZoom = (try? container.decodeIfPresent(Bool.self, forKey: .usesFitZoom))
                ?? WorkspaceViewState().usesFitZoom
            customDayWidth = try? container.decodeIfPresent(Double.self, forKey: .customDayWidth)
            windowStart = try? container.decodeIfPresent(Date.self, forKey: .windowStart)
            inspectorWidth = (try? container.decodeIfPresent(Double.self, forKey: .inspectorWidth))
                ?? WorkspaceViewState().inspectorWidth
            inspectorTab = (try? container.decodeIfPresent(InspectorTab.self, forKey: .inspectorTab))
                ?? WorkspaceViewState().inspectorTab
            outlineColumnWidths = try? container.decodeIfPresent(
                [String: Double].self, forKey: .outlineColumnWidths
            )
            hiddenOutlineColumns = try? container.decodeIfPresent(
                [String].self, forKey: .hiddenOutlineColumns
            )
            visibleOptionalColumns = try? container.decodeIfPresent(
                [String].self, forKey: .visibleOptionalColumns
            )
            outlineColumnOrder = try? container.decodeIfPresent(
                [String].self, forKey: .outlineColumnOrder
            )
            showsNonWorkingDays = try? container.decodeIfPresent(
                Bool.self, forKey: .showsNonWorkingDays
            )
            selectedBaselineID = try? container.decodeIfPresent(UUID.self, forKey: .selectedBaselineID)
            visibleBaselineIDs = try? container.decodeIfPresent(
                [UUID].self, forKey: .visibleBaselineIDs
            )
        }
    }

    private struct UndoEntry {
        var state: ProjectState
        var selectedTaskID: UUID?
        var expandedTaskIDs: Set<UUID>
    }

    /// 偏差计算缓存（v0.13 / 08-baselines §4）：5,000 任务单次约 0.28 s（tester 实测），
    /// 绝不能每次快照重建都重算——日宽、滚动、面板开合都会重建快照。
    ///
    /// 失效键 = (selectedBaselineID, session.revision)：任务编辑与基线创建/删除/改名都会
    /// bump revision；切换基线本身不进模型，只换 key。
    private final class BaselineVarianceCache {
        struct Key: Equatable {
            var baselineID: UUID
            var revision: UInt64
        }

        private var key: Key?
        private var cached: BaselineVarianceReport?
        /// 测试观测缝：真实计算次数（命中缓存不增加）。
        private(set) var computationCount = 0

        func report(
            for baseline: Baseline?,
            revision: UInt64,
            compute: () -> BaselineVarianceReport?
        ) -> BaselineVarianceReport? {
            guard let baseline else {
                key = nil
                cached = nil
                return nil
            }
            let candidate = Key(baselineID: baseline.id, revision: revision)
            if key == candidate { return cached }
            let value = compute()
            computationCount += 1
            key = candidate
            cached = value
            return value
        }
    }

    private let varianceCache = BaselineVarianceCache()

    private var undoStack: [UndoEntry] = []
    private var redoStack: [UndoEntry] = []
    private var lastMergeKey: String?
    private var lastMergeAt: Date = .distantPast

    // MARK: - 初始化

    init(
        now: Date = Date(),
        defaults: UserDefaults = .standard,
        seedsDemoData: Bool = false,
        projectLoader: @escaping @Sendable (URL) throws -> DecodedProject = {
            try KairoFile.read(from: $0)
        }
    ) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        self.calendar = calendar
        self.defaults = defaults
        self.recentStore = RecentProjects(defaults: defaults)
        self.projectLoader = projectLoader

        let session = KairoSession()
        self.session = session
        _ = try? session.createProject(title: I18n.t("alert.project.default_title", "Untitled Project"))
        // AC-1：默认空启动不灌示例数据；seedsDemoData 供测试与旧行为显式启用。
        if seedsDemoData {
            Self.seed(SeedData.makeProject(), into: session)
        }

        let stored = Self.loadPreferences(from: defaults)
        var state = WorkspaceViewState()
        state.expandedTaskIDs = stored.map { Set($0.expandedTaskIDs) }
            ?? Self.allParentIDs(in: session.project?.tasks ?? [])
        if let stored {
            state.outlineWidth = stored.outlineWidth
            if let outlineVisible = stored.outlineVisible {
                state.outlineVisible = outlineVisible
            }
            state.zoom = stored.zoom
            state.usesFitZoom = stored.usesFitZoom
            state.windowStart = stored.windowStart
            state.showsNonWorkingDays = stored.showsNonWorkingDays ?? false
            state.inspectorWidth = stored.inspectorWidth
            state.inspectorTab = stored.inspectorTab
            // 列宽/显隐（F-14-20）：未知列与越界宽度静默丢弃，不牵连其余偏好（D-016）。
            state.outlineColumnWidths = Self.loadedColumnWidths(stored.outlineColumnWidths)
            state.hiddenOutlineColumns = Self.loadedHiddenColumns(stored.hiddenOutlineColumns)
            state.visibleOptionalColumns = Self.loadedOptionalColumns(stored.visibleOptionalColumns)
            state.columnOrder = Self.loadedColumnOrder(stored.outlineColumnOrder)
            // 基线选择是应用级视图偏好：存的是 ID，打开的项目没有这条基线时
            // 由 `selectedBaseline` 解析失败回落成「不比较」，不会指向别的项目的数据。
            state.selectedBaselineID = stored.selectedBaselineID
            // 显示集合同口径：悬挂 ID 由读取侧归一化剔除（可能存了 4 条以上旧偏好）。
            state.visibleBaselineIDs = Set(stored.visibleBaselineIDs ?? [])
        }
        // 自定义日宽：载入时归一化（夹取 + 取整 0.1，与写入口径一致，D-012），
        // 并与「适合项目」互斥（自定义优先）。
        if let custom = stored?.customDayWidth.map(Self.committedDayWidth) {
            state.customDayWidth = custom
            state.usesFitZoom = false
        }
        self.viewState = state
        let viewport = WorkspaceViewport(canvasWidth: 760, canvasHeight: 640)
        self.viewport = viewport
        let initialState = (try? session.snapshot())
            ?? ProjectState(metadata: ProjectMetadata(), tasks: [], resources: [])
        self.exportState = initialState
        self.snapshot = Self.makeSnapshot(
            state: initialState,
            session: session,
            viewState: state,
            viewport: viewport,
            saveState: .saved,
            calendar: calendar,
            now: now,
            varianceCache: varianceCache
        )
        self.saveState = session.hasUnsavedChanges ? .unsaved : .saved
        // 最近列表只读一次：之后由 noteRecentProject / clearRecentProjects 维护。
        self.recentProjects = recentStore.urls

        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkExternalUpdate()
            }
        }
        // 菜单跟踪、窗口缩放与滚动期间仍检测外部更新。
        RunLoop.main.add(timer, forMode: .common)
        monitorTimer = timer
    }

    deinit {
        monitorTimer?.invalidate()
    }

    // MARK: - 派生

    /// 测试观测缝（@testable 消费）：暴露会话以断言缓存行为（如 D-014 排期计数）。
    var sessionForTesting: KairoSession { session }

    /// 测试观测缝（@testable 消费）：撤销栈深度，用于断言被拒绝的动作不产生撤销点。
    var undoDepthForTesting: Int { undoStack.count }

    /// 测试观测缝（@testable 消费）：偏差真实计算次数（命中缓存不增加）。
    var baselineVarianceComputationCountForTesting: Int { varianceCache.computationCount }

    /// 测试观测缝（@testable 消费）：等待进行中的异步打开收尾。
    ///
    /// 完成回执替代「墙钟 sleep + 轮询」（D-030）：轮询窗口在并行全量下会假红。
    /// `isLoading` 在 `startOpenAsync` 里同步置真，发起打开后立刻 await 不会漏掉这次载入；
    /// 已经收尾（或从未发起）时立即返回。
    func awaitPendingOpenForTesting() async {
        guard isLoading else { return }
        await withCheckedContinuation { continuation in
            pendingOpenWaiters.append(continuation)
        }
    }

    var projectURL: URL? { session.projectURL }
    var hasUnsavedChanges: Bool { session.hasUnsavedChanges }
    var selection: UUID? { viewState.selectedTaskID }

    /// 项目基线（有序 = 创建顺序）：基线菜单与检查器共用同一份。
    var baselines: [Baseline] { session.project?.baselines ?? [] }

    /// 解析后的当前对比基线：ID 指向不存在的基线（换项目 / 已被删除）按「不比较」处理，
    /// 与 Presenter 的解析口径一致，避免视图显示「已选中」而列里全是占位符。
    var selectedBaseline: Baseline? {
        guard let id = viewState.normalizedBaselineID(in: baselines) else { return nil }
        return baselines.first { $0.id == id }
    }

    /// 基线四列是否可见：解析成功才算选中（未选时四列与检查器基线段整体隐藏）。
    var hasSelectedBaseline: Bool { selectedBaseline != nil }

    /// 仅深链解析等主线程内部逻辑使用；视图不得读取。
    var exportProject: Project { session.project ?? Project() }

    /// 文件导出的值快照在 `refresh()` 中更新；FileDocument 可能在后台线程编码，不得传活模型。

    /// 锁定选择发生漂移（真实选择与锁定任务不同）。
    var inspectorSelectionDrift: Bool {
        viewState.inspectorLocked
            && lockedTaskID != nil
            && viewState.selectedTaskID != lockedTaskID
    }

    var selectedTaskTitle: String? {
        guard let id = viewState.selectedTaskID else { return nil }
        return session.project?.tasksByID[id]?.title
    }

    // MARK: - 刷新

    func refresh(now: Date = Date()) {
        if saveState != .failed {
            saveState = session.hasUnsavedChanges ? .unsaved : .saved
        }
        let state = (try? session.snapshot())
            ?? ProjectState(metadata: ProjectMetadata(), tasks: [], resources: [])
        exportState = state
        snapshot = Self.makeSnapshot(
            state: state,
            session: session,
            viewState: inspectorState(for: viewState),
            viewport: viewport,
            saveState: saveState,
            calendar: calendar,
            now: now,
            varianceCache: varianceCache
        )
        // 锁定时检查器使用冻结任务；状态栏仍显示真实选择。
        if viewState.inspectorLocked, let title = selectedTaskTitle {
            snapshot.statusBar.selectionSummary = title
        }
        // 面板打开时才重建（关着就是空操作）：改名 / 改色 / 删任务 / 切对比都即时反映。
        rebuildBaselinePanel()
        savePreferences()
    }

    private func inspectorState(for state: WorkspaceViewState) -> WorkspaceViewState {
        guard state.inspectorLocked, let lockedTaskID else { return state }
        var copy = state
        copy.selectedTaskID = lockedTaskID
        return copy
    }

    private static func makeSnapshot(
        state: ProjectState,
        session: KairoSession,
        viewState: WorkspaceViewState,
        viewport: WorkspaceViewport,
        saveState: SaveState,
        calendar: Calendar,
        now: Date,
        varianceCache: BaselineVarianceCache
    ) -> WorkspaceSnapshot {
        // 排期走会话缓存（D-014）：只有任务/元数据写操作会置空缓存，
        // 纯视图动作（日宽调整、面板开合等）命中缓存不重算排期。
        let schedule = (try? session.scheduleOrCompute()) ?? session.lastSchedule
        let violations = schedule.map {
            ViolationEngine.check(result: $0, tasks: state.tasks)
        } ?? []
        // 偏差按 (基线, 会话版本) 缓存（见 BaselineVarianceCache）：切换基线只换 key，
        // 纯视图动作命中缓存，不重算 5k 任务的偏差。
        let selectedBaseline = viewState.selectedBaselineID.flatMap { id in
            state.baselines.first { $0.id == id }
        }
        let variance = varianceCache.report(
            for: selectedBaseline,
            revision: session.revision
        ) {
            guard let baseline = selectedBaseline else { return nil }
            let schedules = schedule.map { BaselineEngine.scheduleIndex(from: $0) } ?? [:]
            return BaselineEngine.variance(
                baseline: baseline,
                tasks: state.tasks,
                schedules: schedules,
                now: now,
                calendar: calendar
            )
        }
        return WorkspacePresenter.make(
            state: state,
            schedule: schedule,
            violations: violations,
            viewState: viewState,
            viewport: viewport,
            calendar: calendar,
            locale: Locale.current, // TODO(F-0706): 由语言设置注入
            now: now,
            saveState: saveState,
            baselineVariance: .cached(variance)
        )
    }

    // MARK: - 视图状态

    func setViewport(canvasWidth: Double, canvasHeight: Double) {
        let width = max(canvasWidth, 1)
        let height = max(canvasHeight, 1)
        guard abs(width - viewport.canvasWidth) > 0.5
                || abs(height - viewport.canvasHeight) > 0.5 else { return }
        viewport = WorkspaceViewport(canvasWidth: width, canvasHeight: height)
        refresh()
    }

    func clearNotice() {
        notice = nil
    }

    /// 横向平移：按整天推进窗口起点（正数 = 内容右移 / 看更早日期）。
    ///
    /// 唯一真源是 `viewState.windowStart`：连续滚动事件都以当前已提交的起点为基准，
    /// 视图层不再自行推进（D-028 —— 旧实现在上下文里乐观 `advance`，store 一旦
    /// 不认这次提交就会越滑越偏）。`usesFitZoom` 关闭，与「适合项目」互斥。
    func panWindow(byDays days: Int) {
        guard days != 0 else { return }
        let base = viewState.windowStart ?? snapshot.gantt.windowStart
        let shifted = calendar.date(byAdding: .day, value: -days, to: base) ?? base
        mutateView {
            $0.windowStart = calendar.startOfDay(for: shifted)
            $0.usesFitZoom = false
        }
    }

    // MARK: - 动作路由

    func dispatch(_ action: WorkspaceAction) {
        switch action {
        case .select(let id):
            restoreSuspendedFilterIfNeeded(selecting: id)
            if id != viewState.highlightedTaskID {
                viewState.highlightedTaskID = nil
            }
            viewState.selectedTaskID = id
            refresh()

        case .reveal(let id):
            reveal(id)

        case .highlight(let id):
            viewState.highlightedTaskID = id
            refresh()

        case .copyTaskLink(let id):
            copyTaskLink(id)

        case .toggleExpanded(let id):
            mutateView {
                if $0.expandedTaskIDs.contains(id) {
                    $0.expandedTaskIDs.remove(id)
                } else {
                    $0.expandedTaskIDs.insert(id)
                }
            }

        case .setExpanded(let ids):
            mutateView { $0.expandedTaskIDs = ids }

        case .setMode(let mode):
            mutateView {
                $0.mode = mode
                if mode == .outline { $0.chartFocused = false }
            }

        case .toggleChartFocus:
            mutateView {
                if $0.mode == .outline {
                    $0.mode = .plan
                    $0.chartFocused = true
                } else {
                    $0.chartFocused.toggle()
                }
            }

        case .setZoom(let zoom):
            // 预设档位与自定义日宽互斥：选预设即回落默认宽度。
            mutateView {
                $0.zoom = zoom
                $0.usesFitZoom = false
                $0.customDayWidth = nil
            }

        case .setFitZoom(let enabled):
            // fit 与自定义互斥（最后写入者胜）：开启 fit 即清空自定义。
            mutateView {
                $0.usesFitZoom = enabled
                if enabled {
                    $0.windowStart = nil
                    $0.customDayWidth = nil
                }
            }

        case .setCustomDayWidth(let width):
            // 手动调宽度自动退出「适合项目」；越界值在此夹取，提交值取整到 0.1。
            mutateView {
                $0.customDayWidth = Self.committedDayWidth(width)
                $0.usesFitZoom = false
            }

        case .nudgeCustomDayWidth(let delta):
            // 基准 = 当前生效日宽（fit 模式下取 fit 宽度），结果再夹取并取整到 0.1。
            let base = snapshot.gantt.dayWidth
            mutateView {
                $0.customDayWidth = Self.committedDayWidth(base + delta)
                $0.usesFitZoom = false
            }

        case .clearCustomDayWidth:
            // 清除自定义：回落到当前档位默认宽度（fit 开启时回落到 fit 宽度）。
            mutateView {
                $0.customDayWidth = nil
            }

        case .panWindow(let date):
            mutateView {
                $0.windowStart = calendar.startOfDay(for: date)
                $0.usesFitZoom = false
            }

        case .goToToday:
            mutateView {
                let today = calendar.startOfDay(for: Date())
                $0.windowStart = today.addingTimeInterval(-7 * 86_400)
                $0.usesFitZoom = false
            }

        case .setFilter(let text):
            suspendedFilterText = nil
            mutateView {
                $0.filterText = text
                $0.revealStatus = nil
            }

        case .toggleCriticalPath:
            mutateView { $0.showCriticalPath.toggle() }

        case .toggleNonWorkingDays:
            mutateView { $0.showsNonWorkingDays.toggle() }

        case .toggleBarLabels:
            mutateView { $0.showBarLabels.toggle() }

        case .setInspectorVisible(let visible):
            mutateView {
                $0.inspectorVisible = visible
                if !visible { $0.inspectorLocked = false }
            }
            if !visible {
                lockedTaskID = nil
                lockedTaskTitle = nil
            }

        case .setInspectorTab(let tab):
            mutateView {
                $0.inspectorTab = tab
                $0.inspectorVisible = true
            }

        case .setInspectorLocked(let locked):
            if locked {
                lockedTaskID = viewState.selectedTaskID
                lockedTaskTitle = selectedTaskTitle
            } else {
                lockedTaskID = nil
                lockedTaskTitle = nil
            }
            mutateView { $0.inspectorLocked = locked }

        case .setInspectorWidth(let width):
            mutateView { $0.inspectorWidth = min(max(width, 280), 420) }

        case .setOutlineVisible(let visible):
            mutateView { $0.outlineVisible = visible }

        case .setOutlineWidth(let width):
            mutateView { $0.outlineWidth = min(max(width, 320), 640) }

        case .setOutlineColumnWidth(let column, let width):
            setOutlineColumnWidth(column, width)

        case .toggleOutlineColumn(let column):
            toggleOutlineColumn(column)

        case .setOutlineColumnOrder(let order):
            setOutlineColumnOrder(order)

        case .setBaseline(let id):
            setBaseline(id)

        case .createBaseline(let name):
            createBaseline(name: name)

        case .renameBaseline(let id, let name):
            renameBaseline(id: id, name: name)

        case .deleteBaseline(let id):
            requestDeleteBaseline(id: id)

        case .setBaselineVisible(let id, let visible):
            setBaselineVisible(id, visible)

        case .setBaselineColor(let id, let colorIndex):
            setBaselineColor(id: id, colorIndex: colorIndex)

        case .createTask(let parentID, let kind):
            createTask(kind: kind, parentID: parentID)

        case .createSibling(let id):
            createSibling(after: id)

        case .rename(let id, let title):
            update(id: id, mergeKey: "rename-\(id)") {
                var patch = TaskPatch()
                patch.title = title
                try self.session.updateTask(id: id, patch: patch)
            }

        case .setPriority(let id, let priority):
            update(id: id, mergeKey: "priority-\(id)") {
                var patch = TaskPatch()
                patch.priority = priority
                try self.session.updateTask(id: id, patch: patch)
            }

        case .setNotes(let id, let notes):
            update(id: id, mergeKey: "notes-\(id)") {
                var patch = TaskPatch()
                patch.notes = notes
                try self.session.updateTask(id: id, patch: patch)
            }

        case .setStatus(let id, let status):
            update(id: id, mergeKey: "status-\(id)") {
                try self.session.statusUpdate(id: id, status: status)
            }

        case .cancelTask(let id, let reason):
            cancelTask(id: id, reason: reason)

        case .setProgress(let id, let progress):
            update(id: id, mergeKey: "progress-\(id)") {
                try self.session.statusUpdate(id: id, progress: min(max(progress, 0), 1))
            }

        case .setDueDate(let id, let date):
            update(id: id, mergeKey: "due-\(id)") {
                var patch = TaskPatch()
                patch.dueDate = date.map(FieldPatch.set) ?? .clear
                try self.session.updateTask(id: id, patch: patch)
            }

        case .setAssignee(let id, let name):
            update(id: id, mergeKey: "assignee-\(id)") {
                var patch = TaskPatch()
                patch.assignee = name.map(FieldPatch.set) ?? .clear
                try self.session.updateTask(id: id, patch: patch)
            }

        case .setDuration(let id, let days):
            update(id: id, mergeKey: "duration-\(id)") {
                var patch = TaskPatch()
                patch.durationDays = days.map(FieldPatch.set) ?? .clear
                try self.session.updateTask(id: id, patch: patch)
            }

        case .setTaskStart(let id, let date):
            // 日粒度归一落在 Store（AC-S8-01 / M-6）：画布、CLI、内联等其它入口不再各自归一，
            // 系统日历是唯一口径来源，文件里不出现带时分秒的 startDate。
            update(id: id, mergeKey: "task-start-\(id)") {
                var patch = TaskPatch()
                patch.startDate = date.map {
                    FieldPatch.set(ScheduleDateMath.startOfDay($0, calendar: self.calendar))
                } ?? .clear
                try self.session.updateTask(id: id, patch: patch)
            }

        case .setActualStart(let id, let date):
            // 实际开始不加日粒度归一：快照显示到日，模型保留完整时间戳（设计 §5「日期口径」）。
            updateAfterSuccess(mergeKey: "actual-start-\(id)") {
                try self.session.setActualStart(id: id, date: date)
            }

        case .setActualFinish(let id, let date):
            updateAfterSuccess(mergeKey: "actual-finish-\(id)") {
                try self.session.setActualFinish(id: id, date: date)
            }

        case .setTaskFinish(let id, let finish, let start):
            // 「结束」只折算持续时间；两重校验都在 update 之前，任一失败不写库、不产生撤销点。
            // ① 起点必须仍是当前排期起点：快照渲染到点击之间排期可能已被撤销/重做、画布拖拽、
            //    ALAP 重算或外部文件合并改写，用陈旧起点折算会把持续时间算错并静默落到别的结束日。
            guard let currentStart = currentScheduleStart(for: id),
                  ScheduleDateMath.dayOffset(from: currentStart, to: start, calendar: calendar) == 0 else {
                alertMessage = I18n.t("alert.schedule_changed", "The schedule changed; pick the finish date again")
                return
            }
            // ② 结束是排他端点，必须晚于起点。
            guard let duration = ScheduleDateMath.durationDays(start: start, finish: finish) else {
                alertMessage = I18n.t("alert.finish_after_start", "The finish date must be later than the start date")
                return
            }
            update(id: id, mergeKey: "task-finish-\(id)") {
                var patch = TaskPatch()
                patch.durationDays = .set(duration)
                try self.session.updateTask(id: id, patch: patch)
            }

        case .canvasEditSchedule(let id, let startDate, let durationDays):
            // F-14-09 画布拖拽：同一 mergeKey 在连续节流提交间合并为一步撤销。
            // move 只带 startDate；resize 右端只带 durationDays；resize 左端两者都带。
            let mergeKey = durationDays == nil ? "canvas-move-\(id)" : "canvas-resize-\(id)"
            update(id: id, mergeKey: mergeKey) {
                var patch = TaskPatch()
                if let startDate { patch.startDate = .set(startDate) }
                if let durationDays { patch.durationDays = .set(durationDays) }
                try self.session.updateTask(id: id, patch: patch)
            }

        case .move(let id, let parentID, let index):
            update(id: id, mergeKey: nil) {
                try self.session.moveTask(id: id, toParent: parentID, at: index)
            }

        case .indent(let id):
            pushUndo(mergeKey: nil)
            do {
                _ = try session.indentTask(id: id)
                // 新父级自动展开，缩进后的任务不消失。
                if let parent = session.project?.tasksByID[id]?.parentID {
                    viewState.expandedTaskIDs.insert(parent)
                }
            } catch {
                report(error)
            }
            refresh()

        case .outdent(let id):
            update(id: id, mergeKey: nil) {
                _ = try self.session.outdentTask(id: id)
            }

        case .delete(let id):
            delete(id: id)

        case .addDependency(let taskID, let predecessorID, let type, let lagDays):
            update(id: taskID, mergeKey: nil) {
                try self.session.addDependency(
                    to: taskID, predecessorID: predecessorID, type: type, lagDays: lagDays
                )
            }

        case .removeDependency(let taskID, let predecessorID):
            update(id: taskID, mergeKey: nil) {
                try self.session.removeDependency(from: taskID, predecessorID: predecessorID)
            }

        case .setPredecessors(let taskID, let raw):
            setPredecessors(taskID: taskID, raw: raw)

        case .setProjectTitle(let title):
            mutateProject(mergeKey: "project-title") {
                try self.session.updateProjectMetadata(title: title)
            }

        case .setProjectStart(let date):
            mutateProject(mergeKey: "project-start") {
                try self.session.updateProjectMetadata(
                    projectStart: date.map(FieldPatch.set) ?? .clear
                )
            }

        case .setProjectEnd(let date):
            mutateProject(mergeKey: "project-end") {
                try self.session.updateProjectMetadata(
                    projectEnd: date.map(FieldPatch.set) ?? .clear
                )
            }

        case .setProjectDirection(let direction):
            mutateProject(mergeKey: nil) {
                try self.session.updateProjectMetadata(direction: direction)
            }

        case .undo:
            undo()

        case .redo:
            redo()

        case .save:
            save()

        case .reloadExternal:
            reloadExternal()

        case .keepLocal:
            acknowledgedMtime = pendingExternalMtime
            pendingExternalMtime = nil
            externalUpdatePending = false
            notice = I18n.t("alert.kept_local", "Kept the local version")
        }
    }

    // MARK: - 变更辅助

    /// 提交自定义日宽：先夹取到合法区间，再取整到 0.1。
    ///
    /// 取整放在动作层，保证落盘偏好与状态栏读数一致（核心 `GanttScale.clampDayWidth`
    /// 只做夹取、不做取整，保持核心接受调用方给定的精度）。
    private static func committedDayWidth(_ width: Double) -> Double {
        let clamped = GanttScale.clampDayWidth(width)
        return (clamped * 10).rounded() / 10
    }

    /// 列宽覆盖（F-14-20）：`nil` 删除该列覆盖值（回落默认宽），非 `nil` 夹取后写入。
    ///
    /// 非有限值（NaN/∞）无法夹取，按复位处理，不留越界值给布局。
    /// 列宽是视图偏好，显隐集合不受影响，也不产生撤销点。
    /// 列宽（F-14-20）：应用级视图偏好，与 `.setOutlineWidth` 一致**不进撤销栈**
    /// （撤销栈只存项目快照，记一步空撤销只会清空 redo 且无法真正回滚列宽）。
    private func setOutlineColumnWidth(_ column: OutlineColumn, _ width: Double?) {
        // 弹性列（任务说明）不吃覆盖值：布局恒按余量计算，写入只会留下永不生效的死状态。
        guard OutlineColumnPreferences.isResizable(column) else { return }
        mutateView { state in
            guard let width, width.isFinite else {
                state.outlineColumnWidths.removeValue(forKey: column.rawValue)
                return
            }
            let range = OutlineColumnPreferences.widthRange(for: column)
            state.outlineColumnWidths[column.rawValue] = min(max(width, range.lowerBound), range.upperBound)
        }
    }

    /// 列显隐（F-14-20 / F-0719）：序号/任务说明固定显示，请求直接忽略（不产生撤销点、不改状态）。
    ///
    /// 可选列（实际开始/实际结束）走另一条偏好 `visibleOptionalColumns`：它们的缺省态是
    /// 「不存在」，记在隐藏集合里无法区分「用户隐藏」与「新列尚未存在」（设计 §5）。
    /// 菜单与命令面板只发同一个动作，由这里按列归属分流，避免视图重复判断。
    ///
    /// 纯视图偏好，与大纲整体宽度一致：走 `mutateView` 而非 `update`，不进撤销栈。
    private func toggleOutlineColumn(_ column: OutlineColumn) {
        guard !OutlineColumnPreferences.alwaysVisible.contains(column) else { return }
        mutateView { state in
            if OutlineColumnPreferences.optional.contains(column) {
                if state.visibleOptionalColumns.contains(column.rawValue) {
                    state.visibleOptionalColumns.remove(column.rawValue)
                } else {
                    state.visibleOptionalColumns.insert(column.rawValue)
                }
                return
            }
            if state.hiddenOutlineColumns.contains(column.rawValue) {
                state.hiddenOutlineColumns.remove(column.rawValue)
            } else {
                state.hiddenOutlineColumns.insert(column.rawValue)
            }
        }
    }

    /// 列顺序（v0.16 / #12）：应用级视图偏好，与列宽 / 显隐同域——走 `mutateView`，
    /// 不进撤销栈、不置脏、不写 `.kairo`。
    ///
    /// 归一化在写入口一次做完（去重 + 补齐缺失列）：视图只负责把「拖到哪」翻译成数组，
    /// 不必各自判重。与当前顺序相同时直接返回——拖回原位不该留下一份看起来改过的偏好。
    private func setOutlineColumnOrder(_ order: [OutlineColumn]) {
        let normalized = OutlineColumnPreferences.normalizedOrder(order)
        guard normalized != OutlineColumnPreferences.normalizedOrder(viewState.columnOrder) else { return }
        mutateView { $0.columnOrder = normalized }
    }

    // MARK: - 基线（v0.13 / 08-baselines）

    /// 切换对比基线（§9-10）：纯视图状态——不进撤销栈、不置脏、不写文件。
    ///
    /// 指向不存在的基线时落成 `nil`：留着悬挂 ID 只会让界面「看起来选了」却没有任何读数。
    private func setBaseline(_ id: UUID?) {
        let resolved = id.flatMap { candidate in baselines.first { $0.id == candidate }?.id }
        mutateView { $0.selectedBaselineID = resolved }
    }

    /// 甘特图显示 / 隐藏某条基线（v0.14 §6）：纯视图状态——不进撤销栈、不置脏、不写文件。
    ///
    /// 三条拒绝口径（全部保持状态不变，不报错）：
    /// - 基线不存在（悬挂 ID / 已删除）；
    /// - 已显示满 `BaselineLanes.maxVisible` 条——不替换、不插队，任何一条都不会因此消失；
    /// - 重复勾选 / 重复取消。
    ///
    /// 写入前按归一化结果重算：顺手清掉撤销回退留下的悬挂 ID，避免它们白占名额。
    private func setBaselineVisible(_ id: UUID, _ visible: Bool) {
        guard baselines.contains(where: { $0.id == id }) else { return }
        var next = Set(viewState.normalizedVisibleBaselineIDs(in: baselines))
        if visible {
            guard !next.contains(id), next.count < BaselineLanes.maxVisible else { return }
            next.insert(id)
        } else {
            guard next.remove(id) != nil else { return }
        }
        mutateView { $0.visibleBaselineIDs = next }
    }

    /// 改基线颜色（v0.14 §4）：写模型（置脏、落盘）并进撤销栈——一次改色 = 一个撤销步。
    ///
    /// 索引越界由会话拒绝（`BaselinePalette.count` 是唯一上限来源），此处不重复夹取：
    /// 静默夹取会让「点错色」看起来成功，用户不知道自己的操作被改写。
    private func setBaselineColor(id: UUID, colorIndex: Int) {
        let entry = captureUndoEntry()
        do {
            try session.setBaselineColor(id: id, colorIndex: colorIndex)
            appendUndo(entry, mergeKey: "baseline-color-\(id)")
        } catch {
            report(error)
        }
        refresh()
    }

    /// 拍一次基线快照：成功后记撤销点，并选中新基线（点「新建基线」的意图就是拿它做对比）。
    ///
    /// 与 `updateAfterSuccess` 同序：先拿前置快照，成功后再压栈——失败不应留下空撤销步。
    private func createBaseline(name: String?) {
        let entry = captureUndoEntry()
        do {
            let baseline = try session.createBaseline(name: name)
            appendUndo(entry, mergeKey: nil)
            viewState.selectedBaselineID = baseline.id
            // §6：未满 3 条时自动加入显示；已满 3 条不替换、不插队（新基线只在菜单里可见）。
            if viewState.normalizedVisibleBaselineIDs(in: baselines).count
                < BaselineLanes.maxVisible {
                viewState.visibleBaselineIDs.insert(baseline.id)
            }
        } catch {
            report(error)
        }
        refresh()
    }

    /// 基线改名：只改名字（条目不可变，§3）；进撤销栈。
    private func renameBaseline(id: UUID, name: String) {
        let entry = captureUndoEntry()
        do {
            try session.renameBaseline(id: id, name: name)
            appendUndo(entry, mergeKey: "baseline-rename-\(id)")
        } catch {
            report(error)
        }
        refresh()
    }

    /// 删除入口（§11）：只登记待确认，确认后才真正删——基线删掉不可重建。
    func requestDeleteBaseline(id: UUID) {
        guard let baseline = baselines.first(where: { $0.id == id }) else { return }
        pendingBaselineDeletion = PendingBaselineDeletion(id: baseline.id, name: baseline.name)
    }

    func cancelPendingBaselineDeletion() {
        pendingBaselineDeletion = nil
    }

    /// 确认删除：进撤销栈；删的是当前对比基线时回落成「不比较」（四列随之隐藏）。
    func confirmPendingBaselineDeletion() {
        guard let pending = pendingBaselineDeletion else { return }
        pendingBaselineDeletion = nil
        let entry = captureUndoEntry()
        do {
            try session.deleteBaseline(id: pending.id)
            appendUndo(entry, mergeKey: nil)
            if viewState.selectedBaselineID == pending.id {
                viewState.selectedBaselineID = nil
            }
            // 展示卫生：删掉的基线不再占显示名额（不产生撤销点，撤销回来也不会自动复显）。
            viewState.visibleBaselineIDs.remove(pending.id)
        } catch {
            report(error)
        }
        refresh()
    }

    // MARK: - 基线面板（v0.15 / 08-baselines §5、10-multi-baseline-gantt §5）

    /// 基线管理面板是否展开（纯视图状态：不进撤销栈、不置脏、不写文件）。
    @Published private(set) var isBaselinePanelPresented = false

    /// 面板数据；nil = 面板未打开。打开期间随每次 `refresh()` 重建，
    /// 改名 / 改色 / 删除基线 / 删除任务之后都不需要重开面板。
    @Published private(set) var baselinePanel: BaselinePanelModel?

    /// 打开面板（「管理基线…」入口）。重复触发只重建数据，不叠出第二个面板。
    func presentBaselinePanel() {
        isBaselinePanelPresented = true
        rebuildBaselinePanel()
    }

    /// 关闭面板并释放数据：面板非常驻，关掉就不再为它计算偏差。
    func dismissBaselinePanel() {
        isBaselinePanelPresented = false
        if baselinePanel != nil { baselinePanel = nil }
    }

    /// 重建面板数据：焦点基线 = 主对比 ?? 最新一条，只为它算一次偏差。
    ///
    /// 失败口径：`baselineVariance` 只会在「会话未打开」或「基线已不存在」时抛错，
    /// 而焦点 id 取自现存基线，故失败等价于「这次没有统计可显示」——孤儿与新增计数
    /// 是补充信息，不该让整个面板打不开。
    private func rebuildBaselinePanel() {
        guard isBaselinePanelPresented else { return }
        let baselines = self.baselines
        let focusID = viewState.normalizedBaselineID(in: baselines) ?? baselines.last?.id
        var report: BaselineVarianceReport?
        if let focusID { report = try? session.baselineVariance(baselineID: focusID) }
        let model = BaselinePanelModel(
            baselines: baselines,
            viewState: viewState,
            report: report
        )
        // 同值时不动 @Published：refresh 在滚动 / 筛选等纯视图动作里也会走，
        // 每次都发 objectWillChange 会让面板白重绘一遍。
        if baselinePanel != model { baselinePanel = model }
    }

    private func mutateView(_ change: (inout WorkspaceViewState) -> Void) {
        change(&viewState)
        refresh()
    }

    /// 任务当前排期起点：优先排期结果；未排期（群组/环/无安排）回落到 `startDate` 意图。
    ///
    /// 「结束」字段的折算口径（视图传 `scheduledStart ?? startDate`）在这里复核，
    /// 保证落库的持续时间与用户看到的起点同源。
    private func currentScheduleStart(for id: UUID) -> Date? {
        if let result = try? session.scheduleOrCompute(),
           result.hasSchedule(for: id),
           let scheduled = result.scheduled(id) {
            return scheduled.scheduledStart
        }
        return session.project?.tasksByID[id]?.startDate
    }

    /// 记录撤销点；相同 `mergeKey` 在 500ms 内合并为一步。
    private func pushUndo(mergeKey: String?) {
        appendUndo(captureUndoEntry(), mergeKey: mergeKey)
    }

    /// 捕获当前项目快照（撤销点内容）；会话不可用时为 nil。
    ///
    /// 与 `pushUndo` 拆开是为了「先改、成功后才压栈」的写入口（实际时间，F-0719）：
    /// 那些入口要先拿到前置快照，再执行可能失败的写入。
    private func captureUndoEntry() -> UndoEntry? {
        guard let state = try? session.snapshot() else { return nil }
        return UndoEntry(
            state: state,
            selectedTaskID: viewState.selectedTaskID,
            expandedTaskIDs: viewState.expandedTaskIDs
        )
    }

    /// 压入撤销点：同一 `mergeKey` 在 500ms 内合并为一步。
    private func appendUndo(_ entry: UndoEntry?, mergeKey: String?) {
        let now = Date()
        if let mergeKey, mergeKey == lastMergeKey, now.timeIntervalSince(lastMergeAt) < 0.5,
           !undoStack.isEmpty {
            lastMergeAt = now
            return
        }
        if let entry {
            undoStack.append(entry)
            if undoStack.count > 50 { undoStack.removeFirst(undoStack.count - 50) }
            redoStack.removeAll()
        }
        lastMergeKey = mergeKey
        lastMergeAt = now
    }

    private func update(
        id: UUID,
        mergeKey: String?,
        _ body: () throws -> Void
    ) {
        pushUndo(mergeKey: mergeKey)
        do {
            try body()
        } catch {
            report(error)
        }
        refresh()
    }

    /// 转入「已取消」（v0.16 D）：原因必须是去空白后的非空文本。
    ///
    /// 空白原因在应用层就拦下（提示「请填写取消原因」），不进会话、不写库、不留撤销步；
    /// 非空原因经 `updateAfterSuccess` 提交，会话层仍会再校验一次（双保险不重复提示）。
    private func cancelTask(id: UUID, reason: String) {
        guard let trimmed = CancelReasonInput.normalized(reason) else {
            alertMessage = I18n.t("alert.cancel_reason_required", "Enter a reason for cancelling")
            return
        }
        updateAfterSuccess(mergeKey: "status-\(id)") {
            try self.session.statusUpdate(id: id, status: .cancelled, cancelReason: trimmed)
        }
    }

    /// **成功后才记撤销点**的写入外壳。
    ///
    /// 与 `update(id:mergeKey:)` 的差异只有顺序：后者先压撤销点再执行，而本路径的
    /// 校验在会话里（实际时间先后、取消原因必填 → 抛错不写库），失败请求会在撤销栈里
    /// 留下一个「撤销后毫无变化」的空步（设计 §4 判据 9「不产生撤销点」）。
    private func updateAfterSuccess(mergeKey: String, _ body: () throws -> Void) {
        let entry = captureUndoEntry()
        do {
            try body()
        } catch {
            report(error)
            refresh()
            return
        }
        appendUndo(entry, mergeKey: mergeKey)
        refresh()
    }

    /// 「前置」列输入 → 依赖集合整体替换（对齐 OmniPlan 的前置任务编辑）。
    ///
    /// 流程：解析 `ID[:类型[:延隔]]` → 前缀解析为 UUID → 值副本上预校验（自依赖、
    /// 成环、重复）→ 求与现有依赖的差集 → 经会话应用；任何一步失败只提示不改数据。
    private func setPredecessors(taskID: UUID, raw: String) {
        let specs = raw
            // 分隔符含半角逗号、空格与表意逗号（U+3001）；用码位写法避开硬编码中文扫描。
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\u{3001}" })
            .filter { !$0.isEmpty }
        guard !specs.isEmpty else {
            clearPredecessors(taskID: taskID)
            return
        }

        // 当前可见行的大纲编号 → 任务 ID（US-E4-01-C1）；折叠/筛选隐藏的行不在其中。
        let outlineNumberByID = Dictionary(
            uniqueKeysWithValues: snapshot.outline.rows.map { ($0.outlineNumber, $0.id) }
        )

        var targets: [UUID: TaskDependency] = [:]
        for spec in specs {
            let parts = spec.split(separator: ":", omittingEmptySubsequences: false)
            guard let idPart = parts.first, !idPart.isEmpty else {
                alertMessage = I18n.t("error.dependency.predecessor_invalid", "Unrecognized predecessor: %1$@", String(spec))
                return
            }
            let type = parts.count > 1 && !parts[1].isEmpty
                ? parts[1].lowercased() : "fs"
            guard let depType = TaskDependency.DependencyType(rawValue: type) else {
                alertMessage = I18n.t("error.dependency.type_invalid", "Unrecognized dependency type: %1$@ (expected fs/ff/ss/sf)", String(spec))
                return
            }
            let lag = parts.count > 2 && !parts[2].isEmpty ? (Double(parts[2]) ?? 0) : 0
            if parts.count > 2, Double(parts[2]) == nil {
                alertMessage = I18n.t("error.dependency.lag_invalid", "Unrecognized lag: %1$@", String(spec))
                return
            }

            let tasks = session.project?.tasks ?? []
            let resolved: UUID
            if idPart.contains(".") || (idPart.allSatisfy(\.isNumber) && idPart.count < 4) {
                // 大纲编号引用（US-E4-01-C1）：含点或 <4 位纯数字按当前可见编号精确匹配；
                // 被折叠/筛选隐藏的任务报 C3 提示，数据不变。
                guard let id = outlineNumberByID[String(idPart)] else {
                    alertMessage = I18n.t("error.dependency.predecessor_hidden", "Predecessor not found: %1$@ (the task may be collapsed or filtered out)", String(idPart))
                    return
                }
                resolved = id
            } else if let id = UUID(uuidString: String(idPart)) {
                resolved = id
            } else {
                // ID 前缀匹配（US-E4-01-C2 混用路径）：≥4 位纯数字先按前缀，失败再回退大纲编号。
                let matches = tasks.filter {
                    $0.id.uuidString.lowercased().hasPrefix(idPart.lowercased())
                }
                if matches.count == 1 {
                    resolved = matches[0].id
                } else if idPart.allSatisfy(\.isNumber) {
                    guard let id = outlineNumberByID[String(idPart)] else {
                        alertMessage = I18n.t("error.dependency.predecessor_hidden", "Predecessor not found: %1$@ (the task may be collapsed or filtered out)", String(idPart))
                        return
                    }
                    resolved = id
                } else {
                    alertMessage = matches.count > 1
                        ? I18n.t("error.dependency.predecessor_ambiguous", "Predecessor ID is not unique: %1$@", String(idPart))
                        : I18n.t("error.dependency.predecessor_not_found", "Predecessor not found: %1$@", String(idPart))
                    return
                }
            }
            if resolved == taskID {
                alertMessage = I18n.t("error.dependency.self", "A task cannot depend on itself")
                return
            }
            let dep = TaskDependency(predecessorID: resolved, type: depType, lagDays: lag)
            if targets[resolved] != nil {
                alertMessage = I18n.t("error.dependency.duplicate", "Duplicate predecessor: %1$@", String(idPart))
                return
            }
            targets[resolved] = dep
        }

        // 值副本上预校验最终集合，避免会话出现「删了一半」的中间态。
        var draft = session.project?.tasks ?? []
        guard let index = draft.firstIndex(where: { $0.id == taskID }) else { return }
        let current = draft[index].dependencies
        var removals: [UUID] = []
        var additions: [TaskDependency] = []
        for dep in current where targets[dep.predecessorID] == nil {
            removals.append(dep.predecessorID)
        }
        for (predecessorID, dep) in targets {
            if let existing = current.first(where: { $0.predecessorID == predecessorID }) {
                if existing.type != dep.type || existing.lagDays != dep.lagDays {
                    removals.append(predecessorID)
                    additions.append(dep)
                }
            } else {
                additions.append(dep)
            }
        }
        for id in removals {
            guard case .success(let updated) = DependencyEditing.remove(
                predecessorID: id, from: taskID, in: draft
            ) else { continue }
            draft = updated
        }
        for dep in additions {
            switch DependencyEditing.add(dep, to: taskID, in: draft) {
            case .success(let updated):
                draft = updated
            case .failure(let error):
                alertMessage = Self.dependencyError(error, id: dep.predecessorID)
                return
            }
        }

        update(id: taskID, mergeKey: nil) {
            for id in removals {
                try self.session.removeDependency(from: taskID, predecessorID: id)
            }
            for dep in additions {
                try self.session.addDependency(
                    to: taskID, predecessorID: dep.predecessorID,
                    type: dep.type, lagDays: dep.lagDays
                )
            }
        }
    }

    /// 清空前置依赖（输入为空时）。
    private func clearPredecessors(taskID: UUID) {
        let current = session.project?.tasks.first { $0.id == taskID }?.dependencies ?? []
        guard !current.isEmpty else { return }
        update(id: taskID, mergeKey: nil) {
            for dep in current {
                try self.session.removeDependency(from: taskID, predecessorID: dep.predecessorID)
            }
        }
    }

    private static func dependencyError(_ error: DependencyEditing.EditError, id: UUID) -> String {
        switch error {
        case .cycle: return I18n.t("error.dependency.cycle", "Adding this dependency would form a cycle: %1$@", String(id.uuidString.prefix(4)))
        case .selfDependency: return I18n.t("error.dependency.self", "A task cannot depend on itself")
        case .predecessorNotFound, .taskNotFound: return I18n.t("error.task.not_found", "Task not found: %1$@", String(id.uuidString.prefix(4)))
        }
    }

    private func mutateProject(mergeKey: String?, _ body: () throws -> Void) {
        pushUndo(mergeKey: mergeKey)
        do {
            try body()
        } catch {
            report(error)
        }
        refresh()
    }

    private func createTask(kind: TaskKind, parentID: UUID?) {
        let title: String
        switch kind {
        case .task: title = I18n.t("outline.new_task.title", "New Task")
        case .group: title = I18n.t("outline.new_group.title", "New Group")
        case .milestone: title = I18n.t("outline.new_milestone.title", "New Milestone")
        }
        let parent = parentID ?? insertionParent()
        pushUndo(mergeKey: nil)
        do {
            let id = try session.addTask(title: title, kind: kind, parentID: parent)
            viewState.selectedTaskID = id
            if let parent { viewState.expandedTaskIDs.insert(parent) }
        } catch {
            report(error)
        }
        refresh()
    }

    /// 在指定任务之后插入同级任务（`⌘↩` 与右键菜单）。
    private func createSibling(after id: UUID) {
        guard let project = session.project,
              let task = project.tasksByID[id] else {
            createTask(kind: .task, parentID: insertionParent())
            return
        }
        let parent = task.parentID
        let siblings = project.tasks.filter { $0.parentID == parent }
        let index = (siblings.firstIndex { $0.id == id } ?? siblings.count - 1) + 1
        pushUndo(mergeKey: nil)
        do {
            let newID = try session.addTask(title: I18n.t("outline.new_task.title", "New Task"), kind: .task, parentID: parent)
            try session.moveTask(id: newID, toParent: parent, at: index)
            viewState.selectedTaskID = newID
            if let parent { viewState.expandedTaskIDs.insert(parent) }
        } catch {
            report(error)
        }
        refresh()
    }

    private func insertionParent() -> UUID? {
        guard let id = viewState.selectedTaskID,
              let task = session.project?.tasksByID[id] else { return nil }
        return task.kind == .group ? id : task.parentID
    }

    /// 依赖选择器条目（不含模型细节，视图不读 `Project`）。
    struct TaskChoice: Identifiable, Hashable {
        var id: UUID
        var title: String
    }

    /// 可作为前驱的候选：排除自身、后代与已有前驱。
    func predecessorCandidates(for taskID: UUID) -> [TaskChoice] {
        guard let project = session.project,
              let task = project.tasksByID[taskID] else { return [] }
        let excluded = OutlineEditor.subtreeIDs(of: taskID, in: project.tasks)
        let existing = Set(task.dependencies.map(\.predecessorID))
        return project.tasks
            .filter { !excluded.contains($0.id) && !existing.contains($0.id) }
            .map { TaskChoice(id: $0.id, title: $0.title) }
    }

    // MARK: - 拖拽重排

    struct MoveTarget: Equatable {
        var parentID: UUID?
        var index: Int
    }

    /// 筛选激活时禁用拖拽重排（计划 §3.4）。
    var allowsDragReorder: Bool {
        viewState.filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 拖到群组行 → 成为最后一个子项；拖到普通行 → 插到其后作为同级。
    ///
    /// 索引按 `OutlineMoving` 的语义计算：移除被拖子树之后的位置。
    func moveTarget(draggedID: UUID, onto targetID: UUID) -> MoveTarget? {
        guard allowsDragReorder,
              draggedID != targetID,
              let project = session.project else { return nil }
        let movingIDs = OutlineEditor.subtreeIDs(of: draggedID, in: project.tasks)
        guard !movingIDs.isEmpty, !movingIDs.contains(targetID) else { return nil }
        let remaining = project.tasks.filter { !movingIDs.contains($0.id) }
        guard let target = remaining.first(where: { $0.id == targetID }) else { return nil }
        if target.kind == .group {
            let index = remaining.filter { $0.parentID == targetID }.count
            return MoveTarget(parentID: targetID, index: index)
        }
        let siblings = remaining.filter { $0.parentID == target.parentID }
        guard let position = siblings.firstIndex(where: { $0.id == targetID }) else {
            return nil
        }
        return MoveTarget(parentID: target.parentID, index: position + 1)
    }

    /// 悬停 600ms 自动展开收合的群组（拖拽重排）；延迟可注入供测试缩短。
    func scheduleDropExpand(on id: UUID, delayNanoseconds: UInt64 = 600_000_000) {
        cancelDropExpand()
        guard let task = session.project?.tasksByID[id],
              task.kind == .group,
              !viewState.expandedTaskIDs.contains(id) else { return }
        dropExpandTargetID = id
        dropExpandTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.viewState.expandedTaskIDs.insert(id)
            self.dropExpandTask = nil
            self.dropExpandTargetID = nil
            self.refresh()
        }
    }

    /// 只取消指定行的待展开计时；其他行的 `dropExited` 不得取消本行。
    func cancelDropExpand(on id: UUID? = nil) {
        if let id, dropExpandTargetID != id { return }
        dropExpandTask?.cancel()
        dropExpandTask = nil
        dropExpandTargetID = nil
    }

    /// 删除入口：叶子任务直接删除；有子项的任务一律确认后级联删除。
    func requestDelete(id: UUID) {
        guard let project = session.project, let task = project.tasksByID[id] else { return }
        let hasChildren = project.tasks.contains { $0.parentID == id }
        if task.kind == .group || hasChildren {
            let affected = OutlineEditor.subtreeIDs(of: id, in: project.tasks).count
            pendingDeletion = PendingDeletion(
                taskID: id, title: task.title, affectedCount: affected
            )
        } else {
            dispatch(.delete(id))
        }
    }

    func confirmPendingDeletion() {
        guard let pending = pendingDeletion else { return }
        pendingDeletion = nil
        dispatch(.delete(pending.taskID))
    }

    private func delete(id: UUID) {
        // 删除后子树已不存在，受影响的 id 必须在删除前计算。
        let removed = session.project.map {
            OutlineEditor.subtreeIDs(of: id, in: $0.tasks)
        } ?? [id]
        pushUndo(mergeKey: nil)
        do {
            _ = try session.deleteTaskCascade(id: id)
            removeFromViewSelection(removed: removed)
        } catch {
            report(error)
        }
        refresh()
    }

    private func removeFromViewSelection(removed: Set<UUID>) {
        if let selected = viewState.selectedTaskID, removed.contains(selected) {
            viewState.selectedTaskID = nil
        }
        if let locked = lockedTaskID, removed.contains(locked) {
            // 保留标题快照，提示「任务已删除」。
            lockedTaskID = nil
            lockedTaskTitle = lockedTaskTitle ?? I18n.t("outline.task.generic", "Task")
        }
        viewState.expandedTaskIDs.subtract(removed)
    }

    // MARK: - 撤销 / 重做

    private func undo() {
        guard let entry = undoStack.popLast() else {
            notice = I18n.t("alert.undo.empty", "Nothing to undo")
            return
        }
        guard let current = try? session.snapshot() else { return }
        redoStack.append(UndoEntry(
            state: current,
            selectedTaskID: viewState.selectedTaskID,
            expandedTaskIDs: viewState.expandedTaskIDs
        ))
        apply(entry)
    }

    private func redo() {
        guard let entry = redoStack.popLast() else {
            notice = I18n.t("alert.redo.empty", "Nothing to redo")
            return
        }
        guard let current = try? session.snapshot() else { return }
        undoStack.append(UndoEntry(
            state: current,
            selectedTaskID: viewState.selectedTaskID,
            expandedTaskIDs: viewState.expandedTaskIDs
        ))
        apply(entry)
    }

    private func apply(_ entry: UndoEntry) {
        do {
            try session.restore(entry.state)
        } catch {
            report(error)
        }
        let existing = Set(entry.state.tasks.map(\.id))
        viewState.selectedTaskID = entry.selectedTaskID.flatMap {
            existing.contains($0) ? $0 : nil
        }
        viewState.expandedTaskIDs = entry.expandedTaskIDs.filter { existing.contains($0) }
        if let locked = lockedTaskID, !existing.contains(locked) { lockedTaskID = nil }
        lastMergeKey = nil
        refresh()
    }

    // MARK: - 揭示目标

    /// 「临时显示」只在被揭示任务保持选中时有效；选择移到别处即恢复原筛选。
    private func restoreSuspendedFilterIfNeeded(selecting id: UUID?) {
        guard let text = suspendedFilterText else { return }
        guard id != viewState.highlightedTaskID else { return }
        suspendedFilterText = nil
        viewState.filterText = text
    }

    /// 展开祖先、必要时临时清除筛选、选中目标；不切换检查器页签。
    func reveal(_ id: UUID) {
        guard let project = session.project else { return }
        guard let task = project.tasksByID[id] else {
            viewState.selectedTaskID = nil
            viewState.highlightedTaskID = nil
            viewState.revealStatus = .missing
            notice = I18n.t("alert.task_deleted", "Task deleted")
            refresh()
            return
        }

        var ancestors: Set<UUID> = []
        var parent = task.parentID
        var hops = 0
        while let current = parent, project.tasksByID[current] != nil, hops <= project.tasks.count {
            ancestors.insert(current)
            parent = project.tasksByID[current]?.parentID
            hops += 1
        }
        viewState.expandedTaskIDs.formUnion(ancestors)

        var status = RevealStatus.visible
        let clauses = AIFilterTranslator.translate(viewState.filterText)
        if !clauses.isEmpty {
            let matched = Set(AIFilterTranslator.apply(clauses: clauses, to: project.tasks).map(\.id))
            if !matched.contains(id) {
                suspendedFilterText = viewState.filterText
                viewState.filterText = ""
                status = .temporarilyShown
            }
        }
        viewState.selectedTaskID = id
        viewState.highlightedTaskID = id
        viewState.revealStatus = status
        switch status {
        case .visible:
            notice = nil
        case .temporarilyShown:
            notice = I18n.t("alert.task_hidden_by_filter", "“%1$@” was hidden by the filter and is now shown temporarily", task.title)
        case .missing:
            break
        }
        refresh()
    }

    // MARK: - 文件

    /// 有待载入的示例项目，但当前项目存在未保存修改；等待用户选择丢弃并载入 / 取消。
    /// 与 `pendingOpenURL` 同款确认流程（AC-3），由视图弹确认对话框。
    @Published private(set) var pendingLoadExample = false

    /// 「文件 → 载入示例项目」（AC-2/AC-3）：无未保存修改时直接用示例数据重建项目内容
    /// （不写磁盘、不自动保存）；有未保存修改时先确认，避免静默丢弃工作。
    func loadExampleProject() {
        guard !session.hasUnsavedChanges else {
            pendingLoadExample = true
            return
        }
        loadExampleNow()
    }

    func cancelPendingLoadExample() {
        pendingLoadExample = false
    }

    func confirmPendingLoadExample() {
        guard pendingLoadExample else { return }
        pendingLoadExample = false
        loadExampleNow()
    }

    /// 载入示例等同「新建示例」：重置为空项目（projectURL 置 nil）再填入示例内容。
    private func loadExampleNow() {
        _ = try? session.createProject(title: I18n.t("alert.project.default_title", "Untitled Project"))
        Self.seed(SeedData.makeProject(), into: session)
        resetViewStateForLoadedProject()
        undoStack.removeAll()
        redoStack.removeAll()
        pendingDeletion = nil
        saveState = .saved
        needsFormatUpgrade = session.needsFormatUpgrade
        notice = I18n.t("alert.example_loaded", "Example project loaded")
        refresh()
    }

    /// 把示例项目内容灌入当前会话项目（不写磁盘；供 init 种子与载入示例共用）。
    /// 静态：init 属性初始化前即可调用。
    private static func seed(_ seed: Project, into session: KairoSession) {
        guard let project = session.project else { return }
        project.metadata.projectStart = seed.metadata.projectStart
        project.metadata.projectEnd = seed.metadata.projectEnd
        project.metadata.direction = seed.metadata.direction
        for task in seed.tasks { project.add(task) }
    }

    @discardableResult
    func open(url: URL) -> Bool {
        do {
            _ = try session.openProject(at: url)
            finishOpen()
            return true
        } catch {
            // 打不开的文件不进最近列表，否则菜单里会留一条永远失败的项。
            forgetRecentProject(url)
            report(error)
            return false
        }
    }

    // MARK: - 最近打开

    /// 显式打开请求（双击文件、深链、菜单选择）：启动时的默认打开不再抢占。
    func noteExplicitOpenRequest() {
        didReceiveExplicitOpen = true
    }

    /// 菜单/命令面板入口：打开最近列表中的文件，走与文件选择器相同的未保存确认。
    func openRecentProject(_ url: URL) {
        noteExplicitOpenRequest()
        openAsync(url: url)
    }

    /// 启动默认打开最近一次使用的项目（产品要求：默认打开最后一个）。
    ///
    /// 三个前提缺一不打开：只尝试一次、本次启动没有更明确的打开请求、当前没有项目路径。
    /// 返回是否发起了打开（测试观测缝）。
    @discardableResult
    func openMostRecentProjectOnLaunch() -> Bool {
        guard !didAttemptLaunchOpen else { return false }
        didAttemptLaunchOpen = true
        guard !didReceiveExplicitOpen, session.projectURL == nil, !isLoading else { return false }
        guard let url = recentStore.mostRecentExisting() else {
            // 顺手剔除失效条目：菜单里不留打不开的死链。
            recentProjects = recentStore.urls
            return false
        }
        openAsync(url: url)
        return true
    }

    /// 「清除菜单」：清空最近列表，不动当前已打开的项目。
    func clearRecentProjects() {
        recentStore.clear()
        recentProjects = []
    }

    private func noteRecentProject(_ url: URL?) {
        guard let url else { return }
        recentStore.note(url)
        recentProjects = recentStore.urls
    }

    private func forgetRecentProject(_ url: URL) {
        recentStore.remove(url)
        recentProjects = recentStore.urls
    }

    /// 文件选择器入口：有未保存修改时先询问，避免静默丢弃工作。
    func openAsync(url: URL) {
        guard !isLoading else {
            // 早退不进入 finishOpen；清理待恢复的升级提示，避免残留到下一次打开。
            pendingUpgradeNoticeAfterOpen = nil
            notice = I18n.t("alert.loading_in_progress", "A project is still loading; try opening again in a moment")
            return
        }
        guard !session.hasUnsavedChanges else {
            pendingOpenURL = url
            return
        }
        startOpenAsync(url: url)
    }

    var canSavePendingOpen: Bool {
        pendingOpenURL != nil && session.projectURL != nil
    }

    func cancelPendingOpen() {
        pendingOpenURL = nil
    }

    func discardChangesAndOpenPending() {
        guard let url = pendingOpenURL else { return }
        pendingOpenURL = nil
        startOpenAsync(url: url)
    }

    func saveAndOpenPending() {
        guard pendingOpenURL != nil else { return }
        let wasUpgrade = session.needsFormatUpgrade
        save()
        guard saveState != .failed else { return }
        if wasUpgrade {
            // finishOpen 会用载入警告重置 notice；升级提示需跨过这次打开保留。
            pendingUpgradeNoticeAfterOpen = I18n.t("alert.upgraded_to", "Upgraded to v%1$ld", KairoFile.currentFormatVersion)
        }
        discardChangesAndOpenPending()
    }

    /// 后台解码，主线程接管；超过 150ms 显示骨架屏。
    private func startOpenAsync(url: URL) {
        guard !isLoading else { return }
        // 载入期间用户仍可编辑旧项目；接管前核对版本，避免静默覆盖新改动。
        let revisionAtStart = session.revision
        let token = UUID()
        loadingToken = token
        isLoading = true
        showsLoadingSkeleton = false

        Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard isLoading, loadingToken == token else { return }
            showsLoadingSkeleton = true
        }

        let accessing = url.startAccessingSecurityScopedResource()
        let loader = projectLoader
        Task { [weak self] in
            let loaded: Result<DecodedProject, Error> = await Task.detached(priority: .userInitiated) {
                Result { try loader(url) }
            }.value
            if accessing { url.stopAccessingSecurityScopedResource() }
            guard let self, self.loadingToken == token else { return }
            switch loaded {
            case .success(let decoded) where self.session.revision == revisionAtStart:
                self.session.adoptProject(
                    decoded.project, from: url, formatVersion: decoded.sourceFormatVersion
                )
                self.finishOpen()
            case .success:
                // 载入期间有新编辑：保留当前内容，重新进入保存/丢弃/取消确认。
                self.pendingUpgradeNoticeAfterOpen = nil
                self.pendingOpenURL = url
                self.notice = I18n.t("alert.changed_while_loading", "The project changed while loading; local content was kept. Confirm opening again.")
            case .failure(let error):
                self.pendingUpgradeNoticeAfterOpen = nil
                self.forgetRecentProject(url)
                self.report(error)
            }
            self.isLoading = false
            self.showsLoadingSkeleton = false
            self.loadingToken = nil
            self.resumePendingOpenWaiters()
        }
    }

    /// 唤醒所有等待打开收尾的调用方（收尾路径唯一，只需在这里通知）。
    private func resumePendingOpenWaiters() {
        let waiters = pendingOpenWaiters
        pendingOpenWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func finishOpen() {
        loadWarnings = session.loadWarnings
        resetViewStateForLoadedProject()
        undoStack.removeAll()
        redoStack.removeAll()
        pendingDeletion = nil
        pendingBaselineDeletion = nil
        pendingOpenURL = nil
        saveState = .saved
        needsFormatUpgrade = session.needsFormatUpgrade
        recordDiskVersion(at: session.projectURL)
        // 升级提示与载入警告同时存在时合并展示，避免丢弃唯一的警告消费点。
        let upgradeNotice = pendingUpgradeNoticeAfterOpen
        pendingUpgradeNoticeAfterOpen = nil
        let warningText = loadWarnings.first.map(Display.loadWarning)
        if let upgradeNotice, let warningText {
            notice = I18n.t("alert.notice.combined", "%1$@; %2$@", upgradeNotice, warningText)
        } else {
            notice = upgradeNotice ?? warningText
        }
        // 打开成功才进最近列表：失败路径在各自 catch 里剔除。
        noteRecentProject(session.projectURL)
        refresh()
    }

    func save(to url: URL? = nil) {
        let wasUpgrade = session.needsFormatUpgrade
        do {
            _ = try session.saveProject(to: url)
            saveState = .saved
            needsFormatUpgrade = session.needsFormatUpgrade
            // 每次保存至多提示一次：保存成功后来源版本即为当前版本。
            if wasUpgrade {
                notice = I18n.t("alert.upgraded_to", "Upgraded to v%1$ld", KairoFile.currentFormatVersion)
            }
            recordDiskVersion(at: session.projectURL)
            noteRecentProject(session.projectURL)
            refresh()
        } catch {
            saveState = .failed
            report(error)
            refresh()
        }
    }

    /// 复制任务深链（`kairo://task/<id>`），由适配层写入剪贴板。
    func copyTaskLink(_ id: UUID) {
        let link = "kairo://task/\(id.uuidString)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        notice = I18n.t("alert.link_copied", "Task link copied")
    }

    /// 另存为面板的默认文件名（FR-FILE-SAVEAS-2）：有路径沿用文件名，否则按项目标题生成。
    var suggestedSaveFilename: String {
        SaveFilenameSuggestion.suggest(
            currentURL: projectURL,
            title: session.project?.metadata.title ?? ""
        )
    }

    /// 打开另存为面板前记录版本，导出完成时据此判断快照是否仍然最新。
    func beginExport() {
        exportRevision = session.revision
    }

    /// 取消另存为面板：清理导出快照版本，之后的完成回调不再误判快照最新。
    func cancelExport() {
        exportRevision = nil
    }

    /// 另存为完成：文件导出器已写入快照，这里只回填路径并清除脏标记，不重复写文件。
    /// 面板打开期间若又有修改，导出内容已过期，改以内存为准直接写一次。
    func rememberSaveURL(_ url: URL) {
        let revision = exportRevision
        exportRevision = nil
        let wasUpgrade = session.needsFormatUpgrade
        // 未经 beginExport 的调用无法确认导出内容是否最新，直接写内存内容。
        if revision == nil || revision != session.revision {
            save(to: url)
            if wasUpgrade, saveState != .failed {
                notice = I18n.t("alert.saved_as_upgraded", "Saved as a new file and upgraded to v%1$ld", KairoFile.currentFormatVersion)
            }
            return
        }
        session.noteExported(to: url)
        saveState = .saved
        needsFormatUpgrade = session.needsFormatUpgrade
        if wasUpgrade {
            notice = I18n.t("alert.saved_as_upgraded", "Saved as a new file and upgraded to v%1$ld", KairoFile.currentFormatVersion)
        }
        recordDiskVersion(at: url)
        noteRecentProject(url)
        refresh()
    }

    /// 外部重载：丢失本地未保存修改，需由视图确认。
    func reloadExternal() {
        guard let url = session.projectURL else { return }
        let mtime = pendingExternalMtime ?? Self.modificationDate(of: url)
        if open(url: url) {
            notice = mtime.map {
                I18n.t("alert.external_update_loaded", "External update loaded at %1$@", Display.time($0))
            } ?? I18n.t("alert.external_update_loaded.plain", "External update loaded")
        } else {
            // 失败保留横幅；相同 mtime 不再重复尝试。
            failedExternalMtime = mtime
        }
    }

    private func resetViewStateForLoadedProject() {
        let tasks = session.project?.tasks ?? []
        viewState = WorkspaceViewState(
            expandedTaskIDs: Self.allParentIDs(in: tasks),
            inspectorVisible: viewState.inspectorVisible,
            inspectorWidth: viewState.inspectorWidth,
            showCriticalPath: viewState.showCriticalPath,
            showBarLabels: viewState.showBarLabels,
            // 非工作日着色是应用级视图偏好：换项目保留用户选择。
            showsNonWorkingDays: viewState.showsNonWorkingDays,
            // 列宽/显隐是应用级视图偏好（与检查器宽度同类）：换项目不重置，
            // 否则打开文件会静默清空用户配置并写回偏好。
            outlineColumnWidths: viewState.outlineColumnWidths,
            hiddenOutlineColumns: viewState.hiddenOutlineColumns,
            visibleOptionalColumns: viewState.visibleOptionalColumns,
            // 基线选择同理：ID 解析不到就是「不比较」，不因为换项目就抹掉偏好。
            selectedBaselineID: viewState.selectedBaselineID,
            // 显示集合同为应用级偏好（v0.14 §6）：解析不到的 ID 由读取侧归一化剔除，
            // 不因为换项目就清空「我在图上想看哪几条」。
            visibleBaselineIDs: viewState.visibleBaselineIDs,
            // 列顺序同为应用级偏好（v0.16 / #12）：换项目保留用户排好的顺序，不悄悄打回默认。
            columnOrder: viewState.columnOrder
        )
        lockedTaskID = nil
        lockedTaskTitle = nil
        suspendedFilterText = nil
    }

    private static func allParentIDs(in tasks: [TaskItem]) -> Set<UUID> {
        Set(tasks.compactMap(\.parentID))
    }

    // MARK: - 视图偏好持久化

    private static func loadPreferences(from defaults: UserDefaults) -> StoredPreferences? {
        guard let data = defaults.data(forKey: preferencesKey) else { return nil }
        return try? JSONDecoder().decode(StoredPreferences.self, from: data)
    }

    /// 载入列宽覆盖：丢弃未知列、非有限值与越界宽度（静默容错，不牵连其它字段）。
    ///
    /// 越界值丢弃而不夹取：宽度不合法说明数据已损坏，回落默认宽比落到边界更贴近用户原意。
    private static func loadedColumnWidths(_ stored: [String: Double]?) -> [String: Double] {
        guard let stored else { return [:] }
        var loaded: [String: Double] = [:]
        for (raw, width) in stored {
            guard let column = OutlineColumn(rawValue: raw),
                  width.isFinite,
                  OutlineColumnPreferences.widthRange(for: column).contains(width) else { continue }
            loaded[column.rawValue] = width
        }
        return loaded
    }

    /// 载入隐藏列：丢弃未知列 rawValue 与固定列（序号/任务说明不参与显隐）。
    private static func loadedHiddenColumns(_ stored: [String]?) -> Set<String> {
        guard let stored else { return [] }
        return Set(stored.compactMap { raw -> String? in
            guard let column = OutlineColumn(rawValue: raw),
                  !OutlineColumnPreferences.alwaysVisible.contains(column) else { return nil }
            return column.rawValue
        })
    }

    /// 载入列顺序：丢弃未知 rawValue，缺失的列按 `allCases` 顺序追加到末尾（**不丢列**）。
    ///
    /// 旧数据没有该字段 → 默认顺序，与改动前逐列一致；损坏数据（未知列 / 重复列）
    /// 由归一化就地修好，不回写脏值、不影响其余偏好（D-016 逐字段容错）。
    private static func loadedColumnOrder(_ stored: [String]?) -> [OutlineColumn] {
        guard let stored else { return OutlineColumnPreferences.defaultOrder }
        return OutlineColumnPreferences.normalizedOrder(stored.compactMap(OutlineColumn.init(rawValue:)))
    }

    /// 载入可选列：只保留可选列集合内的 rawValue，未知列与普通列静默丢弃。
    private static func loadedOptionalColumns(_ stored: [String]?) -> Set<String> {
        guard let stored else { return [] }
        return Set(stored.compactMap { raw -> String? in
            guard let column = OutlineColumn(rawValue: raw),
                  OutlineColumnPreferences.optional.contains(column) else { return nil }
            return column.rawValue
        })
    }

    private func savePreferences() {
        let columnOrder = OutlineColumnPreferences.normalizedOrder(viewState.columnOrder)
        let stored = StoredPreferences(
            outlineWidth: viewState.outlineWidth,
            outlineVisible: viewState.outlineVisible,
            expandedTaskIDs: Array(viewState.expandedTaskIDs),
            zoom: viewState.zoom,
            usesFitZoom: viewState.usesFitZoom,
            customDayWidth: viewState.customDayWidth,
            windowStart: viewState.windowStart,
            inspectorWidth: viewState.inspectorWidth,
            inspectorTab: viewState.inspectorTab,
            // 空覆盖/空隐藏写 nil：JSON 不落空容器，旧版本读回同一语义。
            outlineColumnWidths: viewState.outlineColumnWidths.isEmpty ? nil : viewState.outlineColumnWidths,
            hiddenOutlineColumns: viewState.hiddenOutlineColumns.isEmpty
                ? nil
                : viewState.hiddenOutlineColumns.sorted(),
            visibleOptionalColumns: viewState.visibleOptionalColumns.isEmpty
                ? nil
                : viewState.visibleOptionalColumns.sorted(),
            // 默认顺序写 nil：JSON 不为「没动过」的状态多长一个键，旧版本读回同一语义。
            outlineColumnOrder: columnOrder == OutlineColumnPreferences.defaultOrder
                ? nil
                : columnOrder.map(\.rawValue),
            showsNonWorkingDays: viewState.showsNonWorkingDays,
            // 基线选择是应用级视图偏好：换项目保留（解析不到时等价于「不比较」）。
            selectedBaselineID: viewState.selectedBaselineID,
            // 显隐同口径：Set 无序，按 UUID 字符串排序落盘，保证同一状态写出同一份 JSON。
            visibleBaselineIDs: viewState.visibleBaselineIDs.isEmpty
                ? nil
                : viewState.visibleBaselineIDs.sorted { $0.uuidString < $1.uuidString }
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.preferencesKey)
    }

    // MARK: - 偏差 CSV 导出（v0.15.1）

    /// 把当前对比基线的偏差写成 CSV（与 CLI 共用 VarianceCSV，列头与转义规则同源）。
    func exportVarianceCSV(to url: URL) throws {
        let focusID = viewState.selectedBaselineID ?? (try? session.baselines())?.last?.id
        guard let focusID else {
            throw CSVWriteFailure(message: I18n.t("alert.csv.no_baseline", "No baseline to export yet."))
        }
        let report = try session.baselineVariance(baselineID: focusID)
        let rows = snapshot.outline.rows
        let order = rows.map(\.id)
        let titles = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.title) })
        let ids = VarianceCSV.orderedTaskIDs(report, projectOrder: order)
        let text = VarianceCSV.document(report: report, taskIDs: ids, titles: titles)
        guard let data = text.data(using: .utf8) else {
            throw CSVWriteFailure(message: I18n.t("alert.csv.encode_failed", "The CSV could not be encoded."))
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw CSVWriteFailure(message: error.localizedDescription)
        }
    }

    /// 菜单入口：弹保存面板 → 写盘 → 失败时用应用内提示。
    @MainActor
    func presentVarianceCSVExport() {
        guard (try? session.baselines())?.isEmpty == false else {
            alertMessage = I18n.t("alert.csv.no_baseline", "No baseline to export yet.")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "kairo-variance.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try exportVarianceCSV(to: url)
            notice = I18n.t("notice.csv.exported", "Variance CSV exported: %1$@", url.lastPathComponent)
        } catch {
            alertMessage = (error as? CSVWriteFailure)?.message ?? error.localizedDescription
        }
    }


    // MARK: - 外部更新检测

    /// 比较磁盘 mtime（应用前台每 2 秒调用一次；测试可直接调用）。
    func checkExternalUpdate() {
        guard let url = session.projectURL,
              let mtime = Self.modificationDate(of: url) else { return }
        if let acknowledgedMtime, mtime <= acknowledgedMtime { return }
        if let knownDiskMtime, mtime == knownDiskMtime { return }
        if let failedExternalMtime, mtime <= failedExternalMtime { return }

        if session.hasUnsavedChanges {
            pendingExternalMtime = mtime
            externalUpdatePending = true
        } else if open(url: url) {
            notice = I18n.t("alert.external_update_loaded", "External update loaded at %1$@", Display.time(mtime))
        } else {
            failedExternalMtime = mtime
        }
    }

    private func recordDiskVersion(at url: URL?) {
        knownDiskMtime = url.flatMap { Self.modificationDate(of: $0) }
        pendingExternalMtime = nil
        acknowledgedMtime = nil
        failedExternalMtime = nil
        externalUpdatePending = false
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    // MARK: - 错误

    private func report(_ error: Error) {
        if let sessionError = error as? SessionError {
            alertMessage = sessionError.message
        } else if let fileError = error as? KairoFileError {
            alertMessage = fileError.description
        } else {
            alertMessage = error.localizedDescription
        }
    }
}
