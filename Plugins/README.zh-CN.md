# 用 AI 智能体做项目：Kairo 接入指南

[English](README.md) · **简体中文**

> 面向两种人：① 想让 AI 帮忙拆 WBS、排期、盯进度的人；② 要给某个智能体（Claude Code / CodeBuddy / Codex）接上 Kairo 的人。
> 本文命令在 Kairo v0.8.0（2026-10-23）用 release 产物实测通过；宿主侧配置按官方格式给出，边界见文末「验证范围」。

## 0. 一句话说清分工

| 角色 | 干什么 | 不干什么 |
|---|---|---|
| AI 智能体 | 读需求、拆任务、估投入、写代码、完成后回写状态 | 不做长期记忆，不维护进度账本 |
| Kairo | 存 WBS 与依赖、算排期、查违例与重要路径、聚合完成度 | 不写代码、不替 AI 做技术判断 |
| 人 | 定边界（起止日期、验收口径）、看甘特与违例、干预 | 不逐条盯任务 |

Kairo 的三个入口同源（共用同一套写路径 `KairoSession`）：**MCP 工具 16 个**、**CLI 命令**、**macOS 应用**。数据只有一个落点：`.kairo` 单文件（JSON）。AI 走前两个，人走第三个。

## 1. 为什么只有 Claude Code 有插件

插件不是能力，是**桥**。四件套里三件能被 MCP/CLI 取代，只有 hook 不能：

| 组件 | 能否用通用接口替代 | 结论 |
|---|---|---|
| `.mcp.json` | 能（项目级 MCP 配置） | 只省一步手工配置 |
| 斜杠命令 | 能（规则文件里的一段约定） | 便利，非必需 |
| `TaskCompleted` hook | **不能** | 唯一真正值钱的部分 |
| 清单 / 市场分发 | 不能 | 只在对外分发时值钱 |

而 hook 的用途是**桥接 Claude Code 自己的任务系统**（TaskCreate / TaskCompleted）到 Kairo。Codex 没有等价事件；CodeBuddy 的插件格式是 Claude 格式的分叉（清单目录、根变量名都改了）。给它们各做一个壳，收益是「省一次配置」，成本是「永远跟着对方格式改」。

所以本仓库的取舍：

- **Claude Code**：保留完整插件（斜杠命令 + 自动回写 hook），已实测；
- **CodeBuddy / Codex**：不装插件，一份 MCP 配置 + 一段写进规则文件的约定，零维护。

三种接法里，前两步（§2、§3）通用，做完再挑宿主。

## 2. 共用前置：构建 + 建项目

```bash
# 1) 改这一行：指向你的 Kairo 仓库
export KAIRO="$HOME/work/opc/04-开发项目/Kairo"

# 2) 构建（MCP 与 CLI 两个产物一次出来）
cd "$KAIRO" && swift build -c release

# 3) 建工作目录和项目文件
mkdir -p "$HOME/Projects/demo" && cd "$HOME/Projects/demo"
"$KAIRO/.build/release/KairoCLI" project create "示例项目" \
  --start 2026-11-02 --end 2026-11-20 --file demo.kairo
```

成功输出：

```
已创建项目：52F28B11「示例项目」
已保存：/Users/you/Projects/demo/demo.kairo
格式版本：v1
```

> `--start` / `--end` 是排期引擎的默认边界，超出会报违例。日期一律 `YYYY-MM-DD`。
> CLI 语言按 `--lang <bcp47>` → `KAIRO_LANG` → 系统语言决定，默认回退简体中文；`--json` 输出与语言无关。

可选：验证 MCP 服务本身（两行，看到 serverInfo 与 tools 即通）：

```bash
printf '%s\n%s\n' \
 '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}' \
 '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
 | "$KAIRO/.build/release/KairoMCP" | head -c 400
```

## 3. 共用约定：把这段放进宿主的规则文件

Codex 放 `AGENTS.md`，CodeBuddy 放 `CODEBUDDY.md`，Claude Code 放 `CLAUDE.md`（都在**项目根目录**）。把路径换成你的真实路径：

```markdown
## Kairo 项目管理

本项目用 Kairo 管理 WBS 与排期，项目文件固定为：/Users/you/Projects/demo/demo.kairo

- 开工前先 task_list 读现状，已有任务不要重复创建。
- 拆解顺序：里程碑 → 群组 → 叶子。叶子必须给 effortHours（按 8 小时/人日估），群组与里程碑不给投入。
- 一个叶子 = 一次可交付、可独立验收的改动；预计超过 3 人日就继续拆。
- 拆完立刻 wbs_import，然后 schedule_compute；violations_list 有输出先报告，不要擅自改期限或依赖。
- 每完成一个任务，必须调用 status_update 把状态置 done（进度自动 100%），不要只改进度数字。
- 任务 ID 接受完整 UUID 或 ≥4 位唯一前缀；前缀不唯一时先列候选让用户选，禁止猜。
- 只建计划不写代码时，明确声明「本次只更新 Kairo 计划」。
```

这段约定是三个宿主**唯一**共用的智能层。要改，只改这里，不要在别处再抄一份。

## 4. Claude Code

### 接法 A：只接 MCP（最简，30 秒）

```bash
cd "$HOME/Projects/demo"
cat > .mcp.json <<EOF
{
  "mcpServers": {
    "kairo": { "command": "$KAIRO/.build/release/KairoMCP" }
  }
}
EOF
```

然后 `claude`，首次会提示是否信任该项目的 MCP 服务，同意即可。**这份 `.mcp.json` 与 CodeBuddy 通用**（见 §5），一份配置两个宿主。

### 接法 B：完整插件（斜杠命令 + 自动回写）

```bash
export KAIRO_PROJECT="$HOME/Projects/demo/demo.kairo"
claude --plugin-dir "$KAIRO/Plugins/claude-code"
```

| 命令 | 作用 |
|---|---|
| `/kairo plan <需求文档路径或需求描述>` | 读需求 → 建 WBS → 排期 → 列违例 |
| `/kairo done <任务ID 或前缀>` | 标记完成并回报群组完成度 |
| `/kairo status` | 任务表、重要路径、违例汇总 |

插件还注册 `TaskCompleted` hook：Claude Code 任务完成时按**标题精确匹配**找到同名 Kairo 任务并回写 `done`。因此参与回写的标题必须项目内唯一，否则跳过（重名）或误标（跨任务同名）。hook 直写文件，与应用并发编辑会互相覆盖，回写期间建议关掉应用。

## 5. CodeBuddy

**不做插件壳**（格式分叉，收益只是省一次配置）。两步：

```bash
# 方式一：项目级（推荐，与 Claude Code 共用同一份）
cd "$HOME/Projects/demo"
# §4 已建过 .mcp.json 可跳过
cat > .mcp.json <<EOF
{ "mcpServers": { "kairo": { "command": "$KAIRO/.build/release/KairoMCP" } } }
EOF

# 方式二：用户级（所有项目可见）
codebuddy mcp add --scope user kairo -- "$KAIRO/.build/release/KairoMCP"
```

项目根放 `CODEBUDDY.md`，内容用 §3 那段。启动 `codebuddy` 后首次连接项目级 MCP 需批准；非交互模式加 `--settings '{"enableAllProjectMcpServers": true}'`。

验证：

```bash
codebuddy -p "用 kairo 的 task_list 列出 demo.kairo 的任务，只输出标题和状态"
```

## 6. Codex

Codex 没有斜杠命令、没有可挂的任务完成事件，只有 `config.toml` 和 `AGENTS.md`。所以回写靠**约定**（§3 最后两条），不靠 hook。

```bash
# 1) 注册 MCP → 写入 ~/.codex/config.toml
cat >> ~/.codex/config.toml <<EOF

[mcp_servers.kairo]
command = "$KAIRO/.build/release/KairoMCP"
args = []
EOF

# 2) 项目根放 AGENTS.md，内容用 §3 那段
# 3) 在项目目录启动
cd "$HOME/Projects/demo" && codex
```

Codex 里没有 `/kairo plan`，用一句话触发同样流程：

```
按 AGENTS.md 的 Kairo 流程，把 docs/需求.md 拆成 WBS 导入 demo.kairo，
估算投入，然后排期并列出违例。只更新计划，不写代码。
```

任务完成时让它走 CLI（比走 MCP 更可控，也方便终端复核）：

```bash
"$KAIRO/.build/release/KairoCLI" status update 3AE8 --status done \
  --file "$HOME/Projects/demo/demo.kairo"
```

> 本机 `codex` CLI 不在 PATH（装的是桌面版），上述 `config.toml` 按其现有 `[mcp_servers.*]` 结构给出；首次使用请确认 `codex` 能列出 kairo 工具。

## 7. WBS 怎么拆（重点）

### 7.1 三层结构

```
里程碑（kind=milestone，零工期，对齐外部事件：提测 / 上线 / 评审）
└── 群组（kind=group，只装子节点，不设投入）
    └── 叶子（kind=task，必须有 effortHours，排期与回写的单元）
```

### 7.2 叶子判据（四条全中才是叶子）

1. **可独立验收**：一句话说清「做完的标准」，不需要等别的任务一起看；
2. **单人单责**：一个负责人，不需要并行协商；
3. **0.5–3 人日**：低于半天说明拆过头（合并成本 > 管理成本），高于 3 天说明还没拆清；
4. **有明确产出物**：文件、接口、文档、可运行行为之一。

### 7.3 投入与工期

- 只填 `effortHours`（人时），排期引擎按 8 小时/人日折算持续时间；
- 群组与里程碑不填投入，完成度由子任务**按投入加权**聚合；
- 不给投入 = 排期不可信、违例检查退化。

### 7.4 依赖

只在叶子之间连，格式 `前置ID:类型[:lag]`：

| 类型 | 语义 | 用在哪 |
|---|---|---|
| `fs` | 前置完成后才能开始（默认） | 95% 的场景 |
| `ss` | 与前置同时开始 | 两条并行开发线 |
| `ff` | 与前置同时结束 | 收尾对齐 |
| `sf` | 前置开始后才能结束 | 极少用 |

`lag` 是前导天数，用于「接口冻结后等 2 天才联调」这类现实间隔。

### 7.5 反例

| 写法 | 问题 |
|---|---|
| 「开发支付模块」当叶子、投入 80 小时 | 不可验收、无法并行；拆成接口 / 服务端 / 客户端 / 联调 |
| 群组上填投入 | 完成度会双算 |
| 里程碑填 2 天工期 | 里程碑是时间点，不是工作 |
| 依赖连到群组 | 排期只认叶子，连群组语义不明 |
| 两个任务同名 | Claude Code hook 会跳过或误标 |

## 8. 一次完整走查（可直接照抄）

```bash
cd "$HOME/Projects/demo"
BIN="$KAIRO/.build/release/KairoCLI"

# ⓪ 没有项目就先建一个（已有则跳过，不会覆盖）
[ -f demo.kairo ] || "$BIN" project create "示例项目" \
  --start 2026-11-02 --end 2026-11-20 --file demo.kairo

# ① 写一份 WBS（嵌套 JSON，叶子省略 children 也合法）
cat > wbs.json <<'EOF'
[
  {"title": "支付模块", "kind": "group", "children": [
    {"title": "接口设计", "effortHours": 16},
    {"title": "服务端实现", "effortHours": 40},
    {"title": "客户端接入", "effortHours": 24},
    {"title": "联调验收", "kind": "milestone"}
  ]}
]
EOF

# ② 导入（整棵树一次成型）
"$BIN" wbs import wbs.json --file demo.kairo

# ③ 看清单（跳过也行，④ 用标题自动取前缀）
"$BIN" task list --file demo.kairo
```

输出（前缀以本地为准）：

```
A02505F9 支付模块 [群组] 待办
AFD19693 接口设计 待办 · 投入 16 小时
18352A76 服务端实现 待办 · 投入 40 小时
EF44782F 客户端接入 待办 · 投入 24 小时
33EC0593 联调验收 [里程碑] 待办 · 投入 0 小时 · 持续 0 天
```

```bash
# ④ 连依赖：用标题取前缀，不用手抄 ID
id() { "$BIN" task list --file demo.kairo --json \
  | python3 -c "import json,sys;print([t['id'][:4] for t in json.load(sys.stdin) if t['title']=='$1'][0])"; }

"$BIN" task update "$(id 服务端实现)" --dep "$(id 接口设计):fs" --file demo.kairo
"$BIN" task update "$(id 客户端接入)" --dep "$(id 服务端实现):fs" --file demo.kairo
"$BIN" task update "$(id 联调验收)" --dep "$(id 客户端接入):fs" --file demo.kairo

# ⑤ 排期
"$BIN" schedule compute --file demo.kairo

# ⑥ 重要路径（宽延为 0 的任务链）
"$BIN" schedule path --file demo.kairo

# ⑦ 违例（环、越界、时限冲突）
"$BIN" violations --file demo.kairo

# ⑧ 回写（AI 每完成一个任务做一次）
"$BIN" status update "$(id 接口设计)" --status done --file demo.kairo
```

实测输出要点：

```
已导入 5 个任务
已计算排期：5 个任务
  <前缀> 接口设计  2026-11-01T16:00:00Z → 2026-11-03T16:00:00Z（2 天，ASAP）
  <前缀> 服务端实现 …（依赖生效，紧接接口设计之后）
  <前缀> 客户端接入 …（紧接服务端实现之后）
  <前缀> 联调验收  …（里程碑，零工期，落在链路末端）
重要路径：0 个任务（宽延限制 0 天）
无违例
已回写：<前缀> 接口设计（已完成，进度 100%）
完成度聚合：100%
```

> 「完成度聚合」聚合的是该任务所在子树——叶子就是它自己，所以这里的 100% 表示「这个叶子做完了」，不等于「整个群组做完了」。
> 排期输出是 ISO8601 **UTC**：本地午夜会显示成前一天 16:00Z（东八区）。看日期以 macOS 应用或 `--json` 为准，别拿终端里的 UTC 直接对日历。

## 9. 协作循环

```
人：定边界（起止日期、验收口径）
  ↓
AI：task_list 看现状 → 拆 WBS → wbs_import → schedule_compute → 报违例
  ↓
人：审甘特与违例（macOS 应用），批准或改期限 / 依赖
  ↓
AI：逐任务实现 → status_update done → 群组完成度自动聚合
  ↓
人：看进度与偏差，决定加塞或缩范围
```

两条协作纪律：

- **先看后写**：AI 每次动手前 `task_list`，否则会重复建树；
- **完成即回写**：只改 `progress` 不改 `status`，群组完成度不会动，人看到的进度是假的。

## 10. 排错

| 现象 | 原因 | 处理 |
|---|---|---|
| `command not found` / 找不到 KairoMCP | 未构建或路径写错 | `swift build -c release`，配置里用绝对路径 |
| MCP 连上但工具报「未打开项目」 | 工具不会读环境变量，需显式路径 | 先 `project_open`，或在规则文件里写死路径 |
| `kairo-mcp: 未找到 KairoMCP 构建产物` | 用了插件启动脚本但没构建 | 构建，或设 `KAIRO_MCP_BIN` |
| Claude Code 任务完成但没回写 | 标题不唯一 / 缺 `KAIRO_PROJECT` / 找不到 CLI | 看 stderr 的 `kairo-hook:` 行；设 `KAIRO_CLI_BIN` |
| 应用与 AI 同时改同一个 `.kairo` | 无自动合并 | 应用会提示重新载入；回写期间关应用 |
| 排期日期差一天 | 输出是 UTC，应用显示本地 | 以应用或 `--json` 的本地日期为准 |

## 11. 验证范围

- **实测通过**（macOS，Kairo v0.8.0 release 产物，2026-10-23）：§2、§4A、§4B、§5 的 Kairo 侧命令，§8 全流程，插件 hook 回写。
- **未实测**：Codex 桌面版加载 `[mcp_servers.kairo]` 后工具是否即时可见（本机 `codex` CLI 不在 PATH）；CodeBuddy 的 `TaskCompleted` 事件 payload 字段（文档只列事件名未列字段，故未做 CodeBuddy 版 hook）。
