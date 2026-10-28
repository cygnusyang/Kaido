#!/usr/bin/env bash
# tools/ota-local-verify.sh -- 本地 OTA 全链路验证脚手架（issue #17 的复发防线）。
#
# 为什么需要它：真实 OTA 只有在「线上有新版本」时才能触发，出问题时现场只剩一个
# 替换脚本写的 app_not_quitting，链路上每个判断都无从复核。本脚本用本地构建的包 +
# 本地清单 + 本地丢弃密钥对，把检查 -> 下载 -> 验签 -> 武装 -> terminate -> 替换 ->
# relaunch 整条路在同一台机器上跑一遍，并把每一步写进 ~/Library/Logs/Kairo/ota.log。
#
# 关键前提（务必先读懂）：
#   * 环境变量覆盖只在 DEBUG 构建里编译存在，所以这里构建的是 debug 配置；
#   * 安装目标是临时副本（KAIRO_OTA_APP_PATH），不会覆盖 /Applications/Kairo.app；
#   * 签名用脚本现生成的丢弃密钥，App 经 KAIRO_OTA_PUBKEY_BASE64 信任它的公钥，
#     生产私钥（GitHub secret UPDATE_SIGNING_KEY_BASE64）不参与；
#   * 必须没有任何旧 Kairo 进程在跑 —— OTA 由旧 build 执行会重演 #17。
#
# 用法：
#   tools/ota-local-verify.sh              # 清场 + 构建 + 起服务 + 启动 App
#   tools/ota-local-verify.sh --no-build   # 复用上次构建（改代码后要重新构建）
#   tools/ota-local-verify.sh --no-launch  # 只准备（构建/签名/起服务），自己启动 App
#   tools/ota-local-verify.sh --check      # 校验 ota.log 的关键序列
#   tools/ota-local-verify.sh --stop       # 停本地服务并清场
#
# 判据（--check 自动核对，顺序不可颠倒）：
#   install requested -> preflight ok -> install armed -> NSApp.terminate called
#   -> termination reply ... armed=true ... reply=terminateNow
set -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT=$TMPDIR
if [ -z "$TMP_ROOT" ]; then TMP_ROOT=/tmp; fi
TMP_ROOT=${TMP_ROOT%/}
WORK=$KAIRO_OTA_VERIFY_DIR
if [ -z "$WORK" ]; then WORK="$TMP_ROOT/kairo-ota-verify"; fi
PORT=$KAIRO_OTA_VERIFY_PORT
if [ -z "$PORT" ]; then PORT=8123; fi
LOG="$HOME/Library/Logs/Kairo/ota.log"
APP="$WORK/Kairo.app"
PAYLOAD="$WORK/payload/Kairo.app"
SERVE="$WORK/serve"
PIDFILE="$WORK/server.pid"

MODE=full
DO_BUILD=1
DO_LAUNCH=1
while [ $# -gt 0 ]; do
  case "$1" in
    --no-build) DO_BUILD=0; shift ;;
    --no-launch) DO_LAUNCH=0; shift ;;
    --check) MODE=check; shift ;;
    --stop) MODE=stop; shift ;;
    -h|--help) sed -n "2,30p" "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

say() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

stop_server() {
  if [ -f "$PIDFILE" ]; then
    local pid
    pid=$(cat "$PIDFILE")
    if [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid" >/dev/null 2>&1 || true
      say "已停本地清单服务 pid=$pid"
    fi
    rm -f "$PIDFILE"
  fi
}

# 清掉 app 侧遗留状态：pending 五键 + 上次的临时产物。
# 只删形状匹配的 kairo-ota-* 条目，绝不整目录清空（$TMPDIR 下有别家的文件）。
clean_state() {
  local key
  for key in kairo_ota_pending_result_path kairo_ota_pending_backup_path kairo_ota_pending_backup_dir kairo_ota_pending_script_path kairo_ota_pending_extraction_path; do
    defaults delete app.kairo.macos "$key" >/dev/null 2>&1 || true
  done
  local path name
  for path in "$TMP_ROOT"/kairo-ota-*; do
    [ -e "$path" ] || continue
    # 自己的构建工作区不动（--no-build 复跑要靠它）
    if [ "$path" = "$WORK" ]; then continue; fi
    name=$(basename "$path")
    case "$name" in
      kairo-ota-*) rm -rf -- "$path" ;;
    esac
  done
  say "已清 pending 键与 $TMP_ROOT 下的 kairo-ota-* 残留"
}

# 旧进程是 #17 复发的头号原因：OTA 由「装了新版之前的那个 build」执行时，
# 新代码里的武装旁路根本不存在。
warn_stale_process() {
  local pids
  pids=$(pgrep -f "/Applications/Kairo.app/Contents/MacOS/Kairo" | tr "\n" " ")
  if [ -n "$pids" ]; then
    warn "stale Kairo still running, pid: $pids"
    warn "请先手动退出它：OTA 由旧 build 执行时跑的是旧逻辑，验证结论无效。"
  fi
}

build_app() {
  say "构建 DEBUG App（环境变量覆盖只在 debug 配置存在）"
  bash "$ROOT/tools/build.sh" -c debug -o "$WORK/dist" --skip-gate || die "构建失败"
  rm -rf "$APP"
  mkdir -p "$WORK"
  cp -R "$WORK/dist/Kairo.app" "$APP" || die "拷贝 App 失败"
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || die "adhoc 重签失败（需要 Xcode 命令行工具）"
}

gen_keys() {
  local out
  out=$(swift -e "import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
print(\"PRIVATE=\" + key.rawRepresentation.base64EncodedString())
print(\"PUBLIC=\" + key.publicKey.rawRepresentation.base64EncodedString())") || die "生成临时密钥对失败（需要 swift + CryptoKit）"
  PRIV=$(printf "%s" "$out" | sed -n "s/^PRIVATE=//p")
  PUB=$(printf "%s" "$out" | sed -n "s/^PUBLIC=//p")
  if [ -z "$PRIV" ] || [ -z "$PUB" ]; then die "解析临时密钥对失败"; fi
}

# 清单里的版本必须严格高于当前包版本，否则 check() 会判 upToDate。
next_version() {
  local current major minor patch
  current=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist") || die "读不到当前版本号"
  current=$(printf "%s" "$current" | cut -d- -f1)
  IFS=. read -r major minor patch <<< "$current"
  if [ -z "$patch" ]; then die "版本号不是三段式: $current"; fi
  printf "%s.%s.%s" "$major" "$minor" "$((patch + 1))"
}

prepare_payload() {
  local version="$1"
  rm -rf "$WORK/payload"
  mkdir -p "$WORK/payload"
  cp -R "$APP" "$PAYLOAD" || die "拷贝 payload 失败"
  # payload 也换成新版本号，否则装完的 App 仍报旧版本，下次验证会判 upToDate。
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$PAYLOAD/Contents/Info.plist" || die "改写 payload 版本号失败"
  codesign --force --deep --sign - "$PAYLOAD" >/dev/null 2>&1 || die "payload 重签失败"
}

sign_and_serve() {
  local version="$1"
  local zip="$SERVE/Kairo-ota-local.zip"
  local sha cdhash i
  rm -rf "$SERVE"
  mkdir -p "$SERVE"
  ditto -c -k --sequesterRsrc --keepParent "$PAYLOAD" "$zip" || die "打 zip 失败"
  sha=$(shasum -a 256 "$zip" | awk '{print $1}')
  cdhash=$(bash "$ROOT/tools/extract_cdhash.sh" "$PAYLOAD") || die "取 cdHash 失败"
  UPDATE_SIGNING_KEY_BASE64="$PRIV" \
  MF_VERSION="$version" \
  MF_MINIMUM_VERSION=1.0.0 \
  MF_BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  MF_DOWNLOAD_URL="http://127.0.0.1:$PORT/Kairo-ota-local.zip" \
  MF_CDHASH="$cdhash" \
  MF_SHA256="$sha" \
  MF_NOTES="local verification build" \
  swift "$ROOT/tools/ota_local_sign_manifest.swift" > "$SERVE/update-manifest.json" || die "签名清单失败"

  printf "%s" "$PUB" > "$WORK/dev-pubkey.txt"
  # 自检：用仓库自带的验签工具复核，签出来的清单必须立刻能被验过，
  # 否则 App 侧 ManifestVerifier 也不会认（canonical 契约是双侧字节级一致）。
  if ! swift "$ROOT/tools/verify_update_manifest.swift" "$SERVE/update-manifest.json" "$PUB"; then
    die "清单自检失败：tools/verify_update_manifest.swift 不认这份清单"
  fi
  say "清单已就绪 version=$version cdhash=$cdhash 验签通过（dev-pubkey.txt 已存）"
  cd "$SERVE" || die "进不去 $SERVE"
  nohup python3 -m http.server "$PORT" --bind 127.0.0.1 >"$WORK/server.log" 2>&1 &
  echo $! > "$PIDFILE"
  cd "$ROOT" || die "回不到仓库根目录"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsS "http://127.0.0.1:$PORT/update-manifest.json" >/dev/null 2>&1; then
      say "本地清单服务已起 http://127.0.0.1:$PORT/update-manifest.json"
      return 0
    fi
    sleep 0.3
  done
  die "本地清单服务未就绪（看 $WORK/server.log）"
}

launch_app() {
  say "启动被测 App（DEBUG）"
  # 子 shell 里 cd 到工作区再启动：App 的 cwd 若是仓库根，它自动落盘的 .kairo
  # 会直接掉在仓库里（实测过一次）。
  (
    cd "$WORK" || exit 1
    KAIRO_OTA_MANIFEST_URL="http://127.0.0.1:$PORT/update-manifest.json" \
    KAIRO_OTA_ALLOWED_HOSTS=127.0.0.1 \
    KAIRO_OTA_PUBKEY_BASE64="$PUB" \
    KAIRO_OTA_APP_PATH="$APP" \
    KAIRO_OTA_ALLOW_HTTP=1 \
    nohup "$APP/Contents/MacOS/Kairo" >"$WORK/app-stdout.log" 2>&1 &
  )
  sleep 1
  cat <<STEPS

请在已启动的 Kairo 里操作：
  1) 菜单栏 Kairo -> 检查更新…（或 ⌘K 输入「检查更新」）
  2) 面板出现新版本 -> Download Update
  3) 下载并验签通过 -> Quit and Install
  App 应在 0.5s 内自行退出并 relaunch；替换脚本最多等 60s。

观察：
  tail -f $LOG
  bash tools/ota-local-verify.sh --check        # 自动核对关键序列
  bash tools/ota-local-verify.sh --stop         # 停服务并清场
STEPS
}

# 顺序核对：marker 必须按给定次序出现在最近一次 install 之后。
expect_in_order() {
  local rest="$1"
  shift
  local marker
  for marker in "$@"; do
    if ! printf "%s" "$rest" | grep -q -- "$marker"; then
      echo "FAIL: 缺少或顺序不对 -> $marker" >&2
      return 1
    fi
    rest=$(printf "%s" "$rest" | sed -n "/$marker/,\$p" | tail -n +2)
  done
  return 0
}

check_log() {
  if [ ! -f "$LOG" ]; then die "没有 ota.log（App 还没走过 OTA 路径，先跑一次完整流程）：" "$LOG"; fi
  local start rest
  start=$(grep -n "install requested" "$LOG" | tail -1 | cut -d: -f1)
  if [ -z "$start" ]; then die "日志里没有 install requested（还没点过 Quit and Install）"; fi
  rest=$(tail -n +"$start" "$LOG")
  expect_in_order "$rest" "install requested" "preflight ok" "install armed" "NSApp.terminate called" "reply=terminateNow" || exit 1
  say "PASS: 武装 -> terminate -> terminateNow 序列完整"
  printf "%s" "$rest" | sed -n "1,12p"
}

if [ "$MODE" = check ]; then
  check_log
  exit 0
fi

if [ "$MODE" = stop ]; then
  stop_server
  clean_state
  say "已清理（App 若还在跑请手动退出）"
  exit 0
fi

warn_stale_process
stop_server
clean_state
mkdir -p "$WORK"

if [ "$DO_BUILD" = 1 ]; then
  build_app
else
  if [ ! -d "$APP" ]; then die "--no-build 需要已有构建：$APP"; fi
  say "复用已有构建：$APP"
fi

gen_keys
VERSION=$(next_version)
say "当前版本 -> 清单版本 $VERSION"
prepare_payload "$VERSION"
sign_and_serve "$VERSION"

if [ "$DO_LAUNCH" = 1 ]; then
  launch_app
else
  cat <<STEPS

已就绪，手动启动 App（必须带这些环境变量，否则走生产端点）：
  KAIRO_OTA_MANIFEST_URL=http://127.0.0.1:$PORT/update-manifest.json \\
  KAIRO_OTA_ALLOWED_HOSTS=127.0.0.1 \\
  KAIRO_OTA_PUBKEY_BASE64=$PUB \\
  KAIRO_OTA_APP_PATH=$APP \\
  KAIRO_OTA_ALLOW_HTTP=1 \\
  "$APP/Contents/MacOS/Kairo"
STEPS
fi
