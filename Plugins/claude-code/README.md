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

完成后 hook 按同样顺序查找 `KairoCLI`（`KAIRO_CLI_BIN` → release → debug）。插件经
marketplace 安装到仓库外时，后两级路径不存在，必须设置这两个环境变量。

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

标题是两套任务系统之间的连接键，属于**约定而非强约束**：

- `/kairo plan` 只导入 Kairo WBS，不创建 Claude Code 任务。需要自动回写时，再为对应
  工作项创建同名 Claude Code 任务。
- Kairo 不校验标题唯一。标题重名时 hook 跳过；不同工作项同名时 hook 会误标，
  因此参与回写的标题必须在项目内唯一。

安全边界：

- 匹配 0 个或多个任务、缺少 `KAIRO_PROJECT`、找不到 `KairoCLI`、事件格式非法时，
  只向 stderr 写原因，不回写、不阻塞 Claude Code 的任务完成。除 Python 解释器缺失外，
  hook 始终以 0 退出。
- hook 经 CLI 直接写 `.kairo` 文件，应用不会自动刷新。两边同时编辑会互相覆盖：
  hook 先写、应用后保存时，应用内存中的旧数据会覆盖回写结果。回写期间关闭应用，
  或回写后重新打开再编辑。
- `KAIRO_CLI_BIN` 指定 CLI 路径；`KAIRO_MCP_BIN` 指定 MCP 服务路径，两者独立。
- hook 按项目真实路径加排他锁（锁文件位于系统临时目录），并行子代理同时完成多个
  任务时不会互相覆盖回写。
- `task list --json` 输出裸数组（便于脚本直接遍历），MCP `task_list` 返回
  `{"tasks": [...]}`；两接口字段一致，信封不同。
