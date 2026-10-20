# 调查报告：计划 tab 左侧 Outline 与右侧甘特图不对应

- 调查员：Vera（只读调查，未修改任何文件）
- 日期：2026-10-20
- 任务书：`.agent-runs/2026-10-20/task-001/brief-investigator.md`

---

## 一、现象复现路径推断

用户原话只有一句「左边的列表和右边的甘特图没有对应上」，未描述具体表现。基于代码推断最可能的复现路径：

1. 打开「计划」tab（`WorkspaceView.swift:136`，`WorkspaceMode.plan`），保证大纲与时间画布同时可见（`sizes.showsOutline && sizes.showsTimeline`）。
2. 任务行数较多（≥10 行）时，从上往下看：第 1、2 行的左侧行与右侧甘特条还能大致对齐，越往下偏移越大——**错位量随行号线性增长**，大约每行偏 1pt，到第 28 行附近整行错开一行的高度（行高 28pt）。
3. 表现为：左侧第 N 行的任务，其甘特条画在右侧第 N 行偏上/偏下的位置；且鼠标悬停/点击右侧某行甘特条，选中的任务高亮在左侧不完全是光标所指那一行（命中测试 `TimelineView.swift:134-139` 同样按 28pt 节距换算，与左侧实际节距不一致）。

## 二、数据流对照（两侧各自来源）

**结论：两侧数据完全同源，不是数据集/排序/过滤不一致的问题。**

| 环节 | 证据 |
|---|---|
| 快照唯一来源 | `Presenter.swift:200-250` 由同一棵 `tree.rows` 生成 `planRows`；`:252` 用同一数组建 `rowIndexByID`；`:262-269` 装入 `outline.rows`；`:271-282` 把 `rowIndexByID` 传给 `makeGantt` |
| 视图层共用 | `WorkspaceView.swift:284` `let rows = store.snapshot.outline.rows`；同一 `rows` 同时传给 `OutlineRowsList`（:322-327）与 `TimelineBody`（:334-340） |
| 排序/折叠/过滤 | 折叠与过滤在 `tree.rows` 生成前完成（Presenter 内统一裁剪），两侧无各自二次过滤；无独立排序分支 |
| 滚动联动 | 大纲与画布共用同一个纵向 `ScrollView`（`TimelineView.swift:5-8`、`WorkspaceView.swift:318-344`，ADR-013），不存在两侧独立滚动偏移 |
| 选中联动 | 键盘/查找路径 `WorkspaceView.swift:480-493`（`scrollTarget`）与 `WorkspaceStore.reveal`（`WorkspaceStore.swift:971`）；高亮两侧均按 `row.id == store.selection` 比对（`OutlineTable.swift:104`、`TimelineView.swift:211`），逻辑一致 |

甘特条的 `rowIndex` 也来自同一数组（`Presenter.swift:402-410`：`rowIndexByID[bar.taskID]`），条在画布上按 `rowIndex * rowHeight` 定位（`TimelineView.swift:298`），`rowHeight = 28` 与 `Presenter.swift:394`、`DesignTokens.rowHeight = 28`（`DesignTokens.swift:11`）一致。

**即：行集合、行顺序、行索引三侧完全一致。失配只能出在「像素几何」层。**

## 三、根因结论（文件:行号）

### 根因（高置信）：Outline 每行额外渲染一个 Divider，实际行节距 ≈29pt，而 Timeline 全部按 28pt 节距计算

- **证据 A（左侧多出高度）**：`Apps/macos/Sources/Workspace/Outline/OutlineTable.swift:17-28`
  ```swift
  LazyVStack(spacing: 0) {
      ForEach(rows) { row in
          OutlineRowView(...)
              .frame(height: DesignTokens.rowHeight)   // 28pt
              .id(row.id)
          Divider().opacity(0.35)                      // ← 每行后再挂一条分隔线（macOS 上厚约 1pt，占布局空间）
      }
  }
  ```
  `.opacity(0.35)` 只降透明度、不改变布局尺寸；`spacing: 0` 也不吸收它。因此左列实际行节距 ≈ 28 + 1 = **29pt**。全局未注册任何自定义 `Divider` 样式（已 grep 全部 `Divider(` 用法，无 thickness/环境覆盖）。

- **证据 B（右侧按 28pt 节距）**：`Apps/macos/Sources/Workspace/Timeline/TimelineView.swift`
  - `:99-101` 内容总高 `CGFloat(rows.count) * DesignTokens.rowHeight`
  - `:135` 命中换算 `Int((point.y + offset) / DesignTokens.rowHeight)`
  - `:173` `:209` `:298` 行分隔线/行高亮/任务条全部按 `row * 28 − offset` 定位
  - 依赖线路由在核心层同样按 28pt 节距计算（`GanttLayout.swift:348,406,422-426`，`Presenter.swift:394` 传 `rowHeight: 28`）

- **失配机制**：右侧行 N 的 y = N×28；左侧行 N 的实际 y ≈ N×29。偏移 = N pt，随行号**线性累积**：约第 28 行错开整整一行，第 56 行错开两行。首行几乎无感，越往下越明显——与「没对应上」的模糊描述吻合，且解释了为何此前未在测试中暴露（无任何对齐断言）。

- **附带症状（同一根因）**：
  - 画布 `contentHeight = rows.count × 28`（`TimelineView.swift:100`）小于左列实际总高（≈rows.count×29），滚到底时画布下方留白。
  - 画布点击/悬停命中（`TimelineView.swift:134-139`）按 28pt 换算出的行号，与左侧光标所在行错位，选中后左侧高亮行看起来「指错了」。

- **触发条件**：任务数 ≥ 约 5 行即可感知，行数越多越严重；与缩放档位、折叠、过滤、选中状态无关。

### 次要候选（已排查、排除或低优先）

| 候选 | 结论 |
|---|---|
| 两侧数据集/排序/过滤不一致 | 排除：同一 `rows` 数组直传两侧（见第二节） |
| 滚动联动缺失/漂移 | 排除为主因：共用同一 ScrollView，画布经 `GeometryReader` 读偏移并 `offset(y:)` 贴合视口（`TimelineView.swift:107-116`），机制自洽 |
| 选中滚动不同步 | 部分成立但属体验项：画布点击只 `select` 不触发滚动（`TimelineView.swift:125-128`），`scrollTo` 仅键盘/查找路径（`WorkspaceView.swift:350-356`）。但两侧本就同容器，非「对应不上」的主因 |
| GanttLayout 窗口/缩放导致条错列 | 与纵向对齐无关，横向坐标独立于本问题 |

## 四、修复建议方向（供队长决策，未拍板）

1. **方案 A（推荐，改动最小）**：去掉左列行间距的额外高度来源——把 `OutlineTable.swift:27` 的 `Divider()` 改为不占布局空间的画法，如 `Rectangle().frame(height: 1).opacity(0.35)` 叠进 28pt 行内（overlay 底边），或直接删除分隔线改用行底色。左列节距回到 28pt，右侧零改动。
2. **方案 B**：左列保留分隔线，右侧行节距改为「28 + divider 实测厚度」。需要拿到 Divider 精确厚度（平台/缩放相关，脆弱），且 `GanttLayout` 的 `rowHeight: 28`（`Presenter.swift:394`）与全部命中换算都要联动改，改动面大、易再引入漂移。不推荐。
3. **方案 C（加固）**：无论选 A/B，补一条 GUI 断言/布局测试：渲染 N 行后，断言 `OutlineRowsList` 实测总高 == `rows.count * DesignTokens.rowHeight` == `TimelineBody.contentHeight`，防止回归。现 `GUIRenderTests.swift` 无任何对齐断言（已 grep 确认）。

## 五、遗留问题

- Divider 在目标机上的实际厚度未用真机测量（源码与常识判断约 1pt；Retina 2x 下可能为 0.5pt，会减慢但不会消除累积漂移）。实现者修复时可用方案 A 一并消除该不确定性。
- 用户未描述具体失配表现，建议实现前与用户确认「越往下错得越多」是否与实际现象一致，以闭环验证根因。
