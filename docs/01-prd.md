# Kairo 产品需求文档（PRD）

> 版本 0.1 · 2026-10-17 · 状态：已接受（Sprint 0 产出）
> 上游依据：[00-vision.md](00-vision.md)（愿景与章程）、[FEATURE-BREAKDOWN.md](FEATURE-BREAKDOWN.md)（175 条功能规格）、[04-glossary.md](features/04-glossary.md)（术语基准）
> 术语纪律：全文遵循 [04-glossary.md](features/04-glossary.md) 的 Kairo 定名——「相关性」即任务间依赖关系，「重要路径」即关键路径，「投入」与「持续时间」不得混用。

## 1. 用户画像

Kairo 的第一公民是程序化接口，人是审阅者。三类用户按操作频次与场景划分。

### 1.1 AI 编码智能体（主要操作者）

- **身份**：Claude Code、Codex 等编码智能体，通过 MCP 或 CLI 程序化操作 Kairo。
- **目标**：把复杂项目拆解为可执行的工作分解结构（WBS），按相关性与日历排期，逐任务开发并回写状态，全程无需人工点界面。
- **痛点**：
  - 跨会话的任务树、排期、进度状态散落在对话上下文与临时 Markdown，无法被下一次会话可靠恢复；
  - 手写清单没有相关性计算、进度聚合、违例检测，AI 无法判断「现在该做哪一步」「是否偏离计划」；
  - 现有项目管理软件面向「人点界面」，无程序化接口，AI 无法直接读写。
- **使用方式**：MCP 工具调用（一等公民）为主，CLI 为辅。闭环节奏：读取需求 → 建任务树 → 排期 → 逐任务开发 → 回写状态 → 生成周报。

### 1.2 独立开发者 / 人的审阅者

- **身份**：独立开发者或技术负责人，用 macOS 应用查看与干预。
- **目标**：随时查看全局进度、审阅 AI 生成的 WBS 与排期、修正错误、做人的决策。
- **痛点**：AI 建的任务树可能结构不合理、排期违背现实约束（资源冲突、时限冲突），需要人工校验；需要快照与差异对比来回答「比计划超前还是落后」。
- **使用方式**：macOS SwiftUI 应用（任务列表 / 甘特视图 / 检查器 / 过滤器 / 命令面板），键盘优先；通过 `kairo://` 深链从外部直达任务。

### 1.3 未来的移动端查看者

- **身份**：需要在路上查看项目状态的用户。
- **目标**：只读查看任务、进度、排期与状态摘要。
- **使用方式**：移动端（iOS/Android）读取 `.kairo` 文件或通过接口层查询，不承载编辑主力场景（vision §5.4）。
- **范围边界**：本期不做移动端（vision §6「不做」），但接口层与 `.kairo` 格式为它预留读取能力。

## 2. 核心用户故事（Epic → Story）

主线是 AI 闭环（vision §3）。每个 Story 的验收标准为 Given/When/Then 风格，原子可独立判定。

### E1 WBS 摄入（AI 读需求建任务树）

#### US-E1-01 新建项目
- **用户故事**：作为 AI 智能体，我可以创建带项目设置的新项目，以便设定排程方向、排程间隔与起止日期。
- **验收标准**：
  - Given 尚未打开任何项目，When 调用新建项目并给出标题，Then 返回新项目 ID，且项目以空任务列表打开。
  - Given 新建项目时提供方向为「向前排程」、排程间隔为「日」，When 打开该项目，Then 项目设置中保存这两项值并作用于后续排期。
- **对应规格**：[F-11-01](features/01-views-editing.md)（继承）、[F-11-03](features/01-views-editing.md)（继承）、[F-20-02](features/02-inspectors-scheduling.md)（方向部分）。

#### US-E1-02 单任务创建、更新与删除
- **用户故事**：作为 AI 智能体，我可以在项目中创建、更新、删除单个任务，以便逐项录入 WBS。
- **验收标准**：
  - Given 存在已打开的项目，When 创建任务并给出标题，Then 返回新任务 ID，且该任务出现在任务列表。
  - Given 存在任务 A，When 更新其标题、状态、优先级、进度或截止日期中的任一字段，Then 该字段变为新值，其余字段不变。
  - Given 存在任务 A，When 删除任务 A，Then 任务 A 从列表消失，且指向或源自 A 的相关性一并移除。
- **对应规格**：[F-12-08](features/01-views-editing.md)、[F-13-01](features/01-views-editing.md)、[F-13-06](features/01-views-editing.md)。**现有 MVP 已具备，本 Story 视为完成**（`Project.add/update/remove`、`TaskItem`）。

#### US-E1-03 层级任务树（群组 / 子任务 / 里程碑）
- **用户故事**：作为 AI 智能体，我可以建立层级任务树——群组、子任务与里程碑，以便 WBS 有正确的父子结构与标记点。
- **验收标准**：
  - Given 存在任务 A，When 在 A 下创建子任务 B，Then B 的父任务为 A，且 A 的 kind 变为「群组」。
  - Given 存在任务 M，When 将其 kind 设为「里程碑」，Then M 的持续时间与投入恒为 0，不参与时长计算。
  - Given 存在群组 G 与若干子任务，When 查询 G 的投入，Then 返回各子任务投入之和。
  - Given 存在任务 A 与任务 B，When 创建「群组」并把 A、B 移入，Then A、B 的父任务指向新群组。
- **对应规格**：[F-14-03](features/01-views-editing.md)、[F-14-04](features/01-views-editing.md)、[F-13-03](features/01-views-editing.md)、[F-22-01](features/02-inspectors-scheduling.md)。

#### US-E1-04 批量导入任务树（结构化 WBS）
- **用户故事**：作为 AI 智能体，我可以一次导入结构化 WBS（JSON 或缩进大纲文本），以便把整棵任务树批量录入，而非逐条创建。
- **验收标准**：
  - Given 提供一份嵌套任务节点清单（含标题、kind、子节点），When 调用批量导入，Then 返回生成的完整任务树，父子关系与层级编号正确。
  - Given 导入节点带「投入」与「持续时间」字段，When 导入完成，Then 对应任务保存这两个字段。
  - Given 导入发生字段缺失或名称无法映射，When 导入结束，Then 返回保真报告，列出跳过的字段与警告。
- **对应规格**：AI 场景新增，参考 [F-32-02](features/03-platform-collab.md)（Markdown 大纲导入思路，由 P3 提前为本 Story 的输入形态）。

#### US-E1-05 任务信息完整化（类型 / 投入 / 持续时间 / 富备注）
- **用户故事**：作为 AI 智能体，我可以为任务设置类型、投入、持续时间与富备注（文本 + 链接），以便排期引擎有足够输入。
- **验收标准**：
  - Given 存在任务 A，When 设置其投入为 8 小时、无分配资源，Then A 的持续时间按工作日历换算为对应工作时长。
  - Given 存在任务 A 与人员资源 R（效率 100%），When 把 R 以 100% 单位分配给 A 且投入 8 小时，Then A 的持续时间为 8 小时（`duration = effort / Σ(units×efficiency)`）。
  - Given 任务的备注包含一个 URL，When 打开备注，Then 该链接可点击并唤起对应应用。
- **对应规格**：[F-22-01](features/02-inspectors-scheduling.md)、[F-22-03](features/02-inspectors-scheduling.md)、[F-20-05](features/02-inspectors-scheduling.md)、[F-25-01](features/02-inspectors-scheduling.md)。

### E2 排期（相关性 / 日历 / 时间线计算）

#### US-E2-01 相关性模型（FS / FF / SS / SF + 前导时间）
- **用户故事**：作为 AI 智能体，我可以建立带类型的相关性（FS/FF/SS/SF）与前导时间，以便精确表达任务间的时序约束。
- **验收标准**：
  - Given 任务 B 存在「完成到开始（FS）」相关性指向 A，When 计算排期，Then B 的开始不早于 A 的结束（允许正负前导时间）。
  - Given 相关性带 1 日前导时间（SS 类型），When 计算排期，Then 后继任务的开始不早于前驱开始 + 1 日。
  - Given 现有旧数据中相关性的类型缺失，When 读取项目，Then 该相关性按 FS、无前导时间解释（迁移兼容）。
- **对应规格**：[F-22-06](features/02-inspectors-scheduling.md)、[F-22-07](features/02-inspectors-scheduling.md)。`TaskItem.dependencies: [UUID]` 重构为 `[TaskDependency]`。

#### US-E2-02 排期计算（相关性传播 / 方向 / ASAP-ALAP）
- **用户故事**：作为 AI 智能体，我可以触发排期计算，让引擎沿相关性与项目方向推导每个任务的最早/最晚时间。
- **验收标准**：
  - Given 项目方向为「向前排程」，When 计算排期，Then 各任务的最早开始时间满足全部相关性约束且不小于项目开始日期。
  - Given 存在「开始不早于」时限的任务，When 计算排期，Then 该任务的最早开始时间不小于时限值。
  - Given 任务被标记为「尽可能晚（ALAP）」，When 计算排期，Then 该任务的开始时间取满足约束的最晚值。
- **对应规格**：[F-11-02](features/01-views-editing.md)、[F-22-04](features/02-inspectors-scheduling.md)、[F-20-02](features/02-inspectors-scheduling.md)。

#### US-E2-03 重要路径与宽延
- **用户故事**：作为 AI 智能体，我可以查询重要路径与任务宽延，以便判断哪些任务决定项目总时长、可推迟多少。
- **验收标准**：
  - Given 一个含相关性链的项目，When 计算重要路径，Then 返回总宽延为 0 的任务集合，且覆盖决定项目总时长的完整链路。
  - Given 任务 T 有自由宽延 X，When 查询 T，Then 返回 T 的自由宽延与总宽延两个只读值。
  - Given 项目设置了重要路径宽延限制，When 生成重要路径集合，Then 总宽延 ≤ 该限制的任务均被纳入。
- **对应规格**：[F-14-15](features/01-views-editing.md)、[F-13-10](features/01-views-editing.md)、[F-21-01](features/02-inspectors-scheduling.md)、[F-21-03](features/02-inspectors-scheduling.md)。

#### US-E2-04 工作时数日历（项目级 / 资源级）
- **用户故事**：作为 AI 智能体，我可以设置项目级与资源级的工作时数日历，以便排期按真实可工作时间计算。
- **验收标准**：
  - Given 项目工作周为周一至周五每日 8 小时，When 对跨周末的任务计算持续时间，Then 周末不计入工作时长。
  - Given 资源 R 设置自定义工作日历，When 计算分配给 R 的任务，Then 使用 R 的日历而非项目默认日历。
  - Given 项目存在特定日期的例外（如 2026-11-05 休息），When 计算该日附近的排期，Then 该日不安排工作。
- **对应规格**：[F-16-08](features/01-views-editing.md)、[F-16-09](features/01-views-editing.md)、[F-20-05](features/02-inspectors-scheduling.md)。

#### US-E2-05 时限约束与基础违例检测
- **用户故事**：作为 AI 智能体，我可以为任务设置四类时限，并在排期后查询违例列表，以便发现计划中的逻辑矛盾。
- **验收标准**：
  - Given 任务 A 设置「开始不早于」时限，When 手动把 A 的开始日期改早于该时限，Then 引擎标记一条违例并给出原因。
  - Given 新增相关性后任务图出现环，When 添加该边，Then 引擎拒绝该边或停用环中一条边，并记录一条「相关性循环」违例。
  - Given 存在违例，When 调用违例列表，Then 返回每条违例的类型、涉及任务与建议处理方式。
- **对应规格**：[F-13-07](features/01-views-editing.md)、[F-30-01](features/02-inspectors-scheduling.md)、[F-30-03…14](features/02-inspectors-scheduling.md)（基础子集先行）。

#### US-E2-06 基线快照与差异
- **用户故事**：作为 AI 智能体，我可以对当前排期设置基线，并查询实际日程与基线的差异，以便衡量进度偏离。
- **验收标准**：
  - Given 当前项目已排期，When 设置基线，Then 生成带名称与快照时间的基线，保存全部任务的时间与进度。
  - Given 已设基线后某任务时间变更，When 查询该任务，Then 返回其计划（基线）时间、实际时间与两者差异。
- **对应规格**：[F-14-16](features/01-views-editing.md)、[F-12-17](features/01-views-editing.md)、[F-22-05](features/02-inspectors-scheduling.md)。

### E3 状态回写（AI 更新进度）

#### US-E3-01 单任务状态与进度回写
- **用户故事**：作为 AI 智能体，我在完成一个任务后回写其状态与进度，以便 Kairo 持续反映真实进度。
- **验收标准**：
  - Given 存在任务 A，When 把其状态置为「已完成」且进度置为 1，Then A 记录完成时间，且不再计入剩余投入。
  - Given 存在任务 A（进度 0.4），When 把进度更新为 0.6，Then A 的已完成投入、剩余投入随之更新。
  - Given 回写非法值（进度 > 1），When 调用更新，Then 引擎拒绝并返回参数错误。
- **对应规格**：[F-14-10](features/01-views-editing.md)、[F-12-06](features/01-views-editing.md)、[F-22-03](features/02-inspectors-scheduling.md)。

#### US-E3-02 批量回写与群组完成度聚合
- **用户故事**：作为 AI 智能体，我可以批量回写多个任务的状态，并让群组完成度按投入加权聚合，以便一次同步一批完成的子任务。
- **验收标准**：
  - Given 提供多个任务的状态/进度清单，When 批量回写，Then 每个任务按清单更新，返回成功与失败明细。
  - Given 群组 G 含子任务（投入分别为 2h 与 8h，前者已完成），When 查询 G 的完成度，Then 返回 20%（按投入加权，非按任务数）。
- **对应规格**：[F-12-06](features/01-views-editing.md)、[F-20-03](features/02-inspectors-scheduling.md)。

#### US-E3-03 重新安排未完成任务
- **用户故事**：作为 AI 智能体，我可以在项目滞后时把截至某日未完成的任务顺延，以便日程对齐现实。
- **验收标准**：
  - Given 任务 A 的截止日期已过且未完成，When 对 2026-11-20 执行重新安排，Then A 及其后继任务的开始时间顺延到该日期之后。
  - Given 重新安排，When 完成后，Then 已按时完成的任务时间不变。
- **对应规格**：[F-12-07](features/01-views-editing.md)、[F-14-11](features/01-views-editing.md)。

#### US-E3-04 字段级版本历史
- **用户故事**：作为 AI 智能体与审阅者，我可以回看任意字段的历史变更，以便回答「这个任务是什么时候改的、改了什么」。
- **验收标准**：
  - Given 对任务 A 的进度做过多次变更，When 查询版本历史，Then 返回按时间排序的变更记录（字段、旧值、新值、时间、来源）。
  - Given 一次误改，When 按版本历史撤销，Then 字段恢复到该次变更前的值。
- **对应规格**：[F-35-04](features/03-platform-collab.md)（AI 语义合并建议属远期，本 Story 只做字段级历史）。

#### US-E3-05 同步冲突的 AI 差异说明
- **用户故事**：作为审阅者，我使用云盘同步后遇到冲突副本，以便了解两份文件的差异并决定取舍。
- **验收标准**：
  - Given 存在两份内容不同的 `.kairo` 副本，When 进行差异分析，Then 返回字段级差异清单（同一任务哪些字段不同、新旧值）。
  - Given 两份副本对同一任务的不同字段有修改，When 生成合并建议，Then 建议保留不冲突的双方修改。
- **对应规格**：[F-34-03](features/03-platform-collab.md)。

### E4 人工审阅（macOS 应用查看 / 调整）

#### US-E4-01 任务列表与详情编辑
- **用户故事**：作为审阅者，我可以浏览任务列表并编辑单个任务的详情，以便审阅与修正。
- **验收标准**：
  - Given 打开 `.kairo` 项目，When 浏览任务列表，Then 显示标题、状态、优先级、标签、负责人、截止日期与进度。
  - Given 选中某任务，When 编辑标题/状态/优先级/进度/备注，Then 修改立即写回数据模型并自动保存。
  - Given 存在逾期任务，When 查看列表，Then 该任务以红色标识「已逾期」。
- **对应规格**：[F-13-01…04](features/01-views-editing.md)。**现有 MVP 已具备，本 Story 视为完成**（`ContentView` + `DetailPane`）。

#### US-E4-02 AI 过滤与查找
- **用户故事**：作为审阅者，我可以用自然语言过滤任务、用文本/正则查找内容，以便快速定位。
- **验收标准**：
  - Given 输入「逾期 紧急」，When 应用过滤，Then 只显示同时满足逾期与高优先级条件的任务。
  - Given 打开查找栏并输入文本，When 按 ⌘G 查找下一个，Then 命中项在列表中定位并高亮，到尾端自动回绕。
  - Given 启用正则模式并输入 `v\d+`，When 查找，Then 按正则匹配；输入非法正则时给出无效提示。
  - **升级项（待做，优先级 P1）**：过滤器可保存为具名过滤器并在打开项目后复用。
- **对应规格**：[F-12-04](features/01-views-editing.md)、[F-13-15](features/01-views-editing.md)。**基础能力现有 MVP 已具备（`AIFilterTranslator` + `FindController`），本 Story 基础部分视为完成**。

#### US-E4-03 层次树 / 大纲交互（缩进 / 群组 / 展开收合 / 键盘导航）
- **用户故事**：作为审阅者，我可以在大纲中缩进、建组、展开收合，并用键盘快速编辑，以便管理任务树结构。
- **验收标准**：
  - Given 选中任务 A，When 按 Tab，Then A 缩进为上一任务的子任务；按 Shift-Tab 则反向。
  - Given 选中任务 A，When 按 Return，Then 在 A 下方新建同级任务；A 为群组时新任务成为其子项。
  - Given 群组 G 处于收合状态，When 点击展开，Then 显示其全部子任务。
- **对应规格**：[F-14-02](features/01-views-editing.md)、[F-40-01](features/03-platform-collab.md)。

#### US-E4-04 甘特视图基础（任务条 / 日期标头 / 缩放）
- **用户故事**：作为审阅者，我可以按时间线查看任务条与日期标头，以便直观判断排期与重叠。
- **验收标准**：
  - Given 项目含起止日期，When 切换到甘特视图，Then 每个任务显示为时间轴上的任务条，位置由开始/结束日期决定。
  - Given 甘特视图，When 拖动日期标头或使用缩放菜单，Then 可见时间范围随之改变，可选「缩放以适合项目」。
  - Given 项目设置非工作时段，When 查看甘特，Then 非工作时段以背景色着色。
- **对应规格**：[F-14-01](features/01-views-editing.md)、[F-14-13](features/01-views-editing.md)、[F-14-14](features/01-views-editing.md)、[F-12-02](features/01-views-editing.md)（视图切换）。

#### US-E4-05 命令面板（⌘K）
- **用户故事**：作为审阅者，我可以按 ⌘K 打开命令面板模糊搜索并执行任意命令，以便键盘优先操作。
- **验收标准**：
  - Given 按下 ⌘K，When 打开命令面板，Then 列出全部命令并按名称模糊过滤。
  - Given 命令带快捷键，When 查看面板，Then 显示该快捷键；无快捷键的命令也可在面板中执行。
  - Given 菜单栏的每个命令，When 检查其来源，Then 均来自同一个命令注册表。
- **对应规格**：[F-41-01](features/03-platform-collab.md)。

#### US-E4-06 项目摘要面板
- **用户故事**：作为审阅者，我可以查看项目摘要（总持续时间、完成度、成本、与基线差异），以便一眼掌握全局。
- **验收标准**：
  - Given 项目含任务，When 打开摘要，Then 显示总持续时间、总完成百分比、总成本。
  - Given 已设基线，When 查看摘要，Then 显示实际结束日期与基线结束日期的差异。
- **对应规格**：[F-20-03](features/02-inspectors-scheduling.md)。

#### US-E4-07 检查器与违例面板
- **用户故事**：作为审阅者，我可以查看违例面板了解排期问题，以便决策干预。
- **验收标准**：
  - Given 项目存在违例，When 打开违例面板，Then 逐条列出违例的类型、涉及任务与原因。
  - Given 违例栏显示，When 任务存在违例，Then 该行出现违例图标并可点击打开面板。
- **对应规格**：[F-12-12](features/01-views-editing.md)、[F-30-01](features/02-inspectors-scheduling.md)。

### E5 接口层（MCP / CLI / 插件对等暴露）

#### US-E5-01 MCP 服务
- **用户故事**：作为 AI 智能体，我可以通过 MCP 工具读写项目——任务 CRUD、相关性、排期查询、状态回写、项目统计。
- **验收标准**：
  - Given MCP 服务已启动并连接，When 列出工具，Then 返回任务 CRUD、相关性、排期、状态、统计等全套工具（详见 02-architecture §3.1）。
  - Given 通过 MCP 创建任务，When 随后在 macOS 应用中查看，Then 该任务可见且字段一致。
  - Given MCP 工具调用出错（如任务不存在），When 调用，Then 返回结构化错误，不导致服务崩溃。
- **对应规格**：AI 场景新增。

#### US-E5-02 CLI
- **用户故事**：作为 AI 智能体或脚本，我可以用命令行完成与 MCP 对等的操作。
- **验收标准**：
  - Given 安装 `kairo` 命令，When 执行任务创建/列表/更新/删除、相关性、排期、状态、统计命令，Then 行为与 MCP 对应工具一致。
  - Given 命令输出，When 指定 JSON 格式，Then 输出可被脚本直接解析。
  - Given 命令失败，When 执行，Then 以非零退出码结束并在 stderr 给出原因。
- **对应规格**：AI 场景新增。

#### US-E5-03 Claude Code 插件
- **用户故事**：作为使用 Claude Code 的开发者，我可以用 `/kairo` 斜杠命令与 hooks 把任务管理接入开发会话。
- **验收标准**：
  - Given 项目目录配置 `.mcp.json` 指向 Kairo，When 会话启动，Then MCP 工具对 Claude Code 可用。
  - Given 斜杠命令 `/kairo plan`，When 执行，Then 提示词引导 AI 读需求、建 WBS 并排期。
  - Given hook 配置了任务完成触发，When 检测到任务完成信号，Then 自动调用状态回写。
- **对应规格**：AI 场景新增（vision §4 接口层）。

#### US-E5-04 深链协议（kairo://）
- **用户故事**：作为审阅者，我可以通过 `kairo://` 链接从外部直达项目中的任务。
- **验收标准**：
  - Given `kairo://task/<id>`，When 打开，Then 应用定位并选中该任务。
  - Given 链接中只有项目路径与任务标题，When 打开，Then 按标题匹配定位（存在多选时取第一个并提示）。
- **对应规格**：[F-41-03](features/03-platform-collab.md)。

#### US-E5-05 接口一致性保障
- **用户故事**：作为维护者，我需要 MCP 与 CLI 行为一致，以免接口漂移。
- **验收标准**：
  - Given MCP 工具清单为接口事实源，When 构建 CLI 与插件，Then 二者从同一清单派生，无手写差异。
  - Given 对 MCP 与 CLI 执行同一操作序列，When 运行对等性测试，Then 返回结果一致。
- **对应规格**：AI 场景新增（G3 判据 2「CLI 与 MCP 能力对等」的落地保障）。

#### US-E5-06 JSON Schema 导出
- **用户故事**：作为外部工具或 AI 集成的维护者，我可以获取核心数据模型的 JSON Schema，以便自行集成。
- **验收标准**：
  - Given 导出命令，When 生成 `.kairo` 对应的 JSON Schema，Then 覆盖任务、相关性、资源、日历与项目设置全部实体。
  - Given Schema 变化，When 版本升级，Then 附带版本号，旧版本可被识别。
- **对应规格**：[F-41-06](features/03-platform-collab.md)（自动化接口的 Kairo 形态）。

### E6 持久化与项目文件

#### US-E6-01 .kairo 单文件读写（本地优先）
- **用户故事**：作为用户，我可以用一个本地文件保存整个项目，以便通过云盘或 git 自由分发与备份。
- **验收标准**：
  - Given 项目含任务、相关性、资源与日历，When 保存为 `.kairo`，Then 生成单一 JSON 文件，全部数据可被重新打开还原。
  - Given 保存路径位于云盘文件夹，When 写入，Then 不发起任何网络请求（本地优先）。
  - Given 打开损坏或版本不兼容的 `.kairo`，When 读取，Then 返回明确错误并保留原文件不覆盖。
- **对应规格**：[F-34-01](features/03-platform-collab.md)。

#### US-E6-02 自动保存与文件监控
- **用户故事**：作为用户，我的编辑应当自动持久化，且外部文件变化能反映到当前项目。
- **验收标准**：
  - Given 修改任一任务字段，When 停顿 2 秒，Then 自动保存到 `.kairo`。
  - Given 文件在外部被修改，When 应用检测到变化，Then 提示重新加载或合并。
- **对应规格**：[F-34-04](features/03-platform-collab.md)。

#### US-E6-03 CSV 导入导出与保真报告
- **用户故事**：作为用户，我可以从 CSV 导入任务、把当前视图导出为 CSV，并看到导入导出的保真情况。
- **验收标准**：
  - Given 提供 CSV 文件（首行为栏名），When 导入，Then 默认映射标题/开始/结束/投入/进度/优先级等常见栏名并生成任务。
  - Given 导入栏名不标准，When 导入，Then 返回栏名映射建议（AI 增强）并允许确认。
  - Given 导出任务视图为 CSV，When 完成，Then 只含当前过滤后的任务，编码默认 UTF-8（可选 GB18030）。
  - Given 任意导入或导出，When 完成，Then 附带保真报告（导入 N 任务、跳过 M 字段、K 条警告）。
- **对应规格**：[F-32-01](features/03-platform-collab.md)、[F-32-04](features/03-platform-collab.md)、[F-32-09](features/03-platform-collab.md)。

#### US-E6-04 模板（另存为 / 默认模板）
- **用户故事**：作为用户，我可以用当前项目另存为模板，并设某个模板为默认，以便复用项目结构。
- **验收标准**：
  - Given 当前项目，When 另存为模板，Then 生成模板文件并出现在模板列表。
  - Given 模板列表，When 设为默认，Then 新建项目默认使用该模板。
- **对应规格**：[F-11-04](features/01-views-editing.md)、[F-40-03](features/03-platform-collab.md)。

#### US-E6-05 项目标题与元数据
- **用户故事**：作为用户，我可以设置项目标题与元数据，以便区分文件名与展示名。
- **验收标准**：
  - Given 设置项目标题，When 查看主窗口，Then 标题栏显示项目标题；标题与文件名解耦。
- **对应规格**：[F-20-01](features/02-inspectors-scheduling.md)。

#### US-E6-06 跨设备（云盘文件夹委托）
- **用户故事**：作为用户，我可以把项目放在云盘文件夹并在多台设备查看，以便跨设备访问。
- **验收标准**：
  - Given 项目文件位于 iCloud Drive 或委托文件夹，When 在另一台设备打开，Then 读取同一文件并反映最新数据。
  - Given 两台设备同时编辑产生冲突副本，When 打开，Then 提供差异说明与合并入口（见 US-E3-05）。
- **对应规格**：[F-34-04](features/03-platform-collab.md)、[F-34-05](features/03-platform-collab.md)。

## 3. 功能需求映射表

本表把 6 个 Epic 与 [features/](features/) 的 F-xx-xx 规格建立对应：**继承**＝直接采用 OmniPlan 规格；**AI 场景新增**＝Kairo 相对 OmniPlan 的增量（本表为需求输入，口径与 [FEATURE-BREAKDOWN.md](FEATURE-BREAKDOWN.md) Phase 4 一致）；**降级 P3**＝重量级/专业版能力，本期不做或由 AI 语义化替代。

| Epic | 继承（F 编号） | AI 场景新增 | 降级 / 裁剪（P3 或不做） |
|---|---|---|---|
| E1 WBS 摄入 | F-11-01/03、F-12-08、F-13-01/03/06、F-14-03/04、F-22-01/03、F-25-01 | 批量导入结构化 WBS（JSON/大纲文本→任务树）；栏名映射的 AI 建议 | F-32-02（Markdown 大纲导入由 P3 提前为本 Story 输入形态，采纳其思路；OmniOutliner 私有格式不做） |
| E2 排期 | F-11-02、F-13-07、F-13-10、F-14-15/16、F-16-08/09、F-20-02/05、F-21-01/03、F-22-04/06/07、F-30-01/03…14 | 排期意图的自然语言表达（如「把发布提前一周」→ 引擎重排建议，属远期） | F-12-05（分级→由 AI 建议替代）、F-30-09（吊床）、F-30-15/16（分级与投入上限警告，P1 保留但本期可不做）、F-21-04（考虑资源可用性） |
| E3 状态回写 | F-12-06/07、F-14-10/11、F-20-03、F-22-03、F-35-04 | 群组完成度投入加权聚合的批量回写；同步冲突的 AI 差异说明 | F-33-08/09（EVM 与 Monte Carlo→AI 概率/判断表述，不做引擎） |
| E4 人工审阅 | F-12-02/04/12、F-13-02/15、F-14-01/02/13/14、F-20-03、F-30-01、F-40-01、F-41-01 | 自然语言筛选升级为可保存的结构化过滤器；违例的 AI 解释 | F-24-01…05（样式系统，本期不做）、F-12-13/14（文稿概览/TouchBar）、F-13-11…14（估算与 EVM 栏位） |
| E5 接口层 | F-41-03（深链）、F-41-06（JSON Schema） | MCP 工具集、CLI、Claude Code 插件（斜杠命令+hooks+.mcp.json）全部为 AI 场景新增 | F-41-06 的「脚本引擎」形态不做（Kairo 以 AI 自然语言操作替代，见 04-glossary「自动化」） |
| E6 持久化 | F-11-04、F-20-01、F-32-01/04/09、F-34-01/04/05、F-40-03 | 冲突差异的 AI 说明（US-E3-05）；保真报告的 AI 摘要 | F-32-03/08（MS Project 互转，vision §6 明确不做）、F-34-02（文件格式选择）、F-35-02（服务器帐户） |

**优先级口径**（沿用 features 各文档）：P0 = 核心闭环必备；P1 = 近期补齐；P2 = 进阶能力；P3 = 重量级/专业版/远期。

## 4. 非功能需求

### 4.1 性能

- **NFR-1 列表交互**：在 1,000 条任务的项目中，列表滚动、过滤、查找的交互响应时间应当不超过 100 ms（本地典型交互感知阈值）。
- **NFR-2 排期计算**：1,000 条任务、10,000 条相关性的排期计算（正推 + 逆推）应当不超过 1 s；违例重算应当增量进行，不得每次全量扫描。
- **NFR-3 文件读写**：不超过 5,000 条任务的 `.kairo` 文件，保存与打开应当各不超过 1 s。

### 4.2 数据安全

- **NFR-4 本地优先**：Kairo 默认不得发起任何网络请求；不采集遥测、不建立账号、不提供中心服务器（vision §6）。
- **NFR-5 文件透明**：`.kairo` 必须为可读的单一 JSON 文件，用户可以自行用 git 或云盘版本管理；任何写入不得破坏用户已保存的原文件。
- **NFR-6 同步委托**：跨设备同步必须委托用户现有的文件同步渠道（云盘文件夹），Kairo 自身不得实现私有同步协议。

### 4.3 可测试性

- **NFR-7 核心无 UI 依赖**：核心层（KairoCore）不得 import AppKit/SwiftUI，必须可在无 GUI 环境（含 Linux）编译并通过全量单测。
- **NFR-8 调度纯函数**：调度引擎必须为纯函数（输入 `Project` → 输出安排与违例），不读写全局状态，全部行为可单测。
- **NFR-9 测试覆盖**：核心层单元测试覆盖率不得低于 80%；现有 17 项测试在重构后必须继续通过。
- **NFR-10 接口对等**：MCP 与 CLI 必须通过同一份契约测试，防止接口漂移（对应 G3 判据 2）。

## 5. MVP 范围裁定（Sprint 1–2 交付边界）

**MVP 交付（本周期目标）**：

1. 核心模型重构：`TaskDependency`（类型 + 前导时间）、`kind`（任务/群组/里程碑）、投入/持续时间字段、`Resource` 与分配（基础）；
2. `.kairo` 单文件持久化（本地优先）；
3. 调度引擎：相关性传播（FS/FF/SS/SF + 前导时间）、项目方向、重要路径与宽延、基础违例检测；
4. 状态回写：单任务与批量回写、群组完成度聚合；
5. 接口层：MCP 服务（任务 CRUD/相关性/排期/状态/统计）、CLI 对等、Claude Code 插件（斜杠命令 + `.mcp.json`）；
6. macOS 应用：任务列表/详情/过滤器/查找、层次树大纲、甘特视图基础、命令面板、违例面板、`kairo://` 深链。

**MVP 明确不做（本周期）**：

- 多用户协作服务器、Windows/Linux 前端、移动端（vision §6）；
- MS Project 导入导出（vision §6）、EVM 与 Monte Carlo 引擎；
- 资源负荷分级与发布/订阅、样式系统、重复任务、拆分/吊床任务、模板完整化。

MVP 以 [03-roadmap.md](03-roadmap.md) 的 Sprint 1–2 为时间边界，G3 判据为验收门槛（vision §7）。

## 6. 需求状态表（Backlog）

敏捷需求登记簿，后续按行追加。状态取值：**提议 / 已接受 / 进行中 / 完成**。

| 编号 | 标题 | Epic | 优先级 | 状态 | 备注 |
|---|---|---|---|---|---|
| US-E1-01 | 新建项目 | E1 | P1 | 完成 | Sprint 1（project_create MCP/CLI/应用三面可用） |
| US-E1-02 | 单任务创建、更新与删除 | E1 | P0 | 完成 | 现有 MVP 已具备 |
| US-E1-03 | 层级任务树（群组/子任务/里程碑） | E1 | P0 | 完成 | Sprint 1（TaskKind/parentID；应用层级树展示） |
| US-E1-04 | 批量导入任务树（结构化 WBS） | E1 | P0 | 完成 | Sprint 1（wbs_import 工具 + CLI 子命令；叶子解码 bug 修复） |
| US-E1-05 | 任务信息完整化 | E1 | P1 | 进行中 | Sprint 2 落地资源模型、effort/duration 换算与资源分配（MCP `assignments` / CLI `--assign`）；富备注链接待 UI 落地 |
| US-E2-01 | 相关性模型（FS/FF/SS/SF+前导时间） | E2 | P0 | 完成 | Sprint 2（数据模型 Sprint 1；FS/FF/SS/SF+lag 传播计算落地） |
| US-E2-02 | 排期计算 | E2 | P0 | 完成 | Sprint 2（ScheduleEngine 纯函数 + schedule_compute） |
| US-E2-03 | 重要路径与宽延 | E2 | P1 | 完成 | Sprint 2（总/自由宽延 + 宽延限制 + schedule_critical_path） |
| US-E2-04 | 工作时数日历 | E2 | P1 | 已接受 | — |
| US-E2-05 | 时限约束与基础违例检测 | E2 | P1 | 完成 | Sprint 2（违例引擎 F-30 基础集 + violations_list） |
| US-E2-06 | 基线快照与差异 | E2 | P2 | 提议 | — |
| US-E3-01 | 单任务状态与进度回写 | E3 | P0 | 完成 | Sprint 2（statusUpdate：done 记 completedAt + 进度 1；非法进度拒绝） |
| US-E3-02 | 批量回写与群组完成度聚合 | E3 | P0 | 完成 | Sprint 2（status_batch_update 逐条明细 + groupProgress 投入加权聚合） |
| US-E3-03 | 重新安排未完成任务 | E3 | P1 | 已接受 | — |
| US-E3-04 | 字段级版本历史 | E3 | P1 | 已接受 | — |
| US-E3-05 | 同步冲突的 AI 差异说明 | E3 | P2 | 提议 | — |
| US-E4-01 | 任务列表与详情编辑 | E4 | P0 | 完成 | 现有 MVP 已具备 |
| US-E4-02 | AI 过滤与查找 | E4 | P0 | 完成 | 基础已完成；可保存过滤器升级为 P1 待做 |
| US-E4-03 | 层次树/大纲交互 | E4 | P1 | 进行中 | Sprint 3：缩进/出缩进/新建同级（Tab、Shift-Tab、Return 与 ⌘[ / ⌘] 菜单）已实现；待验收 Demo 确认 |
| US-E4-04 | 甘特视图基础 | E4 | P1 | 进行中 | Sprint 3：任务条、日期标头、日/周/月缩放与「适合项目」、标头拖动平移、周末着色已实现；待人工视觉验收 |
| US-E4-05 | 命令面板（⌘K） | E4 | P0 | 进行中 | Sprint 3：⌘K 面板与统一命令注册表（菜单栏同源）已实现；待验收 Demo 确认 |
| US-E4-06 | 项目摘要面板 | E4 | P1 | 已接受 | — |
| US-E4-07 | 检查器与违例面板 | E4 | P1 | 进行中 | Sprint 3：违例面板与行内图标已实现；待验收 Demo 确认 |
| US-E5-01 | MCP 服务 | E5 | P0 | 完成 | Sprint 2 扩至 16 工具（含排期/违例/批量回写/资源；dependencies 参数）；stdio JSON-RPC 零依赖，ADR-010 |
| US-E5-02 | CLI | E5 | P0 | 完成 | Sprint 2 补齐 schedule/violations/status（含 batch）/resource 对等命令；与 MCP 契约同源；Sprint 3 增加 `task list --json` 机器可读输出 |
| US-E5-03 | Claude Code 插件 | E5 | P0 | 进行中 | Sprint 3：插件清单、`.mcp.json`、`/kairo plan/done/status`、`TaskCompleted` hook 已落地；hook 按标题回写，待真实会话确认 |
| US-E5-04 | 深链协议（kairo://） | E5 | P1 | 进行中 | Sprint 3：解析与定位逻辑 + 应用 onOpenURL 已落地；`.app` 打包并注册 URL scheme 待发布工程 |
| US-E5-05 | 接口一致性保障 | E5 | P0 | 完成 | Sprint 2（InterfaceTests 对等性契约测试 35 项；CLI 打开 MCP 文件验证） |
| US-E5-06 | JSON Schema 导出 | E5 | P1 | 提议 | — |
| US-E6-01 | .kairo 单文件读写 | E6 | P0 | 完成 | Sprint 1（formatVersion + 前向兼容；MCP/CLI/应用三方互通） |
| US-E6-02 | 自动保存与文件监控 | E6 | P1 | 已接受 | — |
| US-E6-03 | CSV 导入导出与保真报告 | E6 | P1 | 已接受 | — |
| US-E6-04 | 模板（另存为/默认模板） | E6 | P2 | 提议 | — |
| US-E6-05 | 项目标题与元数据 | E6 | P2 | 提议 | — |
| US-E6-06 | 跨设备（云盘文件夹委托） | E6 | P2 | 提议 | — |

## 7. 待确认问题（2026-10-17 lead 裁定）

1. **MCP SDK 选型**：Swift MCP SDK 选择官方维护或社区维护版本，已裁定：MVP 自实现最小 JSON-RPC，见 [02-architecture.md](02-architecture.md) ADR-010。
2. **Swift on Linux 工具链**：G3 判据 4 需要核心在 Linux 编译，已裁定：GitHub Actions ubuntu-latest + swift:6.x 镜像，Sprint 2 起门禁（R1）。
3. **用户规模假设**：NFR-1 的「1,000 条任务」为本期假设阈值，维持 1,000 条假设，Sprint 4 复核。
4. **验收口径**：US-E4-02 的可保存过滤器升级优先级定为 P1，已裁定：维持 P1，不提前进 Sprint 1。
