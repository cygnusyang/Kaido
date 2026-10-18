# Kairo Claude Code 插件

把 Kairo 的计划能力接入 Claude Code：斜杠命令驱动 WBS、排期、违例查看与状态回写，
底层经 MCP 工具（ADR-005 契约同源）。

## 前置条件

1. 已在本仓库构建 MCP 服务：

   ```bash
   swift build -c release
   ```

2. 设置 `KAIRO_PROJECT` 为 `.kairo` 文件路径（可放入 shell 配置），或在命令中按提示提供。

## 加载

```bash
claude --plugin-dir /path/to/Kairo/Plugins/claude-code
```

MCP 启动脚本按以下顺序定位服务：

1. 环境变量 `KAIRO_MCP_BIN` 指定的可执行文件；
2. 仓库 `.build/release/KairoMCP`；
3. 仓库 `.build/debug/KairoMCP`。

三者都找不到时，脚本向 stderr 输出原因并以非零码退出。

## 命令

| 命令 | 作用 |
|---|---|
| `/kairo plan <需求>` | 读需求、建 WBS、排期、列违例 |
| `/kairo done <任务ID>` | 任务标记完成并回报群组完成度 |
| `/kairo status` | 任务表、重要路径与违例汇总 |

任务 ID 接受完整 UUID 或 ≥4 位唯一前缀。

## 已配置的 hook

`hooks/hooks.json` 注册 `TaskCompleted` 事件，调用 `bin/kairo-task-hook`：

1. 读取事件 JSON 的 `task_subject`（Claude Code 任务标题）。
2. 用 `KairoCLI task list --json` 读取 `KAIRO_PROJECT` 项目，按标题精确匹配。
3. 恰好匹配一个任务且状态不是 `done` 时，执行 `kairo status update <id> --status done`。

标题是两套任务系统之间唯一的连接键：`/kairo plan` 建 WBS 时让 Claude Code 任务与
Kairo 任务同名，且标题在项目内保持唯一。

安全边界：

- 匹配 0 个或多个任务、缺少 `KAIRO_PROJECT`、找不到 `KairoCLI` 时只向 stderr 写原因，
  不回写、不阻塞 Claude Code 的任务完成（始终以 0 退出）。
- hook 经 CLI 直接写 `.kairo` 文件。应用打开同一文件时不会自动刷新，需重新打开；
  hook 运行前先保存应用内改动，避免被文件内容覆盖。
- 可用 `KAIRO_CLI_BIN` 指定 CLI 路径（与 `KAIRO_MCP_BIN` 同义）。
