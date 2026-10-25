# 08 基线（Baseline）：数据模型、偏差口径与存储方案

> 状态：设计稿（dev-architect）· 2026-10-25 · 前置：[07-actual-dates.md](07-actual-dates.md)
> 上游：PRD [US-E2-06](../01-prd.md)、F-14-16 / F-12-17 / F-13-09 / F-22-05；调研：[docs/research/omniplan-baseline.md](../research/omniplan-baseline.md)（官方手册 4.2.2 / iOS 4.7）
> 信息源标注：【官方】= OmniPlan 手册原文（经调研转述）；【推断】= 手册未明说；【Kairo 扩展】= 明确不与 OmniPlan 对等。
> **已裁定**：`formatVersion` 升 2（加法迁移，理由见 §7）。待用户确认项只剩两条，见 §11。

## 1. 目标

对当前排期拍一次**不可变快照**（基线），再用固定公式把「当前计划」与「实际执行」分别同基线比较，
输出带基线标识的天数偏差，落到大纲列、检查器、CLI 与 MCP。

## 2. 三层时间轴（硬约束）

| 层 | Kairo 字段 | 性质 | 消费方 |
| --- | --- | --- | --- |
| baseline（冻结） | `Baseline.entries[].start/finish` | 承诺快照，不可变 | 偏差计算（只读） |
| plan（预测） | 引擎 `scheduledStart / scheduledFinish` | 每编辑一次就重算 | 违例、关键路径、宽延、甘特条、偏差列 |
| actual（事实） | `actualStart` + `completedAt`（07） | 只由状态/进度或人工写 | 实际偏差、项目摘要 |

**照抄 OmniPlan 的两层会全线错位**：OmniPlan 的 Start/End 列本身就是 actual（自动排期与手填写同一字段，手册未区分），
而 Kairo 的 `scheduledStart` 是**预测**、违例与关键路径都建在它上面。把 plan 改叫 actual，等于让违例引擎读事实层。
因此三层各自独立、单向只读：基线不回流排期，实际时间不进 CPM。

## 3. 数据模型

```swift
// KairoCore/Model/Baseline.swift（新文件）
public struct Baseline: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String          // 默认「基线 N · yyyy-MM-dd」（官方默认名为今日日期）
    public var createdAt: Date       // 快照时刻，不可变
    public var anchor: Date?         // 快照时的排期锚点（D-029 口径），用于解释偏差来源
    public var entries: [BaselineEntry]
}

public struct BaselineEntry: Codable, Hashable, Sendable {
    public var taskID: UUID
    public var start: Date           // 基线计划开始（= 当时 scheduledStart）
    public var finish: Date          // 基线计划结束（排他端点 = 当时 scheduledFinish）
    public var progress: Double      // 快照时完成度
    public var isMilestone: Bool     // 里程碑标记（零时长，start == finish）
}
```

- 条目字段固定为调研建议口径 `(taskID, start, finish, progress, isMilestone)`：不存 title / outlineNumber / parentID / durationDays——
  标题用「已删除」占位（§5），工期由排他端点派生（`finish − start`），条目瘦身直接决定体积（§6）。
- `Baseline.colorIndex: Int?`（**v0.14 追加，可选字段，不升 formatVersion**）：调色板索引 0…7，供甘特图多基线叠加按颜色区分；缺失时按创建顺序由 `BaselinePalette.resolve` 派生（[10-multi-baseline-gantt.md](10-multi-baseline-gantt.md) §4 / §7）。**取代**本节原先「基线无颜色属性」的表述。
- **禁止**在 `TaskItem` 上加 `baselineStart/baselineEnd`：单值只能承载一份基线，与「多基线 + 切换对比」冲突；偏差是「所选基线 × 任务」的**派生量，不落盘**。
- 群组任务同样入条目，时间取聚合值（与 `PlanRow` 同口径）；偏差按自身条目比较，不由子任务求和推导。
- 未排期任务（`scheduledStart/Finish == nil`）**不入条目**：没有时间可比较，入表只会制造 0 偏差假象。
- **依赖边与资源不基线化**：一期只快照时间与进度（调研 §5.2「语义蔓延」缓解）。
- 项目级：`Project.baselines: [Baseline]`（有序，索引即创建顺序），不参与撤销栈之外的特殊处理——`createBaseline` 进撤销栈。
## 4. 偏差口径

### 4.1 输入与符号

| 符号 | 来源 | 说明 |
| --- | --- | --- |
| B.start / B.finish | 基线条目 | 承诺 |
| P.start / P.finish | 当前排期 `scheduledStart/Finish` | 预测 |
| A.start / A.finish | `actualStart` / `completedAt`（07） | 事实 |

符号约定：**偏差 = 后者 − 基线**，单位日历天（`Calendar` 整日相减，禁止 `86_400` 秒除 —— D-023 教训），
正数 = 比承诺晚、负数 = 提前；**空缺一律 `nil`，不写 0**。

### 4.2 最小集（一期只做这些）

按调研结论，OmniPlan 只有 Planned Start / Start Variance / Planned End / End Variance，**没有工期偏差列**。一期与官方对齐：

| 指标 | 公式 | 展示位置 |
| --- | --- | --- |
| 基线开始 `baselineStart` | `B.start` | 大纲列 |
| 开始偏差 `startVariance` | `dayOffset(B.start → <对比层>.start)` | 大纲列 |
| 基线结束 `baselineFinish` | `B.finish` | 大纲列 |
| 结束偏差 `finishVariance` | `dayOffset(B.finish → <对比层>.finish)` | 大纲列（主指标） |
| 实际结束偏差 `actualFinishVariance` | `dayOffset(B.finish → A.finish)` | 检查器 |
| 逾期天数 `overdueDays` | `max(0, dayOffset(B.finish → today))`，仅未完成 | 检查器 / 摘要 |

### 4.3 对比层与 actual 缺失回落

- **大纲列默认对比 plan**（`<对比层> = P`），列头写「计划偏差」——Kairo 的 plan 是预测层，绝大多数任务没有实际时间；
  这是与 OmniPlan「Variance = actual − baseline」的**有意差异**（【Kairo 扩展】），列头文案必须显式区分。
- **检查器同时给两层**：计划偏差（P vs B）与实际偏差（A vs B）。`A` 为空时实际偏差为 `nil`，
  检查器显示「尚未开始 / 尚未结束」，**不回落成 0，也不拿 plan 冒充 actual**。
- 项目级摘要：任务缺 actual 时用 plan 参与汇总，并在摘要行标注「含预测项 N 个」——回落必须**可见**，不能静默。
- `A.finish` 有值但 `A.start` 为空（pending → done 直跳，07 §3）：`actualStart` 侧为 `nil`，不臆造。
- 工期偏差 `durationVariance` 与完成度偏差 `progressVariance`：**一期不做**，列入 v0.15 候选（§10）。

### 4.4 聚合

- 群组用自身条目；项目级给「项目结束偏差 = 最晚 P.finish − 最晚 B.finish」+「晚完成任务数 / 逾期未完成数 / 无基线任务数 / 已删除任务数」。
- 平均值不跨群组重复计入子任务（只按叶子聚合，群组自身的条目仅用于展示）。

### 4.5 偏差必须带基线标识

任何偏差输出（UI 列头提示、CLI、MCP、CSV）都必须携带 `baselineID` + `baselineName` + `createdAt`：
切换对比基线会让所有数值整体变化（【官方】），不带标识的报表跨版本不可比。

## 5. 孤儿与无基线任务

| 情形 | 判定 | 大纲 | 检查器 | 基线面板 |
| --- | --- | --- | --- | --- |
| 有基线条目 | `baseline.entries` 含该 `taskID` | 正常显示偏差列 | 基线段（承诺起止 + 偏差） | 计入统计 |
| 基线后新增 | 任务存在但条目缺失 → 标 `hasBaseline = false` | 偏差列显示 —，悬停「基线之后新增」 | 「基线之后新增，无基线数据」 | 单列计数，不计入平均与最晚结束 |
| 孤儿 | 条目存在但任务已删（按 `taskID` 匹配缺失） | **不出现**（任务行已不存在） | 不适用 | 「已删除的基线任务：N 个」，可展开只读看 `start/finish`，**不消失** |

理由：大纲行集合必须与任务树一致（ADR-013 行索引契约），孤儿不能凭空插行；但基线面板必须让用户看到「这条承诺对应的任务已不存在」，
而不是让条目静默消失（调研：OmniPlan 4.x 对孤儿无任何说明，Kairo 要求显式呈现）。
## 6. 存储形态（已裁定：方案 A）

> **裁定记录（2026-10-25，用户）**：采用**方案 A · 顶级 `baselines` 数组**。理由：单文件承诺不变、CLI/MCP 零改动可读、一条基线一块连续 JSON 对 git diff 最友好。
> **实测（v0.13，2026-10-25）**：5,000 任务 × 5 基线 = 7.31 MB（无基线 1.80 MB，基线净增 5.51 MB，**231 B/条目**，比估算 180 B 高 63%，主因 prettyPrinted + ISO8601 + UUID）；encode 0.205 s / decode 0.234 s / variance 0.183 s（debug，**单次运行样本、与机器负载相关**；全量并发下常见 0.2–0.45 s，最挤 0.63 s），远低于 1 s 门槛；体积为确定值。估算已按实测校正。

### 方案 A · 内嵌快照数组（推荐）

```jsonc
{ "formatVersion": 2, "project": { … }, "tasks": [ … ], "resources": [ … ],
  "baselines": [ { "id": "…", "name": "基线 1 · 2026-10-25", "createdAt": "…", "anchor": "…",
                   "entries": [ { "taskID": "…", "start": "…", "finish": "…", "progress": 0.5, "isMilestone": false } ] } ] }
```

- 落在**顶级 `baselines`**（与 `tasks` 平级），不塞进 `project` 节点：`ProjectMetadata` 的语义是标量元数据（标题/时间戳/窗口），塞数组会让它变成半个项目容器。
  JSON 消费者无差别（都在同一文件），但 Swift 侧 `Project.baselines` 与 `metadata` 分层干净。
- 条目字段 5 个（§3），单条目 pretty 实测 **231 B**：1,000 任务 ≈ 231 KB/基线，5,000 任务 ≈ 1.1 MB/基线；5 基线 × 5,000 任务 ≈ **5.5 MB**（v0.13 已实测，见上方裁定记录；NFR 是 5,000 任务 ≤ 1 s 读写，实测 0.205 s / 0.234 s）。

### 方案 B · 独立 sidecar 文件（`<name>.kairo.baselines.json`）

主文件零增长、单基线文件小巧。代价：破坏「一个 .kairo 就是全部内容」（ADR-003），MCP/CLI 只给主文件时基线静默消失；
分享/云同步要带两个文件；两份文件的一致性与原子性要另写机制。删除/多基线操作反而更脆（要跨文件同步）。

### 方案 C · 单文件内规范化快照表

`baselines: [{id,name,createdAt}]` + `baselineEntries: [{baselineID, taskID, start, finish, progress, isMilestone}]` 扁平表。
体积略小（`taskID` 等键名不复用不省，主要省嵌套括号）；增删一条基线会改动大段 entries 数组 → **git diff 噪音更大**，
读取需按 `baselineID` 分组 join，代码复杂度上升。适合将来做「跨基线条目复用/压缩」，不适合一期。

| 维度 | A 内嵌数组 | B sidecar | C 规范化表 |
| --- | --- | --- | --- |
| 体积 | 中（**实测 231 B/条目**，原估算 180 B） | 主文件 0，总量同 A | 中（略小于 A） |
| git diff 友好（ADR-003） | **好**：一条基线一个连续块，新增只加块 | 差：基线变成另一文件，评审要开两个文件 | 差：entries 扁平混排，删一条基线动大段 |
| 旧版本行为 | 升 v2 后旧版本**拒开**（明确报错） | 旧版本能开主文件但看不到基线（静默缺功能） | 同 A |
| 删除 / 多基线 | **简单**：数组删元素 | 跨文件同步，复杂 | 需同时改两处 |
| MCP/CLI | 零改动可读 | 需新增文件参数 | 同 A |

**推荐 A**。若 v0.13 实测 5,000 任务 × 5 基线超 1 s，退化路径是 A-b（条目时间改存「相对 `anchor` 的整数天」），不是 B/C。
## 7. 迁移与兼容（已裁定：升 formatVersion 2）

### 7.1 为什么必须升 2

读路径对「高于当前版本」的文件直接抛 `KairoFileError.unsupportedFormatVersion` 且**不读取内容**（`Sources/KairoCore/Storage/KairoFile.swift`）。
所以升 2 之后，旧客户端打开 v2 文件**明确报错拒绝**，而不是静默丢基线；真正会静默丢数据的是「不升版本只加未知字段」——v1 客户端读得进、保存时 `Envelope` 只写 `formatVersion/project/tasks/resources` 四个键，`baselines` 被整块抹掉。
结论：**升 2 是数据安全的选择**，代价是「旧版本打不开新文件」，必须在发版说明与错误文案里讲清楚。

### 7.2 迁移步骤（纯加法）

```swift
public struct BaselineFormatV2Migration: FormatMigration {
    public var toVersion: Int { 2 }
    public func migrate(_ document: inout FormatDocument) throws {
        // 只改版本号，不重建根节点：未知键与既有字段原样保留（ADR-011）。
        // baselines 缺失即合法（= 空），由 Envelope 的 decodeIfPresent ?? [] 兜底。
        document.formatVersion = 2
    }
}
public static let standard = FormatMigrationPlan([BaselineFormatV2Migration()])   // KairoFile.currentFormatVersion = 2
```

- **不**把 `document.root` 解成强类型再写回（会丢未知键）；迁移只碰 `formatVersion`。
- `Envelope` 增 `baselines: [Baseline]`，解码 `decodeIfPresent ?? []`，编码按 §7.3 决定是否省略。

### 7.3 打开 / 保存策略

| 动作 | 行为 |
| --- | --- |
| 打开 v1 文件 | 内存内迁移 1→2，`sourceFormatVersion = 1` → `needsFormatUpgrade = true`，UI/CLI 提示「保存后升级为 v2」；**打开不落盘**（沿用现状） |
| 首次保存 | 写 v2；App 在保存成功后提示「本文件已升级为格式 v2，旧版本 Kairo 无法再打开」 |
| 打开 v2 文件 | 直读，`needsFormatUpgrade = false` |
| 写出策略（结论） | **无基线 → 省略 `baselines` 键**；有基线才写。理由：大多数项目没有基线，凭空写 `"baselines": []` 只是给 diff 加噪音；「缺省 = 空」已在解码层定义。`resources` 保持既有「无条件写」，不顺手改 |

### 7.4 版本闸门矩阵

| 文件 \ 客户端 | 新客户端（v0.13+，支持 2） | 旧客户端（≤ v0.12，支持 1） |
| --- | --- | --- |
| v1 文件 | 直读 + 内存迁移；保存后变 v2 | 直读（基线功能不存在） |
| v2 无基线 | 直读 | **拒绝打开**：`unsupportedFormatVersion(2)` |
| v2 有基线 | 直读 | **拒绝打开**：同上 |

错误文案要求（v0.13 实现）：保留稳定错误码 `storage_unsupported_format`，文案追加可操作指引——「此文件由更新版本的 Kairo 保存（格式 v2），请升级 Kairo 后再打开」；CLI 与 App 打开失败提示同源改文案。

### 7.5 回滚与备份（结论：不做自动备份）

- 回到旧版本：只要**未保存**，v1 文件始终是 v1（开放不改盘）；保存成 v2 后旧版本无法打开，这是升版本的既定代价。
- **不写 `.kairo.v1.bak` 自动备份**：① 迁移纯加法、不丢字段，往返可逆；② 每次打开都生成备份会产生垃圾文件，且极易被误提交/误同步；③ 用户侧已有 git 与历史版本兜底。
- 若用户坚持要强保护，退化方案是「首次升级保存前同目录写一次 `.kairo.v1.bak`，且仅写一次（存在即跳过）」——列入 §11 待确认。

### 7.6 测试清单（v0.13 门禁）

1. v1 fixture（无 `baselines`）→ 打开：`sourceFormatVersion == 1`、`baselines == []`、`needsFormatUpgrade == true`。
2. 同一 fixture 保存 → 文件 `formatVersion == 2` 且**无 `baselines` 键**（省略策略）；再读回，metadata/tasks/resources 逐字段相等。
3. v2 fixture（2 条基线 + 1 条孤儿条目）→ 读 → 写 → 读，基线 `id/name/createdAt/entries` 逐字段相等。
4. 未来版本 fixture（`formatVersion: 3`）→ 抛 `unsupportedFormatVersion(3)`，磁盘文件未被修改。
5. 迁移层：v1 根节点塞入未知键 `"futureThing": {…}` → `migrate(1→2)` 后 `document.root` 仍含该键（证明迁移不重建根节点）。
6. v1 缺 `resources` 与缺 `baselines` 同时出现 → 不报错，均回落默认值。

> **口径说明**：保存路径是从模型重编码，未知根键在「打开 → 保存」后**不保留**（现状，ADR-011 只保证读不报错）。
> 若要「保存也保留未知键」，需在 `Envelope` 做 raw 透传（约 +80 行 + 用例），本期列为非目标（§10）；故第 5 条断言落在**迁移层**而非保存层。

> 同版必须一起更新：`docs/02-architecture.md` 的格式契约段、`kairo --version` / `project_save` 的 `formatVersion` 输出说明、CHANGELOG「格式版本 1 → 2，旧版本无法打开新文件」。
## 8. 接口契约

```swift
// KairoCore — 日算术上移（避免第二份实现，D-024 教训）
public enum CalendarDayMath { public static func dayOffset(from: Date, to: Date, calendar: Calendar) -> Int }
// KairoPresentation/ScheduleDateMath.dayOffset 改为转发，既有调用点签名不变

// KairoCore — 偏差（纯函数：无 I/O、无全局时钟）
public struct TaskVariance: Hashable, Sendable {
    public var taskID: UUID
    public var baselineStart: Date?;      public var baselineFinish: Date?
    public var planStartVariance: Int?;   public var planFinishVariance: Int?
    public var actualStartVariance: Int?; public var actualFinishVariance: Int?
    public var overdueDays: Int?
    public var hasBaseline: Bool
}
public struct BaselineVarianceReport: Hashable, Sendable {
    public var baselineID: UUID; public var baselineName: String; public var baselineCreatedAt: Date
    public var tasks: [UUID: TaskVariance]          // 含全部当前任务；基线后新增的也在此，hasBaseline == false 且偏差全 nil（判据 §9-7 口径，不按「只含有条目的任务」裁剪）
    public var orphans: [BaselineEntry]             // 条目在、任务已删
    public var projectFinishVariance: Int?          // 最晚 P.finish − 最晚 B.finish
    public var lateTaskCount: Int; public var overdueOpenCount: Int
    public var tasksWithoutBaseline: Int; public var predictedTaskCount: Int
}
public enum BaselineEngine {
    public static func snapshot(tasks: [TaskItem], schedules: [UUID: ScheduledTask], name: String,
                                anchor: Date?, now: Date) -> Baseline
    public static func variance(baseline: Baseline, tasks: [TaskItem], schedules: [UUID: ScheduledTask],
                                now: Date, calendar: Calendar) -> BaselineVarianceReport
}

// KairoCommands — KairoSession（唯一写入口；**没有** update 条目入口）
@discardableResult public func createBaseline(name: String? = nil, now: Date = Date()) throws -> Baseline
@discardableResult public func renameBaseline(id: UUID, name: String) throws -> Baseline
@discardableResult public func deleteBaseline(id: UUID) throws
public func baselines() throws -> [Baseline]
public func baselineVariance(baselineID: UUID? = nil) throws -> BaselineVarianceReport   // nil = 最新

// KairoPresentation — 快照与动作
public struct PlanRow { public var baselineStart: Date?; public var baselineFinish: Date?
                        public var planStartVariance: Int?; public var planFinishVariance: Int?
                        public var hasBaseline: Bool }
public struct TaskInspector { public var baseline: BaselineSection? }   // nil = 无基线 / 基线后新增
public struct BaselineSection { public var baselineID: UUID; public var name: String
                                public var start: Date; public var finish: Date
                                public var planFinishVariance: Int?; public var actualFinishVariance: Int?
                                public var overdueDays: Int? }
public enum OutlineColumn { case baselineStart, baselineFinish, startVariance, finishVariance }
// 四列均为可选列、默认隐藏，复用 07 的 OutlineColumnPreferences.optional 机制
case setBaseline(UUID?)      // 视图状态：nil = 不比较
case createBaseline(String?)
case deleteBaseline(UUID)
```

- **「当前基线」是视图状态**：`WorkspaceViewState.selectedBaselineID: UUID?` → UserDefaults，不进撤销栈、不进基线快照、不写 `.kairo`。
- CLI：`kairo baseline list | create [--name] | delete <id> | variance [--baseline <id>] [--task <id>] | color <id 或唯一前缀> <0…7>`；输出必须带 `baselineID` 与名称，**并带 `colorIndex`**（缺失时按 `BaselinePalette.resolve` 派生，不写 0 冒充）；`task get` 增「基线」段。
- MCP：`baseline_create / baseline_list / baseline_delete / baseline_variance / baseline_set_color`（`baselineID` 可选，缺省最新）；五处返回均含 `baselineID`、名称与 **`colorIndex`**；越界索引返回稳定细码 `model_baseline_color_index_invalid`（工具总数 20 → 21，逐字等值清单断言已同步）。
- **甘特显示（v0.14 重写，取代本节原「四档 `GanttBaselineMode` + 单基线灰条」方案）**：改为**多基线行内分轨叠加**——1–3 条基线各占 28pt 行内的一条下轨，按 `colorIndex` 上色，几何由 `BaselineLanes` 纯函数给出，`GanttBar` 几何零改动。详见 [10-multi-baseline-gantt.md](10-multi-baseline-gantt.md)。`GanttBaselineMode`（仅实际 / 仅基线 / 双日程 / 分割）**不再作为 v0.14 的实现载体**，其中「仅基线 / 分割」仍是 v0.15+ 候选。
## 9. 判据清单

1. 创建基线：条目数 = 已排期任务数；默认名含日期与序号；`createdAt` 取注入时钟。
2. 不可变：无 API 能改既有条目；`rename` 只改名字；`delete` 后其余基线不受影响；再拍一份是新增而不是覆盖。
3. 偏差公式：`B.finish = 11-05`、`P.finish = 11-08` → `planFinishVariance == 3`；提前一天 → `−1`；空值 → `nil`（不是 0）。
4. 跨 DST（America/New_York 11-02 回拨）：同公式不产生 ±1 天漂移。
5. actual 缺失：`actualFinishVariance == nil` 且 `overdueDays` 有值；完成后 `overdueDays == nil`。
6. 偏差输出必带 `baselineID/name/createdAt`（UI 列头提示、CLI、MCP 逐项检查）。
7. 基线后新增：`hasBaseline == false`，偏差列 `—`，计入 `tasksWithoutBaseline`，不计入项目偏差。
8. 删除任务后：进 `orphans`，大纲行集合不变，项目偏差不含它，基线面板可见「已删除」。
9. 群组：偏差取自身条目聚合值，不等于子任务偏差之和。
10. 切换基线（`setBaseline`）只改视图状态：不产生撤销点、不置脏、不写文件。
11. 格式版本：§7.6 六条迁移/兼容用例全绿；`needsFormatUpgrade` 在 v1 文件上为 true、v2 为 false。
12. CLI 与 MCP 的偏差数值与 `BaselineEngine.variance` 逐字段一致（对等性门禁）。

## 10. 非目标

- 工期偏差 / 完成度偏差 / 挣值（SV/SPI/CV/CPI/BCWP/ACWP）、Monte Carlo。
- 甘特的「仅基线」「分割」两档模式（枚举先定义，v0.15+ 再做）。
- 基线间对比（基线 A vs B）、依赖边与资源的基线化。
- 自动基线（每日/每次保存快照）、基线云同步、变更审批留痕（PMBOK 口径，单人工具不实现）。
- 保存时透传未知根键（需 `Envelope` raw 透传，见 §7.6 口径说明）。
- 基线导出/报表与孤儿标题回溯（条目刻意不存 title）。

## 11. 已裁定（2026-10-25，用户）

| 事项 | 裁定 | 影响 |
| --- | --- | --- |
| 格式版本 | 升 **2**（加法迁移） | 旧版本打开 v2 文件明确拒开（`unsupportedFormatVersion`），不是静默丢数据 |
| 存储形态 | **方案 A**：顶级 `baselines` 数组（§6） | 单文件承诺不变，CLI/MCP 零改动可读 |
| 基线删除 | **允许删除，删除前二次确认** | 无软删除、无审批留痕（与 OmniPlan 一致） |
| 大纲基线列 | 四列（基线开始/基线结束/开始偏差/结束偏差）**全部默认隐藏** | 走列菜单按需打开，不动现有布局 |
| 孤儿 / 基线后新增 | **大纲不插行**，收进基线面板 + 计数 | 不破坏 ADR-013 行索引契约 |
| `.kairo.v1.bak` 备份 | **不做**（§7.5） | 打开不落盘、保存为原子写，备份只会制造第二份真相 |
| 未知根键保存透传 | **非目标**（§7.6） | 断言只落在迁移层；不扩 `Envelope` raw 透传 |
| 条目记 `progress` | 记（§3） | 支撑完成度偏差，+1 字段/条 |
| 基线数量上限 | 不设硬上限 | 体积由 v0.13 实测把关 |
| 基线颜色 | `colorIndex` 0…7，创建时取最小未用索引（v0.14） | 存索引不存色值；删除其他基线不串色（10 §4） |
| 甘特同屏显示条数 | 默认 3 条（保守 / 基准 / 激进） | 超出在菜单提示「另有 N 条未显示」（10 §5 / §6） |

> 至此 08 无待确认项，v0.13 可开工。

## 12. 需修正的既有文档（规格冲突，随 v0.13 一并改）

| 文档 | 现状（冲突点） | 应改为 |
| --- | --- | --- |
| F-14-16 基线衡量进度 | 「`Project.baselines: [Baseline]` + 写回 `TaskItem.baselineStart/baselineEnd`」 | 删掉「写回任务字段」，改为「偏差为派生量，按所选基线 × 任务实时计算」 |
| F-13-09 基线差异栏位 | 「`TaskItem` 增加 `baselineStart/baselineEnd: Date?`（由快照写入）」 | 改为快照条目派生；差异列文案区分「计划偏差 / 实际偏差」 |
| F-22-05 基线 | 「`TaskItem` 增加 `baselineStartDate/baselineDueDate`」+「差异 = 实际 − 基线」（缺 actual 时口径未定） | 同上；补「actual 缺失 → 显示 nil，摘要回落 plan 并标注预测项」 |
| PRD US-E2-06 | 验收标准未含 `baselineID` | 补「查询返回所用基线标识」；补孤儿与基线后新增两条边界 |
| 02-architecture 格式契约 | 仅描述 v1 根结构 | 补 v2：`baselines` 可选键、`formatVersion = 2`、旧版本拒开新文件的语义 |
## 13. 改动清单与并行分组（v0.13.0 实现用）

| 组 | 文件范围（互斥） | 前置 |
| --- | --- | --- |
| A core | `Sources/KairoCore/Model/Baseline.swift`（新）、`Sources/KairoCore/Schedule/BaselineEngine.swift`（新）、`Sources/KairoCore/CalendarDayMath.swift`（新）、`Tests/KairoCoreTests/BaselineVarianceTests.swift`（新） | 07 已合入 |
| B storage | `Sources/KairoCore/Storage/KairoFile.swift`、`Sources/KairoCore/Storage/FormatMigration.swift`、`Tests/KairoCoreTests/FormatMigrationTests.swift`、`Tests/Fixtures/`（v1/v2 fixture） | A |
| C cmds | `Sources/KairoCommands/KairoSession.swift`、`Tests/KairoCoreTests/SessionBaselineTests.swift`（新） | A + B |
| D pres | `Sources/KairoPresentation/Snapshots.swift`、`OutlineColumnPreferences.swift`、`InspectorSnapshots.swift`、`WorkspaceAction.swift`、`ViewState.swift`、`Presenter.swift`、`ScheduleDateMath.swift`（改转发）、`Tests/KairoPresentationTests/BaselinePresentationTests.swift`（新） | A |
| E cli | `Sources/KairoCLI/CLIRouter.swift`、`Sources/KairoCLI/CLIStrings.swift`、`Tests/InterfaceTests/CLITests.swift` | C |
| F mcp | `Sources/KairoMCP/Tools.swift`、`Tests/InterfaceTests/InterfaceTests.swift` | C |
| G app | `Apps/macos/Sources/WorkspaceStore.swift`、`Workspace/WorkspaceView.swift`、`Workspace/Outline/OutlineTable.swift`、`Workspace/Inspector/InspectorView.swift`、`Workspace/Display.swift`、`Apps/macos/Resources/Localizable.xcstrings` | D |

- 波次 1：A。波次 2：**B / D 并行**（core 与 presentation 文件不重叠）。波次 3：C（需 B 的版本号与迁移就绪）。波次 4：**E / F / G 并行**。
- 存储方案（§11 第 1 条）未定前，B 组只可动迁移与版本号，不可动 `baselines` 键的落地写法。
- E 与 F 必须复用 `BaselineEngine` 的数值，禁止各自再算一遍（对等性门禁）。
