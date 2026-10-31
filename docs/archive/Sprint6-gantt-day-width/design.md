# Sprint 6 / T1 设计：甘特图时间轴「日宽可自定义」

- 文档状态：待 lead 评审（其中 4 项标记为需人类确认，见 §9）
- 作者：架构（Max）
- 日期：2026-10-20
- 基线输入：用户需求「甘特图每天的间隔在 UI 上要可以变，宽度用户可以自定义；每一天、每一周都一样，宽度要调整时每天都变宽」+ lead 裁定（单一标量日宽、禁止按天/按周分叉）

---

## 0. 结论先行（TL;DR）

**核心结论：核心布局引擎零改动，需求在呈现层与应用层闭环。**

1. `GanttLayoutEngine.make` 已经用**单一标量 `dayWidth`** 计算全部条体 / 刻度 / 非工作带 / 今天线的 x 坐标，等比性在核心层**天然成立**；`dayWidthOverride: Double?` 这个覆盖口已经存在。因此**不改 `Sources/ZenoCore/Query/GanttLayout.swift` 一行**（硬门禁 A7「逐位一致」结构性成立）。
2. 状态表达采用**绝对日宽覆盖**：`WorkspaceViewState.customDayWidth: Double?`（nil = 未启用）。不采用「档位 × 缩放系数」。
3. 夹取区间 **[2.0, 120.0] 点/天**，NaN/±∞ 有确定回落；夹取**只作用于自定义路径**，不触碰 fit 路径（保住 A7）。
4. 刻度粒度**由日宽推导**（≥18 → 逐日；≥6 → 逐周；否则逐月），这是解决「日宽变小 → 标签重叠 / 绘制量爆炸」的关键；推导只决定**刻度集合**，不改变日界等距性。
5. UI 采用**「工具栏弹出面板内 Slider（连续，主）+ 菜单内步进（兜底）+ ⌘+/⌘−/⌘0 快捷键（辅）」**组合。SwiftUI `Menu` 内**不能**放 Slider（菜单项模型 + 点击即关），必须用 `Button + .popover` 承载。
6. 持久化：`StoredPreferences` 新增**可选**字段 `customDayWidth`，旧数据缺省回落档位默认（A8）。
7. 需 lead 确认：日宽区间与阈值数值、偏好 JSON 格式扩展、`GanttSnapshot.zoom` 语义重定义、ui-redesign 规格改写。

---

## 1. 需求基线与硬约束

| # | 约束 | 本设计的兑现方式 |
|---|---|---|
| C1 | 单一标量日宽驱动全轴，禁止按天/按周分叉宽度 | 核心层本来就是单标量（`GanttLayout.swift:171` `let dayWidth = max(dayWidthOverride ?? zoom.dayWidth, 0.5)`），全轴 x 都是 `offsetDays × dayWidth`；本设计不引入任何按天/按周的宽度分支 |
| C2 | 未启用自定义时布局输出与现状**逐位一致**（414 用例全绿） | 自定义值落在**呈现层**（`ZenoPresentation`）解析；`customDayWidth == nil` 时传给核心的参数与今天**完全相同**；核心文件零 diff |
| C3 | `ZenoPresentation` 平台中立（禁 SwiftUI/AppKit/Combine） | 新增的 `GanttScale` 放 `ZenoCore`（纯 Foundation）；`ZenoPresentation` 只加纯值字段与纯函数 |
| C4 | 不引入新第三方依赖 | 全部用 Foundation / SwiftUI / Swift Testing |
| C5 | 不破坏 D-006 纵向对齐（行节距 28pt，画布高 = 行数 × 28） | 本设计不触碰 `rowHeight` 与行数→高度的换算；`TimelineBody.contentHeight` 保持 `rows.count × DesignTokens.rowHeight` |

**lead 裁定的补充基线**：日/周/月三档保留为「预设」（一键回默认宽度），自定义值与之互斥可切换 → 状态上表现为 `zoom`（预设）与 `customDayWidth`（自定义）两个字段，运行时互斥（§D3）。

---

## 2. 现状核验与关键洞察

### 2.1 核心层已经具备的能力（已核实，无需重复调研）

`Sources/ZenoCore/Query/GanttLayout.swift`：

- `make(..., dayWidthOverride: Double? = nil, ...)` **已存在**覆盖口（第 164 行）。
- 第 171 行：`let dayWidth = max(dayWidthOverride ?? zoom.dayWidth, 0.5)` —— 全轴唯一日宽标量。
- 条体 x：`start.timeIntervalSince(windowStart) / 86_400 * dayWidth`（第 190 行）→ 天数 × 日宽。
- 刻度 x：`offset * dayWidth`（第 244 行）→ 天数 × 日宽。
- 非工作带：`Band(x: x, width: dayWidth)`（第 248 行）→ 带宽恒等于日宽。
- 今天线：`day.timeIntervalSince(windowStart) / 86_400 * dayWidth`（第 298 行）。
- `fitDayWidth(contentRange:viewWidth:calendar:)` 计算 fit 日宽（第 481 行）。

**结论**：等比性（每一天等宽、每一周等宽、跨月跨年一致）在核心层**已经天然成立**。本需求不是"改造布局"，而是"把一个已有的单一标量暴露给用户"。

### 2.2 `zoom` 的双重身份（本设计必须处理的核心结构问题）

`GanttZoom` 当前同时承担两个职责：

1. **默认日宽**（32 / 12 / 5）；
2. **刻度粒度 + 非工作带可见性**（`switch zoom` 第 221–289 行：`.day` 逐日下层刻度；`.week` 每周下层刻度；`.month` 逐月下层刻度且**隐藏非工作带**）。

一旦引入"用户自定义日宽"，职责 1 与职责 2 就**解耦**了：日宽可以是 24（介于日档 32 与周档 12 之间），此时刻度该按天还是按周？若仍按 `zoom` 预设走，则：

- 自定义 40pt + 「周」预设 → 每周 280pt 宽却只标一个「M/D」→ 视觉荒谬；
- 自定义 2pt + 「日」预设 → 逐日标签 380+ 个，标签重叠 + 绘制量爆炸 → **直接违反 A5**。

**裁决**：刻度粒度必须由**实际日宽**推导，而不是由预设档位决定。为保住 A7（逐位一致），推导**只在新模式（自定义）生效**；预设模式与 fit 模式沿用今天的 `zoom` 语义，一字不改。

### 2.3 不改核心的可行性验证

`GanttLayoutEngine.make` 的 `zoom` 参数**只影响刻度粒度与带可见性**，日宽由 `dayWidthOverride` 独立决定。因此呈现层只要这样调用：

```
zoom: 有效刻度档位（自定义时 = 由日宽推导；否则 = 用户预设）
dayWidthOverride: 有效日宽（自定义时 = 用户值；fit 时 = fit 值；否则 = nil）
```

即可得到「自定义日宽 + 自适应刻度粒度」，**核心零改动**。这是本设计最重要的架构结论，直接决定了改动面可以压到 9 个源文件 + 3 个测试文件。

---

## 3. 逐条决策

### D1 状态表达与动作签名

#### 备选方案对比

| 方案 | 表达 | 等比性 | 与核心 `dayWidthOverride` 映射 | 与 fit 共存 | 状态栏可读性 | 评价 |
|---|---|---|---|---|---|---|
| **A（选中）绝对日宽覆盖** `customDayWidth: Double?` | 12.0 = 12 点/天 | 天然（单标量） | 一一对应（`Double?` → `Double?`） | 互斥判定简单（nil vs 非 nil） | 直接显示「12 点/天」 | ✅ |
| B 档位 + 缩放系数 `zoomScale: Double?` | 系数 2.0 相对「日」档 | 天然 | 需在呈现层做乘法再传 | fit 是绝对量，与系数模型语义冲突 | 用户看到的是系数不是宽度 | ❌ 心智模型错位 |
| C 档位 + 绝对宽并存（`zoom` + `dayWidth`） | 两个真相源 | 天然 | 直接传 | 需额外仲裁 | 需额外仲裁 | ❌ 状态歧义 |
| D 给 `GanttZoom` 加 `case custom` | 枚举扩 case | 天然 | 需分支判断 | 需分支判断 | 需额外字段存宽度 | ❌ 破坏 `GanttZoom` 的「预设」语义与既有持久化解码 |

**选择 A**，理由：

1. **与需求语义同构**：用户要的是「每一天占多少点」，绝对量；「每天都变宽、每天等宽」在数学上就是单一标量。系数模型是相对量，同一系数在不同档位下得到的实际宽度不同，用户无法预期。
2. **与核心零阻抗**：`Double?` → `Double?` 直通，核心零改动（§2.3）。
3. **与 fit 天然互斥**：`customDayWidth != nil` 与 `usesFitZoom == true` 是两个正交布尔/可选项，互斥判定只需一处。
4. **状态栏可直接呈现**：「周 · 12 点/天」里的 12 就是这个字段，不需要二次换算。

#### 确定的接口签名

```swift
// Sources/ZenoPresentation/ViewState.swift
public struct WorkspaceViewState: Hashable, Sendable {
    // ...既有字段不动...

    /// 自定义每日宽度（点/天）。
    /// 非 nil 时为**唯一权威日宽**，覆盖 `zoom.dayWidth`；与 `usesFitZoom` 互斥。
    /// 互斥由动作层（WorkspaceStore.dispatch）维护，呈现层再做一次防御（自定义优先）。
    /// 越界值在写入时即被 `GanttScale.clampDayWidth` 夹取，状态内不出现越界/NaN。
    public var customDayWidth: Double?

    public init(
        // ...既有参数不动...
        customDayWidth: Double? = nil
    ) { /* ... */ }
}
```

```swift
// Sources/ZenoPresentation/WorkspaceAction.swift
/// 设定自定义日宽（内部夹取到 GanttScale.dayWidthRange）；进入自定义模式并退出「适合项目」。
case setCustomDayWidth(Double)
/// 相对步进自定义日宽（基准 = 当前生效日宽；fit 模式下以 fit 宽度为基准）。
case nudgeCustomDayWidth(by: Double)
/// 清除自定义日宽，回落到当前档位默认宽度（fit 开启时回落到 fit 宽度）。
case clearCustomDayWidth()
```

**动作语义表**

| 动作 | `customDayWidth` | `usesFitZoom` | `zoom` | `windowStart` |
|---|---|---|---|---|
| `setCustomDayWidth(w)` | `= clamp(w)` | `= false` | 不变 | 不变 |
| `nudgeCustomDayWidth(δ)` | `= clamp(base + δ)`，`base = custom ?? 生效日宽` | `= false` | 不变 | 不变 |
| `clearCustomDayWidth()` | `= nil` | 不变 | 不变 | 不变 |
| `setZoom(z)`（既有） | `= nil` | `= false` | `= z` | 不变 |
| `setFitZoom(true)`（既有） | `= nil` | `= true` | 不变 | `= nil`（既有行为） |
| `setFitZoom(false)`（既有） | 不变 | `= false` | 不变 | 不变 |
| `panWindow(date)`（既有） | **不变** | `= false` | 不变 | `= date` |
| `goToToday()`（既有） | **不变** | `= false` | 不变 | `= today − 7d` |

---

### D2 夹取区间 `[minDayWidth, maxDayWidth]`

#### 备选方案对比

| 方案 | 区间 | 优点 | 缺点 |
|---|---|---|---|
| A（选中）`[2, 120]` | 2–120 点/天 | 下界：窗口天数 ≤ 画布宽/2，核心逐日循环有界；上界：6 天任务 ≈ 720pt，仍留任务名标签空间 | 极窄视图（1 点/天）不可达 |
| B `[0.5, 120]`（沿用核心下限） | 0.5–120 | 与核心 `max(dayWidth, 0.5)` 一致 | 0.5 时窗口天数 = 2×画布宽，4K 全屏 7680 天，单次布局循环 25–45ms；且与"逐位一致"的 fit 路径暴露重叠，回归面变大 |
| C `[4, 200]` | 4–200 | 宽视野更细腻 | 4 点/天下 5 天任务仅 20pt，条体不可读 |
| D 无上界 | `[2, ∞)` | 自由 | 200 点/天下单条 1 天任务即占满 1440 画布，违反 lead「最宽时单条任务占满画布」的顾虑 |

**选择 A：`[2.0, 120.0]`**，依据：

- **下界 2.0**：
  - 窗口天数 = `viewWidth / dayWidth`。画布最宽情形（4K 屏 3840pt、大纲与检查器全隐藏）→ 窗口天数 ≤ 1920；常规 1440pt → ≤ 720 天。
  - 核心逐日循环成本按 3–6 µs/天估（`Calendar.date(byAdding:)` + 3 次 `Calendar.component`）→ 1920 天 ≈ 6–12ms。
  - 对比：fit 路径当前的下限是 0.5 → 窗口天数 ≤ 2×画布宽（3840pt → 7680 天 ≈ 25–45ms）。**自定义路径严格优于既有 fit 路径的最坏情况**。
  - 2.0 点/天仍有实用价值：1440pt 画布可见 ≈ 2 年跨度，配合逐月刻度。
- **上界 120.0**：120 点/天时 6 天任务 = 720pt，在 1440pt 画布上占一半，仍留右侧任务名标签位（`drawLabel` 要求右侧 ≥ 60pt）；单日任务 120pt ≈ 11 个汉字宽，可读。超过 120 后单条 1 天任务即占满画布，命中 lead 的顾虑。
- **两个数值都是单一常量**（`GanttScale.dayWidthRange`），改一个数即可整体调整，不散落魔法数。

#### 夹取语义（含 NaN / ±∞）

```
clampDayWidth(v):
    v.isNaN        → min（2.0）      // A4：绝不产生 NaN
    v == +∞        → max（120.0）
    v == -∞        → min（2.0）
    v < min        → min
    v > max        → max
    否则           → v（不做四舍五入）
```

- **不做四舍五入**：`setCustomDayWidth(12.34)` 原样保存，测试可直接断言；四舍五入只发生在 UI 层（Slider 拖动时取 0.1 精度）。
- **夹取只作用于自定义路径**：`fitDayWidth` 的结果**不夹取**，否则 fit 的输出会变 → 破坏 A7。这条是硬约束。

---

### D3 互斥规则与重置

#### 规则表

| 触发 | `zoom`（预设） | `usesFitZoom` | `customDayWidth` | 生效日宽 | 生效刻度档位 |
|---|---|---|---|---|---|
| 启动（无偏好） | `.week` | `true` | `nil` | fit 值 | `zoom`（现状） |
| 选预设「日/周/月」 | 该预设 | `false` | `nil` | `zoom.dayWidth`（32/12/5） | `zoom`（现状） |
| 选「适合项目」 | 不变 | `true` | `nil` | fit 值 | `zoom`（现状） |
| 设定/步进自定义 | 不变 | `false` | `clamp(v)` | 自定义值 | **由日宽推导** |
| 清除自定义 | 不变 | 不变 | `nil` | `zoom.dayWidth` 或 fit 值 | `zoom`（现状） |
| 平移窗口 / 回到今天 | 不变 | `false` | **不变** | 不变 | 不变 |

#### 关键裁决与理由

1. **「手动调宽度自动退出 fit」→ 是。**
   `setCustomDayWidth` / `nudgeCustomDayWidth` 显式置 `usesFitZoom = false`（A3 上半句）。
2. **「重新开启 fit 恢复 fit 宽度并清空自定义」→ 是。**
   `setFitZoom(true)` 清空 `customDayWidth`（A3 下半句）。
3. **预设与自定义互斥（"最后写入者胜"）。**
   选预设 → 清自定义；调自定义 → 清 fit。规则单一、无分支歧义，用户心智 = "我刚做的操作生效"。
4. **`panWindow` / `goToToday` 不清自定义。**
   理由：平移是**正交**于缩放的操作；用户的"我想要这个宽度"不应因为看一眼别的时间段而丢失。若平移清掉自定义，"连续可调"的手感会被反复打断。既有 `usesFitZoom = false` 的行为**保持不变**（今天平移就会退出 fit）。
   ⚠️ 这是对既有交互语义的**扩展**（今天不存在 `customDayWidth`），不构成逐位一致风险。
5. **呈现层二次防御**：即便状态里同时出现 `usesFitZoom == true` 与 `customDayWidth != nil`（例如从外部构造的状态、偏好文件被手改），**自定义优先**：呈现层按自定义解析，fit 被忽略，快照 `usesFitZoom` 报 `false`。保证"单一真相源"在任何路径下都成立。
6. **偏好载入时归一化**：若偏好文件同时含 `usesFitZoom = true` 与 `customDayWidth`，载入时以**自定义优先**，强制 `usesFitZoom = false`（与运行时规则一致）。

---

### D4 UI 交互方案

#### 备选方案对比

| 方案 | 连续可调 | 精确设定 | 无鼠标可用 | 实现风险 | 评价 |
|---|---|---|---|---|---|
| O1 缩放菜单内「更宽/更窄」步进按钮 | ✗（菜单点击即关，每次只能一档） | ✓（步进固定值） | ✓ | 低 | 作为**兜底/无鼠标路径**保留 |
| **O2 工具栏弹出面板内 Slider** | **✓** | **✓** | ✗ | 中（工具栏 popover 在 macOS 上的呈现需实测） | **主方案** |
| O3 键盘快捷键 ⌘+/⌘−/⌘0 | ✗（离散） | ✓ | ✓ | 低 | 作为**辅方案**（高频微调最快） |
| O4 表头直接拖拽 / ⌘+滚轮改日宽 | ✓（最佳手感） | ✗ | ✗ | 高（与既有平移拖拽手势冲突；SwiftUI 无滚轮修饰符，需 AppKit 桥接） | 列为**未来项 F-01**，本期不做 |

**选择：O2（主）+ O3（辅）+ O1（兜底）**。三者共用同一组动作（`setCustomDayWidth` / `nudgeCustomDayWidth` / `clearCustomDayWidth`），不产生第二套真相源。

#### SwiftUI `Menu` 内放 Slider 的限制与规避（明确结论）

**限制**：

1. `Menu` 的内容是**菜单项模型**（`MenuElement`），`Slider` 是**视图控件**不是菜单项。放进 `Menu { }` 后，macOS 上不会渲染为可拖动的滑杆，通常退化为一个不可交互的静态视图（甚至整体不显示）。
2. macOS 的 `Menu` **在任意点击后立即关闭**并消费该次点击 ⇒ 即便 Slider 能显示，也**无法连续拖拽**（拖到一半菜单已关）。
3. `Menu` 内不放 `Slider`，也不能用 `Picker` 表达连续量（Picker 只能选枚举档位）。

**规避方式**（按推荐度）：

| 方式 | 做法 | 评价 |
|---|---|---|
| **① `Button + .popover`（选中）** | 工具栏放一个标尺图标 `Button`，`.popover(isPresented:)` 里放 `DayWidthControl`（Slider + 读数 + 步进 + 重置） | ✅ 连续拖拽可用；popover 可获得焦点、可键盘操作。**风险**：SwiftUI 工具栏项挂 `.popover` 在个别 macOS 版本上呈现异常 → 备选锚点见下 |
| ② 内联 Slider 放工具栏 | 直接把 `Slider` 塞进 `ToolbarItemGroup` | 占用 ~160pt 工具栏宽度；紧凑布局下会被折叠隐藏；macOS 工具栏对 Slider 支持一般 |
| ③ 菜单项驱动外部 popover | 缩放菜单加「自定义日宽…」项 → 置 `@State` → 打开挂在标尺按钮上的 popover | ✅ 兼得"菜单入口"与"连续面板"；**选中方案中采用**（菜单项与标尺按钮共享同一个 `@State`） |
| ④ `NSMenu` + `NSHostingView` 塞 Slider | 手写 AppKit 菜单 | ❌ 脆弱、脱离 SwiftUI 状态、易与无障碍/焦点打架 |
| ⑤ 独立小窗口 | 另开一个面板窗口 | ❌ 过重，与单窗口应用形态不符 |

**popover 锚点的备选**（若工具栏 popover 在目标 macOS 上不可靠）：同一个 `DayWidthControl` 视图改挂到**时间轴表头左侧的标尺按钮**或**状态栏右下角**——视图可复用，只改锚点，一行改动。**必须列入首轮 GUI 走查项**。

#### 交互细节（面板 `DayWidthControl`）

```
┌─ 日宽 ────────────────────────────┐
│  [ ◀ 1 ]        12 点/天      [ ▶ 1 ]│   ← 步进按钮（±1 点/天）
│  ├────────●──────────────────────┤   │   ← 连续滑杆（对数映射，见下）
│  日(32)  周(12)  月(5)   档位默认   │   ← 预设芯片 + 重置
│  范围 2–120 点/天                 │   ← 说明文案
└───────────────────────────────────┘
```

- **滑杆映射（对数）**：滑杆位置 `t ∈ [0,1]`，日宽 `w = min × (max/min)^t = 2 × 60^t`。
  - 理由：线性 2–120 会把常用区（5–32）挤在左端 25%；对数映射下常用区落在 `t ∈ [0.4, 0.68]`，手感均匀。`t=0.5 → w ≈ 10.95`。
  - 可切换为线性（一条常量），但**默认对数**。
- **提交节流**：拖动中本地 `@State` 实时跟手并显示读数；向 store 提交**节流 ≥ 100ms**（`onEditingChanged` 结束时必提交一次）。避免 60Hz 触发整条快照重建。
- **数值精度**：提交值保留 0.1 点（UI 层四舍五入），核心不做四舍五入。
- **快捷键**（同时进菜单栏「视图」菜单与 ⌘K 面板，走 `ZenoCommandCatalog` 单一来源）：
  - `⌘+` 加宽 1 点/天、`⌘−` 收窄 1 点/天（`nudgeCustomDayWidth(by: ±1)`）
  - `⇧⌘+` / `⇧⌘−` 粗调 ±5 点/天
  - `⌘0` 重置为档位默认（`clearCustomDayWidth()`）
- **可访问性**：Slider 需 `.accessibilityLabel("每日宽度")` + `.accessibilityValue("12 点/天")`；步进按钮需独立标签。

#### 缩放菜单的改造（`WorkspaceView.swift` 工具栏）

现状菜单：日/周/月 → 适合项目 → 显示/隐藏任务条标签。改造后：

```
✓ 日（32 点/天）
  周（12 点/天）
  月（5 点/天）
────────────
  ✓ 适合项目
  自定义日宽…            ← 打开 popover（O2）
────────────
  当前日宽：12 点/天      ← 不可交互的表头行（disabled Text）
────────────
  显示任务条标签
```

- 预设项前缀 `✓ ` 表示当前档位（自定义激活时**没有**任何预设打勾）。
- 「当前日宽」行让菜单本身也反映实际日宽 → 满足 A6。

---

### D5 可读性与性能约束（重点）

#### 5.1 两级抽稀策略

| 级别 | 手段 | 作用层 | 是否影响日界等距 |
|---|---|---|---|
| **粗粒度** | **刻度档位由日宽推导**：`w ≥ 18 → .day`；`6 ≤ w < 18 → .week`；`w < 6 → .month` | 核心策略（`GanttScale.tickUnit`）→ 决定刻度集合 | ❌ 不影响（只少刻度，不改坐标） |
| **细粒度** | 表头**标签**按上限抽稀（stride），网格线不抽稀 | 视图（`TimelineView`） | ❌ 不影响 |

**为什么不用"逐日刻度 + 跳着标"**：那会要求核心在自定义模式下额外产出逐日刻度（760+ 条），核心循环与快照体积显著上升，而收益仅是标签更密；用"换档位"达到同样的可读性，代价接近零。

#### 5.2 阈值推导（可复核）

| 档位 | 标签形态 | 标签宽（11pt 字号） | 槽位宽 | 需求 | 采纳阈值 |
|---|---|---|---|---|---|
| 逐日 | "31" | ≈ 12.4pt（2 位数字） | `w` | `w ≥ 12.4 + 2×1.8 ≈ 16` | **18**（留 1.8pt/侧余量） |
| 逐周 | "10/5" | ≈ 22.6pt | `7w`（标签左偏 3pt） | `7w ≥ 22.6 + 3 + 2 ≈ 28 → w ≥ 4.0` | **6**（`7×6=42` 有富余；且与档位默认值自洽） |
| 逐月 | "10月" / "2026" | ≈ 24pt | `≈30w` | `w ≥ 0.9` | 恒满足（`w < 6` 即走月档） |

**阈值与档位自洽性校验**（关键）：
`day(32) → 18+ ✓ 逐日`；`week(12) → 6+ ✓ 逐周`；`month(5) → <6 ✓ 逐月`。
⇒ **自定义宽度取到档位默认值时，视觉密度与该档位完全一致**（不会出现"自定义 5 点/天反而比月档更密"的割裂）。这是把周档阈值取 6（而非理论下限 4）的原因。

#### 5.3 数量上界（按 4K 全屏 3840pt 画布估，常规 1440pt 约为其 37.5%）

| 量 | 计算 | 上界 | 处置 |
|---|---|---|---|
| 窗口天数 | `viewWidth / w`，`w ≥ 2` | 1920 天 | 核心逐日循环 6–12ms；**受控** |
| 逐日档刻度数 | `viewWidth / 18` | 213 | 表头 213 条网格线（单 Path）+ 213 次 Text 绘制 → 触发**标签上限 200**，按 stride 抽稀 |
| 逐周档刻度数 | `viewWidth / 6` | 640（其中周标签 92 个） | 周标签 92 个 < 200，不抽稀；网格线 640 条（单 Path，Canvas 内可忽略） |
| 逐月档刻度数 | `viewWidth / 2 / 30` | 64 | 无压力 |
| 非工作带 | 窗口天数 × 2/7 | 61（逐日档）/ 183（逐周档） | 逐月档为 0（沿用现状：月缩放隐藏非工作带） |
| 表头 Text 绘制/帧 | min(刻度数, 200) | **200** | 视图侧硬上限，stride = `max(1, ceil(count / 200))` |
| 条体 / 依赖线 | 与日宽无关（由行虚拟化控制） | 不变 | 不受影响 |

**其他上界**：
- 核心 `max(dayWidth, 0.5)` 的既有下限意味着 fit 路径最坏可产生 2×画布宽的天数（3840pt → 7680 天）。**本期不改**（改了会破坏 A7 逐位一致），登记为风险 R-04 + 跟进项 F-02。
- `fitDayWidth` 可能产出 < 2.0 的日宽（长项目塞进窄画布）→ 自定义区间下限 2.0 **不适用于 fit 路径**（D2 已声明）。

#### 5.4 交互性能预算

- 现有性能门禁：`Tests/AppTests/AppPerformanceTests.swift` 断言 1000 任务下 `setZoom(.day)` < 100ms。
- 现状 `refresh()` 每次都 `session.computeSchedule()` → 视图类动作（缩放/平移）也在重算排期，是滑杆跟手的主要成本。
- 处置：
  - **P0（必须）**：滑杆拖动中**节流提交 ≥ 100ms**，松手必提交一次 → 单次刷新增量有限。
  - **P1（推荐，可裁剪）**：视图类动作走「复用 `session.lastSchedule` 的刷新路径」（`ZenoSession` 已有 `lastSchedule` 缓存），避免每次缩放重算排期。**独立任务、独立风险评估**，不阻塞主线。
  - 若实测 P0 仍不跟手 → 降级为"松手才提交"（拖动中仅面板读数变化），功能不受影响。

---

### D6 状态栏 / 菜单标签

#### 备选方案对比

| 方案 | 状态栏 | 工具栏菜单标题 | 评价 |
|---|---|---|---|
| A（选中）`zoomLabel` 保持短名 + 新增 `zoomDetail` | 「周 · 12 点/天」 | 「周」 | ✅ 两处需求都满足，且不撑爆工具栏 |
| B 扩展 `zoomLabel` 为「周 · 12 点/天」 | 同左 | 「周 · 12 点/天」（菜单标题过长） | ❌ 工具栏变宽 |
| C 只在状态栏显示数字，菜单不显示 | 「周 · 12 点/天」 | 「周」 | ❌ A6 要求菜单也反映实际日宽 |
| D 用 `Int(dayWidth)` 直接拼 | 同 A | 同 A | ⚠️ 非整数丢精度（12.5 → 12） |

**选择 A**：

```swift
// Sources/ZenoPresentation/StatusBarSnapshot.swift
/// 实际日宽读数（点/天），如 "12 点/天" / "12.5 点/天"；与 `zoomLabel` 配合展示。
public var zoomDetail: String?
```

```swift
// Sources/ZenoPresentation/Presenter.swift
private static func zoomLabel(_ viewState: WorkspaceViewState) -> String {
    if viewState.customDayWidth != nil { return "自定义" }
    if viewState.usesFitZoom { return "适合项目" }
    switch viewState.zoom {
    case .day: return "日"
    case .week: return "周"
    case .month: return "月"
    }
}

/// 实际日宽读数：整数不带小数位（"12 点/天"），非整数保留 1 位（"12.5 点/天"）。
private static func zoomDetail(dayWidth: Double) -> String { /* ... */ }
```

- 状态栏渲染：`Text("\(status.zoomLabel) · \(status.zoomDetail ?? "")")`（`ChromeViews.swift` 第 195–198 行，`width >= 900` 条件下生效，保持既有降级策略）。
- 工具栏菜单标题：仍用 `statusBar.zoomLabel`（短名）。
- 缩放菜单内加「当前日宽：X 点/天」表头行（见 D4）。
- fit 模式：标签「适合项目」，detail 给出 fit 实际宽度（如「适合项目 · 7.3 点/天」）→ 用户能理解 fit 到底多宽。

---

### D7 持久化

#### 备选方案对比

| 方案 | 做法 | 优点 | 缺点 |
|---|---|---|---|
| **A（选中）** `StoredPreferences` 新增 `customDayWidth: Double?` | 可选字段，缺省 → nil | 与既有「新增字段用可选值解码」约定一致；旧数据零改动可解码 | 属偏好 JSON 格式扩展（半不可逆） |
| B 不持久化 | 只在会话内存 | 零格式风险 | 用户每次启动都要重调，体感差；与既有"缩放/窗口起点已持久化"不一致 |
| C 持久化 `zoom` 的扩展值（如字符串 "custom:12"） | 塞进既有 `zoom` 字段 | 不改 JSON 结构 | 破坏 `GanttZoom` 的 `RawRepresentable` 解码契约与既有类型；旧数据兼容反而更差 |
| D 存"缩放系数" | 存系数 | 数值小 | 语义错位（同 D1-B） |

**选择 A**：

```swift
// Apps/macos/Sources/WorkspaceStore.swift
private struct StoredPreferences: Codable {
    // ...既有字段不动...
    /// 自定义日宽（点/天）；旧数据缺省时为 nil，回落档位默认宽度。
    var customDayWidth: Double?
}
```

**向后兼容解码策略**：

1. Swift 合成的 `Decodable` 对 `Optional` 字段使用 `decodeIfPresent` → **旧偏好文件缺该键时解码成功、值为 nil** ✓（这是 Swift 合成解码的标准行为，与既有 `outlineVisible: Bool?` 的处理方式一致）。
2. 载入时**归一化**：`customDayWidth = stored.customDayWidth.map(GanttScale.clampDayWidth)`；若非 nil 则强制 `usesFitZoom = false`（自定义优先，与运行时一致）。
3. 旧偏好文件的缺省行为：`customDayWidth == nil` → 生效日宽 = 档位默认（32/12/5）或 fit 宽度 → **与今天完全一致** ✓（A8）。
4. 落盘：`savePreferences()` 写入 `customDayWidth: viewState.customDayWidth`（nil 时 JSON 中该键**会被省略**，文件体积不变、语义不变）。

⚠️ **既有风险（非本期引入，但需登记）**：`StoredPreferences` 的其余字段（`outlineWidth`/`zoom`/`usesFitZoom`/`expandedTaskIDs`/`inspectorWidth`/`inspectorTab`）是**非可选**，任一字段在旧文件中缺失都会让**整个结构解码失败** → `loadPreferences` 返回 nil → **所有偏好一并回落默认**。新增字段是可选的，不放大该风险；但未来若有人再加非可选字段，爆炸半径是"全部偏好"。
**建议跟进项 F-03**：把 `StoredPreferences` 拆成「必需 + 可选」两段式容错解码（本期不做，避免与主线耦合）。

---

## 4. 接口契约汇总（跨层签名）

```swift
// ===== Sources/ZenoCore/Query/GanttScale.swift（新增文件，核心零改动其余部分）=====

/// 甘特时间轴的日宽策略：单一标量日宽驱动全轴，刻度粒度由日宽推导。
///
/// 设计要点：
/// - 本类型只提供**策略与常量**，不改变 `GanttLayoutEngine` 的任何行为；
///   未启用自定义时，调用方传给核心的参数与现状完全一致（逐位一致门禁）。
/// - `tickUnit(forDayWidth:)` 只决定**刻度集合**，不参与任何 x 坐标计算，
///   因此不会破坏"每一天等宽"的等比性不变式。
public enum GanttScale {
    /// 逐日标注的日宽阈值（点/天）。
    public static let dayTickThreshold: Double = 18
    /// 逐周标注的日宽阈值（点/天）；低于此值走逐月。
    public static let weekTickThreshold: Double = 6
    /// 自定义日宽的合法区间（点/天）。
    public static let dayWidthRange: ClosedRange<Double> = 2.0...120.0
    /// 键盘步进粒度（点/天）。
    public static let dayWidthStep: Double = 1.0

    /// 夹取到合法区间；NaN → 下界，+∞ → 上界，−∞ → 下界。
    public static func clampDayWidth(_ value: Double) -> Double

    /// 由日宽推导刻度档位（逐日 / 逐周 / 逐月）。
    public static func tickUnit(forDayWidth dayWidth: Double) -> GanttZoom
}
```

```swift
// ===== Sources/ZenoPresentation/Presenter.swift（makeGantt 内的解析顺序）=====

let custom = viewState.customDayWidth.map(GanttScale.clampDayWidth)
// 自定义优先：即便状态里 fit 与自定义同时为真，也以自定义为权威。
let canFit = viewState.usesFitZoom && custom == nil
            && fitRange != nil && viewport.canvasWidth > 0
let dayWidthOverride: Double? = custom
    ?? (canFit ? GanttLayoutEngine.fitDayWidth(
            contentRange: fitRange!, viewWidth: viewport.canvasWidth, calendar: calendar) : nil)
// 预设 / fit：沿用用户档位（与现状逐位一致）；自定义：由日宽推导刻度粒度。
let effectiveZoom: GanttZoom = custom == nil
    ? viewState.zoom
    : GanttScale.tickUnit(forDayWidth: custom!)

// 快照
GanttSnapshot(..., dayWidth: layout.dayWidth, zoom: effectiveZoom, usesFitZoom: canFit, ...)
```

> **语义变更提示**：`GanttSnapshot.zoom` 由「用户预设档位」重定义为「**生效刻度档位**」。预设模式下二者相等（行为不变）；自定义模式下 `zoom` = 推导出的粒度。`GanttSnapshot.zoom` 的全部使用点只有 3 处（`TimelineView.swift` 第 40/41/394 行），语义恰好都是"刻度粒度"，**与新语义一致** ✓。该变更列入 §9 需确认项。

---

## 5. 改动清单与并行分组

### 5.1 文件级清单

| # | 文件 | 改动内容 | 估计行数 | 类型 |
|---|---|---|---|---|
| F1 | `Sources/ZenoCore/Query/GanttScale.swift` | **新增**：`GanttScale`（阈值 / 区间 / 夹取 / 刻度档位推导） | +80 | 新增 |
| F2 | `Sources/ZenoPresentation/ViewState.swift` | `customDayWidth: Double?` 字段 + init 参数 + 文档注释 | +10 | 改 |
| F3 | `Sources/ZenoPresentation/WorkspaceAction.swift` | 3 个新动作 case | +8 | 改 |
| F4 | `Sources/ZenoPresentation/Presenter.swift` | 有效日宽/有效刻度档位解析；`zoomLabel` 扩展；`zoomDetail` 计算 | +45 | 改 |
| F5 | `Sources/ZenoPresentation/StatusBarSnapshot.swift` | `zoomDetail: String?` 字段 + init 参数 | +12 | 改 |
| F6 | `Apps/macos/Sources/WorkspaceStore.swift` | `StoredPreferences` 扩展；载入归一化；落盘；3 个新动作路由；`setZoom`/`setFitZoom` 互斥 | +60 | 改 |
| F7 | `Apps/macos/Sources/Workspace/WorkspaceView.swift` | 工具栏标尺按钮 + popover 锚点 + `@State`；缩放菜单扩展（宽度文案 / ✓ 前缀 / 自定义项 / 当前日宽表头） | +110 | 改 |
| F8 | `Apps/macos/Sources/Workspace/Timeline/DayWidthControl.swift` | **新增**：popover 内容（对数 Slider / 读数 / ±步进 / 档位芯片 / 重置 / 无障碍标签） | +160 | 新增 |
| F9 | `Apps/macos/Sources/Workspace/Timeline/TimelineView.swift` | 标签锚定与条标签显隐改用「生效刻度档位」；表头标签上限 200 + stride 抽稀 | +50 | 改 |
| F10 | `Apps/macos/Sources/CommandRegistry.swift` | 3 条新命令（加宽 / 收窄 / 重置日宽）+ 快捷键 ⌘+ / ⌘− / ⌘0 / ⇧⌘± | +45 | 改 |
| F11 | `Tests/ZenoCoreTests/GanttScaleTests.swift` | **新增**：阈值边界、夹取（含 NaN/±∞）、与档位默认值自洽 | +110 | 新增 |
| F12 | `Tests/ZenoPresentationTests/DayWidthTests.swift` | **新增**：自定义解析 / fit 互斥 / 预设重置 / 标签 / 生效档位 | +120 | 新增 |
| F13 | `Tests/AppTests/DayWidthControlTests.swift` | **新增**：动作路由、持久化、旧偏好回落、popover 冒烟 | +120 | 新增 |
| F14 | `Tests/AppTests/GUIRenderTests.swift` | 可选：自定义日宽导致画面差异的渲染冒烟 | +30 | 改（可选） |
| F15 | `docs/design/ui-redesign.md` | §3 尺寸表补日宽区间/阈值；§5.1 补自定义日宽与刻度推导规则 | +25 | 文档 |
| F16 | `docs/features/01-views-editing.md` | 第 369 行缩放行为注记更新 | +8 | 文档 |
| F17 | `CHANGELOG.md` | 一条变更记录 | +6 | 文档 |

**未改动的关键文件**：`Sources/ZenoCore/Query/GanttLayout.swift`（核心布局引擎 **零 diff**）、`Sources/ZenoPresentation/Snapshots.swift`（`GanttSnapshot` 字段不变，仅语义重定义）、`Sources/ZenoCore/Query/OutlineTree.swift` 等。

### 5.2 并行分组

> 规则：**同一组内任务的文件范围互斥**；每个文件在全部组中只出现一次。组间存在签名依赖，签名已在本设计第 4 节固定，故可并行开工，最终由 G12 统一集成编译。

**W1（可并行）**

| 组 | 代号 | 文件范围（互斥） | 依赖 |
|---|---|---|---|
| G1 | 核心策略 | `Sources/ZenoCore/Query/GanttScale.swift` | 无 |
| G2 | 呈现层状态与动作 | `Sources/ZenoPresentation/ViewState.swift`、`Sources/ZenoPresentation/WorkspaceAction.swift` | 无（签名见 §4） |
| G3 | 核心单测 | `Tests/ZenoCoreTests/GanttScaleTests.swift` | G1 的签名（已固定） |
| G4 | 文档对齐 | `docs/design/ui-redesign.md`、`docs/features/01-views-editing.md`、`CHANGELOG.md` | 无 |

**W2（可并行，依赖 W1 的签名落地）**

| 组 | 代号 | 文件范围（互斥） | 依赖 |
|---|---|---|---|
| G5 | 呈现层解析与快照 | `Sources/ZenoPresentation/Presenter.swift`、`Sources/ZenoPresentation/StatusBarSnapshot.swift` | G1、G2 |
| G6 | 应用层状态与持久化 | `Apps/macos/Sources/WorkspaceStore.swift` | G2、G5（动作与状态签名） |
| G7 | 呈现层单测 | `Tests/ZenoPresentationTests/DayWidthTests.swift` | G1、G2、G5 |
| G8 | 应用层单测 | `Tests/AppTests/DayWidthControlTests.swift` | G6 |

**W3（可并行，依赖 W2）**

| 组 | 代号 | 文件范围（互斥） | 依赖 |
|---|---|---|---|
| G9 | 工具栏与日宽面板 | `Apps/macos/Sources/Workspace/WorkspaceView.swift`、`Apps/macos/Sources/Workspace/Timeline/DayWidthControl.swift` | G6 |
| G10 | 时间轴渲染与标签抽稀 | `Apps/macos/Sources/Workspace/Timeline/TimelineView.swift` | G5（`GanttSnapshot.zoom` 语义） |
| G11 | 命令注册表与快捷键 | `Apps/macos/Sources/CommandRegistry.swift` | G6 |
| G12 | GUI 渲染冒烟 | `Tests/AppTests/GUIRenderTests.swift` | G9、G10 |

**W4（串行）**

| 组 | 代号 | 范围 | 内容 |
|---|---|---|---|
| G13 | 集成与门禁 | 全仓（只读验证，不改文件） | `swift build -c release -Xswiftc -warnings-as-errors`；`swift test`（414 既有 + 新增全绿）；`tools/gate-core.sh`、`tools/gate-ui.sh`；人工视觉走查（popover 呈现、标签抽稀、非工作带） |

**与测试文件交叉的源文件**（改签名即需同步改测试，联编时优先核对）：

| 源文件 | 交叉的测试文件 | 交叉点 |
|---|---|---|
| `Sources/ZenoCore/Query/GanttScale.swift` | `Tests/ZenoCoreTests/GanttScaleTests.swift`（新）、`Tests/ZenoCoreTests/GanttLayoutTests.swift`（既有，**不改**） | `tickUnit(forDayWidth:)`、`clampDayWidth`、`dayWidthRange` 常量 |
| `Sources/ZenoPresentation/ViewState.swift` | `Tests/ZenoPresentationTests/DayWidthTests.swift`（新）、`Tests/ZenoPresentationTests/PresenterTests.swift`（既有，**不改**） | `customDayWidth` 字段与 init 参数 |
| `Sources/ZenoPresentation/WorkspaceAction.swift` | `Tests/AppTests/DayWidthControlTests.swift`（新）、`Tests/AppTests/WorkspaceStoreTests.swift`（既有，**不改**） | 3 个新 case 的关联值签名 |
| `Sources/ZenoPresentation/Presenter.swift` | `Tests/ZenoPresentationTests/DayWidthTests.swift`（新） | `zoomLabel` / `zoomDetail` 文案、`GanttSnapshot.zoom` 生效档位 |
| `Sources/ZenoPresentation/StatusBarSnapshot.swift` | `Tests/ZenoPresentationTests/DayWidthTests.swift`（新） | `zoomDetail` 字段名与可选性 |
| `Apps/macos/Sources/WorkspaceStore.swift` | `Tests/AppTests/DayWidthControlTests.swift`（新）、`Tests/AppTests/WorkspaceStoreTests.swift`（既有，**不改**） | `StoredPreferences` 字段名（决定偏好 JSON 键名） |
| `Apps/macos/Sources/Workspace/Timeline/DayWidthControl.swift` | `Tests/AppTests/DayWidthControlTests.swift`（新） | 视图类型名与初始化签名（`@testable import`） |

> **既有测试文件一律不改**：`GanttLayoutTests.swift`（22 例）、`PresenterTests.swift`（20 例）、`WorkspaceStoreTests.swift`（55 例）、`GUIRenderTests.swift`（8 例）全部保持原样 → 414 用例的"逐位一致"门禁在**文件层面**即成立。

---

## 6. 不可逆 / 半不可逆决策标注

| # | 决策 | 级别 | 说明 | 需要谁确认 |
|---|---|---|---|---|
| **IR-1** | 偏好 JSON 新增 `customDayWidth` 键 | **半不可逆** | 格式扩展本身向后兼容（可选字段），但**键名一旦发布即成事实**；未来若移除/改名，`StoredPreferences` 整体解码失败 → **所有偏好丢失**（不只是日宽） | **lead + 用户** |
| **IR-2** | 日宽区间 `[2.0, 120.0]` 与刻度阈值 `18 / 6` | **半不可逆** | 用户可见的行为契约；改动会使已持久化的偏好值被夹取（用户"自定义 150"会静默变 120）；阈值改动会改变刻度密度 | **lead** |
| **IR-3** | `GanttSnapshot.zoom` 语义由「用户预设档位」重定义为「生效刻度档位」 | **半不可逆** | `ZenoPresentation` 是公开库产品（`Package.swift` 有 `.library` product），该字段语义变更对外部消费者不可逆；仓内使用点仅 3 处且语义吻合 | **lead** |
| **IR-4** | 自定义模式下刻度粒度随日宽变化（而非固定为预设粒度） | **规格变更** | 与 `docs/design/ui-redesign.md` §5.1「缩放：日 / 周 / 月 / 适合项目」及 §3「缩放日宽 日 32 / 周 12 / 月 5」冲突。**裁决：改文档，不改实现**（F15） | **lead** |
| **IR-5** | 自定义宽度不参与 `StoredPreferences` 之外的任何持久化（如项目文件） | 低 | 项目文件格式不动 | lead 知情即可 |
| **IR-6** | 核心 `GanttLayoutEngine` 零改动 | 低（正向） | 避免了布局语义变更，回归风险最小 | lead 知情即可 |

> 其余决策（动作命名、UI 形态、抽稀上限、快捷键）均为**可逆**的局部实现细节，由实现者按本设计执行即可。

---

## 7. 验收判据校准与测试建议

### 7.1 A1 的校准（**必须先与 lead 确认**）

**原 A1**：「设定自定义日宽 W 后，任意相邻两个日界刻度的 x 差恒等于 W（跨周/跨月/跨年同样成立）。」

**冲突**：当自定义日宽 < 18 时，刻度粒度切换为逐周/逐月，快照中的刻度是**周界/月界**，相邻刻度 x 差是 `7W` / `≈30W`，而不是 `W`。若严格按原文字面验收，A1 与 A5（日宽极小时不出现标签重叠与绘制量爆炸）**互斥**：要满足 A5 就必须减少刻度，刻度一减少 A1 的字面表述就不成立。

**校准后的 A1'（建议 lead 采纳）**：

> **A1'（等比性）** 自定义日宽 W 下：
> 1. 快照中**所有**刻度 x、所有非工作带 x、所有条体 x/width，均为 W 的整数倍（误差 < 1e-6）；非工作带宽度恒等于 W；
> 2. 当**生效刻度档位为 `.day`** 时，相邻刻度 x 差恒等于 W，且跨周/跨月/跨年同样成立；
> 3. 生效刻度档位为 `.week`/`.month` 时，相邻刻度 x 差恒等于 `7W` / `≈30W`（该单位跨度的整数倍），**日界等距性由第 1 条保证**。

**为什么这样校准是严谨的**：核心的坐标公式是 `x = 天数 × W`，"日界等距"等价于"x 是 W 的整数倍且带宽恒为 W"——第 1 条是对该公式的直接、可机器验证的断言（比"看两个刻度的差"更强，因为它覆盖了全轴每一个刻度）。第 2 条在 `.day` 档位下与原 A1 **完全等价**。

### 7.2 其余判据的落地映射

| 判据 | 落地方式 | 建议测试位置 |
|---|---|---|
| A1' | 见 7.1 | `GanttScaleTests`（等距不变式）+ `DayWidthTests`（呈现层解析后快照） |
| A2 | `setZoom(.day/.week/.month)` → `customDayWidth == nil` 且 `snapshot.gantt.dayWidth == 32/12/5` | `DayWidthControlTests`（动作）+ `DayWidthTests`（快照） |
| A3 | `setCustomDayWidth(20)` → `usesFitZoom == false`；`setFitZoom(true)` → `customDayWidth == nil` 且日宽 == fit 值 | `DayWidthControlTests` + `DayWidthTests` |
| A4 | `setCustomDayWidth(-5 / 0 / 1000 / .nan / .infinity)` → 落在 `[2, 120]`，非 0/负/NaN | `GanttScaleTests`（纯函数）+ `DayWidthControlTests`（端到端） |
| A5 | `setCustomDayWidth(2)` → 刻度数 ≤ 64、标签数 ≤ 200、非工作带 0；`setCustomDayWidth(18)` → 刻度 x 差恒 == 18 | `DayWidthTests`（数量）+ `GUIRenderTests`（画面差异） |
| A6 | `zoomLabel == "自定义"`、`zoomDetail == "12 点/天"`；菜单表头行文案 | `DayWidthTests`（快照文案）+ 人工走查（菜单） |
| A7 | 既有 414 用例**全绿且文件零改动**；`customDayWidth == nil` 时 `makeGantt` 传参与现状一致 | 回归门禁 + `DayWidthTests` 内置"nil 自定义 ⇒ 与基线快照全等"断言 |
| A8 | 写入偏好 → 新建 store → 恢复；旧偏好 JSON（无该键）→ `customDayWidth == nil` | `DayWidthControlTests` |

### 7.3 建议新增测试清单（供 tester 直接取用）

**`Tests/ZenoCoreTests/GanttScaleTests.swift`（新增，~8 例）**
1. `clampDayWidth` 低于下界 → 2.0；高于上界 → 120.0；区间内原样返回。
2. `clampDayWidth(.nan)` → 2.0；`.infinity` → 120.0；`-.infinity` → 2.0。
3. `tickUnit(forDayWidth: 32)` == `.day`；`12` == `.week`；`5` == `.month`（**与档位默认值自洽**）。
4. 阈值边界：`17.99` → `.week`；`18` → `.day`；`5.99` → `.month`；`6` → `.week`；`1.99` → `.month`。
   > **lead 更正（2026-10-20）**：本行原写 `5.99 → .week`，与 §3 D5 阈值表及 lead 契约「≥6 → .week，否则 .month」矛盾；按契约应为 `.month`。验收用例已按 `.month` 断言。
5. `tickUnit` 单调性：宽度递增 → 粒度只会变粗不会变细。

**`Tests/ZenoPresentationTests/DayWidthTests.swift`（新增，~10 例）**
6. 自定义 20 → `snapshot.gantt.dayWidth == 20`、`zoom == .day`（20 ≥ 18）。
7. 自定义 10 → `dayWidth == 10`、`zoom == .week`。
8. 自定义 3 → `dayWidth == 3`、`zoom == .month`、非工作带为空。
9. **A1' 等距性**：自定义 18（`.day` 档）→ 所有刻度 x 差恒 == 18，跨月/跨年成立；所有 band x 为 18 的整数倍、band.width == 18。
10. 自定义 12（`.week` 档）→ 所有刻度 x 为 12 的整数倍；相邻差 == 84。
11. `customDayWidth == nil` 且 `usesFitZoom == false` → 快照与"未改动基线"**逐字段全等**（A7 强化）。
12. `usesFitZoom == true` 且 `customDayWidth != nil`（矛盾状态）→ 自定义优先，`snapshot.gantt.usesFitZoom == false`。
13. `zoomLabel`：`customDayWidth != nil` → "自定义"；`usesFitZoom` → "适合项目"；否则 "日/周/月"。
14. `zoomDetail`：20 → "20 点/天"；12.5 → "12.5 点/天"。

**`Tests/AppTests/DayWidthControlTests.swift`（新增，~10 例）**
15. `setCustomDayWidth(20)` → `viewState.customDayWidth == 20`、`usesFitZoom == false`。
16. `nudgeCustomDayWidth(by: 2)` → 基准取**当前生效日宽**（fit 模式下取 fit 宽度），结果 = base + 2 并夹取。
17. `clearCustomDayWidth()` → 回落档位默认（32/12/5）。
18. `setZoom(.day)` → `customDayWidth == nil`（A2）。
19. `setFitZoom(true)` → `customDayWidth == nil` 且宽度 == fit 值（A3）。
20. `panWindow` / `goToToday` → `customDayWidth` **不变**（D3 裁决 4）。
21. 持久化：设定 20 → 新建 store → `customDayWidth == 20`（A8）。
22. 旧偏好兼容：手写一份**不含** `customDayWidth` 的 JSON → 载入成功、`customDayWidth == nil`、其余偏好保留（A8）。
23. 越界持久化值：偏好里存 999 → 载入后被夹取到 120。
24. 命令注册表：`ZenoCommandCatalog.make` 含新增的 3 条命令且快捷键为 ⌘+ / ⌘− / ⌘0。

---

## 8. 风险登记

| ID | 风险 | 影响 | 缓解 |
|---|---|---|---|
| R-01 | 工具栏 `.popover` 在目标 macOS 上呈现异常 | 连续调节不可用 | 同一 `DayWidthControl` 改挂到表头/状态栏（只改锚点）；菜单内步进（O1）与快捷键（O3）作为不依赖 popover 的兜底 |
| R-02 | 滑杆拖动触发高频刷新（1000 任务下每次 `refresh` 含排期重算） | 拖动掉帧 | 节流 ≥ 100ms + 松手必提交；P1 优化（复用 `lastSchedule`）；最差降级为"松手提交" |
| R-03 | 档位推导阈值 18/6 的具体数值被后续调宽 | 已有用户的自定义宽度观感突变 | 阈值集中在 `GanttScale` 两个常量；变更需同步 `docs/design/ui-redesign.md` |
| R-04 | fit 路径在长项目 + 窄画布下窗口天数可达 2×画布宽（既有暴露，本期不修） | 单次布局 25–45ms | 记为跟进项 F-02（需改核心 → 破坏逐位一致 → 需单独设计与批准） |
| R-05 | `StoredPreferences` 整体解码失败会清空**全部**偏好（既有结构风险） | 用户偏好丢失 | 跟进项 F-03（容错解码）；本期新增字段用可选值，不放大风险 |
| R-06 | `GanttSnapshot.zoom` 语义变更被外部消费者误用 | 外部集成出错 | `ZenoPresentation` 是公开库产品 → 列入 §9 需确认项 IR-3，并在 CHANGELOG 标注 |
| R-07 | `⌘+` 在部分键盘布局需配合 Shift，⌘K 面板的快捷键文案可能与实际不符 | 快捷键不可预期 | 用 `ZenoShortcut(key: "+", modifiers: .command)` 并在面板展示 "⌘+"；真机验证后再定稿 |

---

## 9. 需 lead / 用户确认的事项（汇总）

1. **IR-1** 偏好 JSON 键名 `customDayWidth` 是否批准（偏好格式扩展，半不可逆）。
2. **IR-2** 日宽区间 `[2, 120]` 与刻度阈值 `18 / 6` 是否采纳（数值可调，但一经发布即为契约）。
3. **IR-3** `GanttSnapshot.zoom` 语义重定义为「生效刻度档位」是否批准（公开库 API 语义变更）。
4. **IR-4 / A1 校准** 自定义模式下"刻度粒度随日宽变化"与"等比性"的验收表述 A1' 是否采纳（**必须裁决**，否则 A1 与 A5 互斥）。
5. **IR-4 续** `docs/design/ui-redesign.md` §3/§5.1 与 `docs/features/01-views-editing.md` 第 369 行的规格改写（**改文档，不改实现**）是否批准。
6. **UI 形态** 「工具栏弹出面板 Slider（主）+ 菜单步进（兜底）+ ⌘+/⌘−/⌘0（辅）」是否采纳；表头直接拖拽改日宽（O4）本期排除是否认可。
7. **F-01/F-02/F-03** 三个跟进项是否登记（表头拖拽缩放 / fit 路径窗口天数上限 / 偏好容错解码）。

---

## 10. 文档对齐清单（改文档，不改实现）

| 文档 | 位置 | 现状 | 目标 |
|---|---|---|---|
| `docs/design/ui-redesign.md` | §3 尺寸表「缩放日宽」行 | 「日 32 / 周 12 / 月 5」 | 追加「自定义 2–120 点/天（单一标量，全轴等比）；刻度粒度按 ≥18 逐日 / ≥6 逐周 / 其余逐月推导」 |
| `docs/design/ui-redesign.md` | §5.1 缩放条目 | 「缩放：日 / 周 / 月 / 适合项目」 | 追加「+ 自定义日宽（2–120 点/天，等比缩放；与前三档互斥）」 |
| `docs/features/01-views-editing.md` | 第 369 行 Zeno 实现方案 | 「缩放档位为日 / 周 / 月 / 适合项目，日宽分别为 32 / 12 / 5」 | 追加自定义日宽与其余规格 |
| `docs/01-prd.md` | US-E4-04 状态行 | 「日/周/月缩放与『适合项目』」 | 可选：补「自定义日宽」 |
| `CHANGELOG.md` | 新增条目 | — | 记录新增自定义日宽能力与偏好字段 |

---

## 附：一句话验收口径（给 tester）

> 在「计划」视图把日宽调到任意值 W（2 ≤ W ≤ 120），全轴每一天的宽度恒为 W（相邻日界刻度 x 差 = W，跨周跨月跨年不变）；日宽小于 18 时刻度自动降为逐周、小于 6 降为逐月，标签不重叠、绘制量有界；选日/周/月预设立刻回到 32/12/5 并清空自定义；开「适合项目」立刻回到 fit 宽度并清空自定义；越界值被夹取、无 0/负/NaN；状态栏与缩放菜单同时显示档位与实际日宽；不启用自定义时输出与现状逐位一致，既有 414 用例全绿。
