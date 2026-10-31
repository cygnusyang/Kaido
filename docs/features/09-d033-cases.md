# D-033 大纲点选与列宽调整：判据 → 用例映射与手动走查清单

> 缺陷：[docs/defects.md](../defects.md) D-033 / GitHub issue #13（用户实测 v0.13.0）。
> 修复版本：v0.13.1（PATCH）。
> 本文件是**测试前置**产物：先于实现落盘，实现完成后逐条转绿。
> 自动化文件（两个，分工不重叠）：
> - `Tests/AppTests/OutlineSelectionAcceptanceTests.swift`（本文件作者：dev-tester，**14 例**）——行为验收：点选与检查器联动、整行拖拽已移除、热区口径、调宽持久化。
> - `Tests/AppTests/OutlineRowInteractionTests.swift`（实现方：dev-coder-pres，13 例）——命中带几何：交界 x、带宽、不重叠、末列内缩、聚焦模式、视口外裁剪、行节距。
> 产物分工：本文档 + 上述行为验收文件归 dev-tester；`Sources/**` 与 `Apps/macos/Sources/**` 归 dev-coder-pres。

## 0. 口径

**L1 层**：全部行为在 `app`（Apps/macos）层；pres 层只被只读复用（`OutlineColumnLayout` / `OutlineColumnPreferences`）。

**L2 可测边界（先说清测不到什么）**：SwiftUI 手势（`.onDrag` / `.onTapGesture` / `.highPriorityGesture` / `.onHover`）、真实鼠标事件序列、`NSCursor` 形态在 Swift Testing 离屏进程里**无法注入**。因此只用三种**诚实的**等价口径，不假装点过鼠标：

| 手段 | 能锁住 | 锁不住 |
|---|---|---|
| Store 端到端（`.select` / `.setOutlineColumnWidth` → 快照） | 选中态、检查器联动、状态栏摘要、宽度落盘与持久化 | 手势是否真把事件送到这个入口 |
| 源码结构守卫（`#filePath` 读 `OutlineTable.swift`，照 `DayWidthUxAcceptanceTests.swift:159` 做法） | 「整行 `.onDrag` 已删除」「拖拽源只剩握把」「表头与行共用同一热区常量」 | 运行时手势仲裁是否真不打架 |
| 常量/几何断言（`OutlineColumnResizeMetrics.hotZone` ≥ 8、`layout.resizeBoundaries()`） | 命中宽度、交界位置 | 光标形态与手感 |
| 手动走查（§3） | 真实拖拽、光标、点击成功率 | — |

**L3 未覆盖项如实登记在 §2，不用等价断言冒充已覆盖。**

**L4 确定性**：`UserDefaults` 每例独立域（`kaido.apptests.d033.<uuid>`）；布局取固定 `totalWidth`；不读字体/屏幕/墙钟。浮点宽度一律用 `0.001` 容差（`Double` 与 `CGFloat` 派生值混比较会假红，见 §5）。

## 1. 判据 → 用例（14 例）

判据编号取自 issue #13「预期」1/2/3 与 D-033 行的修复方向。

### ① 单击行 → 选中 + 检查器联动（issue 预期 1）

| ID | 判据 | 用例 | 断言 | 状态 |
|---|---|---|---|---|
| S-01 | 点任一行都选中，检查器与状态栏同步跟随（不依赖点在哪一列） | `clickingAnyRowSelectsTaskAndDrivesInspector` | 前 3 行逐行：`selection == row.id`；`inspector.content == .task(taskID: row.id, title: row.title)`；`statusBar.selectionSummary == row.title` | ✅ |
| S-02 | 边界：群组 / 里程碑 / 子任务（不同 `kind`、不同深度）都能选中 | `everyRowKindIsSelectable` | 造一个 `.group` 行后遍历**全部**行：`selection == row.id` 且检查器 `taskID` 跟随 | ✅ |
| S-03 | 已选中行重复点击不丢选中（用户连点是常态） | `repeatedClickKeepsSelection` | 连点 3 次，选中与检查器恒定 | ✅ |
| S-04 | 换行点选后检查器跟着换（联动双向） | `selectingAnotherRowMovesInspector` | 选 A 再选 B → `selection == B`、检查器 `taskID == B` | ✅ |
| S-05 | 用户场景：选中后再调列宽，选中不得被清掉 | `selectionSurvivesColumnResizeCommit` | `select` → `setOutlineColumnWidth(.start, 140)` → 选中与检查器不变 | ✅ |
| S-06 | 负路径：选中不存在的 id 不崩、不残留上一选中 | `selectingUnknownTaskKeepsInspectorSafe` | 检查器回落 `.project` 且 `selectionMissing == true` | ✅ |
| S-07 | 负路径：空工程无行可点，选中接口安全 | `emptyProjectHasNoRowsAndStaysSafe` | `rows.isEmpty`；`select(nil)` 后 `selection == nil`、`selectionMissing == false` | ✅ |
| S-08 | 负路径：筛选下重排禁用，但点选仍可用 | `filterDisablesReorderButKeepsSelectionUsable` | `allowsDragReorder == false` 时点行仍选中且检查器跟随 | ✅ |

### ② 重排不再是整行入口（issue 预期 2）

| ID | 判据 | 用例 | 断言 | 状态 |
|---|---|---|---|---|
| R-01 | 整行 `.onDrag` 已删除，拖拽源只剩行首握把 | `outlineTableNoLongerAttachesDragToWholeRow` | 源码不含 `.modifier(DragReorderModifier`、不含 `DragReorderModifier(`；含 `struct ReorderDropModifier`、`struct OutlineReorderGrip`；**每一处** `.onDrag` 的位置都必须在握把声明之后 | ✅ |
| R-02 | 行点击入口仍在，且挂在整行容器上（不按列分流） | `rowTapIsStillOnWholeRowContainer` | 含 `dispatch(.select(row.id))`、含 `.contentShape(Rectangle())`；不存在按列的 `.onTapGesture` 分流 | ✅ |

### ③ 交界热区 ≥ 8pt 且口径唯一（issue 预期 3）

| ID | 判据 | 用例 | 断言 | 状态 |
|---|---|---|---|---|
| B-01 | 热区 ≥ 8pt，且表头与行共用同一常量（不各留字面量） | `resizeHotZoneIsSharedAndWideEnough` | `OutlineColumnResizeMetrics.hotZone >= 8`；源码引用 `OutlineColumnResizeMetrics.hotZone`；旧 `hotZoneWidth: CGFloat = 6` 已消失 | ✅ |

### ④ 调宽链路与持久化（D-033 修复方向 ② 的落地效果）

| ID | 判据 | 用例 | 断言 | 状态 |
|---|---|---|---|---|
| W-01 | 行区域调宽与表头走同一条提交链路 | `rowResizeCommitsThroughTheSameStoreAction` | `OutlineTable.swift` 含 `onResizeEnded`/`onResizeChanged`；`WorkspaceView.swift` 含 `commitLiveColumnResize` | ✅ |
| W-02 | 拖宽持久化：新 store 同偏好域仍保留，布局按覆盖值渲染 | `committedWidthPersistsAcrossStores` | `outlineColumnWidths == ["start": 140, "assignee": 200]`；布局 `width(of:)` 同步 | ✅ |
| W-03 | 复位（双击交界）后新 store 也读不到覆盖值 | `resetClearsPersistedOverride` | 覆盖值清空 + 宽度回落 `defaultWidth(for:)`（0.001 容差） | ✅ |

宽度夹取（`widthRange` 上下界、NaN/∞ 复位）、弹性列拒绝写宽：已有 `WorkspaceStoreTests.setOutlineColumnWidth*` 覆盖，**不重复**。

## 2. 未覆盖与原因（不虚报）

| 未覆盖项 | 原因 | 由谁兜住 |
|---|---|---|
| 视图是否**真的**在点击时派发 `.select`（而非被拖拽会话接管） | 无法注入鼠标按下-微动序列；给视图注入闭包断言「闭包被调用」属同源比较（恒真） | R-01/R-02 结构守卫 + 手动走查 M-01 |
| 「指针抖动 2–3pt 仍能选中」的真实手感 | 需要真实 `NSEvent` 拖拽会话 | 手动走查 M-01（专项包含抖动步骤） |
| `NSCursor.resizeLeftRight` 是否在交界出现 | `NSCursor` 是进程全局态，离屏渲染不体现 | 手动走查 M-04 |
| 行区与表头交界的视觉反馈一致性（高亮线） | 像素差不可归因（行/表头底色本就不同） | 手动走查 M-05 |
| 极窄窗口下相邻图标列的两条交界是否互相挤压 | 需真实像素级手感；几何重叠已由 `bandsDoNotOverlap`（coder 文件）兜住 | 手动走查 M-06 |
| 重排落点语义（插为其后 / 成为子项） | 与本缺陷无关，既有用例已覆盖 `moveTarget` / `OutlineRowDropDelegate` | 既有 `WorkspaceStoreTests`、`OutlineAlignmentTests` |

## 3. 手动走查清单（**必须人工**，离屏测试不覆盖）

前置：`swift run KaidoApp`（或运行 build 出的 app），打开**含 ≥ 8 个任务**的项目，进入**计划模式**。

| ID | 步骤 | 期望 |
|---|---|---|
| M-01 | ① 任意行「任务」列单击一次；② 开始/结束/时长/负责人/完成列各单击一次；③ 每次按下后**刻意让指针抖动 2–3pt 再松开** | 每次都稳定选中（整行高亮）；检查器切到该任务且标题一致；状态栏出现选中摘要；**不得**出现拖拽浮起、插入线或行顺序变化 |
| M-02 | 已选中行连点 3–5 次（含双击标题列） | 选中不丢失；检查器不跳回「工程」；若双击进入重命名，改名后仍保持选中 |
| M-03 | 鼠标移到行首握把（序号列左缘）→ 悬停观察 → 按住拖动 | 握把处出现拖拽反馈；重排按落点生效；**同一行普通单击仍只选中**；状态列左缘不因握把而失去右键菜单 |
| M-04 | 指针移到任意列**交界**（行区域内）→ 观察光标 → 左右拖动 40pt | 光标变左右调整形（↔）；列宽实时跟随；松手后保留，表头与行**同时**变化（不错位） |
| M-05 | 表头交界处做同样拖动 | 与行区域表现一致（同光标、同手感、同 2pt 提交阈值）；交界有 1pt 高亮反馈 |
| M-06 | 窗口拖到最窄（大纲宽 < 400pt），重复 M-04 | 相邻图标列（状态/违例/序号 各 18pt）的交界仍能抓到；抓不到时**优先保证单击选中**（宁可不调宽，不许吞点击） |
| M-07 | 双击列交界 | 该列宽复位默认；其余列宽不变；重启 app 后仍为默认 |
| M-08 | 交界处**只单击不拖动**（松开位移 ≈ 0–1pt） | 列宽**不变**（不写粘滞值）；且这一下不改变当前选中、不误选相邻行 |
| M-09 | 输入筛选词（`allowsDragReorder == false`）后重复 M-01 | 点选仍稳定；握把不出现/不可拖 |
| M-10 | 打开基线对比（显示基线列）与「聚焦标签栏」模式，重复 M-01 / M-04 | 聚焦模式**不出现**调宽光标（与表头一致）；基线/偏差只读列可正常调宽；点选在所有列生效 |

**M-01 与 M-08 是 D-033 用户原话（「选不中」「拖了半天，既没调宽也没选中」）的正面复核，不得省略。**

## 4. 实现侧符号（当前落地形态，测试依赖）

```swift
// Apps/macos/Sources/Workspace/Outline/OutlineTable.swift（皆为 internal）
enum OutlineColumnResizeMetrics { static let hotZone: CGFloat; static let commitThreshold: CGFloat }   // hotZone ≥ 8
enum OutlineReorderMetrics      { static let gripWidth: CGFloat }                                      // 12…16
struct OutlineColumnBoundary    { var column: OutlineColumn; var x: CGFloat; var isLast: Bool; var band: ClosedRange<CGFloat> }
extension OutlineColumnLayout   { func resizeBoundaries() -> [OutlineColumnBoundary]; var dragGripOffset: CGFloat }
struct ReorderDropModifier      // 行：只做 onDrop 落点
struct OutlineReorderGrip       // 行首握把：唯一天然的 .onDrag 来源，另带 .onTapGesture 派发选中
struct OutlineRowsList(...)     // 新增 onResizeChanged / onResizeEnded / onResizeReset
```

口径约束（两条，改了就红）：
1. **弹性列吃余量**：拖宽 `.title` 之前的列时，`title` 按同量收窄，故该列**自身右缘不变**、其后交界才右移。断言交界位移必须取 `.title` **之后**的列（例：`.finish`），否则会把正确行为判红（§5 已发生一次）。
2. **热区口径唯一**：`hotZone` 只存在于 `OutlineColumnResizeMetrics`，表头手柄与行交界带都必须引用它；源码里再出现 `hotZoneWidth: CGFloat = 6` 即为回归。

## 5. 红 → 绿与变异验证记录（2026-10-25）

### 5.1 先红（落盘即验）

测试草案按初始契约（`OutlineRowInteraction`）落盘时，`swift build --build-tests` 报错原文：

```
Tests/AppTests/OutlineSelectionAcceptanceTests.swift:91:26: error: cannot find 'OutlineRowInteraction' in scope
Tests/AppTests/OutlineSelectionAcceptanceTests.swift:106:24: error: cannot find 'OutlineRowInteraction' in scope
Tests/AppTests/OutlineSelectionAcceptanceTests.swift:113:62: error: cannot find 'OutlineRowInteraction' in scope
```

此时**整个 AppTests target 编译不过**（不只本文件红），已同步告知 dev-coder-pres 把符号排到第一批。

实现方落地时选择了另一组命名（`OutlineColumnResizeMetrics` / `layout.resizeBoundaries()` / `OutlineReorderGrip`）。按「测试代码归 dev-tester、生产代码归 coder」的分工，**本文件改为对齐已落地 API**，未要求生产代码改名。

### 5.2 二次红：4 条失败，3 条是测试自身缺陷（已改测试）

| 失败用例 | 报错 | 归因 | 处置 |
|---|---|---|---|
| `resetClearsPersistedOverride` | `(78.0) == (78.0)` 判假 | **测试缺陷**：`CGFloat` 与 `Double` 派生值混比较，尾数不一致 | 改 0.001 容差 |
| `rowResizeCommitsThroughTheSameStoreAction` | `source.contains(".setOutlineColumnWidth(") → false` | **测试缺陷**：提交链路在 `WorkspaceView.swift`，我只读了 `OutlineTable.swift` | 双文件读取 |
| `everyRowKindIsSelectable` | `Set(rows.map(\.kind)).count → 1 >= 2` | **测试缺陷**：种子数据只有一种 `kind`，夹具假设错误 | 显式 `createTask(kind: .group)` 造行 |
| `boundariesFollowWidthOverrides`（coder 文件） | `(360.0) == (417.6)` | **生产实现正确**，coder 用例期望值漏了「`title` 吃余量」 | 已把归因与修法告知 dev-coder-pres，不改其文件 |

### 5.3 结构守卫的变异验证（反向对照）

把 `OutlineTable.swift` 换回修复前版本（`git show HEAD:…`）后，守卫断言用的谓词全部反转 —— 证明这些用例**真会红**，不是恒真断言：

| 谓词 | 修复前 | 修复后 | 守卫期望 |
|---|---|---|---|
| `.modifier(DragReorderModifier` | 1 | 0 | 0（R-01 红→绿） |
| `DragReorderModifier(` | 1 | 0 | 0 |
| `struct ReorderDropModifier` | 0 | 1 | 1 |
| `struct OutlineReorderGrip` | 0 | 1 | 1（R-01 的 `.onDrag` 位置前提） |
| `hotZoneWidth: CGFloat = 6` | 1 | 0 | 0（B-01 红→绿） |
| `OutlineColumnResizeMetrics.hotZone` | 0 | 3 | ≥1 |

### 5.4 当前结果（2026-10-25）

```
swift test --disable-sandbox --filter OutlineSelectionAcceptanceTests
✔ Test run with 14 tests in 1 suite passed

swift test --disable-sandbox
✔ Test run with 1105 tests in 100 suites passed      # 独立复跑，0 failure

swift build                                          # 0 warning
```

收口状态：全量绿（含本文件 14 例、实现方 14 例），线性记录见下 ——
先编译红 → 本文件 14/14 → 全量曾有 1 红（`boundariesFollowWidthOverrides`，期望值漏算 title 吃余量，归因交 dev-coder-pres）→ 其改为不变性断言后全量 1105/1105 绿。
剩余动作：把 commit hash 回填 D-033 行与 issue #13（不属测试职责，由 lead/coder 收口）。
