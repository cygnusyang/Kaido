#!/usr/bin/env python3
"""Claude Code TaskCompleted hook：按任务标题回写 Kairo 状态。

输入：Claude Code 经 stdin 传入的事件 JSON（hook_event_name == "TaskCompleted"，
含 task_subject）。Kairo 任务无 ID 映射时，标题是两系统之间唯一稳定的连接键。

规则：
- 仅在 KAIRO_PROJECT 指向 .kairo 文件、且标题恰好匹配一个 Kairo 任务时回写。
- 已为 done 的任务跳过；匹配 0 个或多个时只写 stderr，不改数据。
- 始终以 0 退出，不阻塞 Claude Code 的任务完成。
"""

import json
import os
import subprocess
import sys


def find_cli():
    """与 bin/kairo-mcp 相同的查找顺序：环境变量 → release → debug。"""
    override = os.environ.get("KAIRO_CLI_BIN")
    if override:
        return override
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
    for configuration in ("release", "debug"):
        candidate = os.path.join(root, ".build", configuration, "KairoCLI")
        if os.access(candidate, os.X_OK):
            return candidate
    return None


def note(message):
    print(f"kairo-hook: {message}", file=sys.stderr)


def main():
    try:
        event = json.loads(sys.stdin.read())
    except (json.JSONDecodeError, UnicodeDecodeError):
        note("输入不是合法 JSON，跳过")
        return 0

    if event.get("hook_event_name") != "TaskCompleted":
        return 0

    subject = (event.get("task_subject") or "").strip()
    project = os.environ.get("KAIRO_PROJECT")
    if not subject or not project:
        return 0

    cli = find_cli()
    if cli is None:
        note("未找到 KairoCLI，跳过（先 swift build，或设置 KAIRO_CLI_BIN）")
        return 0

    try:
        listing = subprocess.run(
            [cli, "task", "list", "--json", "--file", project],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        note(f"读取任务列表失败：{error}")
        return 0
    if listing.returncode != 0:
        note(f"读取任务列表失败：{listing.stderr.strip()}")
        return 0

    try:
        tasks = json.loads(listing.stdout)
    except json.JSONDecodeError:
        note("任务列表不是合法 JSON，跳过")
        return 0
    if not isinstance(tasks, list):
        note("任务列表格式不符，跳过")
        return 0

    matches = [task for task in tasks if task.get("title") == subject]
    if len(matches) != 1:
        note(f"「{subject}」匹配 {len(matches)} 个 Kairo 任务，跳过回写")
        return 0

    task = matches[0]
    if task.get("status") == "done":
        return 0

    try:
        update = subprocess.run(
            [
                cli,
                "status",
                "update",
                str(task.get("id", "")),
                "--status",
                "done",
                "--file",
                project,
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        note(f"状态回写失败：{error}")
        return 0
    if update.returncode != 0:
        note(f"状态回写失败：{update.stderr.strip()}")
        return 0

    note(f"已回写「{subject}」为 done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
