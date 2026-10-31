# Kaido Plan · Mac App Store 提审材料

> 2026-11-01 起草。构建 2.1.0 已上传（Delivery UUID `cc18b8b0-35a7-400d-98e2-e617f65902cc`）。
> 本文按 App Store Connect 的表单顺序组织，可直接复制粘贴；标 **待定** 的需要产品方拍板。

## 一、App 信息

| 字段 | 值 | 说明 |
|---|---|---|
| 名称 | Kaido Plan | 已占用并锁定 |
| 副标题（30 字符内） | Plan work with your AI agent | 中文：让 AI 代理替你把项目计划管起来 |
| 主语言 | 简体中文 | 已设 |
| Bundle ID | top.cygnusyang.kaido | 与 portal / profile 一致 |
| SKU | kaido-macos | 已设 |
| 类别 | 主要：商务（Business）；次要：效率（Productivity） | Info.plist 已声明 productivity，ASC 里按此填 |
| 价格 | **首发免费**，2027-02-01 转买断：美国区 $9.99（中国区待备案后另行开放） | 见 §一·二 |
| 年龄分级 | 4+ | 无用户生成内容、无社交、无广告 |
| 版权 | © 2026 ruohu yang | |
| 上架地区 | **首发仅美国**；中国区等 App 备案号下来再开 | 见 §一·三 |

### 一·二、定价方案（2026-11-01 定）

首发三月免费拉早期用户，**2027-02-01 起转买断**：

| 地区 | 免费期 | 买断价 | 状态 |
|---|---|---|---|
| 美国 | $0（2026-11-01 → 2027-02-01） | $9.99 | 首发上架 |
| 中国 | ¥0（开放日起三个月） | ¥58 | 待工信部 App 备案号 |

三条必须记住的规则：

1. **App Store 没有「限时免费」开关**，只有「当前价格」。做法是现在设 Free，到期改价；
   可以用 App Store Connect API 的 `appPriceSchedules` 预约生效日，也可以日历提醒手动改。
2. **免费期下载的用户永久保留**（他们已完成「获取」动作），改价后对他们不生效。收入只来自新增用户。
3. **价位必须落在 Apple 的价位表里**：$9.99 是标准档；¥58 需要在下拉里确认可选
   （不可选时就近取 ¥58 的邻档，不要用「自定义价」硬写，审核会退回）。
   两区独立定价，不必等价折算。
4. **中国区这次不一起上**：没有工信部备案号时该区不可售。备案下来后再开放，
   并沿用同一策略（开放日起免费三个月 → ¥58），具体起始日以备案日期为准。

改价 checklist（到期前一周做）：

- [ ] ASC ▸ 定价与可用性 ▸ 价格：中国区改 ¥58、美国区改 $19.99（其余地区保持不销售）
- [ ] 确认没有把「限时免费」写进名称/副标题/描述（见 §七 风险表）
- [ ] 改价前在 GitHub / 社交渠道发公告，避免「说免费却收费」的差评
- [ ] 关注首日退款与评论，必要时保留一个低价档过渡

### 一·三、美国区上架的前置

- **税务**：ASC ▸ 协议、税务和银行业务里签 W-8BEN（非美国税务居民），否则无法收款
- **银行账户**：收款账户需通过验证
- **元数据**：英文描述/关键词/截图（本文件 §二 已备英文描述）
- **合规**：美国区无额外备案要求；中国大陆区需要 App 备案号（工信部），**未备案时该区无法上架**

## 二、描述（Description）

### 简体中文

```
Kaido Plan 把 AI 代理干的活记成一本能查的账。

Claude Code、Codex 这类代理擅长执行单个任务，却没有可以排期的东西：WBS、依赖、日期、进度散在对话里和零散 Markdown 中，最后没人说得清「AI 做完了什么、还剩什么、什么时候能交付」。Kaido Plan 把这些抽出来放进一个本地文件，让人和代理看同一份计划。

人会看的：
· 大纲 + 甘特 + 检查器三栏工作台，任务树、四类依赖、里程碑、群组一屏对齐
· 排期引擎按工作日历折算工期，冲突与违例当场标出
· 基线对比，偏差一眼可见
· 挣值、关键路径等常用报表口径
· 全部数据存在本地单个 .kaido 文件里，可放 iCloud、Git、任何同步盘

代理会用的：
· 应用内开通 MCP 服务，Claude Desktop、Claude Code、Cursor 等客户端即可读写同一份计划
· 只开放你授权的文件夹，越界访问一律拒绝
· 也可用内置命令行（同一 App 的 --cli 模式）接入脚本

互操作：
· 读 MS Project XML（.xml），导出 MS Project XML 与 OmniPlan
· 导出为单向快照时会附一份说明文件，列清哪些信息没能带过去

隐私：
· 无账号、无云同步、无遥测，不做任何数据收集
· 所有网络行为只在你自己开启 MCP 服务时发生，且只监听本机回环地址
```

### English

```
Kaido Plan keeps the ledger of what your AI agent actually did.

Claude Code and Codex are good at a single task but have nothing to schedule against: the WBS, dependencies, dates and progress live in conversation context and ad-hoc Markdown, so nobody can answer "what is finished, what is left, when will it land". Kaido Plan pulls that into one local file so the human and the agent look at the same plan.

For humans: outline + Gantt + inspector in one workbench; four dependency types, milestones and groups; a scheduling engine that respects working calendars and flags violations; baseline comparison; earned value and critical path; everything in a single local .kaido file you can keep in iCloud, Git or any sync folder.

For agents: turn on the built-in MCP service and Claude Desktop, Claude Code or Cursor can read and write the same plan; only the folders you authorize are reachable, anything outside is refused; a command-line mode (--cli) of the same app is there for scripts.

Interoperability: reads MS Project XML, exports MS Project XML and OmniPlan, with a companion note listing what could not travel.

Privacy: no account, no cloud sync, no telemetry, no data collection. Network activity only happens when you turn on the MCP service, and it only listens on the local loopback address.
```

## 三、关键词（100 字符内，逗号分隔）

```
甘特图,项目管理,WBS,排期,项目计划,MCP,AI 代理,依赖关系,基线,进度跟踪,gantt,project plan
```

## 四、截图

App Store 对 Mac 截图接受 16:10 的这几档：1280×800、1440×900、2560×1600、2880×1800。**按 2880×1800 拍一次，全档通用**（Retina 2x 抓取即得）。

| # | 画面 | 要传达的一句话 |
|---|---|---|
| 1 | 三栏工作台：大纲 + 甘特 + 检查器（含示例项目，有依赖连线与里程碑） | 「一屏看清整份计划」 |
| 2 | 排期违例高亮 + 检查器里的违例说明 | 「冲突当场标出来，不靠你肉眼找」 |
| 3 | 基线对比（计划条 vs 基线条 + 偏差） | 「承诺和现实差多少，一眼可见」 |
| 4 | MCP 服务面板（开关打开、端点、客户端配置片段、已授权目录） | 「AI 代理读写同一份计划，权限你说了算」 |

拍摄要点：
- 窗口 2880×1800、浅色与深色各拍一套时可只交浅色（审核只要求一套）
- 不要出现真实客户数据；用示例项目或 `Seed Demo Data`
- 第 4 张要露出「仅授权目录」列表，这是审核最容易追问的点，图先答一半

## 五、隐私

**数据收集：无。** 在 ASC「App 隐私」里选 **不收集数据**（No, we do not collect data from this app），逐项不勾。

需要提供**隐私政策 URL**（Apple 强制，没有不能提交）。内容至少要写清：

1. 不收集任何个人信息，不做行为分析
2. 项目数据只存在用户自己选择的本地文件里，不上传
3. MCP 服务由用户手动开启，仅监听 127.0.0.1，token 由本机生成
4. 不包含第三方 SDK、广告或崩溃上报
5. 联系方式

> URL 需要 **待定**：仓库里没有可公开托管的页面。可选项：GitHub Pages（`cygnusyang.github.io/Kaido/privacy`）、或直接在 GitHub Release 里放一份 `PRIVACY.md` 并用其 raw 链接（Apple 接受任意可访问 HTTPS 页面，但用 Pages 更稳妥）。

## 六、App 审核备注（App Review Information → Notes）

这段是**决定过不过**的地方，建议原文粘贴：

```
Kaido Plan is a local-first project planning tool. All project data lives in a single
file the user picks with the standard open/save panels; there is no account, no server
and no cloud sync.

Sandbox usage:
- com.apple.security.files.user-selected.read-write — reading and writing the user's
  .kaido file plus CSV/XML/OmniPlan exports, always through the system panels.
- com.apple.security.files.bookmarks.app-scope — remembering recently opened projects
  and reopening the last project on launch. Bookmarks are created only for files or
  folders the user explicitly chose.
- com.apple.security.network.server / network.client — the optional MCP service
  (Project > MCP Service...). It is OFF by default. When the user turns it on, the app
  listens on 127.0.0.1 only (never 0.0.0.0, never a public interface) so that a local
  AI client (Claude Desktop, Claude Code, Cursor) can read and write the same plan
  through the Model Context Protocol. Every request must carry a bearer token that the
  app generates locally and shows in that panel. File access from MCP is restricted to
  folders the user authorized in the same panel; anything outside is refused with
  mcp_path_not_authorized.

The app performs no automatic updates and downloads no executable code. It contains no
analytics, no third-party SDKs and no advertising. No sign-in is required.

To try it without an AI client: launch the app, create a task, and switch between the
outline, the timeline and the inspector. The MCP panel is under Project > MCP Service...
```

## 七、审核风险点与应对话术

| 风险 | 为什么会被问 | 回应 |
|---|---|---|
| **本地监听端口** | 2.5.1 / 2.5.2：应用不得提供下载或安装代码的能力；监听端口常被怀疑是遥控通道 | 默认关闭、用户显式开启、仅 127.0.0.1、Bearer token、只服务本机客户端；面板里能一键关闭和重置 token |
| **沙盒文件权限** | 想确认不是全盘访问 | 只申请 user-selected + bookmarks，且全部经系统面板产生 |
| **MCP 让外部程序改用户数据** | 担心绕过用户意图 | 授权目录白名单 + 面板可撤销；越界返回明确错误码 |
| **商店版没有 CLI / 自更新** | 与官网版功能不一致可能被判「功能残缺」 | 说明这是商店规则要求（不得下载安装可执行代码），描述里不提 CLI 的具体安装方式 |
| **名称含 "Plan"** | 可能与既有 App 混淆 | 已有商标与名称预占，若被质疑按 ASC 的商标争议流程处理 |

## 八、提审前检查清单

- [ ] ASC 里构建 2.1.0 处理完成（Processing → 可用）
- [ ] 隐私政策 URL 可访问（HTTPS，无登录墙）
- [ ] App 隐私表单：不收集数据
- [ ] 4 张截图（2880×1800）已上传
- [ ] 描述、关键词、副标题按本文填写
- [ ] 价格与可用地区已设：美国 Free（2027-02-01 转 $9.99），可用地区只选美国
- [ ] 美国区：W-8BEN 已签、银行账户已验证
- [ ] 中国区：本次不上架；备案号下来后单独走「开放 + 免费三个月 → ¥58」
- [ ] 审核备注粘贴完毕
- [ ] 出口合规：使用标准 HTTPS 加密，选「豁免」即可（无需 CCATS）
- [ ] 提交审核
