# Sprint 9 设计稿 —— F-14-18 甘特图横向平移（触摸板/滚轮 + 画布拖拽）

> 2026-10-22 · 状态：待评审
> 用户诉求：任务或依赖链超出视口时，画布无法左右移动；macOS 触摸板横向滚动无效，不便检查前后依赖。
> 发版目标：v0.6.0（minor +1）。推翻 F-14-13 原约束「本期用拖动表头平移时间窗，不做横向滚动条」。

## 1. 现状与约束

- **视口即时间窗**：`GanttLayoutEngine.make` 中 `windowSeconds = viewWidth / dayWidth`、`windowEnd = windowStart + windowSeconds`（GanttLayout.swift:175-176），
  画布宽度恒等于视口宽，**不存在可滚动的内容层**。因此横向移动只能是 `windowStart` 位移，不是 ScrollView 平移。
- **窗口起点整天归一**：`calendar.startOfDay(for: requestedStart)`（GanttLayout.swift:172-174）⇒ 平移粒度为整天。
- **现有入口**：仅表头拖拽（TimelineHeaderView，`pannedWindowStart` / 手动取整）；无平移命令、无横向滚动。
- **手势槽位**：`TimelineBody` 已挂 `SpatialTapGesture` + `simultaneousGesture(DragGesture(minimumDistance: 2))`；
  命中 `.none`（空白/群组条）时整段手势空转 —— 直接复用，不新增 gesture。

## 2. 交互规格

| 输入 | 行为 | 说明 |
|---|---|---|
| 触摸板横向双指滑动 | 内容跟手左右平移 | `NSEvent.scrollWheel` 的 `scrollingDeltaX`（系统「自然滚动」由 OS 取反，语义天然一致） |
| Shift + 纵向滚轮/双指 | 转横向平移 | 无横向滚轮设备（鼠标）的替代入口 |
| 画布空白处拖拽 | 内容跟手左右平移 | 起点命中 `.none` 且该行无条；条/依赖线/端点上的拖拽仍归 F-14-09 |
| Escape（拖拽中） | 取消本段拖拽 | 与 F-14-09 一致：已提交的平移不回滚（同表头拖拽既有语义） |

- **方向**：内容跟手 —— 向右拖/向右滑 = 看更早日期（`windowStart` 减小）。
- **粒度**：整天（布局契约）。滚动输入按 `HorizontalPanAccumulator` 累积亚日余量，跨整天才提交，避免逐事件取整导致「一天天蹦」。
- **适合项目**：任何平移都退出 fit（沿用 `panWindow` 语义），工具栏 ✓ 与状态栏同步回落。
- **不做**：横向滚动条（保留「视口即窗口」模型）、子日粒度窗口（会破坏 A7 黄金基线）、平移回滚。

## 3. 架构

### 3.1 纯函数：`HorizontalPanAccumulator`（KairoPresentation，可测）

```swift
public struct HorizontalPanAccumulator {
    public mutating func consume(deltaX: Double, dayWidth: Double) -> Int  // 返回整天数，余量留存
    public mutating func reset()
}
```

- 语义：正数 = 内容右移（窗口起点减小）；`dayWidth < 0.5` 按 0.5 兜底（与 `pannedWindowStart` 同式）。
- `.rounded(.towardZero)` 逐次释放整天，余量留在结构体内 ⇒ 慢速滑动也能累积到位，不丢位移。

### 3.2 拖拽平移：`PanDragSession`（App 层引用语义，可测）

```swift
@MainActor final class PanDragSession {
    func begin(windowStart: Date, dayWidth: Double)
    func update(translationX: Double) -> Date?   // 天数未变返回 nil（抑制无谓 dispatch）
    func end(); func cancel()
}
```

- 锚定按下时 `windowStart`，位移绝对量取整（`GanttHitTesting.days(fromTranslationX:)` 的反号），稳定无抖动。
- 与 F-14-09 的 `CanvasDragSession` 同款「引用语义 + 视图只驱动」纪律（D-020 教训：手势逻辑不得内联在视图）。

### 3.3 滚动捕获：`HorizontalScrollMonitor`（App 层薄胶水）

- `NSEvent.addLocalMonitorForEvents(matching: .scrollWheel)`，条件全部满足才消费：
  1) 事件属于主窗口；2) 光标落在画布视口矩形内（`GeometryReader.frame(in: .global)` + 窗口内容坐标翻转）；
  3) 非 `NSTextView` 首响应者（编辑中不抢滚）；4) 横向分量占优，或 Shift + 纵向。
- 满足则调用 `handler(deltaX)` 并返回 `nil` 吞掉事件；否则原样放行（纵向滚动容器照常工作）。
- 该层不做几何换算（只做命中与转发），换算全在 3.1/3.2 的纯函数里 —— 离屏渲染测试无事件循环，无法覆盖 monitor，靠纯函数 + Store 断言兜底。

### 3.4 视图接线（TimelineView.swift）

- `GeometryReader` 背景记录 `viewportRect`（global 坐标），`onAppear/onDisappear` 装卸 monitor。
- 滚动 → `panAccumulator.consume` → `store.dispatch(.panWindow(to: windowStart - days))`。
- 拖拽：`handleDragChanged` 首帧分支补 `hitTest == .none && taskID(at:) == nil` → `panDrag.begin`；后续帧 `panDrag.update` 有值即 dispatch；`onEnded` 收尾，`Escape` 一并 `cancel`。
- 复用现有 `.panWindow` 动作（含退出 fit、整天归一），**命令层与 Store 零改动**。

## 4. 测试计划

| 层 | 用例 | 归宿 |
|---|---|---|
| 纯函数 | 亚日余量累积（0.5+0.5 才出 1 天）、负向、跨多天、`dayWidth=0` 兜底、`reset` | KairoPresentationTests（GanttPanningTests） |
| 状态机 | 拖拽方向与取整、同天数抑制、`end/cancel` 后失活、锚定期间外部快照变化不影响结果 | AppTests（PanDragSessionTests） |
| Store | 平移退出 fit、保留 customDayWidth、连续平移累积正确 | AppTests |
| 回归 | A7 黄金基线不变（无平移时布局逐位一致）；全量绿 | 既有套件 |

## 5. 风险

| # | 风险 | 预案 |
|---|---|---|
| R1 | 坐标空间不一致导致命中矩形偏移（滚动画布内却判成画布外） | 先按窗口内容坐标翻转实现，真机手测校正；命中判定独立成纯函数便于调参 |
| R2 | 横向滚动事件被纵向容器吞掉 / 反之 | 仅横向占优或 Shift 时消费并返回 nil，其余放行 |
| R3 | 高频滚动触发快照重算（1000 任务重布局约 60ms） | 整天累积本身就是节流（日宽 5–32pt ⇒ 每 5–32pt 才一次）；必要时后续加 100ms 节流 |
| R4 | 触摸板惯性与整天吸附叠加产生「滑过头」 | 整天吸附为契约；惯性事件自然累积，不做额外衰减 |
