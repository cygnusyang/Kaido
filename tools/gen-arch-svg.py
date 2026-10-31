#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 docs/02-architecture.md 配套的 SVG 图（文档图形资产的可复现来源）。

用法：python3 tools/gen-arch-svg.py
输出：docs/architecture-{dataflow,entities,repo-layout,adr013-layers}.svg

图内坐标由本脚本按内容自动排布，勿手工编辑 SVG；改内容请改本脚本后重跑。
"""
import io
import os

LANG = os.environ.get("KAIDO_SVG_LANG", "en")

DOCS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs")

STYLE = """  <style>
    .canvas { fill: #FFFFFF; }
    .panel { fill: #FFFFFF; stroke: #D8DAE0; stroke-width: 1; }
    .soft { fill: #F6F7F9; stroke: #D8DAE0; stroke-width: 1; }
    .accent { fill: #EEF0FE; stroke: #5F6CF8; stroke-width: 1; }
    .core { fill: #F4EEFC; stroke: #A13EF2; stroke-width: 1; }
    .line { stroke: #7A8290; stroke-width: 1.3; fill: none; }
    .tree { stroke: #C3C7D0; stroke-width: 1; fill: none; }
    .t-title { font: 600 13px "SF Pro Text", -apple-system, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif; fill: #1C1C1E; }
    .t-sub { font: 400 12px "SF Pro Text", -apple-system, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif; fill: #5C6169; }
    .t-name { font: 600 12.5px "SF Mono", ui-monospace, Menlo, monospace; fill: #1C1C1E; }
    .t-mono { font: 400 12px "SF Mono", ui-monospace, Menlo, monospace; fill: #1C1C1E; }
    .t-band { font: 600 11px "SF Pro Text", -apple-system, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif; fill: #5C6169; letter-spacing: 0.4px; }
    .t-note { font: 400 10.5px "SF Pro Text", -apple-system, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif; fill: #5C6169; }
    .arrow-head { fill: #7A8290; }
    @media (prefers-color-scheme: dark) {
      .canvas { fill: #1C1C1E; }
      .panel { fill: #2C2C2E; stroke: #3A3A3C; }
      .soft { fill: #242426; stroke: #3A3A3C; }
      .accent { fill: #232640; stroke: #5F6CF8; }
      .core { fill: #2B2233; stroke: #A13EF2; }
      .line { stroke: #8B93A3; }
      .tree { stroke: #4A4A4E; }
      .t-title, .t-name, .t-mono { fill: #F2F2F7; }
      .t-sub, .t-band, .t-note { fill: #A6A6AD; }
      .arrow-head { fill: #8B93A3; }
    }
  </style>
"""

DEFS = """  <defs>
    <marker id="kaido-arrow" markerWidth="8" markerHeight="8" refX="7.2" refY="4"
            orient="auto" markerUnits="userSpaceOnUse">
      <path d="M0,0 L8,4 L0,8 Z" class="arrow-head"/>
    </marker>
  </defs>
"""


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


# ------------------------------------------------------------------ 双语
# KAIDO_SVG_LANG=zh 出中文图；默认 en。中文原文即键，缺键视为无需翻译。
# 图内坐标按内容自动排布，英文比中文宽，译文长度需受控（见各图注释里的宽度上限）。
EN = {
    # ---- 1.1 分层图
    "Kaido 分层架构": "Kaido layered architecture",
    "等价接口层（macOS 应用、MCP 服务、CLI、Claude Code 插件）之下依次为 KaidoPresentation "
    "与 KaidoCommands，底部为跨平台核心 KaidoCore（数据模型、调度引擎、存储、查询过滤）。"
    "箭头方向为依赖方向。":
        "Four equivalent interfaces (macOS app, MCP server, CLI, Claude Code plugin) sit on top of "
        "KaidoPresentation and KaidoCommands; the cross-platform core KaidoCore (model, scheduler, "
        "storage, queries) is at the bottom. Arrows point along the dependency direction.",
    "等价接口层（能力对等）": "Equivalent interface layer (same capability)",
    "macOS 应用": "macOS app",
    "MCP 服务": "MCP server",
    "Claude Code 插件": "Claude Code plugin",
    "斜杠命令 + hooks": "slash commands + hooks",
    "（经 MCP 服务 / CLI 接入）": "(via MCP server / CLI)",
    "视图状态 → 平台中立快照 + 动作": "view state → snapshot + actions",
    "KaidoSession（唯一写入口）；MCP 服务与 CLI 共用同一命令语义":
        "KaidoSession (single write path); MCP server and CLI share one command semantics",
    "跨平台核心 KaidoCore（纯逻辑）": "Cross-platform core KaidoCore (pure logic)",
    "数据模型": "Data model",
    "调度引擎": "Scheduler",
    "存储": "Storage",
    "查询过滤": "Query",
    "箭头方向 = 依赖方向（上层依赖下层）。KaidoCore / KaidoCommands / KaidoPresentation "
    "均为 Foundation-only，":
        "Arrows point along the dependency direction (upper depends on lower).",
    "可在 iOS 与 Linux 编译。macOS 应用是本期唯一 UI 壳；MCP 服务与 CLI 经 KaidoCommands "
    "共享同一命令语义，接口层互不依赖。":
        "KaidoCore, KaidoCommands, KaidoPresentation are Foundation-only (iOS/Linux); the app is the "
        "only UI shell, and interface layers are independent.",

    # ---- 1.2 数据流
    "Kaido 核心闭环数据流": "Kaido core loop: data flow",
    "需求文档经 AI 读取得到 WBS 分解，MCP/CLI 建任务树后由 KaidoCore 排期；"
    "状态回写经 MCP/CLI 回到 AI 逐功能开发，人随时在 macOS 应用审阅与干预。":
        "The AI reads the requirements document into a WBS; MCP/CLI build the task tree and "
        "KaidoCore schedules it. Status flows back through MCP/CLI to the AI, which builds feature "
        "by feature while the human reviews in the macOS app.",
    "需求文档": "Requirements",
    "WBS 分解": "WBS breakdown",
    "KaidoCore 排期": "KaidoCore scheduling",
    "AI 读取": "read by AI",
    "(MCP/CLI: 建任务树)": "(MCP/CLI: build task tree)",
    "AI 逐功能开发": "AI implements",
    "(MCP/CLI: 状态回写)": "(MCP/CLI: status write-back)",
    "人随时在 macOS 应用审阅 / 干预": "Human reviews / intervenes in the app",
    "实线为自动链路；回流段由 MCP/CLI 承接状态回写，形成「需求 → 计划 → 开发 → 回写」闭环。":
        "Solid lines are automatic; MCP/CLI carry the status write-back, closing the loop "
        "requirements → plan → build → write-back.",

    # ---- 4.1 实体关系
    "Kaido 项目实体关系": "Kaido project entity relations",
    "Project 聚合设置、任务、相关性、资源、分配、工作日历、基线、变更历史与元数据；"
    "Task、TaskDependency、Resource、TaskAssignment 各自展开字段。":
        "Project aggregates settings, tasks, dependencies, resources, assignments, work calendar, "
        "baselines, change history and metadata; Task, TaskDependency, Resource and TaskAssignment "
        "are expanded field by field.",
    "priority, tags, constraints(4 个可空时限日期),":
        "priority, tags, constraints(4 nullable constraint dates),",
    "快照名 + 时间 + 任务时间/进度": "snapshot name + time + task dates/progress",
    "字段路径 + 旧值 + 新值 + 时间 + 来源": "field path + old value + new value + time + source",
    "字段级草案：Task / TaskDependency / Resource / TaskAssignment 展开到字段，其余聚合项只列口径。":
        "Field-level draft: Task / TaskDependency / Resource / TaskAssignment are expanded to fields; "
        "the other aggregates state their shape only.",

    # ---- 5 目录结构
    "Kaido 仓库目录结构": "Kaido repository layout",
    "monorepo 目录：Package.swift 根清单、Sources 跨平台核心、Apps/macOS 应用、"
    "Interfaces（MCP / CLI）、Plugins/claude-code、Tests 与 docs。":
        "Monorepo: Package.swift at the root, Sources for the cross-platform core, Apps/macOS for the "
        "app, Interfaces (MCP / CLI), Plugins/claude-code, Tests and docs.",
    "SwiftPM 根清单（core + 各产品 target 同仓）":
        "SwiftPM manifest (core and product targets in one repo)",
    "跨平台核心（纯逻辑；零 AppKit/SwiftUI import）":
        "cross-platform core (pure logic; no AppKit/SwiftUI import)",
    "调度引擎（相关性传播/重要路径/宽延/违例）":
        "scheduler (dependency propagation, critical path, slack, violations)",
    ".kaido 编解码 / 模板 / 导入导出": ".kaido codec / templates / import and export",
    "AIFilter 迁移 + 查询/过滤接口": "AIFilter migration + query/filter interfaces",
    "macOS SwiftUI 应用（import KaidoCore）": "macOS SwiftUI app (imports KaidoCore)",
    "ContentView / 甘特 / 命令面板 / kaido:// 深链":
        "ContentView / Gantt / command palette / kaido:// deep links",
    "MCP 服务（复用 KaidoCore）": "MCP server (reuses KaidoCore)",
    "CLI（复用 KaidoCore；从 MCP 契约派生命令）":
        "CLI (reuses KaidoCore; commands derived from the MCP contract)",
    "斜杠命令 + hooks + .mcp.json 模板": "slash commands + hooks + .mcp.json template",
    "核心全量单测（Linux 亦编译；现有 17 项迁入）":
        "full core unit tests (also build on Linux)",
    "应用层测试（Store 交互 + ImageRenderer 离屏渲染）":
        "app-layer tests (store interaction + offscreen ImageRenderer)",
    "MCP/CLI 对等性契约测试（US-E5-05）": "MCP/CLI parity contract tests (US-E5-05)",
    "本文档集（00-vision / 01-prd / 02-architecture / 03-roadmap / features）":
        "this documentation set (00-vision / 01-prd / 02-architecture / 03-roadmap / features)",
    "边界规则：KaidoCore 不得反向依赖任何接口层或 UI；接口层只允许依赖 KaidoCore 公开 API。":
        "Boundary rule: KaidoCore never depends on an interface layer or UI; interface layers may only "
        "use the public KaidoCore API.",

    # ---- 6.1 ADR-013 分层
    "ADR-013 呈现层与唯一写路径分层": "ADR-013 presentation layer and single write path",
    "KaidoMacApp 依赖 KaidoPresentation，KaidoPresentation 依赖 KaidoCommands，"
    "KaidoCommands 依赖 KaidoCore；KaidoMCP 与 KaidoCLI 经 KaidoCommands 接入核心。":
        "KaidoMacApp depends on KaidoPresentation, which depends on KaidoCommands, which depends on "
        "KaidoCore; KaidoMCP and KaidoCLI reach the core through KaidoCommands.",
    "SwiftUI：WorkspaceStore 适配、壳层、绘制与手势":
        "SwiftUI: WorkspaceStore adapter, shell, drawing and gestures",
    "Foundation-only：视图状态 → 平台中立快照 + 动作":
        "Foundation-only: view state → neutral snapshot + actions",
    "Foundation-only：KaidoSession（唯一写入口）":
        "Foundation-only: KaidoSession (single write path)",
    "Foundation-only：模型、排期、违例、查询、布局几何":
        "Foundation-only: model, scheduling, violations, queries, layout geometry",
    "箭头指向被依赖层，依赖方向单向。KaidoPresentation 不得 import SwiftUI、AppKit 或 Combine；":
        "Arrows point at the depended-on layer; dependencies are one-way. KaidoPresentation must not "
        "import SwiftUI, AppKit or Combine;",
    "三层 Foundation-only 模块必须能在 iOS 与 Linux 编译。":
        "the three Foundation-only modules must build on iOS and Linux.",
}


def tr(s):
    return s if LANG == "zh" else EN.get(s, s)


def text(x, y, s, cls="t-sub", anchor=None):
    a = ' text-anchor="%s"' % anchor if anchor else ""
    return '  <text class="%s" x="%s" y="%s"%s>%s</text>\n' % (cls, x, y, a, esc(tr(s)))


def rect(x, y, w, h, cls="panel", rx=8):
    return '  <rect class="%s" x="%s" y="%s" width="%s" height="%s" rx="%s"/>\n' % (
        cls, x, y, w, h, rx)


def path(d, cls="line", marker=True):
    m = ' marker-end="url(#kaido-arrow)"' if marker else ""
    return '  <path class="%s" d="%s"%s/>\n' % (cls, d, m)


def vline(x, y1, y2):
    return '  <path class="tree" d="M%s,%s L%s,%s"/>\n' % (x, y1, x, y2)


def hline(x1, x2, y):
    return '  <path class="tree" d="M%s,%s L%s,%s"/>\n' % (x1, y, x2, y)


def label_w(name, mono=True):
    per = 7.6 if mono else 6.6
    return sum(13.5 if ord(c) > 0x2E80 else per for c in name)


def head(w, h, title, desc):
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d"\n'
        '     role="img" aria-labelledby="kaido-fig-title kaido-fig-desc">\n'
        '  <title id="kaido-fig-title">%s</title>\n'
        '  <desc id="kaido-fig-desc">%s</desc>\n'
        % (w, h, w, h, esc(tr(title)), esc(tr(desc)))
    ) + STYLE + DEFS + '  <rect class="canvas" x="0" y="0" width="%d" height="%d"/>\n' % (w, h)


def write(name, body):
    p = os.path.join(DOCS, name)
    with io.open(p, "w", encoding="utf-8") as f:
        f.write(body)
    print("wrote %s (%d bytes)" % (name, len(body.encode("utf-8"))))


# ---------------------------------------------------------------- 1.1 分层图

def layers():
    W, H = 900, 614
    s = head(W, H, "Kaido 分层架构",
             "等价接口层（macOS 应用、MCP 服务、CLI、Claude Code 插件）之下依次为 KaidoPresentation "
             "与 KaidoCommands，底部为跨平台核心 KaidoCore（数据模型、调度引擎、存储、查询过滤）。"
             "箭头方向为依赖方向。")

    # 接口层
    s += rect(20, 20, 860, 164, "soft", 12)
    s += text(36, 44, "等价接口层（能力对等）", "t-band")
    s += rect(44, 58, 180, 100)
    s += text(134, 100, "macOS 应用", "t-title", "middle")
    s += text(134, 122, "SwiftUI", "t-sub", "middle")
    s += rect(240, 58, 180, 100)
    s += text(330, 100, "MCP 服务", "t-title", "middle")
    s += text(330, 122, "MCP SDK", "t-sub", "middle")
    s += rect(436, 58, 180, 100)
    s += text(526, 100, "CLI", "t-title", "middle")
    s += text(526, 122, "kaido cmd", "t-sub", "middle")
    s += rect(632, 58, 224, 100)
    s += text(744, 82, "Claude Code 插件", "t-title", "middle")
    s += text(744, 104, "斜杠命令 + hooks", "t-sub", "middle")
    s += text(744, 124, "+ .mcp.json", "t-sub", "middle")
    s += text(744, 146, "（经 MCP 服务 / CLI 接入）", "t-sub", "middle")

    # 呈现层 / 命令层
    s += rect(44, 222, 250, 64, "accent")
    s += text(169, 248, "KaidoPresentation", "t-title", "middle")
    s += text(169, 270, "视图状态 → 平台中立快照 + 动作", "t-sub", "middle")
    s += rect(44, 326, 812, 60, "accent")
    s += text(60, 352, "KaidoCommands", "t-title")
    s += text(60, 372, "KaidoSession（唯一写入口）；MCP 服务与 CLI 共用同一命令语义", "t-sub")

    # 依赖箭头
    s += path("M134,158 L134,222")
    s += path("M169,286 L169,326")
    s += path("M330,158 L330,326")
    s += path("M526,158 L526,326")
    s += path("M450,386 L450,420")

    # 核心层
    s += rect(20, 420, 860, 154, "core", 12)
    s += text(36, 444, "跨平台核心 KaidoCore（纯逻辑）", "t-band")
    for x, name, sub in [(44, "数据模型", "Model"), (251, "调度引擎", "Schedule"),
                          (458, "存储", "Storage"), (665, "查询过滤", "Query")]:
        s += rect(x, 456, 191, 96)
        s += text(x + 95, 492, name, "t-title", "middle")
        s += text(x + 95, 514, sub, "t-sub", "middle")

    s += text(20, 588, "箭头方向 = 依赖方向（上层依赖下层）。KaidoCore / KaidoCommands / KaidoPresentation "
                       "均为 Foundation-only，", "t-note")
    s += text(20, 606, "可在 iOS 与 Linux 编译。macOS 应用是本期唯一 UI 壳；MCP 服务与 CLI 经 KaidoCommands "
                       "共享同一命令语义，接口层互不依赖。", "t-note")
    return s + "</svg>\n"


# ---------------------------------------------------------------- 1.2 数据流

def dataflow():
    W, H = 880, 320
    s = head(W, H, "Kaido 核心闭环数据流",
             "需求文档经 AI 读取得到 WBS 分解，MCP/CLI 建任务树后由 KaidoCore 排期；"
             "状态回写经 MCP/CLI 回到 AI 逐功能开发，人随时在 macOS 应用审阅与干预。")

    s += rect(40, 44, 150, 56, "panel")
    s += text(115, 77, "需求文档", "t-title", "middle")
    s += rect(290, 44, 150, 56, "panel")
    s += text(365, 77, "WBS 分解", "t-title", "middle")
    s += rect(610, 44, 210, 56, "core")
    s += text(715, 77, "KaidoCore 排期", "t-title", "middle")

    s += path("M190,72 L290,72")
    s += text(240, 62, "AI 读取", "t-sub", "middle")
    s += path("M440,72 L610,72")
    s += text(525, 62, "(MCP/CLI: 建任务树)", "t-sub", "middle")

    s += rect(330, 142, 170, 52, "accent")
    s += text(415, 174, "AI 逐功能开发", "t-title", "middle")
    s += path("M715,100 L715,168 L500,168")
    s += path("M330,168 L115,168 L115,100")
    s += text(222, 158, "(MCP/CLI: 状态回写)", "t-sub", "middle")

    s += rect(265, 246, 300, 50, "soft")
    s += text(415, 276, "人随时在 macOS 应用审阅 / 干预", "t-title", "middle")
    s += path("M415,246 L415,194")

    s += text(20, 310,
              "实线为自动链路；回流段由 MCP/CLI 承接状态回写，形成「需求 → 计划 → 开发 → 回写」闭环。",
              "t-note")
    return s + "</svg>\n"


# ---------------------------------------------------------------- 4.1 实体关系

def entities():
    rows = [
        ("settings", "ProjectSettings",
         ["direction, schedulePrecision, dateMode,",
          "granularity, projectStartDate/EndDate, workWeek"]),
        ("tasks", "[Task]",
         ["Task: id, title, notes, kind(task|group|milestone|hammock), parentID?",
          "startDate, dueDate, duration, effort, progress, status,",
          "priority, tags, constraints(4 个可空时限日期),",
          "baselineStart/baselineEnd, customValues"]),
        ("dependencies", "[TaskDependency]",
         ["TaskDependency: predecessorID, type(FS|FF|SS|SF),",
          "lag { amount, unit: working|elapsed|percentage }"]),
        ("resources", "[Resource]",
         ["Resource: id, name, email, type(person|equipment|material|group),",
          "units, efficiency, costPerUse, costPerHour,",
          "availabilityStart/End, parentID?, calendar?"]),
        ("assignments", "[TaskAssignment]",
         ["TaskAssignment: taskID, resourceID, units"]),
        ("calendar", "WorkCalendar", ["weeklyBlocks + exceptions"]),
        ("baselines", "[Baseline]", ["快照名 + 时间 + 任务时间/进度"]),
        ("history", "[ChangeRecord]", ["字段路径 + 旧值 + 新值 + 时间 + 来源"]),
        ("metadata", "", ["title, fileVersion, createdAt, updatedAt"]),
    ]

    x_root, y_root = 24, 26
    box_w, box_h = 120, 34
    indent = 18
    line_h = 17
    label_x = x_root + 14 + indent
    connector_x = x_root + 14
    detail_x = label_x + 22

    y = y_root + box_h + 26
    positions = []
    for name, typ, details in rows:
        positions.append((name, typ, details, y))
        y += line_h * (1 + len(details)) + 8
    height = y + 14
    width = 920

    s = head(width, height, "Kaido 项目实体关系",
             "Project 聚合设置、任务、相关性、资源、分配、工作日历、基线、变更历史与元数据；"
             "Task、TaskDependency、Resource、TaskAssignment 各自展开字段。")
    s += rect(x_root, y_root, box_w, box_h, "accent")
    s += text(x_root + box_w / 2, y_root + 23, "Project", "t-title", "middle")

    s += vline(connector_x, y_root + box_h, positions[0][3])
    s += vline(connector_x, positions[0][3], positions[-1][3])
    for name, typ, details, ny in positions:
        s += hline(connector_x, label_x - 6, ny)
        s += text(label_x, ny + 4, name, "t-name")
        if typ:
            s += text(label_x + label_w(name) + 12, ny + 4, ": " + typ, "t-mono")
        for k, d in enumerate(details):
            s += text(detail_x, ny + 4 + line_h * (k + 1), d, "t-sub")

    s += text(20, height - 6,
              "字段级草案：Task / TaskDependency / Resource / TaskAssignment 展开到字段，其余聚合项只列口径。",
              "t-note")
    return s + "</svg>\n"


# ---------------------------------------------------------------- 5 目录结构

def repo_layout():
    tree = [
        ("Package.swift", "SwiftPM 根清单（core + 各产品 target 同仓）", []),
        ("Sources/", "", [
            ("KaidoCore/", "跨平台核心（纯逻辑；零 AppKit/SwiftUI import）", [
                ("Model/", "Task/TaskDependency/Resource/WorkCalendar/Project/ProjectSettings", []),
                ("Schedule/", "调度引擎（相关性传播/重要路径/宽延/违例）", []),
                ("Storage/", ".kaido 编解码 / 模板 / 导入导出", []),
                ("Query/", "AIFilter 迁移 + 查询/过滤接口", []),
            ]),
        ]),
        ("Apps/", "", [
            ("macos/", "macOS SwiftUI 应用（import KaidoCore）", [
                ("Sources/", "ContentView / 甘特 / 命令面板 / kaido:// 深链", []),
                ("Resources/", "", []),
            ]),
        ]),
        ("Interfaces/", "", [
            ("mcp/", "MCP 服务（复用 KaidoCore）", []),
            ("cli/", "CLI（复用 KaidoCore；从 MCP 契约派生命令）", []),
        ]),
        ("Plugins/", "", [
            ("claude-code/", "斜杠命令 + hooks + .mcp.json 模板", []),
        ]),
        ("Tests/", "", [
            ("KaidoCoreTests/", "核心全量单测（Linux 亦编译；现有 17 项迁入）", []),
            ("AppTests/", "应用层测试（Store 交互 + ImageRenderer 离屏渲染）", []),
            ("InterfaceTests/", "MCP/CLI 对等性契约测试（US-E5-05）", []),
        ]),
        ("docs/", "本文档集（00-vision / 01-prd / 02-architecture / 03-roadmap / features）", []),
    ]

    x_root, y_root = 24, 24
    box_w, box_h = 110, 34
    indent = 18
    line_h = 19

    entries = []

    def layout(nodes, depth, y_start):
        """先占自身行，再向下排子节点；每个节点只登记一次。"""
        idxs = []
        y = y_start
        for name, comment, kids in nodes:
            idx = len(entries)
            entries.append({"name": name, "comment": comment, "depth": depth, "y": y, "kids": []})
            idxs.append(idx)
            y += line_h
            if kids:
                child_idxs, y = layout(kids, depth + 1, y + 3)
                entries[idx]["kids"] = child_idxs
        return idxs, y

    top, _ = layout(tree, 1, y_root + box_h + 22)
    height = entries[-1]["y"] + line_h + 18
    width = 920

    s = head(width, height, "Kaido 仓库目录结构",
             "monorepo 目录：Package.swift 根清单、Sources 跨平台核心、Apps/macOS 应用、"
             "Interfaces（MCP / CLI）、Plugins/claude-code、Tests 与 docs。")
    s += rect(x_root, y_root, box_w, box_h, "accent")
    s += text(x_root + box_w / 2, y_root + 23, "Kaido/", "t-title", "middle")

    def lx(depth):
        return x_root + 14 + depth * indent

    def cx(depth):
        return x_root + 14 + (depth - 1) * indent

    for e in entries:
        s += hline(cx(e["depth"]), lx(e["depth"]) - 6, e["y"])
        s += text(lx(e["depth"]), e["y"] + 14, e["name"], "t-name")
        if e["comment"]:
            cx2 = lx(e["depth"]) + label_w(e["name"]) + 16
            s += text(cx2, e["y"] + 14, "# " + tr(e["comment"]), "t-sub")

    # 竖脊：根 → 一级，以及每组兄弟
    s += vline(cx(1), y_root + box_h, entries[top[0]]["y"])
    for e in entries:
        if e["kids"]:
            kids = e["kids"]
            s += vline(cx(e["depth"] + 1), entries[kids[0]]["y"], entries[kids[-1]]["y"])

    s += text(20, height - 6,
              "边界规则：KaidoCore 不得反向依赖任何接口层或 UI；接口层只允许依赖 KaidoCore 公开 API。",
              "t-note")
    return s + "</svg>\n"


# ---------------------------------------------------------------- 6.1 ADR-013 分层

def adr013_layers():
    W, H = 880, 440
    s = head(W, H, "ADR-013 呈现层与唯一写路径分层",
             "KaidoMacApp 依赖 KaidoPresentation，KaidoPresentation 依赖 KaidoCommands，"
             "KaidoCommands 依赖 KaidoCore；KaidoMCP 与 KaidoCLI 经 KaidoCommands 接入核心。")

    bars = [
        ("KaidoMacApp", "SwiftUI：WorkspaceStore 适配、壳层、绘制与手势", "accent"),
        ("KaidoPresentation", "Foundation-only：视图状态 → 平台中立快照 + 动作", "accent"),
        ("KaidoCommands", "Foundation-only：KaidoSession（唯一写入口）", "accent"),
        ("KaidoCore", "Foundation-only：模型、排期、违例、查询、布局几何", "core"),
    ]
    x, w, bh, step = 40, 560, 54, 26
    y0 = 26
    for i, (name, desc, cls) in enumerate(bars):
        y = y0 + i * (bh + step)
        s += rect(x, y, w, bh, cls)
        s += text(x + 20, y + 23, name, "t-title")
        s += text(x + 20, y + 42, desc, "t-sub")
        if i < len(bars) - 1:
            s += path("M%d,%d L%d,%d" % (x + w // 2, y + bh, x + w // 2, y + bh + step))

    bx, bw, bh2 = 640, 220, 84
    by = y0 + 2 * (bh + step) - 14
    s += rect(bx, by, bw, bh2, "soft")
    s += text(bx + 16, by + 26, "KaidoMCP / KaidoCLI", "t-title")
    s += text(bx + 16, by + 48, "→ KaidoCommands", "t-mono")
    s += text(bx + 16, by + 68, "→ KaidoCore", "t-mono")
    s += path("M%d,%d L%d,%d" % (bx, by + bh2 // 2, x + w, by + bh2 // 2))

    s += text(20, H - 32,
              "箭头指向被依赖层，依赖方向单向。KaidoPresentation 不得 import SwiftUI、AppKit 或 Combine；",
              "t-note")
    s += text(20, H - 15, "三层 Foundation-only 模块必须能在 iOS 与 Linux 编译。", "t-note")
    return s + "</svg>\n"


if __name__ == "__main__":
    # 默认出英文（仓库主语言），KAIDO_SVG_LANG=zh 出中文；中文文件名加 .zh-CN 后缀。
    for lang in ("en", "zh"):
        globals()["LANG"] = lang
        suffix = "" if lang == "en" else ".zh-CN"
        write("architecture-layers%s.svg" % suffix, layers())
        write("architecture-dataflow%s.svg" % suffix, dataflow())
        write("architecture-entities%s.svg" % suffix, entities())
        write("architecture-repo-layout%s.svg" % suffix, repo_layout())
        write("architecture-adr013-layers%s.svg" % suffix, adr013_layers())
