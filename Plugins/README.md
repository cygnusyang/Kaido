# Kaido for AI agents

**English** · [简体中文](README.zh-CN.md)

> Two audiences: ① you want an AI to break down a WBS, produce a schedule and track progress; ② you want to wire Kaido into an agent (Claude Code / CodeBuddy / Codex).
> Every command below was run against Kaido v0.9.1 release binaries on macOS (2026-10-25). Host-side configuration follows each vendor's documented format — see "Scope of verification" at the end.

## 0. Division of labour, in one table

| Role | Does | Does not |
|---|---|---|
| AI agent | Reads the requirement, breaks it down, estimates, writes code, writes status back | No long-term memory, does not keep the ledger |
| Kaido | Stores the WBS and dependencies, computes the schedule, lists violations and the critical path, aggregates progress | Does not write code, does not make technical calls for the AI |
| Human | Sets the boundaries (dates, acceptance criteria), reviews the Gantt and violations, intervenes | Does not babysit individual tasks |

Kaido's three entry points share one write path (`KaidoSession`): **16 MCP tools**, the **CLI**, and the **macOS app**. There is exactly one store: a single `.kaido` file (JSON). Agents use the first two, humans use the third.

## 1. Why only Claude Code gets a plugin

A plugin is not a capability, it is a **bridge**. Three of the four pieces can be replaced by MCP/CLI; only the hook cannot:

| Component | Replaceable by a generic interface? | Verdict |
|---|---|---|
| `.mcp.json` | Yes (project-level MCP config) | Saves one manual step |
| Slash commands | Yes (a convention inside the rules file) | Convenient, not required |
| `TaskCompleted` hook | **No** | The only part that is actually worth it |
| Manifest / marketplace distribution | No | Only pays off when publishing externally |

The hook exists to **bridge Claude Code's own task system** (TaskCreate / TaskCompleted) into Kaido. Codex has no equivalent event; CodeBuddy's plugin format is a fork of Claude's (different manifest directory, different root variable names). Shipping a shell for each of them buys you "one less config step" and costs "chasing someone else's format forever".

So this repository chooses:

- **Claude Code**: full plugin kept (slash commands + automatic write-back hook), tested;
- **CodeBuddy / Codex**: no plugin — one MCP config plus a convention written into the rules file, zero maintenance.

Of the three wirings, the first two steps (§2, §3) are shared; do those, then pick a host.

## 2. Shared prerequisites: build + create a project

```bash
# 1) change this line: point at your Kaido checkout
export KAIDO="$HOME/work/opc/04-开发项目/Kaido"

# 2) build (MCP and CLI both come out of this one command)
cd "$KAIDO" && swift build -c release

# 3) create the working directory and the project file
mkdir -p "$HOME/Projects/demo" && cd "$HOME/Projects/demo"
"$KAIDO/.build/release/KaidoCLI" project create "Demo Project" \
  --start 2026-11-02 --end 2026-11-20 --file demo.kaido
```

The CLI picks its language from `--lang <bcp47>` → `KAIDO_LANG` → the system locale, falling back to Simplified Chinese when it cannot tell. The sample output in this page is English, so export the variable once before running along:

```bash
export KAIDO_LANG=en   # or append --lang en to any single command; --json is language-independent
```

Successful output:

```
project created: B2D0A3C3 "Demo Project"
saved: /Users/you/Projects/demo/demo.kaido
format version: v1
```

> `--start` / `--end` are the scheduling engine's default boundaries; anything scheduled outside them is reported as a violation. Dates are always `YYYY-MM-DD`.

Optional: verify the MCP server itself (two lines; you are through when you see serverInfo and tools):

```bash
printf '%s\n%s\n' \
 '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}' \
 '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
 | "$KAIDO/.build/release/KaidoMCP" | head -c 400
```

## 3. Shared convention: put this into the host's rules file

Codex reads `AGENTS.md`, CodeBuddy reads `CODEBUDDY.md`, Claude Code reads `CLAUDE.md` — all at the **project root**. Replace the path with your real one:

```markdown
## Kaido project management

This project keeps its WBS and schedule in Kaido. The project file is fixed at:
/Users/you/Projects/demo/demo.kaido

- Before starting, call task_list to read the current state; do not re-create tasks that already exist.
- Breakdown order: milestone → group → leaf. Leaves must carry effortHours (estimate at 8 hours per person-day); groups and milestones carry no effort.
- One leaf = one change that is deliverable and acceptable on its own; if it looks bigger than 3 person-days, break it further.
- Right after breaking down: wbs_import, then schedule_compute. If violations_list returns anything, report it first — do not silently change deadlines or dependencies.
- Whenever a task is finished, call status_update to set status to done (progress becomes 100% automatically). Do not just edit the progress number.
- Task IDs accept a full UUID or a unique prefix of at least 4 characters; when a prefix is ambiguous, list the candidates and let the user choose. Never guess.
- If you are only planning and not writing code, say so explicitly: "this turn only updates the Kaido plan".
```

This block is the **only** shared intelligence layer across the three hosts. If it must change, change it here and nowhere else — never keep a second copy.

## 4. Claude Code

### Option A: MCP only (simplest, 30 seconds)

```bash
cd "$HOME/Projects/demo"
cat > .mcp.json <<EOF
{
  "mcpServers": {
    "kaido": { "command": "$KAIDO/.build/release/KaidoMCP" }
  }
}
EOF
```

Then run `claude`; the first time it asks whether to trust this project's MCP server — accept. **This `.mcp.json` is shared with CodeBuddy** (§5): one config, two hosts.

### Option B: the full plugin (slash commands + automatic write-back)

```bash
export KAIDO_PROJECT="$HOME/Projects/demo/demo.kaido"
claude --plugin-dir "$KAIDO/Plugins/claude-code"
```

| Command | What it does |
|---|---|
| `/kaido plan <path to a requirements doc, or a description>` | read requirement → build WBS → schedule → list violations |
| `/kaido done <task ID or prefix>` | mark it done and report the group's progress |
| `/kaido status` | task table, critical path, violation summary |

The plugin also registers a `TaskCompleted` hook: when a Claude Code task completes, it finds the Kaido task with the **exact same title** and writes back `done`. Titles that take part in write-back must therefore be unique within the project, otherwise the hook skips (duplicate names) or marks the wrong one (same name across different work items). The hook writes the file directly, so it and the app will overwrite each other if both are open — close the app during write-back.

## 5. CodeBuddy

**No plugin shell** (the format is a fork; the only gain would be skipping one config step). Two steps:

```bash
# Option 1: project level (recommended, shares the file with Claude Code)
cd "$HOME/Projects/demo"
# skip if §4 already created .mcp.json
cat > .mcp.json <<EOF
{ "mcpServers": { "kaido": { "command": "$KAIDO/.build/release/KaidoMCP" } } }
EOF

# Option 2: user level (visible in every project)
codebuddy mcp add --scope user kaido -- "$KAIDO/.build/release/KaidoMCP"
```

Put `CODEBUDDY.md` at the project root with the §3 block as its content. After starting `codebuddy`, the first connection to a project-level MCP server needs approval; in non-interactive mode add `--settings '{"enableAllProjectMcpServers": true}'`.

Verify:

```bash
codebuddy -p "use kaido's task_list to list the tasks in demo.kaido, output titles and statuses only"
```

## 6. Codex

Codex has no slash commands and no task-completed event to hook; it only has `config.toml` and `AGENTS.md`. So write-back relies on the **convention** (the last two bullets of §3), not on a hook.

```bash
# 1) register MCP → ~/.codex/config.toml
cat >> ~/.codex/config.toml <<EOF

[mcp_servers.kaido]
command = "$KAIDO/.build/release/KaidoMCP"
args = []
EOF

# 2) put AGENTS.md at the project root with the §3 block as its content
# 3) start in the project directory
cd "$HOME/Projects/demo" && codex
```

There is no `/kaido plan` in Codex; one sentence triggers the same flow:

```
Follow the Kaido flow in AGENTS.md: break docs/requirements.md into a WBS, import it into
demo.kaido, estimate the effort, then schedule and list violations. Update the plan only,
do not write code.
```

When a task is done, let it use the CLI (more controllable than MCP, and easier to double-check in a terminal):

```bash
"$KAIDO/.build/release/KaidoCLI" status update 3AE8 --status done \
  --file "$HOME/Projects/demo/demo.kaido"
```

> The `codex` CLI is not on PATH on this machine (the desktop app is installed instead); the `config.toml` snippet above follows its existing `[mcp_servers.*]` structure. On first use, confirm that `codex` lists the kaido tools.

## 7. How to break down a WBS (the important part)

### 7.1 Three levels

```
milestone (kind=milestone, zero duration, aligned to an external event: test hand-off / release / review)
└── group (kind=group, holds children only, no effort)
    └── leaf (kind=task, must carry effortHours; the unit of scheduling and write-back)
```

### 7.2 Leaf criteria (a leaf only counts if all four hold)

1. **Acceptable on its own**: one sentence states "what done means"; nothing else has to be finished first to judge it;
2. **One owner, one responsibility**: a single person accountable, no parallel negotiation needed;
3. **0.5–3 person-days**: under half a day means you over-split (merge cost exceeds management cost); over 3 days means it is not broken down yet;
4. **A concrete output**: a file, an interface, a document, or an observable behaviour.

### 7.3 Effort and duration

- Fill in `effortHours` only (person-hours); the engine converts at 8 hours per person-day;
- Groups and milestones carry no effort; their progress is **effort-weighted** from their children;
- No effort means the schedule cannot be trusted and violation checking degrades.

### 7.4 Dependencies

Connect leaves only, in the form `predecessorID:type[:lag]`:

| Type | Meaning | Where it is used |
|---|---|---|
| `fs` | successor starts after the predecessor finishes (default) | 95% of cases |
| `ss` | both start together | two parallel development lines |
| `ff` | both finish together | aligning wrap-up work |
| `sf` | successor finishes only after the predecessor starts | rarely used |

`lag` is a lead time in days, for real gaps like "integration starts 2 days after the API freezes".

### 7.5 Anti-patterns

| What people write | Why it is wrong |
|---|---|
| "Build the payment module" as a leaf with 80 hours | Not acceptable, not parallelisable; split into API / server / client / integration |
| Effort on a group | Progress gets counted twice |
| A milestone with a 2-day duration | A milestone is a point in time, not work |
| A dependency pointing at a group | The engine only honours leaves; group dependencies are ambiguous |
| Two tasks with the same title | The Claude Code hook will skip or mis-mark |

## 8. One full walkthrough (copy as-is)

```bash
cd "$HOME/Projects/demo"
BIN="$KAIDO/.build/release/KaidoCLI"
export KAIDO_LANG=en   # English output; omit it for the default language

# ⓪ create the project if it is missing (skipped if present, never overwritten)
[ -f demo.kaido ] || "$BIN" project create "Demo Project" \
  --start 2026-11-02 --end 2026-11-20 --file demo.kaido

# ① write a WBS (nested JSON; omitting children on a leaf is legal)
cat > wbs.json <<'EOF'
[
  {"title": "Payment module", "kind": "group", "children": [
    {"title": "API design", "effortHours": 16},
    {"title": "Server implementation", "effortHours": 40},
    {"title": "Client integration", "effortHours": 24},
    {"title": "Integration sign-off", "kind": "milestone"}
  ]}
]
EOF

# ② import (the whole tree at once)
"$BIN" wbs import wbs.json --file demo.kaido

# ③ look at the list (optional; ④ resolves prefixes from titles)
"$BIN" task list --file demo.kaido
```

Output (prefixes are local to your project):

```
imported 5 tasks
  560E37A9 Payment module
```

```
560E37A9 Payment module [group] pending
8113CA26 API design pending · effort 16 h
6E47F1F3 Server implementation pending · effort 40 h
F7507B0F Client integration pending · effort 24 h
3E82456D Integration sign-off [milestone] pending · effort 0 h · duration 0 days
```

```bash
# ④ wire dependencies: resolve prefixes by title instead of copying IDs by hand
id() { "$BIN" task list --file demo.kaido --json \
  | python3 -c "import json,sys;print([t['id'][:4] for t in json.load(sys.stdin) if t['title']=='$1'][0])"; }

"$BIN" task update "$(id 'Server implementation')" --dep "$(id 'API design'):fs" --file demo.kaido
"$BIN" task update "$(id 'Client integration')" --dep "$(id 'Server implementation'):fs" --file demo.kaido
"$BIN" task update "$(id 'Integration sign-off')" --dep "$(id 'Client integration'):fs" --file demo.kaido

# ⑤ schedule
"$BIN" schedule compute --file demo.kaido

# ⑥ critical path (the chain with zero slack)
"$BIN" schedule path --file demo.kaido

# ⑦ violations (cycles, out-of-bounds, deadline conflicts)
"$BIN" violations --file demo.kaido

# ⑧ write-back (the AI does this once per finished task)
"$BIN" status update "$(id 'API design')" --status done --file demo.kaido
```

What the real run printed:

```
task updated: 6E47F1F3 Server implementation
task updated: F7507B0F Client integration
task updated: 3E82456D Integration sign-off
---
schedule computed: 5 tasks
  560E37A9 Payment module  2026-11-01T16:00:00Z → 2026-11-02T16:00:00Z (1 day, ASAP)
  8113CA26 API design  2026-11-01T16:00:00Z → 2026-11-03T16:00:00Z (2 days, ASAP)
  6E47F1F3 Server implementation  2026-11-03T16:00:00Z → 2026-11-08T16:00:00Z (5 days, ASAP)
  F7507B0F Client integration  2026-11-08T16:00:00Z → 2026-11-11T16:00:00Z (3 days, ASAP)
  3E82456D Integration sign-off  2026-11-11T16:00:00Z → 2026-11-11T16:00:00Z (0 days, ASAP)
---
critical path: 0 tasks (slack limit 0 days)
  560E37A9 Payment module  total slack 17 days / free slack 17 days
  8113CA26 API design  total slack 8 days / free slack 0 days
  6E47F1F3 Server implementation  total slack 8 days / free slack 0 days
  F7507B0F Client integration  total slack 8 days / free slack 0 days
  3E82456D Integration sign-off  total slack 8 days / free slack 8 days
---
no violations
---
status written: 8113CA26 API design (done, progress 100%)
completed at: 2026-10-25T03:23:58Z
group progress: 100%
```

> `group progress` aggregates the subtree the task belongs to — for a leaf that is the task itself, so 100% here means "this leaf is done", not "the whole group is done".
> Schedule output is ISO8601 **UTC**: local midnight shows up as 16:00Z the previous day (UTC+8). Trust the macOS app or `--json` for calendar dates; do not read the terminal's UTC straight onto a calendar.

## 9. Collaboration loop

```
Human: set boundaries (start/end dates, acceptance criteria)
  ↓
AI: task_list to read the state → break down the WBS → wbs_import → schedule_compute → report violations
  ↓
Human: review the Gantt and violations (macOS app), approve or change deadlines / dependencies
  ↓
AI: implement task by task → status_update done → group progress aggregates automatically
  ↓
Human: watch progress and drift, decide to insert work or cut scope
```

Two collaboration rules:

- **Read before writing**: the AI calls `task_list` before every change, otherwise it rebuilds the same tree;
- **Write back on completion**: changing `progress` without `status` leaves group progress untouched, and the human then looks at a fake number.

## 10. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `command not found` / KaidoMCP not found | Not built, or the path is wrong | `swift build -c release`, and use absolute paths in the config |
| MCP connected but tools say "no project open" | Tools do not read environment variables; they need an explicit path | Call `project_open` first, or hard-code the path in the rules file |
| `kaido-mcp: KaidoMCP build product not found` | The plugin launch script ran without a build | Build, or set `KAIDO_MCP_BIN` |
| A Claude Code task completed but nothing was written back | Title not unique / `KAIDO_PROJECT` missing / CLI not found | Read the `kaido-hook:` lines on stderr; set `KAIDO_CLI_BIN` |
| App and AI editing the same `.kaido` | No automatic merge | The app offers to reload; close the app during write-back |
| Scheduled dates off by one day | Output is UTC, the app shows local time | Trust the app or the local dates in `--json` |

## 11. Scope of verification

- **Verified** (macOS, Kaido v0.9.1 release binaries, 2026-10-25): §2 including the MCP probe, §8 end to end with English CLI output.
- **Verified earlier** (Kaido v0.8.0, 2026-10-23, re-checked against the current tree but not re-run): §4A / §4B / §5 Kaido-side commands and the plugin hook write-back.
- **Not verified**: whether Codex desktop exposes the `[mcp_servers.kaido]` tools immediately (no `codex` CLI on PATH here); CodeBuddy's `TaskCompleted` event payload fields (its docs list the event name but not the fields, so no CodeBuddy hook exists).
