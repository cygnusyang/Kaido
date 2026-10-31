#!/usr/bin/env bash
# tools/build-mas.sh —— Mac App Store 变体的构建入口（独立产物目录 dist-mas/）。
#
# 与 tools/build.sh 的差别只有「商店不允许的那几件事」，实现复用同一个脚本：
#   - 自更新在编译期关闭（KaidoUpdater 会起子进程替换 /Applications 里的 .app，商店必拒）；
#   - 不产出 KaidoCLI / KaidoMCP 两个独立可执行文件（沙盒下外部 spawn 读不到用户文件，
#     MCP 改由 app 内 loopback HTTP 托管，CLI 走 app 的 --cli 瘦客户端模式）；
#   - 不做 ad-hoc 签名（随后由 tools/sign-mas.sh 用 Apple Distribution 重签）。
#
# 用法：
#   tools/build-mas.sh [--output dir] [--skip-gate]
#
# 产出：dist-mas/Kaido.app（未签名）。签名与出包：
#   tools/sign-mas.sh --app dist-mas/Kaido.app \
#     --entitlements Apps/macos/Resources/Kaido.entitlements \
#     --provisionprofile ~/kairo-signing/KaidoPlanMAS.provisionprofile \
#     --pkg-out dist-mas/Kaido.pkg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${DIST_DIR:-$ROOT/dist-mas}"
ARGS=(--mas)

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output)
      DIST_DIR="${2:?}"
      shift 2
      ;;
    --skip-gate)
      ARGS+=(--skip-gate)
      shift
      ;;
    -h|--help)
      sed -n '2,25p' "$0"
      exit 0
      ;;
    *)
      echo "未知参数: $1" >&2
      exit 2
      ;;
  esac
done

bash "$ROOT/tools/build.sh" --output "$DIST_DIR" "${ARGS[@]}"

APP="$DIST_DIR/Kaido.app"
if [[ ! -d "$APP" ]]; then
  echo "ERROR: 未产出 $APP" >&2
  exit 1
fi

# 判据（P2）：包内不得出现 CLI / MCP 可执行文件，也不得带自更新安装脚本。
LEAKS="$(find "$APP" -type f \( -name 'KaidoCLI' -o -name 'KaidoMCP' -o -name 'install.sh' \) -print)"
if [[ -n "$LEAKS" ]]; then
  echo "ERROR: 商店包内出现不应存在的可执行文件：" >&2
  echo "$LEAKS" >&2
  exit 1
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
if [[ "$BUNDLE_ID" != "top.cygnusyang.kaido" ]]; then
  echo "ERROR: bundle id 为 ${BUNDLE_ID}，与 App Store 记录的 top.cygnusyang.kaido 不一致" >&2
  exit 1
fi

# entitlements 必须是 AMFI 能解析的 XML：注释里出现 `--` 会被 codesign 拒
# （实测报错 "AMFIUnserializeXML: syntax error"），plutil -lint 不拦这一条。
ENTS="$ROOT/Apps/macos/Resources/Kaido.entitlements"
if [[ -f "$ENTS" ]] && command -v xmllint >/dev/null 2>&1; then
  if ! xmllint --noout "$ENTS" 2>/dev/null; then
    echo "ERROR: ${ENTS} 不是合法 XML（常见原因：注释里写了双连字符）" >&2
    xmllint --noout "$ENTS" >&2 || true
    exit 1
  fi
fi

echo "==> 商店变体就绪: $APP"
echo "    下一步：tools/sign-mas.sh（Apple Distribution + profile → .pkg）"
