# 10 多基线叠加：甘特图同屏可见、按颜色区分（v0.14）

> 状态：设计稿（dev-architect）· 2026-10-25 · **取代** [09](09-baseline-version-plan.md) §3 原「单基线灰条」方案（用户否决）
> 上游：[08-baselines.md](08-baselines.md)（数据模型与偏差口径，v0.13.x 已实现）；调研：[omniplan-baseline.md](../research/omniplan-baseline.md)
> 前置硬约束：行高 28pt 不变、`GanttBar.x/width` 语义不变（A7 黄金布局）、基线绝不回流排期引擎。

## 1. 需求与方案定位

用户原话（需求源）：「基线首先在菜单里面要有地方创建基线，而且可以创建很多个。创建基线的时候，甘特图下面会多一条基线同时显示在同一行，这样可以看到某个任务跟当前实际状态的差距。可以直接参考 OmniPlan。多基线的意义：保守基线、激进基线、以及实际适中的基线。基线可以创建很多个，在甘特图上显示时需要用不同颜色表示。」

可验收的三条：① 创建入口在菜单里显眼（历史坑：只藏在工具栏溢出菜单 → 找不到，D-035）；② 多条基线同时画在同一任务行内，与计划条上下并列、颜色区分；③ 基线数量不设上限，同屏上限 3 条（保守 / 基准 / 激进），超出在菜单提示。

与 OmniPlan 的**有意差异**：OmniPlan「双日程」是**一条**灰色全高条被实际条压住、「分割」是同行上下各半；Kairo 要在 28pt 内表达 **1–3 条**，故不用叠加遮挡，改用**行内分轨（lane stack）**：计划条占上轨，每条基线各占一条下轨，互不遮挡、颜色独立。

## 2. 视觉方案

28pt = 上边距 3 + 计划轨 + 轨间间隙 + N 条等高基线轨（轨间同间隙）+ 下边距 3。**n ≥ 1 时轨道末端恒为 25pt**；n = 0 保持现状（计划条 14pt @ y=7，末端 21pt）—— 这是 A7 逐像素保命的硬条件，不要为了「统一 25」去动无基线的行。

```
 N=0（现状，逐像素一致）        N=3
 ┌──────────────┐ 0          ┌──────────────┐ 0
 │  ████████ 14 │ 7          │ ███ 计划 7pt │ 3
 │              │            │ ▂▂▂ 基线① 青 │ 11
 │              │            │ ▂▂▂ 基线② 珀 │ 16
 └──────────────┘ 28         │ ▂▂▂ 基线③ 绿 │ 21
                             └──────────────┘ 28
```

- 基线恒在计划条**下方**（对齐用户「甘特图下面会多一条基线」）；轨道自上而下 = 显示顺序（创建顺序），不随勾选重排。
- N=0 完全走既有渲染：计划条 14pt 居中（y=7）、群组条 10pt（y=9）、里程碑菱形 10pt（中心 y=14）。
- 基线轨**只画实心细条**：无进度填充、无标签、不参与命中与拖拽（基线不可变）；里程碑基线画同轨高菱形。
- 基线细条与计划条**同 x 换算**，直接呈现「这条承诺比现在早 3 天开始」的水平位移。

## 3. 几何（纯函数，不靠目测）

```swift
// Sources/KairoPresentation/BaselineLanes.swift（新）
public struct BaselinePlanLane: Hashable, Sendable { public var top: Double; public var height: Double }
public struct BaselineLaneLayout: Hashable, Sendable {
    public var plan: BaselinePlanLane
    public var baselineHeight: Double
    public var baselineTops: [Double]        // 升序，下标即 lane
}
public enum BaselineLanes {
    public static let maxVisible = 3         // 显示上限唯一来源（App 菜单也读它）
    public static func layout(visibleCount n: Int) -> BaselineLaneLayout                 // n 夹取到 0…3
    public static func planBarFrame(kind: GanttBar.Kind, layout: BaselineLaneLayout) -> (top: Double, height: Double)
    public static func milestoneFrame(layout: BaselineLaneLayout) -> (centerY: Double, side: Double)
}
```

| n | 计划轨 top | 计划轨高 | 轨间隙 | 基线轨高 | 基线轨 top（i=0,1,2） | 末端 |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | 7 | 14 | — | — | — | 21 |
| 1 | 3 | 14 | 2 | 6 | 19 | 25 |
| 2 | 3 | 9 | 1.5 | 5 | 13.5 / 20 | 25 |
| 3 | 3 | 7 | 1 | 4 | 11 / 16 / 21 | 25 |

`baselineTop(i) = plan.top + plan.height + gap + i × (baselineHeight + gap)`；`planBarFrame` 在轨内居中且高 = `min(轨高, kindHeight)`；`milestoneFrame.side = min(10, 轨高)`。

水平换算**不得写第二份**（D-024）：把 `GanttLayoutEngine.make` 里内联的 `(start − windowStart)/86400 × dayWidth` 抽成公开纯函数，计划条与基线共用。

```swift
// Sources/KairoCore/Query/GanttLayout.swift（改）：x(for:windowStart:dayWidth:) 与 width(from:to:dayWidth:)
```

## 4. 颜色与图例

- 调色板 **8 色，索引 0…7**，存 `Baseline.colorIndex`；快照只带索引，颜色值在 `DesignTokens.baselinePalette[8]`（ADR-013：快照零颜色值）。
- **分配规则（纯函数）**：创建时取**当前未被占用的最小索引**（0→7 循环）；已分配索引**永不因其他基线增删而改变**，故删中间某条后新建不会撞色。
- 旧文件缺 `colorIndex`：按数组（创建）顺序贪心分配最小未用索引；**只在写路径补齐**（创建 / 改名 / 改色 / 删除前先 `ensureBaselineColors()`），打开只读不落盘、不置脏。补齐后再删 → 其余颜色不动。
- 深色 / 高对比由 DesignTokens 双档解析，索引语义不变。
- **图例不进画布**（不侵占 28pt 行与表头）：图例 = 状态栏色点 + 名称（最多 3 项，超出「+N」）+ 工具栏「基线」菜单 label 的色点组；悬停基线细条出提示（名称 + 承诺起止），提示不参与命中优先级。

| 索引 | 名 | light | dark | 备注 |
| --- | --- | --- | --- | --- |
| 0 | 青 | 0E7C7C | 4FC7C4 | 首条默认 |
| 1 | 琥珀 | A86800 | E3A63C | |
| 2 | 绿 | 2E7D46 | 5CC088 | |
| 3 | 品红 | 9C2A6B | DE7BA8 | |
| 4 | 橄榄 | 6B7A1F | A9B84E | |
| 5 | 藏青 | 1F4E8C | 74A0E0 | 与 `progressFill` 同色系，靠下轨 + 无填充 + 4–6pt 高区分（§12-5） |
| 6 | 棕 | 7A5433 | BE9066 | |
| 7 | 岩蓝 | 0F7089 | 4FB3CE | |

## 5. 菜单结构（创建置于最显眼处）

三处入口，**创建永远第 1 项且带快捷键**，不再存在「只藏在工具栏溢出菜单」的路径。

1. 菜单栏**顶级「基线」菜单**（新增 `KairoCommandGroup.baseline`，位于「视图」与「查找」之间）：

```
新建基线…                        ⌘⌥B   ← 第 1 项，任何状态都可用
────────────────────────
在甘特图中显示 ▸                      ← 多选：图上画哪些
    ☑ 保守基线 ●   ☑ 基准基线 ●   ☐ 激进基线 ●
    ─────────
    最多同时显示 3 条 / 另有 2 条未显示（N>0 才出现；禁用说明项）
────────────────────────
对比基线 ▸                            ← 单选：驱动大纲四列与检查器
    ☑ 基准基线     ☐ 不对比
────────────────────────
重命名「基准基线」…
颜色 ▸  仅作用于对比基线（8 色板，勾选当前色）
删除「基准基线」…                     ← 二次确认（08 §11）
────────────────────────
基线面板…                             ← 全部基线管理
```

2. 工具栏：单个 `Menu`，label =「基线」+ 可见基线色点（0–3 个），内容与上表同源；被系统收进溢出菜单时菜单栏 / ⌘K 仍可达。
3. ⌘K：`baseline.create`（显示 ⌘⌥B）、`baseline.manage`、`baseline.hideAll`、`baseline.compareClear` 为静态；另为每条基线动态生成「显示/隐藏 <名称>」「对比 <名称>」两条可搜索项。颜色项**不进** ⌘K（8 × N 会挤爆面板）。

文案分工（防混淆）：**「在甘特图中显示」= 多选画图**，**「对比基线」= 单选读数**；两处不共用「当前基线 / 选中基线」这类词。

## 6. 视图状态（两个概念，两套命名）

```swift
public struct WorkspaceViewState {
    /// 图上画哪些基线（多选，上限 BaselineLanes.maxVisible）；空集 = 不画（N=0）。
    public var visibleBaselineIDs: Set<UUID> = []
    /// 大纲四列 / 检查器读数对比的那一条（单选，v0.13 已有）；nil = 不比较。
    public var selectedBaselineID: UUID?
}
```

- 二者**互相独立**：可只对比不显示（只看数字），也可只显示不对比（只看图形）。
- 均为纯视图状态：不进撤销栈、不进 `.kairo`、不写基线快照；持久化到 UserDefaults。
- 读取侧归一化 `normalizedVisibleBaselineIDs(in:)`：剔除悬挂 ID（撤销到创建之前）、按创建顺序排序、**截断到前 3 条**（防旧偏好存了 4+）。
- 删除基线：删除成功后从两个集合剔除该 ID（展示卫生，不产生撤销点）。
- 创建基线：`selectedBaselineID` 设为新基线（沿用 v0.13）；若 `visibleBaselineIDs` 未满 3 则自动加入显示，**已满 3 不替换、不插队**，仅提示「已显示 3 条，新基线未在甘特图中显示」（§12-2）。

## 7. 数据结构（加法，不升 formatVersion）

```swift
// KairoCore/Model/Baseline.swift
public struct Baseline { /* 既有字段不变 */ 
    /// 调色板索引 0…7（v0.14 可选字段）。nil = 旧文件，读时派生，写路径补齐。
    public var colorIndex: Int?
}
// KairoCore/Model/BaselinePalette.swift（新，纯函数，无颜色值）
public enum BaselinePalette {
    public static let count = 8
    public static func resolve(_ indices: [Int?]) -> [Int]      // nil / 越界 / 重复 → 最小未用
    public static func nextIndex(used: Set<Int>) -> Int
}
// KairoCommands/KairoSession.swift
@discardableResult public func setBaselineColor(id: UUID, colorIndex: Int) throws -> Baseline   // 进撤销栈
// 内部：创建 / 改名 / 改色 / 删除四条写路径入口处先 ensureBaselineColors()

// KairoPresentation/Snapshots.swift
public struct GanttBaselineBar: Identifiable, Hashable, Sendable {
    public var id: String { "\(baselineID)-\(taskID)" }
    public var baselineID: UUID; public var taskID: UUID; public var rowIndex: Int
    public var lane: Int            // 0…n-1，0 最靠上（= 显示顺序）
    public var x: Double; public var width: Double
    public var colorIndex: Int      // 0…7
    public var isMilestone: Bool
}
public struct BaselineLegendItem: Identifiable, Hashable, Sendable {
    public var id: UUID { baselineID }
    public var baselineID: UUID; public var name: String; public var colorIndex: Int; public var lane: Int
}
public struct GanttSnapshot {
    // 既有字段不变
    public var baselineBars: [GanttBaselineBar] = []       // 仅可见行 × 可见基线（≤ 行数 × 3）
    public var baselineLanes: BaselineLaneLayout? = nil    // nil = N=0（走既有渲染）
    public var baselineLegend: [BaselineLegendItem] = []
    public var hiddenBaselineCount: Int = 0
}
```

- **`GanttBar` 一个字都不改**：基线走独立结构 + 独立图层，行索引仍与大纲一致（ADR-013）。
- 基线条**不依赖 `BaselineVarianceReport`**（那是大纲 / 检查器通道）：直接读 `state.baselines[].entries`，避免为画图多算偏差、也避免 3 条基线逼出 3 份报告。`selectedBaselineID` 的缓存口径不变。
- 只为 `rowIndexByID` 中存在的行生成基线条（收起 / 被筛选行天然不生成）。

## 8. 降级与空态

| 情形 | 表现 |
| --- | --- |
| 无任何基线 / 有基线但一条都没勾 / 全部任务无条目 | N=0，逐像素即现状；菜单「在甘特图中显示」下出禁用项「尚未创建基线」；不出现空轨、不留白 |
| 任务无该基线条目（基线后新增 / 未排期） | 该行只画计划条，该轨留空；**不插行、不额外生成行、不报错** |
| 已创建 > 3 条 | 图上最多 3 条；菜单提示「另有 N 条未显示」 |
| 悬挂 UUID（撤销到创建之前） | 读取侧归一化剔除，不报错、不改写 viewState |
| `colorIndex` 缺失 / 越界 / 重复 | `BaselinePalette.resolve` 派生稳定值，不崩、不闪色 |

## 9. 性能与虚拟化

- 规模：1,000 可见行 × 3 基线 = 3,000 条 `GanttBaselineBar`；构造 `O(可见行 × 可见基线)` 字典查表，无二次复杂度路径。
- 绘制沿用 `drawBars` 的**行窗口裁剪**（`firstRow…lastRow`），只画视口内约 40 行；基线图层同样按 `rowIndex` 分组后取行，不遍历全量。
- 阈值（tester 实测记入 CHANGELOG）：快照构造 P50 < 100 ms（debug，1000 行 × 3 基线）；滚动单帧 CPU < 16 ms。

## 10. 判据清单

1. **A7 黄金不变**：`DayWidthTests` / `DayWidthAcceptanceTests` **一行不改**全绿；`layout(visibleCount: 0)` 的 `planBarFrame` / `milestoneFrame` 与既有硬编码（14pt@7、10pt@9、菱形 10pt 中心 14）逐位相等。
2. **几何纯函数**：n=1/2/3 的 `plan.top`、`plan.height`、`baselineHeight`、`baselineTops` 与 §3 表逐项相等；**n ≥ 1 末端恒 25，n = 0 末端 21（现状）**；`baselineTops` 严格升序且不重叠。
3. **横向换算一致**：同一日期的基线条与计划条 `x/width` 相等（共用 `GanttLayoutEngine.x/width`）；跨 DST 无 ±1 天漂移。
4. **颜色稳定**：建 4 条（0,1,2,3）→ 删索引 1 → 剩余仍为 0,2,3；再新建得 1（最小未用），不串色。
5. **旧文件补色**：全缺 → resolve 得 0,1,2；含重复值 → 取最小未用；补齐后删一条，其余颜色不变。
6. **上限降级**：已显示 3 条时勾第 4 条被拒、`visibleBaselineIDs` 不变并提示；含 5 个 ID 的旧偏好截断为 3（按创建顺序）。
7. **空态**：`baselineLanes == nil`、`baselineBars` 为空、几何与 N=0 一致；菜单出现「尚未创建基线」禁用项。
8. **无条目不占位**：基线后新增任务行不产生基线条、行数不变，大纲与画布行索引逐一对应。
9. **命中门禁**：基线轨内按下拖动**不**产生 `.body/.handle`（`GanttHitTesting` 传 plan lane 后落在基线轨 → `.none`）；N=0 时既有命中用例全绿。
10. **1000 行 × 3 基线不掉帧**：构造与绘制阈值见 §9，实测记入 CHANGELOG。
11. **零回流**：显示开关不改 `bars`、不改 `ScheduleResult`、不产生撤销点、不置脏、不写 `.kairo`。
12. **菜单可达性**：「新建基线…」在菜单栏顶级菜单第 1 项、工具栏菜单第 1 项、⌘K 搜索三处均命中（注册表断言，不靠肉眼）。
13. **改色可撤销**：`setBaselineColor` 一次编辑 = 一步撤销；撤销后 `colorIndex` 回退，其余基线颜色不变。

## 11. 非目标

- 行高动态增长；「分割日程」「仅基线」两档视图模式、基线间对比（A vs B）、CSV 导出（均 v0.15 候选）。
- 基线细条的拖拽 / 编辑（基线不可变，永久非目标）；基线条进度填充、条内标签、关键路径着色。
- 图例常驻画布（侵占 28pt 行与表头）；颜色自定义取色器（只有 8 色索引）。

## 12. 需用户确认

1. **行内分轨 vs 底部细轨**：分轨在 n=2/3 时计划条从 14pt 缩到 9/7pt；备选「底部细轨」计划条零位移，但 3 条基线各只有 1.7pt（颜色可辨、形状不可辨）。推荐分轨。
2. **创建第 4 条时**：推荐「不替换、只提示」（可预测）；备选「顶掉最早显示的一条」（自动刷新视图）。
3. **「不占位」口径**：本设计 = 「不插行、不额外生成行」，全图统一按 N 分轨（无条目的行留空轨）。备选「逐行自适应」会让计划条高度逐行不同，已否决，仅作记录。
4. **撤销语义**：删除基线后撤销恢复基线，但 `visibleBaselineIDs` / `selectedBaselineID` 不随之恢复（与 v0.13「视图状态不进撤销栈」一致）。
5. **调色板 5（藏青）与 `progressFill` 同色系**：接受该风险，或换深靛 `4B3F9E`。

## 11. 裁定（2026-10-25，lead 代行，用户可推翻）

架构列的 5 项确认，按以下结论进入实现（若要改，改的是几何常量与文案，不影响结构）：

| 项 | 裁定 | 理由 |
| --- | --- | --- |
| 行内分轨 vs 底部细轨 | **行内分轨** | 3 条基线各 1.7pt 的底部细轨在 2× Retina 下只剩 3 物理像素，颜色无法辨认；分轨虽然把计划条压到 7pt，但四条轨都可读 |
| 创建第 4 条时 | **不替换、只提示**「另有 N 条未显示」 | 静默顶掉别人正在看的基线是最容易引发"数据消失"误解的行为 |
| 「不占位」口径 | **不插行、全图统一按 N 分轨**（无条目行留空轨） | 逐行自适应会让计划条高度逐行不同，破坏行节奏与 A7 布局基准 |
| 撤销语义 | 删除后撤销恢复基线，但**显示/对比集合不恢复** | 视图状态不进撤销栈是 v0.13 既定契约，不为本条破例 |
| 调色板 5 与计划条进度色同系 | **换成深靛 #4B3F9E** | 基线色与"进行中"语义同色会造成误读 |
| 旧数据补色与新建的先后 | **createBaseline 先对既有基线 `ensureColors`，再给新基线分配** | 颜色与图例都按创建顺序排；若新建先占 0，等于把最新一条顶到图例首位、旧基线整体后移，且「只保存」与「保存前建过一条」会得到两套映射，不可解释 |

## 12. 命令面（v0.14 补充）

- CLI：`kairo baseline color <基线ID|唯一前缀> <0…7>`（文本回执「已改色：<名> 颜色索引：N」；非整数退出 2，越界退出 1 并给 `model_baseline_color_index_invalid`，未知/歧义 ID 退出 2）；`baseline list|create|variance` 的文本与 `--json` 均带 `colorIndex`（缺值按 `BaselinePalette.resolve` 派生，不写 0）。
- MCP：`baseline_set_color(baselineID, colorIndex)` 新增；`baseline_create|list|delete|variance` 返回体补 `colorIndex`；越界透传同一细码，非整数报 `mcp_wrong_type`。工具总数 20 → 21，`InterfaceTests` 的逐字等值清单已同步。
- 已知边界：绕过 `saveProject` 的自定义导出路径不补色，读取侧 `resolve` 兜底派生（不落盘）。
