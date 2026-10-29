# 更新日志

所有显著改动记录于此。格式参照 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)；
版本号遵循语义化版本。发布版本另见 [GitHub Releases](https://github.com/cygnusyang/Kairo/releases)。

## [Unreleased]

### 新增

- **互操作骨架 + MSPDI 读（v1.2 P0）**：新增两个互不依赖的 target——`KairoInterop`（供应商无关 IR：任务树 / 时间 / 四型依赖 + 秒级 lag / 约束 / 资源与分配 / 日历 / 基线 / 自定义域；`FidelityLedger` 有损登记；`FormatAdapter` 协议 + `AdapterRegistry`；`KairoBridge` IR ↔ Kairo 模型）与 `InteropMSPDI`（MS Project XML 读）。适配器不 import `KairoCore`，工作日历换算只在 `KairoBridge` 一处。
- **契约测试 `AdapterConformanceSuite`**：空计划 / 单任务 / 四类依赖 / lag / 里程碑 / 群组 / 多日历 / 基线 / 中文 emoji / 畸形 XML 共 12 个 MSPDI 样本，每次新增格式只加样本、不改断言。
- **版本闸门**：`SaveVersion` 只接受 12–14，未知版本抛 `unsupportedFormatVersion`；命名空间必须是 `http://schemas.microsoft.com/project`。

### 判据与证据

- 真实样本 `/tmp/plb2012.xml`（客户文件，不入库）解析出 187 任务（37 汇总 / 2 里程碑）、126 依赖（全 FS、零 lag）、3 日历、4 基线（478 条任务级记录 + 346 条分配级基线登记为丢弃）。
- `FidelityLedger` 登记 97 条硬约束降级（SNET 41 / FNET 56）、日历换算（周一至周五 5 天/周 × 8h，另 37 条例外日）、4 个自定义域（105 条任务上 214 个值）。
- 全量 **1408 tests / 134 suites** 通过；新增 23 例，零 warning。

## v1.3.5 — 2026-10-29

### 修复

- **甘特翻到远处时不知道该往哪边拖（D-046）**：状态栏虽有「Today」按钮，但它常驻右下角、只在今天移出窗口时出现，且不带方向——用户看不出今天在左边还是右边。修法：今天线移出窗口时，在画布**对应一侧**浮出方向胶囊（左侧「◀ 今天」、右侧「今天 ▶」），点击即回到今天并带上 `⌥⌘T` 的提示；状态栏按钮同步加箭头。胶囊只在窗口外出现，今天可见时不占地方。
- **快照补方向字段**：`GanttSnapshot` / `StatusBarSnapshot` 新增 `todaySide`（`.left` / `.right` / `.none`），由 `Presenter` 按 `today` 与 `windowStart` 的关系推导；画布胶囊与状态栏按钮读同一字段，避免在两处各自判方向。

### 判据

- `TodaySideTests`（4 例，真实执行）：窗口在过去 ⇒ `.right`；窗口在未来 ⇒ `.left`；今天在窗口内 ⇒ `.none`；方向随平移方向翻转。
- 呈现层全量 **283 用例 / 22 套件**通过（含 A7 冻结基线与翻窗性能门禁）。
## v1.3.4 — 2026-10-29

### 修复

- **启动时右侧甘特窗口起点错（D-039）**：打开项目后时间轴停在项目最早排期日，今天线常跑到窗口外；没有项目可开时还会回放上次会话的平移位置。根因三条叠加：① `Presenter` 在无显式起点时回落到内容起点，而默认又是「适合项目」；② 启动直接回放持久化的 `windowStart`，无时效校验；③ 默认档位是 12px/天的周档而不是日档。修法：新增窗口跨度模式（`windowSpanDays`，默认 7 天、不落盘），日宽 = 画布宽 / 7；自定义日宽与固定跨度两条路径的缺省起点锚今天；停止持久化 `windowStart`，偏好加 `schema=2` 一次性迁移（重置 `zoom` / `usesFitZoom` / `customDayWidth`，其余偏好保留）。验证：新增 `StartupWindowTests`、`StartupWindowAnchorTests`、`StartupWindowSeedVisibilityTests`；呈现层 282 用例真跑全绿，A7 冻结基线与 `main@4ece5fa` 的预设/fit 路径逐位一致（20 组配置全字段 diff 为空）。
- **跨度模式下缩放菜单打错勾**：启动态菜单勾着「周 (12 pts/day)」、状态栏却写「7-day window · 74 pts/day」；同一处的「适合项目」勾选也有同样问题。修法：两处 active 判断都加 `windowSpanDays == nil` 门控。
- **点档位后窗口跳回项目起点**：启动是跨度窗口（今天），用户点一下日/周/月会被清掉跨度并按内容起点重排，界面从今天跳到项目最早那天。修法：离开跨度的那一刻把当前可见起点固化进 `windowStart`；用户已平移过的位置不覆盖。

### 变更（用户可见）

- 启动默认视图由「适合项目」改为「固定 7 天跨度、起点今天」；状态栏新增「7 天窗口」档位显示。预设三档（32 / 12 / 5 px/天）与「适合项目」行为不变。
- 偏好结构升到 `schema=2`：老用户首次启动会重置甘特三项（档位、适合项目、自定义日宽），大纲列宽、列顺序、检查器宽度、基线显示等其余偏好原样保留。
- 内置示例项目的时间分布前移到今天附近（首屏 7/10 条可见，另留一条无显式开始日的样本、一条逾期与一条远期）。

### 已知取舍（均登记于 docs/defects.md，目标 v1.4.0）

- **D-040** 项目整体在过去时首屏为空；**D-041** 四个互斥标志待合并为 `WindowWidthMode`；**D-042** 宽视口下跨度日宽超出滑杆上界、`reveal` 不滚窗；**D-043** 窗口外有任务时无提示，离开跨度后也没有入口回到 7 天。

### 影响面

- 改动集中在 `KairoPresentation` 的窗口/日宽解析与 `WorkspaceStore` 的视图状态；排期引擎、`.kairo` 文件格式、CLI/MCP 契约、互操作均未变。
- 版本号三处同源更新（`tools/build.sh` / `Sources/KairoMCP/MCPServer.swift` / `Apps/macos/Sources/CommandRegistry.swift`）。
## v1.3.3 — 2026-10-29

### 修复

- **OTA 取消点了没反应（#28）**：点下载后立刻点取消，界面无变化，下载照旧推进。根因是 `performCheck` / `performDownload` 从建任务到首次状态回写之间存在窗口，此时任务尚未登记为当前飞行，取消逻辑找不到可取消对象；可取消的状态范围也过窄。修法：两个入口加 `isCurrentFlight` 守卫堵住窗口，可取消范围扩到 `.checking` / `.updateAvailable` / `.downloading` / `.downloaded`，仅 `.installing` 不可取消（该态面板只给「关闭」，不存在死按钮）。验证：新增「取消后不得复活下载」用例并做反例红验证（`17ddcdb`），共 7 条用例先红后绿（`a816aea`）。
- **跨版本升级后 OTA 临时目录清不掉（#24 复发）**：旧版 pending 键缺失时，按 uuid 反查脚本与 result 会落空，产物留在 `$TMPDIR`。修法：pending 缺键时按形状（同 uuid 的脚本 / result）清扫；解压目录因 prepare 与脚本 uuid 本就不同，改为「名字严格 `kairo-ota-<UUID>` + 内容恰好一个 `.app` + mtime 超 1 小时」三条件同时成立才删，仍不做宽前缀批量删除。验证：7 条用例先红后绿，与上条同一提交（`a816aea`）。
- **甘特翻窗性能用例在共享 runner 上假红（#27）**：原判据是单帧 ≤50ms 墙钟绝对量，CI 上实测 50.98–51.58ms 抖动必红；且该判据对「翻窗退化成全量重建」这类真回归不敏感——慢化 20ms 时仍然绿。改为相对判据：翻窗中位 ≤ 全量重建中位 ×0.5（交替采样 7 轮、各预热 2 次、取中位），保留 500ms 病态兜底。验证：注入 20ms 慢化后比值 0.75 变红（旧判据为绿），20 次连跑 0 失败（`2d6aff7`）。
- **macOS CI 作业测试改走 `tools/test.sh`**：与 Linux 作业同源看门狗 + 全新 scratch path，避免共享 `.build` 锁导致的长时间排队；Linux 作业保持直接 `swift test`（该环境无 `sample`，接上看门狗会失效）（`74676a6`）。

### 影响面

- 改动集中在 KairoUpdater 的取消/清理路径与 Presentation 层测试判据；排期、互操作、`.kairo` 格式与 CLI/MCP 契约均无变化。
- 版本号三处同源更新（`tools/build.sh` / `Sources/KairoMCP/MCPServer.swift` / `Apps/macos/Sources/CommandRegistry.swift`），产物版本由 `tools/release.sh` 派生。

### 许可变更

- 自 v1.3.3 起，许可由 MIT 改为 **PolyForm Noncommercial 1.0.0**：个人学习、爱好、科研、实验与非商业组织（慈善、教育、公共研究、公共安全/卫生、环保、政府）免费使用；任何预期商业应用的场景（含营利公司内部用 Kairo 管自己的项目）需另行取得商业授权。
- **v1.3.2 及以前的已发布版本继续按 MIT 授权**，不追溯变更；本仓库的 git 历史与旧 tag 保持原样。
- 再分发须随附本许可条款（或链接）与 `Required Notice:` 行；本许可无自动转开源条款，也不允许转授权。
- 选择理由：目标客户是企业团队，「个人/教育免费、商业付费」直接对应定价模型，比 FSL 的两年独占窗更贴合按席位/按团队收费。代价是部分企业法务会禁止使用非 OSI 许可的软件，故 README 给出商业授权联系方式。详见 `LICENSE` 与 README「License / 许可证」节。

## v1.3.2 — 2026-10-28

### 修复

- **OTA 安装后进程不退出（#23 复发）**：更新面板作为 sheet 会推迟 AppKit 的终止流程，导致 terminate 从未进入裁决。改为先关面板、等一个 runloop 回合、再 terminate；判定逻辑未改。已用本地升级链路实证：日志出现 sheet dismissed → terminate → reply=terminateNow，版本 1.3.1 → 1.3.2、进程 PID 实测切换。
- **CI 偶发死锁（约 50%）**：并行跑时 OTA 两条下载态用例的 waitUntil 到期返回 false，而下载器的 finish() 早于 continuation 注册、信号被静默丢弃，waiter 永久等一个不会 resume 的 continuation。修法：GateDownloader 先记状态、注册即兑现；新增 waitUntilStarted() 事件信号；用例删掉 3s 轮询判定。串行 0 挂、并行挂一半 → 修复后 10 次全新 scratch 0 挂。

### 新增

- **测试看门狗**：tools/test.sh 输出停滞 120s → sample 抓栈 → 报告含「最后 started / 最后 ended / 仍在进行中」归因段 → 退出 124。自检入口可复跑。

### 判据

- 全量 **1533 tests / 155 suites**；10 次全新 scratch 连跑 0 挂；build 零 warning；gate-i18n 与全角检查通过。
- 已知红：GanttRenderPerformanceTests 的 50ms 墙钟阈值在共享机器上假红（已单独立项）。

## v1.3.1 — 2026-10-28

### 修复

- **大纲序号过长被截断（#25）**：序号列原为固定 44pt，窄窗再乘压缩系数至 26pt，六级以上序号被行裁掉。改为按表格实际字体的最长序号串度量加内边距，随折叠/增删同步；列宽上限 80→120，避免用户拖宽时被夹回。
- **跨版本 OTA 残留（#24）**：旧版写入的 pending 缺 script/extraction 键，新版清理不到解压目录与替换脚本——改为按形状加同一 uuid 匹配兜底，不做宽前缀批量删。

### 新增

- **OTA 决策留痕（#23）**：terminationReply 记录 armed/unsaved 快照与 reply 结果，install 记录 requested → preflight → armed → terminate 全过程，os_log 与 ~/Library/Logs/Kairo/ota.log 同步双写。判定逻辑一字未改。
- **本地升级验证脚手架**：tools/ota-local-verify.sh 加 DEBUG-only 清单覆盖，可在本机走完整 OTA 链路（清残留 → 现签清单 → 本地服务 → 临时副本启动），不覆盖 /Applications；启动前若发现旧 build 在跑会 WARN。

### 判据

- 全量 **1531 tests / 154 suites** 通过（独占运行），零 warning；release 双架构构建通过；gate-i18n 与全角检查通过。

## v1.3.0 — 2026-10-27

### 新增

- **工时挣值（SV / SPI）**：项目摘要新增挣值块。PV 按工作日插值（5 天工作周下 2/5 而非 2/7），里程碑零工期二分；EV 用 effectiveProgress —— 实际完成日不晚于数据日期强制 100%，晚于数据日期强制 0。
- **数据日期（Status Date）**：项目设置可固定或回到「今天（未固定）」；未固定时界面明确标注「每次查看按当天计算」，固定后提示「报告可复现」。该字段不进基线。
- **挣值块两句已知局限**直接写在界面上：SPI 末期回归 1；工时口径下工作量前重后轻时早期 SPI 偏高。

### 明确不做

- **CV / CPI 置灰**：未启用成本与费率，无法计算成本绩效。不给数字，只给原因——避免用户拿无效数字做决策。

### 判据与证据

- 全量 **1511 tests / 150 suites** 通过，零 warning；gate-i18n 通过（659 键两侧一致）。
- SPI 无定义（ΣPV=0）时显示「—」而非 0；固定数据日期后同一快照两次计算相等（可复现性用例锁死）。
- 已取消任务不进分子分母；群组与有子项任务不单列（避免子树重复计工作量），记入 excludedTaskCount。

## v1.2.0 — 2026-10-27

### 新增

- **MS Project 导入**（MSPDI XML）：真实样本 187 任务 / 37 汇总 / 2 里程碑 / 126 依赖 / 3 日历 / 4 基线，用两套独立解析器验过往返一致。
- **OmniPlan 导入与导出**（`.oplx`）：读 26 任务样本；写出的文件已在 OmniPlan 4.10.3 实测打开，任务标题与层级回读正确。
- **MS Project 导出（Beta）**：往返数据一致，但未经 Windows Project 实机验证，界面与旁注均如实标注。
- **导入预检**：四块清单（丢失 / 已换算 / 日历 / 依赖明细）+ 不计漏不变量（四块计数之和必等于台账条目数），默认按钮为「取消」。
- **互操作架构**：`KairoInterop`（IR + FormatAdapter + FidelityLedger + KairoBridge）与两个互不依赖的适配器 target；删掉任一通道，另一个仍可编译。

### 修复

- **#19** OTA 失败/超时后清理 `$TMPDIR` 解压目录与替换脚本（成功路径不删回滚备份）。
- **#20** 未读的安装失败结果不再被启动 5s 自动检查覆盖。
- **#21** 更新面板「检查中/下载中」提供真取消，关闭面板与取消语义分离。

### 判据

- 全量 **1481 tests / 144 suites** 通过，零 warning；i18n 双语校验通过。
- 互操作往返：MSPDI 187/37/2/126/3/4 逐项相等；OmniPlan 26/10/1/深度 4 全等。

## v1.1.1 — 2026-10-27

### 修复

- **OTA「退出并安装」永久卡死（#17）**：点「退出并安装」后进程不退出，60s 后脚本写 `app_not_quitting`，面板停在「正在安装更新」且**没有任何按钮**。根因是把「旧进程会不会退出」交给了未保存守卫——`NSApp.terminate` 触发 `applicationShouldTerminate` 的保存模态框，用户不答/取消/保存失败都返回 `.terminateCancel`，脚本等不到进程退出。
- 修法：① **装前先同步保存**，保存失败直接中止安装并报错（不再把人拦在模态框里）；② OTA 武装后 `applicationShouldTerminate` 返回 `.terminateNow` 旁路；③ 安装中轮询结果文件，失败即进 failed 态并可重试/关闭，同时清理 pending 三键；④ **75s 超时兜底**，任何状态都有按钮，不再出现无路可走的死界面。

### 判据与证据

- 新增 5 例 `OTAInstallGuardTests`：装前保存、保存失败不装、旁路生效、失败结果驱动面板、超时离开安装中。
- 全量 **1385 tests / 131 suites** 通过；零 warning。

### 已知未做

- 脚本超时后 `$TMPDIR` 里的解压目录仍会残留；下次启动 `consumePendingInstallResult()` 的失败仍可能被 5s 自动检查覆盖。两条已记入 issue #17 的后续项。

## v1.1.0 — 2026-10-27

### 新增

- **工作日历（F-22-06）**：项目可声明工作周（7 天 / 周一至周六 / 周一至周五 / 自定义七天开关）、每日工时（0.5–24h）与例外日（节假日 / 调休上班，可带备注）。排期按**工作日**推进，跨周末、跨假期自动顺延。
- **项目设置面板**：菜单栏新增「项目 → 项目设置…」，⌘K 同源可搜。三段卡片（工作周 / 每日工时 / 例外日），改动即时生效、合并为一步撤销；「恢复默认（全周 7 天）」一键回到改动前。
- **甘特非工作日阴影**：由项目日历派生，周末与节假日铺灰；无日历时不画任何带，与改动前一致。
- **顺延留痕**：约束或开始日期落在非工作日时，检查器显示「已从 2026-10-01 顺延到 2026-10-09（非工作日）」，不静默改期。

### 变更

- **`durationDays` 语义由「日历天」改为「工作日」**。默认全周 7 天时两者等价，**既有项目行为完全不变**（1343 个既有用例一条未改仍全绿）。
- `.kairo` 仍为 **formatVersion 2**：日历是可选加法字段，全默认时不写键；旧文件读入即全周，旧版本读新文件不受影响。

### 判据与证据

- 全量 **1379 tests / 130 suites** 通过（既有 1343 + 工作日历引擎 10 + UI 26）；debug 零 warning。
- 引擎：5 天工作周跨周末、FS 链每周末右移 2 天、节假日顺延、调休周六上班、里程碑吸附、ALAP、群组聚合跨非工作日、空工作日不死循环、存读往返。
- UI：26 例覆盖模板反推、末位上班日保护、同日例外覆盖、默认不落键、一撤销即回退、重复值不压栈、端到端「每周只周一上班 → 最晚任务推后」。

### 说明

- 顺延留痕没有做成 `Violation` 的 info 级别，而是结构化 `calendarAdjustments`（Violation 只有 warning/error，加 info 会连锁改三处文案与 String Catalog）。理由与裁决记录在 `docs/features/16-work-calendar.md` §6。

## v1.0.2 — 2026-10-27

### 变更

- **MCP 工具描述切英文（F-0714）**：21 个工具的 description、参数说明与 schema 枚举说明全部改为英文 —— MCP 是给 AI 客户端读的协议面，此前 20 条是中文，非中文模型理解会偏差。需求号（`US-E1-01` 等）保留以便追溯。
- **错误码一个未改**：`ToolFailure.code` 仍是 `{internal_error, invalid_argument}`，11 个 reason 稳定码逐项不变；v0.8.5 冻结文案逐字比对继续通过。

### 新增门禁

- `toolsListProtocolTextIsEnglishOnly`：递归扫描 `tools/list` 返回的每个工具名称、描述、schema 键名与枚举串，出现 CJK 即失败。该用例做过变异验证（把一条描述改回中文 → 变红），不是空转。

### 判据与证据

- `perl -CSD` 扫描 `Sources/KairoMCP/Tools.swift`：`description:` 行含 CJK = **0**；全文仍有 96 行含 CJK（注释与冻结错误文案），证明检测不是空转。
- 全量 **1343 tests / 126 suites** 通过；build 零 warning。

### 已知未做

- **冻结的 MCP 错误文案仍是中文**：`Tests/Fixtures/mcp-errors-v085.json` 逐字锁定，改动需解冻 fixture 并单独评审，已登记为后续工作项。

## v1.0.1 — 2026-10-26

### 修复

- **应用只有 arm64 一份，Intel Mac 打不开**：`tools/build.sh` 一直只构建宿主架构，而下载页没有任何「仅 Apple Silicon」说明 —— Intel 用户拿到 DMG 会直接遇到「应用无法打开」。现改为默认产出 **universal（arm64 + x86_64）**，app / `KairoCLI` / `KairoMCP` 三者一致；交叉编译不可用时回退宿主架构并显式告警。

### 变更（发布链路）

- **下载校验补齐**：DMG 与 ZIP 各出 `*.sha256`，另给汇总 `SHA256SUMS`（含 CLI tarball），随 Release 与 `artifacts/<tag>/`、`latest/` 一并归档。此前只有 CLI tarball 带校验和，而 DMG 才是用户实际下载安装的入口。

### 判据与证据

- `file dist/Kairo.app/Contents/MacOS/Kairo` → 双架构（x86_64 + arm64）；CLI / MCP 同。
- 全量 **1342 tests / 126 suites** 通过；`-warnings-as-errors` 通过。
- `update-manifest.json` 的 `sha256` 与发布的 zip 字节一致（OTA 载体完整性可自证）。

## v1.0.0 — 2026-10-26

首个正式版：单机、单人、可交付的完整闭环 —— WBS → 排期 → 审阅 → 实际进度 → 基线对比 → 报表。完整范围与准入判据见 `docs/release-1.0-scope.md`，发布检查单见 `docs/release-1.0-checklist.md`。

### 新增（相对 0.x 的最终形态）

- **排期**：ASAP/ALAP 双向传播、关键路径与宽延、违例检查；群组作为阶段门，依赖**下推到叶子**。
- **视图**：大纲（列宽/显隐/**顺序拖拽**、重置）与甘特（日/周/月、适合项目、直接编辑、增量平移 4.9 ms/1000 行）逐行对齐；检查器、⌘K 命令面板。
- **实际进度与基线**：实际开始/结束自动记录；不可变基线、偏差公式、**3 条基线同屏 8 色分轨**、项目摘要偏差、偏差 CSV（UTF-8 BOM / 11 列固定表头 / 孤儿分节）。
- **协作接口**：CLI 22 子命令、MCP 21 工具（语义对等、错误码稳定）、Claude Code 插件与深链。
- **状态词汇**：待办 / 进行中 / 已完成 / 受阻 / **已取消**（必填原因、可恢复、不进排期与统计口径）。
- 中英双语（含系统菜单同步切换）、应用内 OTA 更新、最近打开项目。

### 不兼容变更

- **`.kairo` formatVersion 2 起冻结**：新增字段一律加法+可选；破坏性变更必须升版本并提供相邻迁移。**旧客户端（0.12 及更早）打开 v2 文件会被明确拒绝**（`unsupportedFormatVersion`），不会静默丢数据。降级前请先在 1.0 中「另存为」留档。
- 列位置改由「单一列顺序」决定，取代 0.15 的「可选列紧随 finish、找不到锚点就追加末尾」；默认顺序下渲染结果不变。
- 取消任务必须填写原因，且只能通过 `status update`（`task update --status cancelled` 一律拒绝）。

### 修复（进入 1.0 的最后一批）

- 横向翻窗由整表刷新改为增量快照：37.6 ms → **4.9 ms**（D-038）。
- 接口测试并行串写根治：改用 `emit` 注入，不再全局替换 fd 1（D-036）。
- 大纲行内状态菜单恢复「已取消」并复用原因弹层，两个入口共用一条规则（D-037）。
- 稳定性审计修 5 条：异步打开期间误重载、外部刷新失败误摘最近打开、⌘S 静默覆盖磁盘、退出保存失败重复弹窗、退出守卫无测试缝。

### 验证

- 全量 **1342 tests / 126 suites** 连续两次通过；`-warnings-as-errors` 零告警。
- 性能：5,000 任务 × 3 基线 release decode 0.155 s（门槛 1 s）；1,000 行翻窗 4.9 ms（预算 16.7 ms）。
- 缺陷表无「待修复」项。
- 下载校验：附件提供 `Kairo-v1.0.0.dmg.sha256`、`Kairo-v1.0.0.zip.sha256` 与汇总 `SHA256SUMS`；`update-manifest.json` 的 `sha256` 与 zip 字节一致（OTA 载体完整性）。

### 已知限制

- **本版未签名、未公证**（Apple Developer 账号尚未就绪）：首次打开需右键 → 打开；OTA 的签名校验在未签名场景下不生效。账号就绪后将补发签名版本。
- 甘特同时最多显示 3 条基线，第 4 条起提示「另有 N 条未显示」。
- 无自动保存：崩溃会丢失未保存修改（有退出守卫，但没有恢复草稿）。
- 绕过 `saveProject` 的自定义导出路径不补基线颜色（读取侧派生兜底）。

## v0.17.3 — 2026-10-25

### 修复

- **大纲行内状态菜单恢复「已取消」（D-037）**：v0.16.0 因为行内没有原因输入，暂时把该项藏了起来（选它会被会话拒绝弹错）。现在抽出唯一判据 `OutlineStatusAction.forSelection(_:current:)` —— 转取消必弹原因层、其余状态直写、已在取消状态再选不重复弹；大纲行内菜单与检查器 `select` **共用这一个函数**，两个入口规则不再可能分叉。

### 判据与证据

- 新增 4 例：四种状态转取消必弹原因层、已取消再选不弹、其余状态直写、行内取消经 `cancelTask` 落库且原因去首尾空白。
- 全量 **1342 tests / 126 suites** 通过。

## v0.17.2 — 2026-10-25

### 修复（测试基建）

- **接口测试并行串写根治（D-036）**：`captureStdout` 过去用 `dup2` **全局替换 fd 1**，锁只能串行化「同样走捕获」的用例，挡不住别的套件直接 `print` —— 表现为偶发 JSON 首字节变成 `å`（BOM 被拦腰截断）或 SIGPIPE，单跑必过、并行随机红。
- 改为走 `CLIRouter.execute(... emit:)` 这个**本来就存在的注入缝**：新增 `cliOutput(arguments:environment:preferredLanguages:)` 收集输出，7 处调用点全部迁移，`captureStdout` 与其锁一并删除。唯一残留是 `CLILanguageTests` 的 `captureStderr`（单用例、`contains` 断言），已在注释标注。

### 判据与证据

- `swift test --filter Interface` **连跑 5 次，117/117 全绿**，每次 4.3–4.9 s（比 dup2 方案快约 1 s —— 少了一次全局重定向与管道读写）。
- 全量 **1338 tests / 125 suites** 通过。

## v0.17.1 — 2026-10-25

### 修复

- **甘特横向翻窗不再整表刷新（D-038）**：跨日翻窗过去走整表 `refresh()`，1000 行下 release 37.6 ms / debug 54.6 ms，是 60Hz 单帧预算（16.7 ms）的 2–3 倍，连续横滑每跨一天掉 1–2 帧。现在翻窗只重建甘特与状态栏，复用上一帧的大纲行与检查器，且不触发文件导出快照重编码：release **4.3–8.1 ms**（四次测量，门禁取 10 次样本平均）、debug **9.0–10.1 ms**（1000 行 × 3 基线 4.8–6.6 / 12.6–16.8 ms）。正确性用「同一窗口下增量快照 == 全量重建快照」逐字段断言（8 个视图状态场景 + 应用层真实会话，各 5 个随机窗口）；性能门禁两档并列（release ≤ 16.7 ms、debug ≤ 50 ms）。

### 判据与证据

- 相等性硬门禁：同一 windowStart 下增量快照与全量 refresh 逐子快照相等（8 种视图状态 × 5 个随机窗口 = 40 次比对，附变异检验）。
- 性能硬门禁：1,000 行 release ≤ 16.7 ms / debug ≤ 50 ms（两档写在用例里，避免 CI 抖动假红）。
- 全量 1338 tests / 125 suites 通过；A7 黄金布局一行未改仍绿；warnings-as-errors 通过。

## v0.17.0 — 2026-10-25

稳定化版本：不加新功能，只做性能取证、稳定性审计与发版链路整改。

### 修复（稳定性审计，5 条）

- 异步打开项目期间外部轮询仍在跑 → 会同步重载旧项目、清撤销栈、把目标文件降级成「再确认一次」并弹假提示。改为打开期间跳过轮询。
- 外部刷新复用打开路径 → 刷新失败会把**仍在编辑**的项目从「最近打开」里摘掉。改为刷新失败不摘。
- 有外部更新横幅时按 ⌘S → 静默覆盖磁盘版本并清横幅。改为保存后提示「已保留本地版本」。
- 退出时保存失败 → 取消退出后主窗口会**第二次**弹同一错误；且保存后未复核脏标记。改为先取走文案清槽再弹、保存后复查脏标记。
- 退出守卫无测试缝 → 抽出注入点（默认行为不变），补 5 条用例：未保存必拦、干净直接退、保存后退出、保存失败取消退出、无路径走保存面板。

### 变更（发版链路）

- **zip 也能 staple**：改为「签 App → 公证并装订 App → 打包 DMG/zip → 公证并装订 DMG」，CI 断言 App 与 DMG 都 `stapler validate` 通过；此前 OTA 的 zip 里没有票据，离线首启会被 Gatekeeper 拦。
- **凭据三态前置**：全空=未签名发布、齐全=全链路、只配一半=直接失败并列出缺失项（不再跑到 notarytool 才报错）。
- **未签名发布有标注**：Release 说明顶部加横幅，附件与 `artifacts/<tag>/` 落 `SIGNING.txt`（含 codesign 摘要），本地 `tools/release.sh` 同样写 `dist/SIGNING.txt`。
- **CLI/MCP 二进制补签名**（此前完全未签）；证书落 `$RUNNER_TEMP` 不进工作区、签名后断言 hardened runtime 与 Authority、去掉 `--deep`、补钥匙串清理、加 concurrency。
- **release 工作流补齐门禁**：gate-core 之外加上 gate-ui / 全角检查 / i18n；i18n 门禁抽成 `tools/gate-i18n.sh`，ci 与 release 共用。
- **Linux CI 与本地同口径**：两侧都开 `-Xswiftc -warnings-as-errors`；顺带清掉 `OutlineSelectionAcceptanceTests` 的一处未使用返回值告警（现在 `swift build --build-tests -warnings-as-errors` 干净）。

### 性能取证（docs/perf-1.0.md）

- **NFR-1 达标**：5,000 任务 × 3 基线 release 版 encode 0.136 s / decode 0.155 s / variance 0.170 s，体积 5.10 MB（×5 基线 7.31 MB）；相对 1 s 门槛余量 4.7×。体积与 v0.13 逐字节一致。
- **NFR-2 部分不达标**：1,000 行渲染的 6 项里 5 项达标（30–51 ms，预算 100 ms），**横向翻窗 37.6 ms 超过 60Hz 帧预算 16.7 ms**（D-038）。根因是翻窗走整表 refresh；修复方向已登记（增量重绘 + 逐帧成本钩子）。

### 判据与证据

- 全量 **1332 tests / 123 suites** 连续两次通过；`swift build --build-tests -Xswiftc -warnings-as-errors` 零 warning。
- 文档：`docs/perf-1.0.md`（71 行）、`docs/stability-audit-0.17.md`（41 行）、`docs/release.md`（339 行，含 5 个 secret 的生成、逐步签名/公证验证命令与期望输出、下载侧判定表）。
- **签名与公证链未实跑**：本机无 Developer ID 证书，`gh secret list` 只有 `UPDATE_SIGNING_KEY_BASE64`，已发产物全部是 ad-hoc 未签名未公证 —— 文档如实标注，未冒充已验证。

## v0.16.0 — 2026-10-25

### 新增

- **大纲列可拖拽重排（#12）**：拖列头**中部**=换位置（最小位移 8pt 才启动，拖动时显示插入竖线），拖**右缘**仍是调宽；顺序存全局偏好，换项目保留；右键菜单新增「重置列顺序」。序号与任务列仍是固定列（不可隐藏），但可以拖动换位置。
- **列显隐模型合并**：把「常规列隐藏集合」与「可选列显示集合」收成单一「成员 + 顺序」模型 —— 隐藏的列**守自己的槽位**，重新显示时回到原位置而不是跑到末尾；未知列丢弃、缺失列补末尾，旧偏好读入不丢列。
- **任务「已取消」终态**：`TaskStatus.cancelled` + `TaskItem.cancelReason`。取消**必须填原因**（空白拒绝且不写库），可「恢复为待办」；取消的任务不排期（甘特无条）、不进进度分母、不产违例、不进关键路径，群组聚合忽略它。检查器状态菜单选「已取消」会弹必填原因弹层；CLI 用 `status update <id> --status cancelled --reason "…"`；MCP `status_update` / `status_batch_update` 增 `cancelReason`。
- **工具栏基线菜单与菜单栏同源**：工具栏那颗棋盘旗现在渲染与菜单栏**同一个**菜单视图，逐条基线的显隐 / 主对比 / 8 色改色 / 改名 / 删除行为完全一致，不再各写一份。

### 变更

- 列顺序与列显隐都进 `kairo.workspace.preferences.v1`（新字段 `outlineColumnOrder`，键名不升版）；默认顺序不写键，旧偏好缺失即按默认顺序。
- 大纲行内状态菜单不再列出「已取消」——该状态需要填原因，走行内「一点即改」会被会话拒绝（D-037）；取消统一从检查器或 CLI 发起。

### 修复

- **取消必须带原因**：`task update --status cancelled` 一律拒绝（这条写入口不走状态回写、不落原因），取消只有 `status update` 一条路径；CLI 缺 `--reason` 或纯空白为用法错误（退出码 2）且在打开文件前就拒。
- **接口测试并行抖动（D-036）**：新增取消用例改用注入 `emit` 收行、不碰进程级 fd 1，`--filter Interface|Cancel` 连跑 4 次 147/147；存量套件仍用 `captureStdout`，根因待 v0.16.1 处理。

### 判据与证据

- 全量 **1318 tests / 121 suites** 通过；debug 零 warning。
- 新增 46 例：列顺序 24、已取消 22（模型/会话/排期/进度）、CLI/MCP 取消 10、检查器取消 6、工具栏菜单 3（部分与上列重叠计数按 suite 归并）。
- 真机待验：拖列头重排的手感、取消弹层的必填校验、恢复待办后甘特条回归。

## v0.15.1 — 2026-10-25

### 修复

- **界面上找不到 CSV 导出（用户实测反馈）**：v0.15.0 的偏差 CSV 只有 CLI 入口（`baseline variance --csv`），应用里没有任何按钮或菜单项 —— 等于这个功能对 GUI 用户不存在。
- 修复：把 CSV 组装从 CLI 目标搬到 **KairoCommands**（`VarianceCSV`），CLI 与 App 共用同一份实现（列头、BOM、RFC 4180 转义、孤儿分节全部同源，不可能漂移）；应用侧新增「基线 → 导出偏差 CSV…」菜单项与 ⌘K 命令，走 NSSavePanel 保存，成功后状态栏提示、失败弹应用内提示。

### 判据与证据

- 新增 2 例（`VarianceCSVExportTests`）：导出文件按字节带 BOM（EF BB BF）、第 4 行恒为 11 列固定表头、任务行逐行 11 列；无基线时抛 `CSVWriteFailure` 而不是写出空文件。
- 全量 **1253 tests / 112 suites** 通过。

## v0.15.0 — 2026-10-25

### 新增

- **基线面板**：菜单栏「基线 → 管理基线…」打开的清单，逐条显示颜色块、名称、创建时间、条目数、甘特显隐与主对比状态；行内可直接设为主对比、切换甘特显示、改色、重命名、删除（沿用二次确认）。底部固定两块：**孤儿条目**（任务已删除，只读，显示基线上的原始起止）与**基线之后新增**计数。
- **项目摘要偏差块**：检查器「项目」页新增「与基线对比」，一次看到结束偏差、晚完成数、逾期未完成、无基线条目、基线后新增、已删除条目；未选基线时整段不出现，不做「缺省比最新」的静默回落。
- **偏差 CSV 导出**：`kairo baseline variance --csv <路径>`，UTF-8 带 BOM 便于 Excel 直接打开；前三行是基线身份（id / 名称 / 创建时间），第四行起 11 列固定表头（taskID,title,baselineStart,baselineFinish,planStartVariance,planFinishVariance,actualStartVariance,actualFinishVariance,overdueDays,hasBaseline,isForecast）；空值留空不写 0，负数保留符号，孤儿条目单独分节且列数不变。`kairo project summary` 同步输出同一份偏差块。

### 修复

- **CSV 解析崩溃**：导出文件带 BOM，解析助手按 `hasPrefix("#")` 判注释时被 BOM 挡掉，落到空分节的下标 -1，进程直接 `Fatal error`。现已改为剔除 BOM 后按行种类分派，并把分节/取列收敛到 `requireCSVSection` / `requireCSVField` / `requireCSVWidth`，结构性异常变成一条红用例而不是中断整轮测试。
- CSV 字段按 RFC 4180 转义（逗号、双引号、换行），测试端用状态机解析器 + python `csv` 模块双向交叉验证。
- `--csv` 与 `--json` 互斥；`--csv` 后缺路径不再把 `--file` 的值当文件名写垃圾文件。

### 判据与证据

- 全量 **1251 tests / 112 suites** 通过；debug 零 warning。
- 新增 33 例：项目摘要 13、基线面板 12、CSV 与 project summary 8。
- 真机验证：在 36 项路线图上创建基线并导出 CSV，列头 11 项、行 36、孤儿 0，Excel 可直接打开。

## v0.14.5 — 2026-10-25

### 修复

- **序号列仍然显示不全（v0.14.4 未修好）**：v0.14.4 只是把列加宽到 44pt，但序号是**左对齐**，多级序号（`1.1`、`10.12`）贴着列左缘被行裁剪吃掉首位，视觉上仍是「.1」。改为**右对齐**（数字列惯例）并留 6pt 右内距，任何层级的序号都完整可见。

### 判据与证据

- 全量 **1218 tests / 109 suites** 通过；debug 零 warning。

## v0.14.4 — 2026-10-25

### 修复

- **切换语言后没有任何反馈**：语言偏好写入 `UserDefaults` 不会触发 SwiftUI 重算，勾选态停在原处、菜单一关就再无动静，用户只能认为「没生效」。现在：① 菜单改用 `@AppStorage` 观察同一偏好键，选完立刻打勾到新语言；② 弹出提示「已切换语言：English —— 退出并重新打开 Kairo 后生效」。
- **大纲序号显示不全**：「10.12」这类三级序号在 30pt 宽的序号列里会被截断或换行。列宽 30 → **44**，并加 `lineLimit(1)` + `minimumScaleFactor(0.8)` 兜底超深层级。

### 变更

- 序号列变宽 14pt，标题列相应收窄（标题吃余量）；相关布局用例的期望值同步更新（600pt 下固定列合计 522 → 536，360pt 下 82.8 → 91.2）。

### 判据与证据

- 全量 **1218 tests / 109 suites** 通过；debug 零 warning。
- 语言切换仍按既有约定「重启生效」，但不再是「无反馈」。

## v0.14.3 — 2026-10-25

### 修复

- **群组依赖只顺延了一部分（v0.14.2 回归，#16）**：v0.14.2 里群组依赖只让下游等到「前驱阶段开始后 N 天」，而不是「前驱整棵子树完成」。根因在拓扑序：只保留「群组节点 → 下游任务」一条边时，群组节点在 Kahn 队列里很早就出队，下游任务会在前驱子树**还没排完**时被计算。
- 修复：拓扑序把群组前驱**展开为其全部叶子**（阶段门 = 前一阶段所有叶子做完），并排除自环；前向传播的两遍与子树聚合窗口保持不变。
- 实测（路线图项目）：v0.15 11/2 收口 → v0.16 列表 11/2–11/20 → **v0.16 MCP 11/20–11/24**（此前是 11/13 就开始）→ v0.17 11/24–12/5 → v1.0 12/5–12/11。

### 判据与证据

- 新增回归守卫 `groupDependencyWaitsForWholeSubtree`：阶段 A 内部串行（2 天 + 3 天），阶段 B 依赖 A，B 的任务必须等 A2 完成才启动。
- 全量 **1218 tests / 109 suites** 通过。

## v0.14.2 — 2026-10-25

### 修复

- **群组依赖真正生效（#16）**：给「阶段/版本」这类群组加依赖后，依赖现在会**下推到整棵子树**——前一阶段全部完成，后一阶段的叶子任务才会开始。实现要点：有效前驱 = 自身依赖 ∪ 所有祖先群组依赖（去重、防环）；环检测、拓扑序、前向/后向传播、宽延一律按有效前驱计算；群组作为前驱时取**子树聚合窗口**而非自身占位窗口，并做两遍前向传播让下游吃到聚合值。
- **群组依赖可编辑（#16）**：大纲「前置」列对群组不再置灰，检查器 Dependencies 区块可对群组增删依赖（在此之前群组一行被整体判为只读，用户无法设置阶段依赖）。群组的日期/工期/进度仍为聚合只读值。
- **群组跨度不再恒为 1 天（#16）**：`schedule compute` 输出的群组窗口改为子树聚合，与甘特群组条同源；此前 CLI 打印「群组 1 天」而甘特画的是聚合跨度，两者自相矛盾。
- 顺带修正群组提示条文案：由「所有字段只读」改为「日期/工期/进度为聚合值，依赖在群组上维护」。

### 判据与证据

- 新增 14 例：`GroupDependencyTests` 5 例（下推、两级祖先、成环检出、群组跨度=子树、无群组依赖时行为不变）+ `GroupDependencyEditingTests` 9 例（前置列可编辑、其余文本列仍只读、落库与清除、检查器候选、增删一步撤销、日期仍只读、叶子行为不变）。
- 全量 **1217 tests / 109 suites** 通过；debug 构建零 warning。

## v0.14.1 — 2026-10-25

### 修复

- **切换英文后菜单栏残留中文（#15）**：`文件 / 编辑 / 显示 / 窗口 / 帮助` 这些 AppKit 标准菜单跟随的是**进程级**语言（`AppleLanguages`），而应用内文案走的是自己的 `.lproj` 选择 —— 两套来源互不影响，于是出现「自定义菜单已英文、系统菜单仍中文」的中英混排。
- 修复：`AppLanguage.store(_:)` 与启动时（`applicationWillFinishLaunching`）都把当前语言同步写入 `AppleLanguages`（English → `["en"]`、简体中文 → `["zh-Hans"]`、跟随系统 → 移除该键）。与既有「切换语言后重启生效」同一时机；同时修复历史安装（早前只写了 `KairoLanguage`，系统菜单会一直停在系统语言）。

### 判据与证据

- 新增 2 例：`processLocalizationFollowsAppLanguage`（en / zh-Hans / system 三档映射）、`storingLanguageAlsoWritesProcessLocalization`（`store` 是唯一写入口，两个键同步落盘，杜绝半更新状态）。
- 全量 **1203 tests / 107 suites** 通过。真机核验：`KairoLanguage = en` 重启后菜单栏全部为英文（含 File / Edit / View / Window / Help 及其系统项）。

## v0.14.0 — 2026-10-25

### 新增

- **甘特图上同时显示多条基线**：行内分轨，最多 3 条（保守 / 基准 / 激进），基线细条恒在计划条下方、与计划条共用同一时间轴，一眼看出「当时的承诺」相对现在偏了多少。基线轨只读，拖动不会改期。
- **基线用颜色区分**：8 色调色板，创建时按「未占用的最小索引」分配，删除其它基线不会让已分配的颜色改变；颜色写进 `.kairo`（可选字段，**不升 formatVersion**），旧文件在保存时按创建顺序补齐，打开时不置脏。
- **顶级「基线」菜单**：新建基线（⌥⌘B，恒为第一项）→ 每条基线的子菜单（在甘特图中显示 / 设为主对比 / 8 色改色 / 重命名 / 删除）→ 未显示条数提示 → 不对比 → 图例（颜色 · 名称 · 色名 · 创建日期）。菜单与 ⌘K 同源；颜色命令不进 ⌘K 以免挤爆面板。
- **CLI / MCP**：`baseline color <id|前缀> <0…7>` 与 `baseline_set_color` 新增；`baseline list/create/variance` 的文本与 `--json` 都返回 `colorIndex`（缺字段按调色板派生，不写 0）。MCP 工具总数 20 → 21。

### 变更

- 「另有 N 条未显示」只统计**被 3 条上限截断**的数量，不统计用户自己没勾选的基线（说明项回答的是「第 4 条为什么画不出来」）。
- 基线颜色是视图属性但落进项目文件：同一项目换机器打开颜色一致；改色一步可撤销。

### 判据与证据

- 全量 **1201 tests / 107 suites** 通过；release 构建 `-warnings-as-errors` 零 warning。
- **A7 黄金布局未被触碰**：`DayWidthTests` / `DayWidthAcceptanceTests` 一行未改仍全绿；`n=0`（无基线）的纵几何与 v0.13 逐像素一致。
- 几何走纯函数（`BaselineLanes` 表驱动 n=0…3）；横向换算收敛为唯一实现（`GanttLayoutEngine.x/width`），计划条与基线不再各写一份。
- 离屏渲染取样验证：三条轨 lane top 11/16/21 处取色等于调色板 0/1/2（容差 12），行底无基线色，隐藏全部基线后画布基线色像素数为 0。
- 命中闸门：`n=3` 时点在基线轨（11…15 / 16…20 / 21…25）全部 miss，不会误拖改期。

### 已知限制

- 同时显示上限 3 条；第 4 条起只在菜单提示，不替换。
- 绕过 `saveProject` 的自定义导出路径不补色（读取侧派生兜底，不落盘）。
- 工具栏的基线菜单尚未加显隐/改色，入口以菜单栏与 ⌘K 为准（v0.14.1 对齐）。

## v0.13.3 — 2026-10-25

### 新增

- **基线入口进菜单栏与 ⌘K（D-035）**：「新建基线」与「不比较基线」两条命令加入「显示」菜单与命令面板 —— 之前基线只能从工具栏那颗棋盘旗进入，窗口一窄就被系统收进溢出菜单，用户找不到「新建基线」在哪。

### 判据与证据

- 命令注册表 42 → 44 条（`WorkspaceStoreTests` 计数同步）；全量 **1107 tests / 100 suites** 通过。

## v0.13.2 — 2026-10-25

### 修复

- **甘特画布左右平移在会话中静默失效（D-034）**：现场日志显示 `scroll surface attached` 之后出现两次 `detached`，此后再无 `attached` —— 监听被摘掉且没人补装，画布完全不动而界面无任何异常。根因：监听只挂在 `viewDidMoveToWindow` / `viewWillMove(toWindow:)` 上，SwiftUI 在结构变化时不保证这对生命周期按序到达。
- 修复：新增 `syncMonitoringState()`，在每次 `updateNSView` 时把「视图在窗口」与「监听在岗」拉回一致（窗口有视图但监听缺失就补装，反之摘除）。漏掉的生命周期事件不再致命。

### 判据与证据

- `GanttScrollSurfaceTests` 新增 2 例：`syncMonitoringStateReattachesAfterUnexpectedDetach`（模拟漏事件后自愈补装）、`syncMonitoringStateStaysOffWithoutWindow`（不在窗口不得凭空安装）。
- 全量 **1107 tests / 100 suites** 通过；debug 构建零 warning。

## v0.13.1 — 2026-10-25

### 修复

- **大纲行点选不灵（D-033 / #13）**：整行挂了拖拽重排的 `.onDrag`，按下后指针轻微移动就启动拖拽会话，把行点击吞掉 —— 表现为「点不中，或者非常难选中」。改为拖拽源只挂**行首 12pt 握把**（落在序号列左缘，不占布局、不遮状态列菜单，单击握把同样选中），行本身只保留 `.onDrop`，点击与拖拽物理隔离。
- **列交界左右拖动（Excel 式）**：原来只有表头 6–8pt 的窄手柄能调宽，行区域拖过去既没调宽也没选中。新增整列高度的 **8pt 交界命中带**（表头与行区域共用同一套几何与光标），悬停变左右调整光标、拖动改宽、松手才落盘、双击复位；末列右缘（大纲/画布分界）内缩一个热区，避免两处手柄打架；被裁到视口外的交界不铺命中带。

### 判据与证据

- `OutlineSelectionAcceptanceTests` 14 例（点选与检查器联动、重复点击不丢选中、整行 `.onDrag` 已移除、热区 ≥ 8pt、调宽与复位持久化、结构守卫反向对照）。
- `OutlineRowInteractionTests` 14 例（交界 x 与列右缘一致、命中带不重叠/末列内缩/视口外丢弃、握把偏移与宽度、加点覆盖层后行节距仍 = 行数 × 28pt）。
- 全量 **1105 tests / 100 suites** 通过；`swift build -c debug` 零 warning。
- **待人工验收**：真实鼠标拖拽手感与光标变化在离屏测试里不可验，走查清单见 `docs/features/09-d033-cases.md`（M-01…M-10）。

## v0.13.0 — 2026-10-25

> **发版链路说明（2026-10-25）**：v0.10.0 → v0.12.0 为本地构建与装机验证，未打 tag、未走 release CI（因此 GitHub Releases 上没有对应产物），不是产物丢失；从 v0.13.0 起恢复「tag → CI 发布」流程，历史版本不再回补 tag 以免与产物错位。


### 新增

- **基线（Baseline）**：把当前排期冻结成一份不可变快照（条目只存任务身份 + 计划起止 + 完成度 + 里程碑标记），任意时刻对比**选中的那一条**；基线不可编辑，调整计划后只能新建一份。
- **大纲四个基线列**（基线开始/基线结束/开始偏差/结束偏差，**默认隐藏**）：偏差 = 当前计划 − 基线，日历天，正数 = 比承诺晚；无基线条目的任务标记为「无基线」、单元格显示「—」而不是 0。
- **检查器基线段与项目页基线面板**：并列显示计划偏差与实际偏差（实际缺失时显示「尚未结束」，不拿计划冒充实际）；面板单独列出「任务已删除」的孤儿条目与「基线之后新增」的任务；删除基线需二次确认。
- **CLI / MCP**：`baseline list|create|delete|variance` 四个子命令与 `baseline_create/list/delete/variance` 四个工具，输出统一带 `baselineID`/`name`/`createdAt`，数值与 `BaselineEngine` 逐字段一致；空值省略键、负数保留符号。
- 偏差计算按 `(selectedBaselineID, session.revision)` 缓存：缩放/日宽/面板等纯视图动作不重算，任务编辑与基线增删改名才失效。

### 变更（不兼容，需注意）

- **`.kairo` 格式版本 1 → 2**：新增顶层 `baselines` 数组；无基线的项目不写该键。**0.12.0 及更早版本打开 v2 文件会被明确拒绝**（`unsupportedFormatVersion`，提示升级 Kairo），不会静默丢基线。v1 文件打开时内存内迁移、**不落盘**，首次保存才写成 v2。
- 偏差字段名与符号规则自本版起作为对外契约（CLI `--json` 与 MCP 返回同名同义），后续改口径视为破坏性变更。
- 基线删除不做软删除、不留审批痕迹（与 OmniPlan 一致，PMBOK 口径不适用单人工具）。

### 修复

- **D-031**：`WorkspaceView` 的 body 单表达式在 CI runner 上类型检查超时（`unable to type-check this expression in reasonable time`），按「框架 / 浮层 / 弹窗两段」拆成四个计算属性，逻辑不变；本地不复现、只在 runner 复现，故本轮以 CI 为验证依据。
- **D-032**：「载入示例项目」的未保存确认绑定写成 `pendingLoadExample != nil`（该值是 `Bool`，比较恒真），弹窗语义失效；拆 body 后编译器告警暴露，改为直接取布尔值。
- **D-030**：`RecentProjectsTests.launchOpensTheMostRecentProject` 改为「完成回执」等待（`awaitPendingOpenForTesting`，`CheckedContinuation` 挂起、打开收尾统一 resume），去掉墙钟 sleep 轮询 —— 并行全量下的偶发超时假红消除。

### 判据与证据

- 全量 **1077 tests / 98 suites** 通过（`swift test --disable-sandbox`，2026-10-25 15:40，树已冻结）。
- 基线相关 139 例分四层：core/storage/commands 91、pres 19、app 17、cli+mcp 12；判据 1-12 四层均有落盘用例。
- 体积/耗时（debug，**耗时为单次运行样本、与机器负载相关**；体积是确定值）：5,000 任务 × 3 基线 = **5.10 MB**（encode 0.108–0.515 s / decode 0.150–0.262 s / variance 0.199–0.284 s）；5,000 任务 × 5 基线 = **7.31 MB**（231 B/条目）。内置体积护栏 12 MB / 15 MB 并做过变异验证。
- 已知边界（不算缺口，但未验证）：① 视图侧只做函数级与本地渲染断言，没有整屏截图比对；② 只在 macOS 跑，未走 Linux CI 口径；③ 基线数不设上限，未测 50 条基线的体积曲线。

## v0.12.0 — 2026-10-25

### 新增

- **任务的实际开始 / 实际结束**：计划之外单独记录「真的什么时候开工、什么时候完的」。任务首次进入「进行中」（或进度 > 0）时自动记实际开始；完成时自动记实际结束；两种时间都不覆盖已存在的值，回退到「待办」也不会抹掉实际开始（历史不因状态回退消失）。
- 检查器新增「实际」分区（两行日期，可手工补录与清空，群组不显示）；大纲新增「实际开始」「实际结束」两个可选列，**默认隐藏**，走列菜单按需打开。
- CLI `task get` 输出实际开始/实际结束两行（有值才输出）；`task list --json` 带 `actualStart`，实际结束沿用既有 `completedAt` 键，不新增 `actualFinish`。

### 变更

- `completedAt` 的语义明确为「实际结束」，界面与 CLI 标签统一改为「实际结束」（原「完成于」退场）。
- 新增错误码 `model_actual_date_order_invalid`：实际结束早于实际开始被拒绝且不写库。

### 判据与证据

- 验收用例 24 例（`ActualDatesAcceptanceTests`）+ 接口层 3 例（`ActualDatesInterfaceTests`，锁 CLI/MCP 键形状）+ core 24 例 + 展示 14 例 + 应用层 13 例；全量 **937 例 / 93 suites** 通过。
- 判据映射与先红证据见 `docs/features/07-actual-dates-cases.md`；设计见 `docs/features/07-actual-dates.md`。
- 群组行「实际时间恒 nil」有可失败用例（先写脏数据、再断言快照抑制），并做过变异验证（去掉抑制即变红）：
  - 去掉行侧抑制（`Presenter` 的 `actualStart: isGroup ? nil`）→ `ActualDatesPresentationTests` 报 `(row.actualStart → 2025-10-18) == nil` 失败、`ActualDatesWorkspaceTests` 报 `(groupRow.actualStart → 2025-11-03 16:00) == nil` 失败；
  - 去掉检查器侧抑制（`completedAt` / `actualStart` 两处）→ 报 `(inspector.actualStart → 2025-10-18) == nil`、`(inspector.completedAt → 2025-10-20) == nil` 失败；
  - 还原后复跑即绿（变异由 dev-coder-ui 执行，2026-10-25）。

## v0.11.0 — 2026-10-25

### 新增

- **非工作日着色开关（F-14-14 / #10）**：时间轴默认不再把周六/周日画成灰底 —— Kairo 按日历天排期，「一周 7 天都算工作日」才和图上的条体一致。需要对照周末时，用「显示 → 显示/隐藏非工作日」（或 ⌘K 命令面板）打开，周末重新以灰带标出。
- 该选择是应用级视图偏好（`UserDefaults` 的 `kairo.workspace.preferences.v1`），换项目与重启都保留；旧偏好在缺失该字段时回落为「不显示」。

### 变更

- `GanttLayoutEngine.make` 的 `nonWorkingWeekdays` 默认值由 `[1, 7]` 改为空集：库层默认「全是工作日」，需要着色由调用方显式传周末集合。
## v0.10.2 — 2026-10-25

### 修复

- **无日期任务一律从「今天」起排（D-029）**：没设项目开始日期、任务也没填开始日期的项目，所有任务条都落在今天，且锚点随打开日期每天右移。改为按「项目开始日期 → 最早任务开始日期 → **项目创建日期** → 今天」推导，即「输入任务的那天」就是计划起点；Podium 这类 10/21 建立的 WBS 现在从 10/21 起排。
- 起点提示条按实际来源出措辞（按创建日期 / 按最早任务 / 按今天），不再一律说「已按最早任务开始日期推导」。
- `ScheduleResult` 与 `GanttSnapshot` 新增 `projectStartSource`（旧文件解码时回落为原措辞，不影响兼容）。

## v0.10.1 — 2026-10-25

### 修复

- **甘特图双指横向平移在长会话中失效（D-028，F-14-18 第三次回归）**：左右两个方向都不再响应，退出重启才恢复。根因不在判定规则（纯函数单测一直全绿），而在架构：平移链路横跨 `HorizontalScrollMonitor.shared` / `HorizontalPanContext.shared` / `CanvasViewportProbe` 三个常驻全局件，缓存的视口矩形与 `weak window` / `weak store` 在视图重建或画布纵向滚动位移后变旧且无人刷新，命中判定随即恒为「光标不在画布内」，事件全部被放行。
- 改为 **视图自持** 的 `GanttScrollSurface`（`NSViewRepresentable`）：监听随视图进出窗口装卸，命中用自身 `bounds` 现场换算，派发目标每次渲染注入，窗口起点只由 `WorkspaceStore.panWindow(byDays:)` 推进（`viewState.windowStart` 为唯一真源）。删除三个全局件与「首响应者是否 `NSTextView`」的编辑判据。
- 回归防护补到真正会失效的层级：`GanttScrollSurfaceTests` 13 例覆盖 controller（累积/放行/日宽）、视图层（`handle` 消费与放行）、store 层双向整天推进。

## v0.10.0 — 2026-10-25

### 新增

- **最近打开的项目（最多 5 个）**：成功打开或保存的 `.kairo` 文件记入最近列表，同一文件去重后置顶，超过 5 条挤掉最旧；文件被移动/删除后，失效路径在读取时剔除，菜单里不留打不开的死链。入口是「文件 → 最近打开」子菜单与 ⌘K 命令面板（标题为文件名，同名文件用父目录消歧），子菜单底部有「清除菜单」——只清列表，不动当前项目。
- **启动默认打开最后一个项目**：本次启动没有显式打开请求（双击 `.kairo`、深链）且当前未载入项目时，启动 300ms 后自动打开最近列表中最新且仍存在的文件；有显式请求则让位，不抢用户要打开的文件。打开失败的文件不进列表。
- 偏好键 `kairo.recent.projects.v1`（`UserDefaults`，路径数组；只存路径不存书签）。

## v0.9.1 — 2026-10-24

### 新增

- **关于面板显示版权与联系邮箱**：credits 第二行为 `Copyright (c) 2026 cygnusyang <ruohuyang@gmail.com>`；该声明不参与本地化，也不进 String Catalog（法律文本不翻译）。

### 变更

- **LICENSE 版权行补联系邮箱**：`Copyright (c) 2026 cygnusyang <ruohuyang@gmail.com>`。

### 修复

- **菜单栏图标误命名**：`design/icons/menubar` 下两个以邮箱命名的 PNG 实为 22pt / 18pt 的 @2x 倍图，改为 `kairo-menubarTemplate@2x.png` / `kairo-menubarTemplate-18@2x.png`；`tools/build.sh` 不再把这两个设计源文件当运行时资源拷进 `.app`。

## v0.9.0 — 2026-10-24

### 破坏性变更

`KairoCore` / `KairoCommands` / `KairoPresentation` / `KairoUpdater` 仅有本仓库内部消费者，iPadOS 壳尚未发布；pre-1.0 不为下列删除保留兼容层。

- 删除 `Violation.message`：违例只带 `reason`（语义枚举 + 参数）与派生的 `code`
- **`violations_list` 的 `code` 取值改变**：原先返回规则码（`cycle`、`cannot_schedule_asap_alap` 等），现返回稳定错误码（`schedule_cycle`、`schedule_negative_slack` 等）。按旧码分支的脚本与提示词需改用新码或改用 `reason` 的语义字段。
- **`violations_list[].reason` 为结构化语义值**，其 JSON 形状随 `ViolationReason` 演进，**不作为稳定契约**；稳定契约是 `code`（47 个冻结码）。
- 删除 `RuleCategory.name`：规则名改由视图按 `violation.rule.<code>` 查 Catalog
- 删除 `StatusBarSnapshot.zoomLabel` / `zoomDetail`：改为 `zoom: ZoomIndicator`（`preset` + `pointsPerDay`）
- 删除 `ViolationItem.name` / `message`：改为 `code` + `reason`
- 删除 `WorkspacePresenter.zoomLabel(_:)` / `zoomDetail(dayWidth:)`
- `OutlineDateEditing.disabledReason(for:)`（返回中文整句）改为属性 `disabledReason: DateFieldDisabledReason?`
- `SessionError` 旧签名：增加 `reason: KairoErrorCode`；`code` 与 `message` 保留
- 删除 Updater 各类型的 `errorDescription`：改为 `UpdaterErrorCode`（码 + 参数）
- `UpdaterState.failed(String)` → `failed(UpdaterFailure)`
- `KairoSession.loadWarnings: [String]` → `[LoadWarning]`

### 新增

- **界面双语（英文 / 简体中文）**：英文为源语言，简体中文为译文；语言按系统语言协商，`CFBundleLocalizations` 声明 `en` 与 `zh-Hans`，启动时确定。
- **应用语言设置（三档）**：跟随系统 / English / 简体中文，持久化到 `KairoLanguage`；缺失或非法值（含被手工改坏）回退跟随系统。
- **String Catalog（419 键）**：`Apps/macos/Resources/Localizable.xcstrings` 为唯一源文件；`.xcstrings` 不进任何 target 的 `resources`（SwiftPM 只原样拷贝、不编译，resource bundle 也没有 `Info.plist`），改由 `tools/i18n-compile.sh` 在打包期用 `xcstringstool` 编出 `en` / `zh-Hans` 两份 `.lproj`，`tools/build.sh` 在 `codesign` 之前拷进 `Contents/Resources/`；缺 Catalog 或任一语言目录直接失败，不产出单语包。
- **`KairoErrorCode`（47 个稳定码）**：`<group>_<detail>` 文法，其中 `schedule_start_after_project_window` 归因「任务开始日落在项目窗口外」；v0.9.0 起冻结，只增不改。
- **`UpdaterErrorCode`（34 个稳定码）**：`updater_` 前缀，覆盖清单解析、签名校验、校验和、端点策略、下载、安装与产品校验（含 F-0719 的 `install_app_still_running` / `install_backup_failed` / `install_replace_failed`）；更新面板按码翻译。
- **违例文案单一实现（F-0720）**：`violations_list` 恢复 `message` 字段（v0.8.5 有此字段，语义化后一度缺失）；文案由 `KairoCommands.ViolationText` 统一渲染，CLI 与 MCP 共用一份，阶段一均为中文。
- **MCP 错误新增 `reason`**：`code` 六个取值冻结不变（`project_not_open` / `task_not_found` / `invalid_argument` / `file_unreadable` / `unsupported_format` / `internal_error`），`reason` 给出细粒度稳定码；`message` 保持中文原样，切英文排在 v0.10.0。
- **CLI 语言策略**：`--lang <bcp47>` 与 `KAIRO_LANG`，优先级 命令行 > 环境变量 > 系统语言；系统语言不可判定时回退简体中文，既有中文脚本不受影响；`--json` 输出与语言无关，两种语言下字节一致。
- **多语言 CI 门禁（`tools/i18n-lint.sh` + `tools/i18n-lint-selftest.sh`，31 例）**：零硬编码中文（白名单已清零）、`KairoCore` / `KairoCommands` / `KairoPresentation` 无 `Bundle.module`、两份 `.lproj` 的键集合与占位符一致、白名单为空；无跳过开关，Catalog 缺失即失败。

### 变更

- **分层不再持有文案**：违例、会话错误与更新错误一律「码 + 类型化参数」，快照只带语义值；视图层是唯一翻译点，CLI 与 MCP 各自渲染。
- **打包清单**：`CFBundleDevelopmentRegion` 由 `zh_CN` 改为 `en`，新增 `CFBundleLocalizations`（`en` / `zh-Hans`）。
- **发版前置校验**：`tools/release.sh` 在改版本号之前编译 Catalog 并断言白名单为空，多语言闸门不合格即中止发版。
- **快照零自然语言（F-0718）**：`OutlineSnapshot.filterSummary: String?` 改为 `filterExplanation: FilterExplanation?`，筛选说明由视图按语义结构渲染，快照不再携带整句。
- **更新检查失败的兜底映射收紧**：未知错误（`URLError` 等）不再把 error 描述拼进界面参数，改为 `updater_check_failed` + 诊断号 `OTA-E-2001`；原始错误只进日志。
- **安装失败只传稳定码（F-0719）**：更新安装不再把替换脚本的原文或中文字符串带给界面，只传稳定码与 `exitCode`；结果文件里 `message` 字段名保留（兼容旧版本脚本已写下的结果文件），内容改为稳定码，旧的中文取值解析为 `nil`，调用方只认退出码。

### 修复

- **任务晚于项目窗口时的违例归因（D-022）**：改报 `schedule_start_after_project_window`，参数含任务开始日与项目窗口，中文文案点明是输入导致，不再笼统报「负宽延」。
- **时限窗口按日历日计算（D-023）**：原先用 `86400` 秒换算，跨夏令时（America/New_York 春进 / 秋退）会差一小时并误判时限冲突；改用日历加法。
- **排期「无下界」哨兵统一（D-024）**：`startDateLowerBound` 与排期内部哨兵共用 `ScheduleBounds.noLowerBound`，行为不变。
- **脚本错误提示被吞（#7）**：六处变量紧贴全角标点（`tools/release.sh` 两处、`tools/install.sh` / `tools/package.sh` / `tools/sign_update_manifest.sh` / `tools/release_notes.sh` 各一处），bash 3.2 把全角字符并入变量名，出错时以 `unbound variable` 崩溃而非打印原因；改用 `${VAR}`，并新增 `tools/check-shell-fullwidth.sh` 接入 CI 防止复发。

## v0.8.5 — 2026-10-24

### 新增

- **发布附带 CLI / MCP 二进制**：Release 增加 `kairo-v0.8.5-macos-universal.tar.gz`（含 `kairo` 与 `kairo-mcp`，arm64 + x86_64 通用二进制）及 `.sha256` 校验文件。接入智能体不再需要装 Swift 工具链编译，解包即可用。
- **持续集成**：新增 `.github/workflows/ci.yml`，push 与 PR 触发 macOS（测试 + 两道门禁）与 Linux（`swift:6.0-jammy`，验证 ADR-004 可移植性）双任务，README 挂 CI 徽章。
- **可选签名与公证**：发布流水线支持 Developer ID 签名 + `notarytool` 公证 + staple；未配置证书时整段跳过，未签名发布照常进行。所需 secrets 见 `CONTRIBUTING.md`。
- **英文文档**：新增 `QUICKSTART.md`、`ARCHITECTURE.md`、`CONTRIBUTING.md`、`SECURITY.md`、Issue / PR 模板；五张架构图改为中英双语生成（`tools/gen-arch-svg.py`，`KAIRO_SVG_LANG=en|zh`）。

### 修复

- **Linux 构建失败（#4）**：`Package.swift` 外层 `#if os(macOS)` 内嵌套同名条件，非 macOS 时 `updaterProduct` 未定义、清单编译失败。
- **核心层依赖 CoreFoundation（#5）**：`FormatDocument.parseVersion` 用 `CFGetTypeID` 判 JSON 布尔，Linux 无此符号；改用 `objCType`，行为不变。
- **测试目标硬依赖 Darwin / Process（#6）**：`InterfaceTests` 条件导入 Darwin/Glibc；`TaskHookTests` 依赖 `Process`，限定在 Darwin 主机执行。

## v0.8.4 — 2026-10-24

### 修复

- **甘特图双指横向平移无响应（D-027，F-14-18 回归）**：v0.6.0 交付的触摸板平移在真机上表现为「画布不动」，两轮排查后确认是四处串联闸门，逐条拆除：
  - **坐标同源**：视口改由 `CanvasViewportProbe`（NSView `convert(bounds, to: nil)`）上报 AppKit 窗口坐标，光标用 `window.convertPoint(fromScreen:)` 换算到同一空间；不再拿 SwiftUI `.global` 矩形比对 `locationInWindow`。
  - **单实例**：监听与平移上下文收敛为全进程单例（`HorizontalScrollMonitor.shared` / `HorizontalPanContext.shared`），视图重建只重复 `start()`（接管语义）。此前 SwiftUI 重复 `onAppear` 会叠出多个监听，且可能绑在已销毁实例上（视口恒 nil）。
  - **不按事件窗口身份判定**：`scrollWheel` 的 `event.window` 常为 nil、`keyWindow` 可能指向辅助窗口，改为「光标是否在画布视口内」定位。
  - **「编辑中」按光标落点判定**：SwiftUI 工作台窗口在没有任何输入框获得焦点时，首响应者仍是窗口共用 field editor，原判据会把每条滚动当成编辑中放行 —— 这是最后一处、也是最隐蔽的一处。
  - 判定抽为纯函数 `GanttScrollRouter`；连续滚动由 `advance(byDays:)` 就地推进窗口起点（不再反复派发同一目标），整天推进改用 `Calendar` 加法（跨 DST 安全）。
  - 现场诊断：新增 `os.Logger`（subsystem `ai.kairo.app` / category `gantt-pan`）记录安装、首个滚动事件（含视口/光标/是否命中）、每种放行原因与每次平移提交，可用 `log stream --predicate 'subsystem == "ai.kairo.app"'` 定位。
  - 验证：合成 `CGEvent` 横向滚动 + 光标定位跑通端到端（日志显示 8 次滚动 → 7 次整天提交，状态栏窗口区间由 10/23–… 移至 10/17–11/2）；新增 26 例用例（含事件级消费与「编辑中」判据），全量 768/768。

### 变更

- **更新面板改为标准面板形态**：图标徽章 + 标题 + 说明 + 详情 + 右对齐动作三段式（宽 400pt），替代原来「一行文字 + 好」的裸对话框；8 个状态各有语义图标与配色，`已是最新` / `已下载` 不再留空档，更新说明区限高可滚动、错误文案单列显示。
- **空项目去掉「通过 MCP 导入…」按钮**：MCP 是协议而非界面能力，WBS 导入由 AI 智能体在会话侧（MCP / CLI）完成；空态只保留「新建任务」一个入口，说明文案改为「或由 AI 智能体通过 MCP / CLI 导入现有 WBS」。

## v0.8.3 — 2026-10-23

### 新增

- **一键发版（`tools/release.sh`）**：`tools/release.sh 0.8.3` 一次完成发版全流程——前置校验（必须在 main、工作区干净、tag 不存在、版本递增、CHANGELOG 有对应章节）→ 同步三处版本号 → 全量测试 → 打包 → 提交 → annotated tag → 推送。`--dry-run` 只做校验、测试与打包，不动仓库。
- **产物打包抽为 `tools/package.sh`**：本地与 CI 同源，一次产出 `Kairo-<tag>.dmg`（挂载后拖入 Applications）与 `Kairo-<tag>.zip`（OTA 载体，ditto 保留签名）。打包前校验应用内 `CFBundleShortVersionString` 与 tag 一致——版本号漏改会在打包阶段直接失败，而不是把旧版本装进新版本附件。
- **Release 说明单一来源 `tools/release_notes.sh`**：CI 与本地共用同一段 CHANGELOG 抽取逻辑，Release 说明即 `CHANGELOG.md` 的对应章节；章节缺失时回退为自动生成的提交列表。

### 变更

- 发版工作流改为调用上述脚本：CI 内联的 zip / DMG / changelog 逻辑（三处重复实现）合并为一处，避免本地与线上产物口径漂移。

## v0.8.2 — 2026-10-23

### 修复

- **发版归档步骤加固（D-026）**：产物推送失败不再让整轮发版白跑。
  - `git push origin artifacts` 连续失败时重试 3 次（间隔 10 秒）；提交已生成，重试不产生冗余提交。同时抬高 `http.postBuffer` 并放宽低速判定，减少 408 / 断连概率。
  - `artifacts` 分支的 `latest/` 每次重建，只镜像当前版本；此前的 `Kairo-v0.3.1.*`、`Kairo-v0.4.0.*` 等历史残留随本次归档一并清除（`git add -Af` 记录删除）。
  - 同一 tag 重跑幂等：内容无变化时跳过提交，推送为 no-op 且判成功。

## v0.8.1 — 2026-10-23

### 修复

- **发版 CI 在 UTC runner 上整体错位一天（D-025）**：`Sprint8DateFieldRenderTests` 把日历钉死在 Asia/Shanghai，而被测的 `Display.isoDate` 与视图渲染使用 `TimeZone.current`，两者在 UTC 主机上相差一天，导致 4 条用例失败、v0.5.0 起的 tag 全部跑红。测试日历改为跟随主机时区（locale 与周首仍固定），断言与被测实现同口径。核销：`TZ=UTC swift test` 742/742。
- 由此确认：v0.5.0–v0.8.0 只存在于 CHANGELOG 与 git 历史，未发布过 GitHub Release；首个带产物的发布版本为 v0.8.1。

## v0.8.0 — 2026-10-22

### 新增

- **大纲列宽可调（F-14-20）**：表头每列右缘出现 6pt 调整手柄，拖动即可改列宽，双击复位默认宽。
  - 拖动中实时预览（表头与行同步）、松手才提交一次，不逐帧写偏好；位移 < 2pt 视为误触不提交。
  - 宽度区间按列区分：状态/违例 10–60、序号 18–80、其余 24–320；任务说明为弹性列继续吃余量（最小 120pt）。
  - 列宽持久化到视图偏好，**不进撤销栈、不把项目标记为已修改**。
- **列显隐可配置（F-14-20）**：视图菜单新增 8 条「显示/隐藏…列」，大纲表头右键菜单提供带勾选的同源开关。
  - **序号（#）与任务说明固定显示**，不出现在开关列表，隐藏请求双重忽略。
  - 窄窗阈值降级仍优先（放不下的列不会因用户配置强行显示）；聚焦标签栏忽略用户配置。
  - 显隐同样持久化、不产生撤销点。
- 表头与行列表统一 leading 锚定并加右侧裁切：列宽总和超过大纲宽度时从右侧裁切，不再出现表头居中导致的错列。

## v0.7.0 — 2026-10-22

### 新增

- **大纲「开始 / 结束」日期列可编辑（F-14-19）**：左侧大纲两列由只读文本改为点击即弹月历，快速选日期。
  - 开始列：写任务意图开始日期（可「清除」回落自动排期）；显示值仍是排期开始（与画布对齐），依赖可能使排期后移，单元格 tooltip 已说明。
  - 结束列：改写持续时间（结束为排他端点），最小可选日 = 起点次日；不允许清除。
  - 禁用语义与检查器一致：群组两列只读、里程碑结束只读、无排期时结束不可选，均以灰字 + tooltip 给出原因而不是静默无反应。
  - 写回动作与撤销粒度与检查器完全同源（`setTaskStart` / `setTaskFinish`，`task-start-*` / `task-finish-*`）；命令层零改动。
- 新增 `OutlineDateEditing` 纯函数策略（KairoPresentation）承载启用/原因/最小日判定，视图不写规则；跨 DST 日期以日历加法而非 +86400 秒推进。
- 设计稿与测试矩阵：docs/archive/Sprint10-outline-date-cells/design.md（17 例策略测试 + 2 例同源断言）。

## v0.6.0 — 2026-10-22

### 新增

- **甘特图横向平移（F-14-18）**：任务或依赖链超出视口时可左右移动时间窗查看前后日期。
  - 触摸板双指横向滑动直接平移（光标在画布内即生效；鼠标用户用 Shift + 纵向滚轮）。
  - 画布空白处按住拖拽平移，内容跟手；条体 / 端点 / 依赖线上的拖拽仍是 F-14-09 编辑行为，互不干扰。
  - 平移粒度为整天（布局契约）：滚动输入按亚日余量累积、跨整天才提交，慢速滑动不丢位移也不跳格；切换缩放档位时余量清零。
  - 平移自动退出「适合项目」，窗口起点按整天归一；Escape 可取消进行中的拖拽（已生效的平移不回滚，与表头拖拽一致）。
- 实现：`HorizontalPanAccumulator` 纯函数（KairoPresentation）、`PanDragSession` 拖拽状态机与 `HorizontalPanContext` 引用上下文（App 层）、`HorizontalScrollMonitor` 事件捕获薄层；命令层与 Store 复用既有 `.panWindow`，零改动。
- 设计稿：docs/archive/Sprint9-gantt-horizontal-pan/design.md；F-14-13 原「本期不做横向滚动条」约束改写（仍不做滚动条，横向平移由触摸板/拖拽承担）。

## v0.5.0 — 2026-10-21

### 新增

- **任务起止日期可自定义（F-14-10）**：检查器任务页「开始」「结束」两行可编辑，点击字段弹出月历（236×300）选择日期——月份导航、今天/选中/非本月/周末状态、越界日置灰、预览行「开始日 – 结束日 · N 天」、「今天 / 下周一 / +1 周 / 清除」快捷项、方向键/Return/Esc/Tab 键盘导航与 VoiceOver 标签；深浅色全部走 DesignTokens。
  - 「开始」写 `startDate`（用户意图锚点，可清除；群组只读；与计划开始相差 ≥1 天时副行显示计划开始）。
  - 「结束」写 `durationDays`（保持开始不变，落点为排他端点；里程碑/群组/无排期禁用并给出原因；结束早于开始不可达，Store 二次拒绝）。
  - 截止日期与项目开始/结束改用同一组件；行内日期统一 `YYYY-MM-DD`；每次编辑一步撤销，与画布拖拽撤销互不合并；提交时校验排期起点是否已变化（陈旧输入拒绝，不占撤销点）。
- **排期引擎消费 `startDate`（D-021 修复）**：显式开始日作为「开始不早于」下界参与前向传播（叶子任务与里程碑；群组仍由子任务聚合），ASAP/ALAP 选定安排统一收敛到该下界。**v0.4.0 中画布拖条改期实际不移动条体的缺陷随本项修复**——拖条、检查器、命令三条入口自本版起真正生效。
- **按日历日计算排期（夏令时修复）**：`addDays` / `daysBetween` 改为 Calendar 整日算术（小数天余量仍按秒折算）。跨夏令时的结束落点不再少一天，宽延恒为整数天；America/New_York 回拨/春令两侧均有自动化用例。

### 已知观感变化（升级必读）

- v0.4.0 期间由画布拖拽或命令写入、但因 D-021 从未生效的 `startDate`，自 v0.5.0 起会参与排期：相关任务可能前移、依赖链随之位移。**不做数据迁移**（无字段改写）；如不希望某个任务被钉住，可在检查器点「清除开始」。

### 已知限制（顺延 v0.5.1，均不阻断）

- **D-022**：给任务设置晚于项目窗口的开始日后，违例页出现错误级「任务无法安排：最晚开始早于最早开始」，文案未点明是用户输入导致（后向传播按裁定不变）。
- **D-023**：违例引擎仍以 86 400 秒换算持续时间，跨夏令时的时限窗口可能误报/漏报。
- **D-024**：同文件两个「无下界」哨兵取值不一致（`distantPast` vs epoch 0），无现实故障。
- **真机未验证**：popover 系统动画与屏幕边缘翻转、物理键盘事件与焦点环可见性、VoiceOver 实际播报顺序、系统 firstWeekday 真机渲染、窄窗排版。

### 门禁与证据

- `swift test`：**669 用例 / 69 套件全部通过**（v0.4.0 收尾基线 558 → 669，只增不减）；日志 `docs/archive/Sprint8-task-dates/logs/gate-*.log`。
- `tools/gate-core.sh` · `tools/gate-ui.sh` 通过；`swift build -c release -Xswiftc -warnings-as-errors` 通过（CI 口径）。
- 判据：[acceptance.md](docs/archive/Sprint8-task-dates/acceptance.md)（AC-S8-01…23）· 设计与裁定：[design.md](docs/archive/Sprint8-task-dates/design.md) · 范围：[scope.md](docs/archive/Sprint8-task-dates/scope.md)。
- 审查：[Sprint8-task-dates-review.md](docs/reviews/Sprint8-task-dates-review.md)（3 HIGH 全部修复并复跑；MEDIUM 修复 5 项、驳回 1 项经裁定、LOW 修 3 项）。
- 缺陷：[defects.md](docs/defects.md) D-021 已核销；D-022…D-024 顺延 v0.5.1。

## v0.4.0 — 2026-10-21

### 新增

- **甘特图直接编辑（F-14-09）**：画布支持拖条改期（日粒度吸附，显式锚定开始日期）、拖右端点改持续、拖左端点改开始（结束不变）；从条端点外环带拖出绘制依赖线（FS / lag 0，拖出方向决定前后驱，成环自动拒绝）；点选依赖线后按 Delete/Backspace 删除。拖拽中显示虚线预览与目标日期标签，松手生效，Escape 取消。
- 交互架构：`GanttHitTesting` 纯函数命中测试（KairoPresentation，区域表全分支单测）+ `CanvasDragSession` 引用语义节流状态机（100ms 节流、松手必提交末值、同值去重）；长拖拽多笔提交经撤销合并键（`canvas-move-*` / `canvas-resize-*`）并为一步撤销。命令层复用 `updateTask(id:patch:)` 与依赖动作，零改动。
- 对象适配：里程碑仅拖改期（菱形端点退化为条体）；群组聚合条不可拖（由子任务推导）；群组/里程碑仍可作依赖端点。
- 设计稿：docs/archive/Sprint7-gantt-direct-edit/design.md；ui-redesign §10「画布禁拖」约束随本特性解除。

## v0.3.1 — 2026-10-20

### 新增

- **OTA 自动检查**：启动后 5 秒静默检查一次，此后每 4 小时一次；静默语义 = 网络失败不打扰（手动检查可见失败态），发现未跳过的新版本才自动展示更新面板，同版本一次运行只弹一次。「跳过此版本」仍然有效。
- **产物仓库归档**：发版时 DMG / OTA 载体 zip / 签名清单自动提交到 `artifacts` 分支（按 tag 子目录 + `latest/` 镜像），主分支保持干净。
- 文档：US-E7-01 落 PRD Backlog（完成）；新增 docs/features/05-ota-updates.md（F-36 规格族）与 docs/archive/Sprint7-ota-updates/design.md（设计决策记录）；roadmap 补状态更新与 Sprint 7/8 计划。

## v0.3.0 — 2026-10-20

本版引入应用内 OTA 更新（通用更新模块 KairoUpdater，移植自 COFFER OTA 的安全设计）。

### 新增

- **应用内 OTA 更新**：应用菜单「检查更新…」手动检查（零网络姿态：无启动静默检查、无定时后台检查）。安全链路与 COFFER OTA 同构——Ed25519 签名清单（canonical JSON）验证、下载 zip SHA256 完整性校验、产物 CDHash 与清单比对、GitHub host 白名单 + 强制 HTTPS + 重定向拦截、防降级地板（minimumVersion）；下载完成后经确认弹窗退出替换并自动重启，支持「跳过此版本」（安全关键版本禁跳）。
- **通用更新模块 KairoUpdater**（独立库 target）：清单解析/验签、版本比较、端点白名单、网络层（协议注入、禁缓存）、8 态更新状态机、zip 安装器（非沙盒 detached 脚本替换协议：等退出→备份→替换→relaunch→result 握手），全部可独立测试；appId/公钥/feed/白名单经配置注入，可直接复用于其他 Apple 平台项目。
- Release 附件扩展：DMG（人装）之外新增 OTA 载体 zip 与签名清单 update-manifest.json（/releases/latest/download/ 永久链接即 feed）。

### 已知限制

- v0.2.0 及更早版本不含 OTA 客户端：需手动安装 v0.3.0 一次，此后版本即可应用内更新。
- 应用为 ad-hoc 签名（无 Apple 开发者证书）：首次打开需要在「系统设置 → 隐私与安全性」中点「仍要打开」，或执行 `xattr -cr /Applications/Kairo.app`。
- 视图偏好文件任一字段缺失或损坏会使**全部**偏好回落默认值（项目数据不受影响，Sprint 7 改为逐字段容错）。
- 「适合项目」在跨多年的超长项目下时间窗口无上限，逐日刻度绘制量偏大（Sprint 7 设上限）。
- 拖条改期、拖拽建依赖、多选、基线与资源视图未实现；依赖创建从检查器进入。

### 安装

1. 从本页附件下载 `Kairo-v0.3.0.dmg`。
2. 打开 DMG，把 `Kairo.app` 拖入「应用程序」（窗口内有 Applications 快捷方式）。
3. 首次打开：右键点按 → 「打开」，或按上面的已知限制放行 Gatekeeper。
4. 之后的新版本可直接在应用内「检查更新…」完成升级。

## v0.2.0 — 2026-10-20

本版聚焦文件与协作基础（格式版本契约、另存为、负责人、大纲编号前置）与甘特图时间轴的自由缩放。

### 新增

- 甘特图时间轴「日宽可自定义」：2–120 点/天连续可调，全轴由单一标量日宽驱动（每天等宽、每周等宽）；刻度粒度在启用自定义日宽时按实际日宽推导（≥18 逐日 / ≥6 逐周 / 其余逐月），预设档位与「适合项目」沿用既有粒度行为不变；标签不重叠、绘制量有界。入口为工具栏标尺弹出面板（滑杆 / ± 步进 / 档位芯片 / 重置）、缩放菜单步进项与 `⌘+` / `⌘-` / `⌘0`；自定义值持久化在视图偏好（`customDayWidth`），不改 `.kairo` 项目文件格式。
- CLI `task add/update` 增加 `--assignee`，MCP `task_add/task_update` 增加 `assignee` 属性：设置任务负责人，空串清空；与 Claude Code 协作时可填子智能体名（US-E1-02-A1…A4）。
- `task get` 文本输出渲染负责人行。
- 大纲「前置」列支持按大纲编号填写依赖（如 `1.1`、`1.1:fs`、`1.1:ss:1`），可与任务 ID 前缀混用；前置摘要同以大纲编号展示（US-E4-01-C1…C4）。
- 「文件 → 另存为…」（⇧⌘S）：另存为新 `.kairo` 文件并继续在新文件上工作，原文件不变；保存面板预填当前文件名，未保存项目按项目标题生成；写入当前最新格式版本（FR-FILE-SAVEAS-1…6）。
- `.kairo` 格式版本兼容：读取 1…当前版本并顺序迁移；读取更高版本或迁移失败时明确报错且不改动磁盘文件；保存与另存为恒写当前版本；CLI/MCP 打开结果报告磁盘版本与升级需求，保存结果报告写入版本与升级来源（FR-KAIRO-FMT-1…6）。

### 修复

- 负责人输入去除首尾空白，纯空白等价清空（D-004）。
- 计划视图大纲与甘特图纵向错位：大纲行分隔线改为行内自绘 overlay，不再占用 28pt 行布局空间；行数越多错位越明显的累积漂移消除，画布点击选中恢复逐行对齐（D-006）。

### 变更

- `KairoPresentation` 公共 API 变更：新增 `WorkspaceAction` case（`setCustomDayWidth` / `nudgeCustomDayWidth` / `clearCustomDayWidth`，外部穷尽 switch 需补 `default`）、`GanttSnapshot` 新增 `tickGranularity` 字段（init 参数可选，缺省由 `zoom` 派生，旧构造点源码兼容）。
- 应用启动不再默认加载示例数据：默认打开为空项目；「文件 → 载入示例项目」按需填充示例（有未保存修改时先确认）。

### 已知限制

- 应用为 ad-hoc 签名（无 Apple 开发者证书）：首次打开需要在「系统设置 → 隐私与安全性」中点「仍要打开」，或执行 `xattr -cr /Applications/Kairo.app`。
- 视图偏好文件任一字段缺失或损坏会使**全部**偏好回落默认值（含窗口布局与日宽自定义；项目数据不受影响，Sprint 7 改为逐字段容错）。
- 「适合项目」在跨多年的超长项目下时间窗口无上限，逐日刻度绘制量偏大（Sprint 7 设上限）。
- 拖条改期、拖拽建依赖、多选、基线与资源视图未实现；依赖创建从检查器进入。

### 安装

1. 从本页附件下载 `Kairo-v0.2.0.dmg`。
2. 打开 DMG，把 `Kairo.app` 拖入「应用程序」（窗口内有 Applications 快捷方式）。
3. 首次打开：右键点按 → 「打开」，或按上面的已知限制放行 Gatekeeper。

## v0.1.0 — 2026-10-18

第一个可安装版本。围绕「计划工作台」重设计完成 macOS 客户端重构。

### 新增

- **计划工作台**：大纲与时间画布逐行对齐、充满窗口；检查器三页（任务 / 项目 / 违例）、状态栏健康摘要、⌘K 命令面板。
- **可拖拽分界线**：大纲 ⇄ 甘特分界线可左右拖动调整宽度（320–640pt）并持久化；拖动时列表各列等比压缩，标题列吃剩余宽度。
- **列表显隐**：工具栏开关隐藏任务列表，时间画布占满主区。
- **「关于」面板**：应用菜单显示版本号 0.1.0 与编译时间。
- **甘特布局 v2**：月/年 + 日/周两级刻度、四型依赖直角折线路由、今天线、折叠群组汇总条、无排期标记、月缩放隐藏非工作带。
- **核心层地基**：项目摘要与健康度（加权进度、逾期口径、剩余天数）、大纲树（过滤/展开/群组聚合）、四型依赖 CRUD 与环校验、撤销用值快照。
- **会话写路径**：任务补丁 set/clear 语义、移动与父子环校验、级联删除（CLI / MCP 同步采用）、排期缓存按需重算、导出采用不重写磁盘。
- **外部更新检测**：前台每 2 秒比较磁盘 mtime，未保存时提示「重新载入 / 保留本地」。
- **撤销/重做**：50 步快照栈，连续输入 500ms 合并，删除群组、依赖变更可撤销。

### 修复

- 项目未设开始日期时排期落在 1970 纪元（D-003）：按最早任务开始日期推导并提示。
- 表头被分界线抬高、行被压到窗口中部的布局塌陷。
- 分界线拖动被滚动手势吞掉（改用 highPriorityGesture）。

### 已知限制

- 应用为 ad-hoc 签名（无 Apple 开发者证书）：首次打开需要在「系统设置 → 隐私与安全性」中点「仍要打开」，或执行 `xattr -cr /Applications/Kairo.app`。
- 拖条改期、拖拽建依赖、多选、基线与资源视图未实现；依赖创建从检查器进入。

### 安装

1. 从本页附件下载 `Kairo-v0.1.0.zip`。
2. 解压得到 `Kairo.app`，拖入「应用程序」。
3. 首次打开：右键点按 → 「打开」，或按上面的已知限制放行 Gatekeeper。
