# Quickstart

Five minutes from nothing to a scheduled project, then one line to hand it to an AI agent.
Every command below is meant to be copied as-is.

## 1. Install the app

```bash
brew install --cask cygnusyang/kaidoplan/kaido
```

No Homebrew? Download `Kaido-vX.Y.Z.dmg` from the [latest release](https://github.com/cygnusyang/Kaido/releases/latest) and drag it to Applications.

> The app is currently **ad-hoc signed, not notarized**. On first launch macOS blocks it:
> allow it in **System Settings → Privacy & Security → Open Anyway**. See
> [SECURITY.md](SECURITY.md) for what that means for provenance.

## 2. Get the CLI and the MCP server

Prebuilt universal binaries (Apple Silicon and Intel in one file):

```bash
VER=$(curl -sS https://api.github.com/repos/cygnusyang/Kaido/releases/latest \
  | sed -n 's/.*"tag_name": *"\(v[^"]*\)".*/\1/p')
BASE="https://github.com/cygnusyang/Kaido/releases/download/$VER"

curl -sSL -O "$BASE/kaido-$VER-macos-universal.tar.gz"
curl -sSL -O "$BASE/kaido-$VER-macos-universal.tar.gz.sha256"

# verify before unpacking: a truncated download fails right here
[ "$(cat kaido-$VER-macos-universal.tar.gz.sha256)" = \
  "$(shasum -a 256 kaido-$VER-macos-universal.tar.gz | awk '{print $1}')" ] \
  && echo "checksum ok"

tar xzf "kaido-$VER-macos-universal.tar.gz"
sudo install -m 755 "kaido-$VER-macos-universal/bin/kaido" \
  "kaido-$VER-macos-universal/bin/kaido-mcp" /usr/local/bin/
kaido
```

Or build from source (Swift 5.9+, Xcode 16+):

```bash
git clone https://github.com/cygnusyang/Kaido.git
cd Kaido
swift build -c release
```

The binaries land in `.build/release/` as `KaidoCLI` and `KaidoMCP`.

## 3. Schedule a project

```bash
kaido project create "Example project" --start 2026-11-02 --end 2026-11-20 --file demo.kaido

cat > wbs.json <<'EOF'
[
  {"title": "Payments", "kind": "group", "children": [
    {"title": "API design", "effortHours": 16},
    {"title": "Server implementation", "effortHours": 40},
    {"title": "Client integration", "effortHours": 24},
    {"title": "Joint acceptance", "kind": "milestone"}
  ]}
]
EOF

kaido wbs import wbs.json --file demo.kaido
kaido task list --file demo.kaido
```

Add the dependency chain (IDs accept a unique prefix of four or more characters, so you do
not have to copy UUIDs):

```bash
id() { kaido task list --file demo.kaido --json | python3 -c "import json,sys;print([t['id'][:4] for t in json.load(sys.stdin) if t['title']=='$1'][0])"; }

kaido task update "$(id 'Server implementation')" --dep "$(id 'API design'):fs" --file demo.kaido
kaido task update "$(id 'Client integration')" --dep "$(id 'Server implementation'):fs" --file demo.kaido
kaido task update "$(id 'Joint acceptance')" --dep "$(id 'Client integration'):fs" --file demo.kaido

kaido schedule compute --file demo.kaido     # dates
kaido schedule path --file demo.kaido        # critical path and slack
kaido violations --file demo.kaido           # cycles, out-of-range, deadline conflicts
```

Open the same file in the app (**File → Open**, or double-click the `.kaido`) and you see
the outline and the timeline aligned row by row.

> Since **v0.9.0** both the app and the CLI speak English and Simplified Chinese; see
> [Language](#4-language). The `.kaido` file, the flags and the MCP tool names are
> language-neutral either way.

## 4. Language

Both the app and the CLI speak English and Simplified Chinese.

**App** — follows the system language (System Settings → General → Language & Region) and is
resolved at launch: switch the language, then relaunch. Nothing to configure.

**CLI** — resolves its language in this order:

1. `--lang <bcp47>` (or `--lang=<bcp47>`)
2. the `KAIDO_LANG` environment variable
3. the system language
4. **Simplified Chinese**, when the system language cannot be determined — v0.9.0 deliberately
   keeps existing Chinese scripts working. If you match on output text, pin English explicitly.

| `--lang` value | Output |
|---|---|
| `en` | English |
| `zh-Hans` | Simplified Chinese |

```bash
kaido task list --file demo.kaido --lang en          # English (needs v0.9.0 or newer)
KAIDO_LANG=zh-Hans kaido violations --file demo.kaido # pinned via environment
kaido task list --file demo.kaido --lang en --json    # --json ignores the language
```

`--json` output never depends on the language: same bytes, same keys, same codes under either
setting. An unsupported `--lang` value is a usage error and exits **2**; success exits 0 and a
runtime failure exits 1.

> `--lang` and `KAIDO_LANG` exist from **v0.9.0**. On v0.8.5 the CLI is Chinese-only and
> rejects the flag as an unknown option.

## 5. Hand it to an agent

**Claude Code plugin** — slash commands plus automatic status write-back:

```bash
claude --plugin-dir /path/to/Kaido/Plugins/claude-code
```

Then `/kaido plan <requirement>`, `/kaido done <task-id>`, `/kaido status`.

**Codex / CodeBuddy / Claude Code over plain MCP** — a project-root `.mcp.json`:

```bash
cat > .mcp.json <<EOF
{ "mcpServers": { "kaido": { "command": "$(command -v kaido-mcp)" } } }
EOF
```

Then tell the agent, in `AGENTS.md` (or `CODEBUDDY.md` / `CLAUDE.md`): use Kaido's MCP tools
for planning, mark completion with `status_update`, and never edit the `.kaido` file directly.
The exact wording to copy lives in [Plugins/README.md](Plugins/README.md).

## 6. What just happened

- `demo.kaido` is the whole project: one JSON file, human-readable, diffable, safe to commit.
- The schedule is derived, not stored: change an effort or a dependency and `schedule_compute`
  recomputes dates; violations are reported rather than silently fixed.
- AI and human read and write the same file through different doors: MCP/CLI for the agent,
  the app for review.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| "Kaido can't be opened because Apple cannot check it" | not notarized yet | System Settings → Privacy & Security → Open Anyway |
| `kaido: command not found` | `/usr/local/bin` not on PATH | move the binaries somewhere on `PATH`, or export it |
| `task update: 用法错误` | ID prefix ambiguous | use more characters from `task list --json` |
| Schedule unchanged after editing | schedule is derived | run `kaido schedule compute` again |
