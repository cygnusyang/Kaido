# Sprint 1 验收 Demo 文档

> 记录 2026-10-18 的实际验收执行：同一份 WBS 输入、同一命令层（KairoSession，ADR-005 契约同源），
> 分别经 MCP / CLI / macOS 应用三个接口面完成「建项目 → 导入 WBS → 查看任务树」。
> 本节所有命令输出均为真实执行摘录，未做任何编造或后处理。

## 一、Demo 输入：三级 WBS（15 个任务）

`wbs.json`（MCP 与 CLI 共用同一输入文件）：

```json
[
  {"title": "规划", "children": [
    {"title": "需求分析", "children": [
      {"title": "访谈"},
      {"title": "整理需求"}
    ]},
    {"title": "技术选型", "children": [
      {"title": "评估方案"},
      {"title": "写技术方案", "kind": "milestone"}
    ]}
  ]},
  {"title": "开发", "children": [
    {"title": "后端", "children": [
      {"title": "模型层"},
      {"title": "接口层"}
    ]},
    {"title": "前端", "children": [
      {"title": "界面"},
      {"title": "交互"}
    ]}
  ]},
  {"title": "发布", "kind": "milestone"}
]
```

层级：根（规划/开发/发布）→ 群组（需求分析/技术选型/后端/前端）→ 任务叶子；含 2 个里程碑（写技术方案、发布）。
展开后共 15 个任务。

## 二、MCP：stdio JSON-RPC 逐行管道

四行请求逐行送进 KairoMCP 服务（验收使用 `swift build` 产物 `.build/…/KairoMCP`；等效于管道进 `swift run KairoMCP`）：

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"演示"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"project_create","arguments":{"title":"演示项目"}}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"wbs_import","arguments":{"nodes":[…]}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"project_save","arguments":{"path":"/tmp/kairo-demo/mcp.kairo"}}}
```

其中 `wbs_import` 的 `arguments.nodes` 即上文 `wbs.json` 的数组内容。

服务端真实返回（逐行 stdout）：

```
{"id":1,"jsonrpc":"2.0","result":{"serverInfo":{"name":"kairo","version":"0.1.0"},"capabilities":{"tools":{}},"protocolVersion":"2024-11-05"}}
{"id":2,"jsonrpc":"2.0","result":{"isError":false,"content":[{"text":"{\"projectID\":\"DAF7DE29-206B-4869-8D4E-619824BBBC2F\",\"title\":\"演示项目\"}","type":"text"}]}}
{"id":3,"jsonrpc":"2.0","result":{"isError":false,"content":[{"text":"{\"rootIDs\":[\"4679E17C-4137-400C-B136-8A6BD6217C5C\",\"C0D3DFBA-84D3-48EE-968B-78FF8260846A\",\"3A1B91A1-4C87-46B5-8A4A-2195F47D1E50\"],\"warnings\":[],\"total\":15}","type":"text"}]}}
{"jsonrpc":"2.0","result":{"isError":false,"content":[{"text":"{\"path\":\"\/tmp\/kairo-demo\/mcp.kairo\",\"savedAt\":\"2026-10-17T17:05:18Z\"}","type":"text"}]},"id":4}
```

验收要点：

- `initialize` 返回协议版本与 `serverInfo.name = "kairo"`。
- `wbs_import` 返回 3 个根任务 `rootIDs`、`total: 15`，与输入一致。
- `project_save` 落盘 `.kairo` 单文件；`savedAt` 为实际写入时刻（UTC 17:05:18Z）。

## 三、CLI：同一序列的 kairo 命令

工作目录 `/tmp/kairo-demo-cli`（含 `wbs.json`），执行：

```
$ kairo project create 演示项目
已创建项目：F5FFCF04「演示项目」
已保存：/private/tmp/kairo-demo-cli/project.kairo

$ kairo wbs import wbs.json
已导入 15 个任务
  C9DADF26 规划
  AFF2B749 开发
  067918F4 发布

$ kairo task list
C9DADF26 规划 [群组] 待办
730F999C 需求分析 [群组] 待办
BC7602B7 访谈 待办
04063899 整理需求 待办
DCCB25E6 技术选型 [群组] 待办
CE76B795 评估方案 待办
8ECAFD74 写技术方案 [里程碑] 待办 · 投入 0 小时 · 持续 0 天
AFF2B749 开发 [群组] 待办
13F2267E 后端 [群组] 待办
ACE60557 模型层 待办
211DC4D2 接口层 待办
72879F52 前端 [群组] 待办
885193DC 界面 待办
EE8D8948 交互 待办
067918F4 发布 [里程碑] 待办 · 投入 0 小时 · 持续 0 天
```

补充验证（同一 `project.kairo`，使用完整 UUID 操作；开发 = `AFF2B749-…`、发布 = `067918F4-…`）：

```
$ kairo task add 写验收文档 --parent AFF2B749-D71C-4293-8561-8BC6AB0F6990 --effort 4 --duration 1 --tags 文档,验收
已创建任务：21A2999C 写验收文档

$ kairo task get 067918F4-7373-4DE4-9D5B-8648165B7F43
任务：发布
ID：067918F4-7373-4DE4-9D5B-8648165B7F43
类型：里程碑
状态：待办
投入：0 小时
持续：0 天
进度：0%

$ kairo task update 067918F4-7373-4DE4-9D5B-8648165B7F43 --status in_progress --progress 0.5
已更新任务：067918F4 发布

$ kairo task list --parent AFF2B749-D71C-4293-8561-8BC6AB0F6990
13F2267E 后端 [群组] 待办
72879F52 前端 [群组] 待办
21A2999C 写验收文档 待办 · 投入 4 小时 · 持续 1 天 · #文档 #验收
```

验收要点：

- 输出使用短 ID（UUID 前 8 位）；`[群组]` / `[里程碑]` 行内标记种类；里程碑投入/持续恒为 0。
- `task add --parent`、`task get`、`task update --progress`、`task list --parent` 均经同一 KairoSession 契约。

## 四、macOS 应用：打开同一 .kairo

在 SwiftUI 应用中执行「文件 → 打开…」（⌘O，`fileImporter`），选择上文中 MCP 或 CLI 生成的任一
`.kairo`（如 `/tmp/kairo-demo/mcp.kairo`）。应用经 `KairoSession.openProject` 载入：

- 主窗口任务列表按 `parentID` 构建层级树（根为 `parentID == nil`）：规划/开发/发布为顶层，
  其下群组可展开，任务叶子在末层。
- 行内区分 `kind`：群组标题加粗、里程碑显示菱形标记。
- 保存（⌘S / 另存为）经 `KairoSession.saveProject` / `fileExporter` 回写同一 `.kairo` 格式。

演示数据文件结构（MCP 保存产物 `mcp.kairo` 实测）：`formatVersion = 1`、`project.title = "演示项目"`、
15 个任务、3 个根任务、2 个里程碑。

## 五、契约一致性核对

| 接口 | 建项目 | 导入 WBS | 保存 | 查任务树 |
| --- | --- | --- | --- | --- |
| MCP | `project_create` | `wbs_import` → total 15 | `project_save` | `task_list` |
| CLI | `project create` | `wbs import` → 15 个任务 | 自动回写 | `task list` |
| macOS | 新建/打开 | 打开 .kairo 即见树 | ⌘S / 另存为 | 大纲层级树 |

三接口共用 `KairoSession`（命令层），工具/子命令参数与 `.kairo` 格式同源（ADR-005）。
