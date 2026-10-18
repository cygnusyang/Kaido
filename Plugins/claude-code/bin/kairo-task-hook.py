#!/usr/bin/env python3
"""Claude Code TaskCompleted hook：按任务标题回写 Kairo 状态。

输入：Claude Code 经 stdin 传入的事件 JSON（hook_event_name == "TaskCompleted"，
含 task_subject）。Kairo 任务无 ID 映射时，标题是两系统之间唯一稳定的连接键。

规则：
- 仅在 KAIRO_PROJECT 指向 .kairo 文件、且标题恰好匹配一个 Kairo 任务时回写。
- 已为 done 的任务跳过；匹配 0 个或多个时只写 stderr，不改数据。
- 始终以 0 退出，不阻塞 Claude Code 的任务完成。
- 对项目文件加排他锁，避免并行子代理同时完成时互相覆盖回写结果。
"""

import fcntl
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unicodedata


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
    """向 stderr 写一行；剥离控制字符，避免把事件文本原样注入终端。"""
    clean = "".join(ch for ch in str(message) if unicodedata.category(ch)[0] != "C")
    print(f"kairo-hook: {clean}", file=sys.stderr)


def normalize(text):
    """标题比较前统一 Unicode 形式与首尾空白。"""
    return unicodedata.normalize("NFC", text).strip()


def run(cli, args):
    """执行 CLI，返回 (ok, stdout, stderr)。"""
    try:
        result = subprocess.run(
            [cli] + args, capture_output=True, text=True, encoding="utf-8", timeout=10
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return False, "", str(error)
    return result.returncode == 0, result.stdout, result.stderr


def sync_status(cli, project, subject):
    """在项目文件锁内完成「读取列表 → 匹配标题 → 回写」。"""
    ok, stdout, stderr = run(cli, ["task", "list", "--json", "--file", project])
    if not ok:
        note(f"读取任务列表失败：{stderr.strip()}")
        return

    try:
        tasks = json.loads(stdout)
    except json.JSONDecodeError:
        note("任务列表不是合法 JSON，跳过")
        return
    if not isinstance(tasks, list):
        note("任务列表格式不符，跳过")
        return

    matches = [
        task
        for task in tasks
        if isinstance(task, dict)
        and isinstance(task.get("title"), str)
        and normalize(task["title"]) == subject
    ]
    if len(matches) != 1:
        note(f"「{subject}」匹配 {len(matches)} 个 Kairo 任务，跳过回写")
        return

    task = matches[0]
    if task.get("status") == "done":
        return

    ok, _, stderr = run(
        cli,
        ["status", "update", str(task.get("id", "")), "--status", "done", "--file", project],
    )
    if ok:
        note(f"已回写「{subject}」为 done")
    else:
        note(f"状态回写失败：{stderr.strip()}")


def main():
    try:
        event = json.loads(sys.stdin.read())
    except (json.JSONDecodeError, UnicodeDecodeError):
        note("输入不是合法 JSON，跳过")
        return 0
    if not isinstance(event, dict):
        note("事件不是 JSON 对象，跳过")
        return 0

    if event.get("hook_event_name") != "TaskCompleted":
        return 0

    raw_subject = event.get("task_subject")
    if not isinstance(raw_subject, str):
        return 0
    subject = normalize(raw_subject)
    project = os.environ.get("KAIRO_PROJECT")
    if not subject or not project:
        return 0

    cli = find_cli()
    if cli is None:
        note("未找到 KairoCLI，跳过（先 swift build，或设置 KAIRO_CLI_BIN）")
        return 0

    # CLI 以原子替换写文件，项目文件的 inode 会变，不能直接锁它；
    # 改锁按项目真实路径派生的稳定排他锁，避免并行完成互相覆盖。
    real = os.path.realpath(project)
    lock_name = "kairo-hook-" + hashlib.sha256(real.encode()).hexdigest()[:16] + ".lock"
    lock_path = os.path.join(tempfile.gettempdir(), lock_name)
    try:
        with open(lock_path, "a") as lock_file:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
            try:
                sync_status(cli, project, subject)
            finally:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
    except OSError as error:
        note(f"无法获取项目锁：{error}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:  # noqa: BLE001 - hook 不阻塞任务完成
        note(f"意外错误，跳过：{error}")
        sys.exit(0)
