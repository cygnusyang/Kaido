# Sprint 7 设计稿 —— F-14-09 甘特图直接编辑（画布拖拽）

> 2026-10-21 · 状态：待评审
> 依据：docs/features/01-views-editing.md F-14-09（P1）、docs/03-roadmap.md §5 Sprint 7 主线、
> docs/design/ui-redesign.md §10「本期不做」（:273-277，本期显式解除画布拖拽禁令）
> 发版目标：v0.4.0（feature 级）

## 1. 范围与裁定

### 本期做（4 项交互）

| # | 交互 | 写回 | OmniPlan 参照 |
|---|---|---|---|
| 1 | 拖条体（水平）改期 | `startDate` 平移（duration 不变，dueDate 随排程联动） | 拖条体 = 移动 |
| 2 | 拖右端点改持续 | `durationDays`（start 不变） | 拖右端牵引条 |
| 3 | 拖左端点改开始 | `startDate`（end 不变，duration = end−start 随动） | 拖左端 |
| 4 | 从条端点外环带拖出建依赖线（FS / lag 0）；点选线（≤4pt）+ Delete 删线 | `addDependency` / `removeDependency` | 条首尾拖箭头；点选按 Delete |

### 不做（本期显式排除，延续「不做半成品」原则）

- 拖拽绘制 SSn/FF 时限（constraint）：写回面不同，留后续。
- 拖条内进度白点改 progress：检查器已有 setProgress，画布版留 P2。
- 多选/框选、跨视图拖拽（大纲↔画布）、拖拽改层级。
- `schedulingType = .manual`：Zeno 无该类型。**裁定**：拖条改期 = 显式 `startDate` 锚定
  （`TaskPatch.startDate = .set(...)`），排程尊重显式开始，语义等价 OmniPlan 手动安排。

### 对象适配裁定

| 条类型 | 拖动 | 端点 | 依赖线 |
|---|---|---|---|
| 普通任务条 | ✅ | ✅ | ✅ |
| 里程碑（菱形） | ✅（仅改期） | ❌（端点命中退化为 body） | ✅ |
| 群组聚合条（isAggregate） | ❌（命中 none，仅点选） | ❌ | ✅（可作依赖端点） |

依赖方向语义：从 A **尾端**拖到 B → A 是 B 的前驱（写 B 的 dependencies）；从 A **首端**拖到 B → B 是 A 的前驱。
环检测复用 `DependencyEditing.add`（cycle → 拒绝提交，预览线消失，无残留状态）。

## 2. 架构

### 2.1 命中测试（纯函数，ZenoPresentation 新文件 `GanttHitTesting.swift`）

GanttBar 定义在 ZenoPresentation（Snapshots.swift:175-220），命中测试放同层而非 ZenoCore，测试进 ZenoPresentationTests。

```swift
enum GanttDragTarget: Equatable {
    case body(UUID)            // 拖条改期
    case startHandle(UUID)     // 拖左端
    case endHandle(UUID)       // 拖右端
    case dependencyStart(UUID) // 从首端外环带拖出建依赖
    case dependencyEnd(UUID)   // 从尾端外环带拖出建依赖
    case dependencyLine(Int)   // 依赖线命中（GanttDependency 下标），供删除
    case none
}

enum GanttHitTesting {
    static func hitTest(point: CGPoint, canvasOffset: CGFloat,
                        bars: [GanttBar], dependencies: [GanttDependency],
                        rowHeight: CGFloat, dayWidth: CGFloat) -> GanttDragTarget
    static func date(atX: CGFloat, windowStart: Date, dayWidth: CGFloat) -> Date   // 日粒度吸附
    static func days(fromTranslationX: CGFloat, dayWidth: CGFloat) -> Int          // 复用 pannedWindowStart 模式
}
```

命中区域表（`row = Int((point.y + offset) / rowHeight)`，行内再按 x 细分）：

| 区域 | 条件 | 输出 |
|---|---|---|
| 端点内 6pt | 条 x 范围内，\|x−startX\|≤6 或 \|x−endX\|≤6 | startHandle / endHandle |
| 端点外 8pt 环带 | 条 x 范围外，距端点 ≤8pt | dependencyStart / dependencyEnd |
| 条体内 | x ∈ [startX, endX] | body |
| 空白 | — | none（先行行命中，再全线段距离 ≤4pt 测依赖线，优先返回 dependencyLine） |

日期换算：`days = Int((x / dayWidth).rounded())`（日粒度吸附，与拖拽位移同式），`date = windowStart + days × 86400`。
dayWidth 下限兜底沿用 `pannedWindowStart` 的 0.5 处理（GanttLayout.swift:516-523）。

### 2.2 拖拽状态机（引用语义 class，模板 = DayWidthThrottle）

新文件 `Apps/macos/Sources/Workspace/Timeline/CanvasDragSession.swift`。**硬约束**：GUIRenderTests 只能 dispatch 动作、无法模拟手势事件（GUIRenderTests.swift 驱动方式），故拖拽逻辑必须抽成引用语义状态机直接驱动（DayWidthControl.swift:7-10 教训）。

```swift
final class CanvasDragSession {
    enum Phase { case idle, moving(UUID), resizing(UUID, edge), linking(source: UUID, isFromEnd: Bool) }
    // 本地预览态：偏移 pt / 预览目标条 / 依赖预览终点 —— 只在视图层消费，不进 GanttSnapshot
    // 时钟注入（now: () -> Date），单测可控
    func begin(target: GanttDragTarget, at: CGPoint)
    func update(translation: CGSize, location: CGPoint) -> [CommitRequest]   // 100ms 节流
    func finish() -> [CommitRequest]    // 松手必提交末值
    func cancel()                       // Escape：丢弃预览，不产生提交
}
enum CommitRequest { case move(id: UUID, startDate: Date); case resize(id: UUID, startDate: Date?, durationDays: Double); case link(taskID: UUID, predecessorID: UUID) }
```

- 预览态为视图本地状态，**不写入 GanttSnapshot / WorkspaceViewState**：无拖拽时零预览 → A7 黄金基线（preset/fit 逐位一致）天然不受影响；不污染 presentation 快照。
- 100ms 节流 + `pushUndo` 合并（500ms，合并时 `lastMergeAt` 刷新，WorkspaceStore.swift:649-651 已核实）→ 长拖拽全程并为一步撤销。

### 2.3 动作层（WorkspaceAction 新增 1 个，其余复用）

```swift
case canvasEditSchedule(UUID, startDate: Date?, durationDays: Double?)
```

- Store 端组装 `TaskPatch`：move = `startDate: .set`；resize 右端 = `durationDays: .set`；
  resize 左端 = `startDate: .set` + `durationDays: .set(新duration)`（end 不变）。
- duration 下限 1 天（日粒度拖拽天然满足）；`updateTask(id:patch:)`（ZenoSession.swift:372-415）已支持全部字段，**命令层零改动**。
- 依赖建/删直接复用 `.addDependency(taskID:predecessorID:type:lagDays:)` / `.removeDependency`；环检测免费获得。
- 撤销 mergeKey：`"canvas-move-\(id)"` / `"canvas-resize-\(id)"`；依赖增删 `mergeKey: nil`（结构性操作，沿用既有先例）。

### 2.4 视图接线（TimelineView.swift）

- `TimelineBody` 的 Canvas：在现有 `SpatialTapGesture`（:139-142）旁挂 `DragGesture(minimumDistance: 2)`；
  命中优先依赖线 > 端点 > 环带 > 条体 > 空白。Tap 与 Drag 共存行为在实现时验证（风险点 R2）。
- 预览绘制：新 `drawDragPreview`（目标位半透明条 + 虚线框 + 日期标签）、`drawDependencyPreview`
  （起点→鼠标折线 + 箭头，样式对齐现有 drawDependencies/drawArrow）。预览几何由 `GanttHitTesting`
  纯函数计算（可测），渲染复用现有 Canvas 管线。
- 依赖线选中态：TimelineBody 本地 `@State selectedDependencyIndex: Int?`（纯视图交互态，不进持久化
  view state）；Delete/Backspace 键 → dispatch `.removeDependency`，并清除选中。
- 光标（可选打磨）：hover 端点时 NSCursor.resizeLeftRight。

### 2.5 约束解除（文档同步，随实现一起改）

- `docs/design/ui-redesign.md` §10:277「画布不得注册条体拖拽或依赖连线拖拽手势」→ 改为「已随 F-14-09 落地，
  手势必须经 CanvasDragSession 状态机 + 纯函数命中测试，禁止视图内联提交逻辑」。
- `docs/features/01-views-editing.md` F-14-09 实现方案段（:341）同步更新为已实现态。

## 3. 测试计划

| 层 | 用例 | 归宿 |
|---|---|---|
| 纯函数 | hitTest 区域表全分支（body/start/end/depStart/depEnd/line/none）× 三条类型（普通/里程碑/群组）；越界与 rowHeight/dayWidth 兜底 | ZenoPresentationTests（新 GanttHitTestingTests.swift） |
| 纯函数 | date(atX:) 日粒度吸附、days(fromTranslationX:) 方向与 0.5 兜底 | 同上 |
| 状态机 | 节流窗口内合并、finish 必提交末值、cancel 零提交、Escape 后重拖、注入时钟驱动时序 | AppTests（CanvasDragSessionTests.swift） |
| Store 路由 | canvasEditSchedule 三语义（move 保 duration / resize 右端保 start / resize 左端 end 不变）；undo 合并为一步 | AppTests（Sprint7 Gantt Edit 用例） |
| 依赖 | 尾拖/首拖方向语义、环拒绝不落库、删线路由 removeDependency | AppTests |
| 渲染回归 | A7 黄金基线不变（无拖拽零预览）；GUIRenderTests 现有用例全绿 | GUIRenderTests |

缺陷登记沿用 `docs/defects.md`（D-0xx 顺延编号）。验收判据 = roadmap §5：「甘特画布直接拖拽完成改期/建依赖全流程」。

## 4. 风险与预案

| # | 风险 | 预案 |
|---|---|---|
| R1 | 拖拽期间虚拟化重排（firstRow/lastRow 变化）致预览闪烁 | 预览以 row 计算独立于虚拟化窗口，仅渲染可见部分 |
| R2 | SpatialTapGesture 与 DragGesture 共存识别冲突 | 实现时验证；必要时以 minimumDistance 区分或统一为单一手势 + 位移阈值判定 |
| R3 | 500ms 撤销合并窗口与 100ms 节流的边界（最后一笔 >500ms 间隔） | finish() 必提交；若拆步属可接受降级（两步而非一步），不阻塞 |
| R4 | 排程重算与拖拽节流的竞态（拖拽中快照刷新使 bars 位移） | 预览基于拖拽起点快照锚定，提交后才消费新快照 |
