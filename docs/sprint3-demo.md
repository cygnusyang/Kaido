# Sprint 3 验收 Demo

- 日期：2026-10-18
- 范围：US-E4-03、US-E4-04、US-E4-05、US-E4-07、US-E5-03、US-E5-04
- 结论：代码与自动化证据齐备；GUI 渲染与交互逻辑已自动化覆盖，视觉美观与真人操作手感待人工确认（见 §7、§8）。

## 1. 甘特视图基础（US-E4-04）

### 已实现

- 工具栏「任务 / 甘特」分段切换（F-12-02）。
- 左侧任务列按层级缩进；右侧时间轴绘制任务条：位置取排期结果 `scheduledStart`，
  宽度取 `scheduledFinish − scheduledStart`；里程碑绘制为菱形。
- 条内按 `progress` 填充；重要路径任务红色描边；有违例的任务橙色描边。
- 日期标头：日 / 周 / 月三档刻度；每月首日为粗体主刻度。
- 缩放菜单（标头左侧按钮）：日、周、月、缩放以适合项目。
- 拖动日期标头左右平移时间窗（F-14-13）。
- 非工作时段着色：周六、周日整列显示浅灰背景（F-14-14）。

### 人工验收步骤

1. 打开应用，工具栏切换到「甘特」。
2. 缩放菜单依次切到日、周、月，确认刻度密度与任务条宽度变化；点「缩放以适合项目」，确认全部任务落在可见宽度内。
3. 在日期标头上左右拖动，确认时间窗平移、日期标签随之变化。
4. 确认周六、周日列有浅灰背景。
5. 点击任一任务条，确认右侧检查器打开对应任务。

### 自动化证据

`Tests/ZenoCoreTests/GanttLayoutTests.swift` 的 16 项测试覆盖：

- 内容范围取项目边界与任务排期边界并集；
- 任务条横坐标与宽度由计划日期换算；
- 窗口外任务不产出条、跨界任务保留负坐标由视图裁剪；
- 里程碑零宽度；
- 周六、周日背景带位置；
- 三档缩放的每日宽度与刻度标签；
- 窗口结束时间随视图宽度变化；
- 「适合项目」宽度换算与覆盖值优先级；
- 进度与重要路径标记透传；
- 拖动平移的方向换算与每日宽度下限（`pannedWindowStart`）。

`Tests/AppTests/GUIRenderTests.swift` 用 `ImageRenderer` 离屏渲染（无窗口）验证界面确实绘制：

- 大纲模式渲染出多色界面（List 行由 AppKit 表格承载，`ImageRenderer` 不绘制其单元格）；甘特有任务与无任务的画面不同（负向对照，证明任务条确实被绘制）；
- 切到甘特后画面差异 > 5%；
- 日 / 周 / 月三档缩放两两产生不同画面；
- 平移窗口起点 7 天后画面改变；
- 打开查找栏后画面改变；
- 命令面板有命令与无命令时画面不同（行内容数据驱动）；
- 违例面板显示后画面差异 > 5%，清除时限后同一面板内容再次改变。

## 2. 大纲层级编辑（US-E4-03）

### 已实现

- **Tab**：选中任务缩进为上一同级任务的子任务。
- **Shift-Tab**：任务上移一级，其子树随行，并排在父任务子树之后。
- **Return**：在选中任务之后新建同级任务并选中新任务；选中群组时新任务成为其子项。
- 菜单「编辑」提供同能力命令：缩进 ⌘]、减少缩进 ⌘[、新建同级任务 ⌘↩。
- 菜单命令与 ⌘K 面板同源（见 §3）。

### 人工验收步骤

1. 在大纲中选中第二个顶层任务，按 Tab，确认它缩进到第一个任务之下。
2. 按 Shift-Tab，确认它回到顶层并排在原父任务子树之后。
3. 选中一个任务按 Return，确认其下方出现同级的「新任务」且保持选中；选中群组按 Return，确认新任务缩进为群组子项。

### 自动化证据

`Tests/ZenoCoreTests/OutlineEditingTests.swift` 的 10 项测试覆盖：

- 缩进取上一同级任务；首个同级任务与跨父组时不可缩进；
- 出缩进时子树整体搬移，顺序为「父任务子树之后」；
- 顶层任务不可出缩进；
- 群组与普通任务的 Return 父级判定；
- 子树枚举含后代并防御自环；
- `Project.insert(after:)` 的插入位置。

`Tests/AppTests/ProjectStoreTests.swift` 直接驱动 `.onKeyPress` 的处理目标：

- Tab 缩进到上一同级任务；Shift-Tab 回到顶层并排在父任务之后；
- Return 在选中任务后插入同级任务并选中新任务；群组按 Return 时新任务成为子项；
- 无选中时三个命令均不改变任务列表。

按键事件本身由 SwiftUI `.onKeyPress` 合成；本套件验证其调用的 Store 方法，
不在测试中伪造 AppKit 键盘事件。

## 3. 命令面板（US-E4-05）

### 已实现

- ⌘K 打开浮层面板，列出注册表中的全部 16 条命令。
- 输入文本按命令名称不区分大小写过滤；列表展示分组与快捷键；点击或按 Return 执行首条匹配；Esc 或点击遮罩关闭。
- 菜单栏「文件 / 编辑 / 任务 / 视图 / 查找」的每一项均由同一注册表生成（`CommandRegistry.swift`）。

### 人工验收步骤

1. 按 ⌘K，确认面板列出全部命令并显示快捷键。
2. 输入「甘特」，确认只剩视图相关命令；按 Return，确认主区域切到甘特。
3. 对照菜单栏逐项核对：文件（打开 ⌘O、保存 ⌘S）、编辑（⌘] / ⌘[ / ⌘↩）、任务（⌘⌥N / ⌘⌥G / ⌘⌥M）、视图（⌘⌥V）、查找（⌘F / ⌘G / ⌘⇧G / ⌘⌥E / ⌘K）。

### 自动化证据

`Tests/AppTests` 覆盖：

- 注册表 16 条命令、ID 唯一、5 个分组齐全，快捷键标签正确（⌘K、⇧⌘G、⌘↩）；
- `CommandPalette.matching` 按标题过滤（「甘特」只剩 `view.gantt`），空查询返回全部；
- 视图命令切换 `ProjectStore.viewMode`，⌘K 命令打开面板；
- 打开面板后离屏渲染画面差异 > 5%。

## 4. 违例面板与时限修正（US-E4-07）

### 已实现

- 给任务设置与相关性链冲突的时限即可触发违例；面板列出类型与原因，点击定位任务。
- 检查器「时限」下拉可改四类时限及其日期；修改后项目即时重排，违例面板与行内图标同步刷新。

### 人工验收步骤

1. 首页演示数据中选中「发布 v1.0」，在检查器把「时限」设为「最晚结束」，日期选昨天。
2. 工具栏打开「违例」面板，确认出现「因先决条件无法满足『结束不晚于』时限」（`constraint_is_prerequisite`），任务行出现橙色图标。同一时限还会伴随一条负宽延记录（`cannot_schedule_asap_alap`）；两条均属预期。
3. 把时限日期改到 30 天后，或把「时限」改回「无」，确认违例消失、图标消失，计划开始/结束与宽延随之更新。

### 自动化证据

`Tests/AppTests` 用演示数据设置「发布 v1.0」的 `endNoLaterThan`（昨天）后
（Store 断言在 `ProjectStoreTests`，画面断言在 `GUIRenderTests`）：

- `ProjectStore.violations` 含 `constraint_is_prerequisite` 与 `cannot_schedule_asap_alap`，`taskID` 指向该任务，消息含任务标题；
- 清空时限后该任务的违例消失；
- 打开违例面板后离屏渲染画面差异 > 5%。

D-002（演示数据未设项目时间线导致排期落在 1970 纪元）由这组测试发现并修复，见 [defects.md](defects.md)。

## 5. Claude Code 插件回写（US-E5-03）

`/zeno plan` 与 `/zeno done` 的命令提示词位于 `Plugins/claude-code/commands/`，底层调用
MCP 工具。下面的会话直接驱动 `ZenoMCP` stdio（与插件内 `bin/zeno-mcp` 启动的是同一二进制），
为 2026-10-18 实际运行输出：

```
1) initialize -> {'version': '0.1.0', 'name': 'zeno'}
2) project_create -> Zeno Sprint 3 演示
3) wbs_import -> {'rootIDs': ['E93AD9CA-663F-4470-8A33-CD689ACA3794'], 'total': 3, 'warnings': []}
4) task_list -> 接口设计 83382990 / 界面开发 E04ED868
5) task_update(界面开发 依赖 接口设计) -> [('83382990', 'fs')]
6) schedule_compute -> E93AD9CA 2026-11-01T16:00:00Z -> 2026-11-02T16:00:00Z slack 10
6) schedule_compute -> 83382990 2026-11-01T16:00:00Z -> 2026-11-03T16:00:00Z slack 6
6) schedule_compute -> E04ED868 2026-11-03T16:00:00Z -> 2026-11-06T16:00:00Z slack 6
7) violations_list -> {'violations': []}
8) status_update(done) -> {'title': '接口设计', 'status': 'done', 'progress': 1, 'groupProgress': 1, 'completedAt': '2026-10-18T07:51:34Z'}
9) schedule_critical_path -> {'criticalPath': [{'taskID': 'E93AD9CA-663F-4470-8A33-CD689ACA3794', 'isCritical': False, 'freeSlackDays': 10, 'totalSlackDays': 10}, {'taskID': '83382990-B6DC-4C67-829F-710DB77592A7', 'isCritical': False, 'freeSlackDays': 0, 'totalSlackDays': 6}, {'taskID': 'E04ED868-8B7B-4E33-B5A3-6A609B8521B1', 'isCritical': False, 'freeSlackDays': 6, 'totalSlackDays': 6}]}
```

说明：

- 时间为 UTC；本机时区 UTC+8，`2026-11-01T16:00:00Z` 即本地 2026-11-02 00:00。
- 界面开发在接口设计结束后开始，证明 FS 依赖进入排期；群组完成度在子任务完成后为 1。
- 插件清单与命令通过 `claude plugin validate --strict`。

### 完成信号 hook（US-E5-03 验收 3）

`hooks/hooks.json` 注册 `TaskCompleted`，按事件中的 `task_subject` 与 Zeno 任务标题
精确匹配，唯一命中时经 CLI 回写 `done`。2026-10-18 用真实 `.zeno` 文件驱动脚本：

```
$ echo '{"hook_event_name":"TaskCompleted","task_subject":"接口设计"}' | ZENO_PROJECT=... zeno-task-hook
zeno-hook: 已回写「接口设计」为 done
hook_exit=0
$ zeno task list --json ... | jq -r '.[] | "\(.title) \(.status)"'
接口设计 done
界面开发 pending

$ ... task_subject=重名任务（两个同名任务）
zeno-hook: 「重名任务」匹配 2 个 Zeno 任务，跳过回写
ambiguous_exit=0

$ ... task_subject=不存在的任务
zeno-hook: 「不存在的任务」匹配 0 个 Zeno 任务，跳过回写
nomatch_exit=0

$ ... 未设置 ZENO_PROJECT / 非 TaskCompleted 事件
noenv_exit=0 / otherevent_exit=0
```

所有负路径均以 0 退出且不改数据。

真实会话验证：以 `claude --plugin-dir Plugins/claude-code -p` 启动会话，让会话用
`TaskCreate` 创建「接线测试」并用 `TaskUpdate` 标记完成。会话结束后读取同一 `.zeno`：

```
$ zeno task list --json --file live.zeno | jq -r '.[] | "\(.title) \(.status)"'
接线测试 done
```

任务由 `pending` 变为 `done`，证明 `TaskCompleted` 事件到 CLI 回写的链路贯通。

并发验证：同一项目内并行触发 5 个不同标题的 `TaskCompleted`，5 个任务全部落盘为
`done`（hook 对项目路径加排他锁，避免原子替换写导致丢更新）。

自动化证据：`Tests/InterfaceTests/TaskHookTests.swift` 用假 CLI 驱动 hook，覆盖唯一命中、
重名跳过、0 命中、已完成不重写、无关事件、缺 `ZENO_PROJECT`、非法事件与非法任务列表，
并断言所有路径退出码为 0。

## 6. 深链 zeno://（US-E5-04）

- 支持 `zeno://task/<完整 UUID 或 ≥4 位前缀>`、`zeno://task?title=<标题>`、`zeno://project/<id>`。
- 应用实现 `onOpenURL`：任务链接选中并滚动；标题重名时定位第一个并提示数量；指向其他项目时提示当前项目名。
- 自动化证据：`Tests/ZenoCoreTests/DeepLinkTests.swift` 的 10 项测试覆盖解析、前缀唯一性、标题大小写回退、项目匹配与非法输入。

## 7. 门禁与测试结果（2026-10-18）

```
gate-core: ZenoCore 无 AppKit/SwiftUI/Cocoa import，通过（19 个 Swift 文件）
gate=0
build=0
Test run with 199 tests in 30 suites passed
```

测试分布：ZenoCore 124、Interface 51、AppTests 24。

## 8. 遗留项

| 项 | 状态 | 去向 |
|---|---|---|
| GUI 视觉美观与真人操作手感（§1–§4） | 待人工；渲染与交互逻辑已自动化覆盖 | 本 Demo 验收会 |
| 未设项目时间线的项目仍从 1970 纪元起算排期（D-003） | 已知缺陷，未修复 | Sprint 4 排期模型 |
| Claude Code 完成信号 hook | 已配置并按标题匹配；脚本级与真实会话验证通过 | 标题重名时安全跳过；应用打开同一文件时不自动刷新 |
| `.app` 打包与 URL scheme 注册 | 未完成 | 发布工程；当前仅能通过 `swift run` 运行并接收系统转发的 URL |
| 非工作时段按项目/资源日历着色 | 未完成 | 工作日历模型（F-22-06），Sprint 5 |
| 甘特横向滚动条 | 未实现 | 当前用拖动标头平移；需要时再评估滚动与时间窗的交互 |
| hook 与应用并发写同一 `.zeno` | 未解决 | hook 侧已加锁；应用保存不检测 mtime，后保存者覆盖。US-E6-02（自动保存/冲突检测）Sprint 5 |
| 显式任务 ID 映射（`cc:<task_id>` 标签） | 未实现 | 当前以标题为连接键；需要跨系统强关联时再引入标签映射 |
