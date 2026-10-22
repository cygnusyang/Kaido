# Sprint 11 设计稿 —— F-14-20 大纲列宽可调 + 列显隐可配置

> 2026-10-22 · 状态：待评审
> 用户需求：① 任务栏（大纲）列宽无法调节，信息显示不全，需要能调宽；② 序号（#）与任务说明固定显示，其余列可选择显示/隐藏。
> 发版目标：v0.8.0。

## 1. 现状

- 列集合：`OutlineColumn.visibleColumns(outlineWidth:)` 按阈值降级（Snapshots.swift:36-50）；视图另有一份计算（WorkspaceView.swift:336-340），Presenter 也各算一份（Presenter.swift:264-267）——**三处口径**。
- 列宽：`OutlineColumnLayout`（OutlineTable.swift:37-57）非标题列按 `scale = clamp(totalWidth/600, 0.6, 1)` 压缩，`title` 吃余量（下限 120）；全部派生，**无用户状态、不落盘**。
- 表头：一排只读 `Text`（OutlineTable.swift:59-92），无手柄、无 hover、无光标反馈。
- 偏好：`StoredPreferences` 逐字段容错解码（D-016）；`WorkspaceViewState` 无列相关字段。

## 2. 交互规格

| 能力 | 规格 |
|---|---|
| 列宽拖拽 | 表头每列右缘 6pt 热区，拖动改该列宽度；hover 显示左右调整光标 + 1px 高亮 |
| 即时预览 | 拖动中只改视图草稿（标题列同步让位），**松手才提交一次**（避免每个 onChanged 落盘） |
| 复位 | 双击列右缘手柄 → 该列宽度回落默认（删除覆盖值） |
| 宽度范围 | 状态/违例 18–60；序号 24–80；其余 40–320（`OutlineColumnPreferences.widthRange`，区间必须包住各自默认宽） |
| 弹性列 | `title` 不参与拖拽（继续吃余量，最小 120）；要看全任务说明请拉宽大纲整体 |
| 列显隐 | 视图菜单 8 项「显示/隐藏…列」+ 大纲表头右键菜单勾选；**序号 `#`、任务说明永远显示**，不出现在开关列表 |
| 优先级 | 阈值降级（物理放不下）优先；用户隐藏只能进一步收窄；聚焦模式忽略用户配置（固定 `status/violation/title`） |
| 用户宽度 | 覆盖值**不再乘压缩系数**（否则拖宽无效）；总宽超出时由 title 下限兜底、右侧自然裁切（提示：拉宽大纲或隐藏列） |

## 3. 架构

### 3.1 策略（KairoPresentation 新文件 `OutlineColumnPreferences.swift`，纯函数可测）

```swift
public enum OutlineColumnPreferences {
    public static let alwaysVisible: Set<OutlineColumn> = [.number, .title]
    public static var configurable: [OutlineColumn] { ... }        // allCases - alwaysVisible
    public static func isResizable(_ column: OutlineColumn) -> Bool // title 之外均可
    public static func widthRange(for column: OutlineColumn) -> ClosedRange<Double>
    public static func defaultWidth(for column: OutlineColumn) -> Double
    public static func visibleColumns(outlineWidth: Double, hidden: Set<OutlineColumn>, focused: Bool) -> [OutlineColumn]
}
```

- `visibleColumns`：`focused` → `[.status, .violation, .title]`（忽略 hidden）；否则取 `OutlineColumn.visibleColumns(outlineWidth:)` 再减去 `hidden - alwaysVisible`。
- 视图与 Presenter 统一调用该函数，消除列集合双源。

### 3.2 状态与持久化

- `WorkspaceViewState` 新增：
  - `outlineColumnWidths: [String: Double]`（键 `OutlineColumn.rawValue`，值 = 用户设定点宽）
  - `hiddenOutlineColumns: Set<String>`
- `StoredPreferences` 同步两字段（`[String: Double]?` / `[String]?`），沿用逐字段 `(try? decodeIfPresent) ?? 默认`；载入时过滤未知 rawValue 与越界宽度。
- 新增动作：
  - `.setOutlineColumnWidth(OutlineColumn, Double?)`（nil = 复位；内部按 `widthRange` 夹取）
  - `.toggleOutlineColumn(OutlineColumn)`（`alwaysVisible` 直接拒绝）
  - **撤销口径（评审修正）**：列宽与显隐都是应用级视图偏好，**均不产生撤销点**（与 `.setOutlineWidth` 一致）。撤销栈只存项目快照，记一步「空撤销」只会清空 redo 且无法真正回滚列宽。
  - 动作层拒绝不可拖拽的列（`.title` 弹性列），避免持久化永不生效的死状态。

### 3.3 视图

- `OutlineColumnLayout` 增加 `widthOverrides: [OutlineColumn: Double]` 与 `liveResize: (OutlineColumn, CGFloat)?`；
  `width(of:)` 顺序：live → override（不压缩）→ 默认（乘 scale）。无覆盖值时逐位等于现状（既有断言不变）。
- `WorkspaceView` 持有 `@State liveColumnResize`（跨行/表头共享，保证表头与行同步预览）；`planArea` 用它构造 layout。
- `OutlineHeaderView` 增加 `onResizeChanged: (OutlineColumn, CGFloat) -> Void`、`onResizeEnded: () -> Void`、`onResizeReset: (OutlineColumn) -> Void`；
  每个可调列右缘 `Rectangle().frame(width: 6).contentShape(...).onHover{NSCursor}` + `highPriorityGesture(DragGesture(minimumDistance: 1))`。
- 表头 `.contextMenu`：`Toggle` 绑定 `hiddenOutlineColumns`（逐列，序号/任务说明不出现）。
- 命令注册表「视图」组追加 8 条 `view.outlineColumn.<raw>`（标题「显示/隐藏X列」），与右键菜单同源动作。

## 4. 测试计划

| 层 | 用例 |
|---|---|
| 策略 | alwaysVisible 锁定（隐藏 number/title 无效）；configurable 不含固定列；focused 忽略 hidden；阈值降级优先；宽度范围/默认宽 |
| 布局 | 无覆盖值 = 现状逐位；覆盖值不压缩；title 吃余量且 ≥120；live 草稿优先于 override |
| Store | set/clamp/reset/toggle（固定列拒绝）；偏好持久化往返；损坏字段逐字段容错 |
| 既有回归 | `outlineColumnsScaleWithWidth`、`outlineColumnsDegradeWithWidth`、`OutlineAlignmentTests` 行高不变 |

## 5. 风险

| # | 风险 | 预案 |
|---|---|---|
| R1 | 拖动每帧落盘卡顿 | 拖动只改本地草稿，松手一次提交 |
| R2 | 表头手柄与大纲右边界手柄几何重合 | 列手柄只在表头、宽 6pt；边界手柄保持行区与表头整列，右端列手柄向内缩进 |
| R3 | 用户宽度导致横向溢出 | title 下限 120 兜底；文档提示拉宽大纲或隐藏列 |
| R4 | 隐藏列后用户找不到恢复入口 | 视图菜单 + 表头右键菜单双入口 |
