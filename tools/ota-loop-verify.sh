#!/usr/bin/env bash
# tools/ota-loop-verify.sh -- OTA 自动闭环检测：无人值守连跑 N 轮真升级，每轮自己判定
# 成败并指出卡在哪一阶段。
#
# 为什么需要它：tools/ota-local-verify.sh 能把本地清单与包准备好，但最后三步要靠人点
# 面板按钮（检查 -> 下载 -> 退出并安装）。SwiftUI 面板的按钮不暴露给 Accessibility
# （buttons of sheet 为空、坐标点击打偏），UI 自动化这条路是死的。所以驱动端搬进应用：
# KAIRO_OTA_AUTOPILOT=1 让 DEBUG 构建自己按同一条内部序列走（OTAInstallSequence，
# 与面板按钮共用一份实现），本脚本只负责摆场地、掐时间、判结果。
#
# 每轮做什么：
#   1) 清 pending 五键 + ${TMPDIR} 与轮次目录下的 kairo-ota-* 残留
#   2) 把源 App 复制到本轮临时目录，版本改成 A（= 新版本 B 的 patch - 1）
#   3) 本地清单指向新包（版本 B），起 http 服务
#   4) 带 KAIRO_OTA_AUTOPILOT=1 启动，最多等 --timeout 秒
#   5) 判定四件事：版本 A->B、PID 换了、ota.log 有 sheet dismissed -> terminate ->
#      reply=terminateNow、脚本结果文件 success=true
#
# 安装目标永远是本轮临时副本，**绝不写 /Applications**（--app 只决定源，不决定目标）。
#
# 用法：
#   tools/ota-loop-verify.sh                   # 构建 DEBUG + 跑 3 轮
#   tools/ota-loop-verify.sh --rounds 5
#   tools/ota-loop-verify.sh --app /Applications/Kairo.app --no-build   # 测某份现成产物
#   tools/ota-loop-verify.sh --stop            # 停服务、杀本轮进程、清残留
#
# 退出码：0 = 全部 PASS；1 = 有 FAIL；2 = 参数/环境错误（没跑起来）。
#
# 维护提醒（踩过的坑，改这个脚本时别踩第二次）：
#   * 变量后面紧跟全角标点必须写成 ${VAR}——本机 bash 3.2 下 "$VA，" 会把变量名连同
#     全角字符的前半字节一起吃掉，日志里只剩半个汉字（排查了两轮才定位）。
#   * 路径一律取物理路径（pwd -P）：$TMPDIR 报 /var/folders/...，进程命令行报
#     /private/var/folders/...，字符串比较/残留清理全靠它对齐。
set -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}"; TMP_ROOT="${TMP_ROOT%/}"
# 物理路径：/var/folders/... 与进程/目录实际所在的 /private/var/folders/... 是同一个地方，
# 但字符串比较是另一回事——残留清理靠字符串比较排除工作区，不归一化就会把自己的工作区删掉。
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
WORK="${KAIRO_OTA_LOOP_DIR:-$TMP_ROOT/kairo-ota-loop}"
# $TMPDIR 是 /var/folders/... 而进程命令行里报的是 /private/var/folders/...：
# 统一取物理路径，否则 pgrep 一个都匹配不上（实测踩过）。
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd -P)"
PORT="${KAIRO_OTA_LOOP_PORT:-8137}"
LOG="$HOME/Library/Logs/Kairo/ota.log"
MANIFEST_URL="http://127.0.0.1:$PORT/update-manifest.json"

ROUNDS=3
SOURCE_APP=""
DO_BUILD=1
TIMEOUT=120
MODE=run

while [ $# -gt 0 ]; do
  case "$1" in
    --rounds) ROUNDS="${2:?--rounds 需要数字}"; shift 2 ;;
    --app) SOURCE_APP="${2:?--app 需要路径}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?--timeout 需要秒数}"; shift 2 ;;
    --no-build) DO_BUILD=0; shift ;;
    --stop) MODE=stop; shift ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

case "$ROUNDS" in ''|*[!0-9]*) echo "ERROR: --rounds 必须是正整数" >&2; exit 2 ;; esac
case "$TIMEOUT" in ''|*[!0-9]*) echo "ERROR: --timeout 必须是正整数" >&2; exit 2 ;; esac

say() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 2; }

# ---------------------------------------------------------------- 进程与清场

# 本脚本管的进程：路径落在 $WORK 下的 Kairo。别的 Kairo（比如 /Applications 里那个）
# 会让 open 把它当成「已在运行」而拒绝拉起新副本，判据就全乱——必须先退出。
app_pids() { pgrep -f "$1/Contents/MacOS/Kairo" 2>/dev/null || true; }

foreign_kairo_pids() {
  local pid cmd
  for pid in $(pgrep -f "Kairo.app/Contents/MacOS/Kairo" 2>/dev/null || true); do
    cmd=$(ps -o command= -p "$pid" 2>/dev/null) || continue
    case "$cmd" in "$WORK"/*) continue ;; esac
    echo "$pid"
  done
}

kill_round_apps() {
  local pid
  for pid in $(app_pids "$1"); do
    kill "$pid" 2>/dev/null || true
  done
  sleep 0.5
  for pid in $(app_pids "$1"); do
    kill -9 "$pid" 2>/dev/null || true
  done
}

# pending 五键：不清的话，上一轮的结果会盖住这一轮的现场（首启消费也读不到干净的初始态）。
clean_pending_keys() {
  local key
  for key in kairo_ota_pending_result_path kairo_ota_pending_backup_path \
             kairo_ota_pending_backup_dir kairo_ota_pending_script_path \
             kairo_ota_pending_extraction_path; do
    defaults delete app.kairo.macos "$key" >/dev/null 2>&1 || true
  done
}

# 只删形状匹配的 kairo-ota-*：$TMPDIR 下有别家的文件，绝不整目录清空。
# 自己的工作区（$WORK）同样跳过——它就长成 kairo-ota-loop 的样子。
clean_tmp_residue() {
  local dir path name
  for dir in "$@"; do
    [ -d "$dir" ] || continue
    for path in "$dir"/kairo-ota-*; do
      [ -e "$path" ] || continue
      [ "$path" = "$WORK" ] && continue
      name=$(basename "$path")
      case "$name" in
        kairo-ota-*) rm -rf -- "$path" ;;
      esac
    done
  done
}

# 停本地清单服务。只认「端口上确实在跑 http.server」的进程：pidfile 里的号可能
# 落在中间隔了一层的 shell 上（实测留下过一个孤儿 python 占着端口，下次跑直接卡住）。
stop_server() {
  local pids="" pid cmd
  if [ -f "$WORK/server.pid" ]; then
    pid=$(tr -dc '0-9' < "$WORK/server.pid")
    [ -n "$pid" ] && pids="$pid"
    rm -f "$WORK/server.pid"
  fi
  pids="$pids $(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | tr '\n' ' ')"
  for pid in $pids; do
    cmd=$(ps -o command= -p "$pid" 2>/dev/null) || continue
    case "$cmd" in *http.server*) kill "$pid" >/dev/null 2>&1 || true ;; esac
  done
  sleep 0.3
  for pid in $pids; do
    cmd=$(ps -o command= -p "$pid" 2>/dev/null) || continue
    case "$cmd" in *http.server*) kill -9 "$pid" >/dev/null 2>&1 || true ;; esac
  done
}

if [ "$MODE" = stop ]; then
  stop_server
  for pid in $(app_pids "$WORK"); do kill "$pid" 2>/dev/null || true; done
  clean_pending_keys
  clean_tmp_residue "$TMP_ROOT" "$WORK"/rounds/*/tmp
  say "已停服务、清 pending 键与 kairo-ota-* 残留"
  exit 0
fi

# ---------------------------------------------------------------- 场地

# 别的 Kairo（/Applications 里那个）不阻塞本轮：实测 open 对同 Bundle ID、不同路径的
# 副本会另起一个进程，不会激活别人。只提示一句，免得误判成「新进程起来了」。
foreign_pids=$(foreign_kairo_pids)
if [ -n "$foreign_pids" ]; then
  for pid in $foreign_pids; do
    warn "另有 Kairo 在跑 pid=${pid}（不影响本轮，判据只看本轮临时副本的 PID）"
  done
fi

if [ -n "$SOURCE_APP" ]; then
  [ -d "$SOURCE_APP" ] || die "--app 指向的 .app 不存在：$SOURCE_APP"
  SRC="$SOURCE_APP"
  DO_BUILD=0
  say "源 App（只读拷贝，绝不就地升级）：$SRC"
elif [ "$DO_BUILD" = 1 ]; then
  say "构建 DEBUG App（自动驾驶只在 debug 配置编译存在）"
  bash "$ROOT/tools/build.sh" -c debug -o "$WORK/dist" --skip-gate >/dev/null || die "构建失败"
  SRC="$WORK/dist/Kairo.app"
else
  SRC="$WORK/dist/Kairo.app"
  [ -d "$SRC" ] || die "--no-build 需要已有构建：$SRC"
fi

stop_server
mkdir -p "$WORK"
rm -rf "$WORK/base" "$WORK/rounds" "$WORK/payload" "$WORK/serve"
mkdir -p "$WORK/base" "$WORK/rounds"
cp -R "$SRC" "$WORK/base/Kairo.app" || die "拷贝源 App 失败"

plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }
plist_set() { /usr/libexec/PlistBuddy -c "Set :$2 $3" "$1/Contents/Info.plist" >/dev/null 2>&1; }
app_version() { plist_get "$1" CFBundleShortVersionString; }

VB=$(app_version "$WORK/base/Kairo.app")
[ -n "$VB" ] || die "读不到源 App 版本号"
IFS=. read -r v_major v_minor v_patch <<< "$VB"
[ -n "$v_patch" ] && [ "$v_patch" -gt 0 ] 2>/dev/null || die "版本号不是三段式或 patch 为 0：$VB"
VA="$v_major.$v_minor.$((v_patch - 1))"
say "版本对：被测 App 先降到 A=${VA}，清单给 B=$VB"

# ---------------------------------------------------------------- 临时密钥对与签名清单

keys=$(swift -e "import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
print(\"PRIVATE=\" + key.rawRepresentation.base64EncodedString())
print(\"PUBLIC=\" + key.publicKey.rawRepresentation.base64EncodedString())") || die "生成临时密钥对失败"
PRIV=$(printf "%s" "$keys" | sed -n 's/^PRIVATE=//p')
PUB=$(printf "%s" "$keys" | sed -n 's/^PUBLIC=//p')
[ -n "$PRIV" ] && [ -n "$PUB" ] || die "解析临时密钥对失败"

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  die "端口 $PORT 已被占用（换一个：KAIRO_OTA_LOOP_PORT=xxxx）"
fi

mkdir -p "$WORK/payload" "$WORK/serve"
cp -R "$WORK/base/Kairo.app" "$WORK/payload/Kairo.app" || die "拷贝 payload 失败"
plist_set "$WORK/payload/Kairo.app" CFBundleShortVersionString "$VB"
codesign --force --deep --sign - "$WORK/payload/Kairo.app" >/dev/null 2>&1 \
  || die "payload 重签失败（需要 Xcode 命令行工具）"

ZIP="$WORK/serve/Kairo-ota-loop.zip"
ditto -c -k --sequesterRsrc --keepParent "$WORK/payload/Kairo.app" "$ZIP" || die "打 zip 失败"
ZIP_SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
ZIP_CDHASH=$(bash "$ROOT/tools/extract_cdhash.sh" "$WORK/payload/Kairo.app") || die "取 cdHash 失败"

UPDATE_SIGNING_KEY_BASE64="$PRIV" \
MF_VERSION="$VB" \
MF_MINIMUM_VERSION=1.0.0 \
MF_BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
MF_DOWNLOAD_URL="http://127.0.0.1:$PORT/$(basename "$ZIP")" \
MF_CDHASH="$ZIP_CDHASH" \
MF_SHA256="$ZIP_SHA" \
MF_NOTES="ota loop verification build" \
swift "$ROOT/tools/ota_local_sign_manifest.swift" > "$WORK/serve/update-manifest.json" || die "签名清单失败"

swift "$ROOT/tools/verify_update_manifest.swift" "$WORK/serve/update-manifest.json" "$PUB" >/dev/null \
  || die "清单自检失败（App 侧也不会认）"

# exec 让 pidfile 记的就是 python 本体（中间隔一层 shell 会留下杀不掉的孤儿）；
# disown 免得收尾时把这行 "Terminated" 作业通知混进判据输出。
( cd "$WORK/serve" && exec nohup python3 -m http.server "$PORT" --bind 127.0.0.1 ) \
  >"$WORK/server.log" 2>&1 &
echo $! > "$WORK/server.pid"
disown 2>/dev/null || true

ready=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if curl -fsS "$MANIFEST_URL" >/dev/null 2>&1; then ready=1; break; fi
  sleep 0.3
done
[ "$ready" = 1 ] || die "本地清单服务未就绪（看 $WORK/server.log）"
# 任何退出路径都收服务：留在后台的 http.server 会让下一次跑死在「端口被占用」。
trap 'stop_server' EXIT
say "清单服务就绪 ${MANIFEST_URL}（cdhash=${ZIP_CDHASH}）"

# ---------------------------------------------------------------- 单轮执行

# 结果文件精准抓取：路径在武装时刻由 App 写进状态文件。晚一步就没了——重启后的
# App 首启会消费并删掉它，所以这里按 0.1s 一拍盯着，出现即拷贝。
watch_result() {
  local state="$1" dest="$2" limit="$3" waited=0 rp=""
  while [ "$waited" -lt "$((limit * 10))" ]; do
    if [ -z "$rp" ] && [ -s "$state" ]; then
      rp=$(sed -n 's/^armed .*result_path=//p' "$state" 2>/dev/null | tail -1)
    fi
    if [ -n "$rp" ] && [ -f "$rp" ]; then
      if cp -- "$rp" "$dest" 2>/dev/null; then return 0; fi
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  return 1
}

launch_round_app() {
  local app="$1" tmp="$2" state="$3" cwd="$4"
  (
    cd "$cwd" || exit 1
    # 注意：不覆盖 TMPDIR——macOS 上 FileManager.default.temporaryDirectory 取的是
    # 用户级 temp 目录（confstr），不吃 $TMPDIR，覆盖了只会让人误以为产物落在轮次目录。
    # 残留靠形状守卫（kairo-ota-*）清理，不靠 TMPDIR 隔离。
    KAIRO_OTA_MANIFEST_URL="$MANIFEST_URL" \
    KAIRO_OTA_ALLOWED_HOSTS=127.0.0.1 \
    KAIRO_OTA_PUBKEY_BASE64="$PUB" \
    KAIRO_OTA_APP_PATH="$app" \
    KAIRO_OTA_ALLOW_HTTP=1 \
    KAIRO_OTA_AUTOPILOT=1 \
    KAIRO_OTA_AUTOPILOT_STATE="$state" \
    nohup "$app/Contents/MacOS/Kairo" >"$cwd/app-stdout.log" 2>&1 &
    echo $!
  )
}

# 关键序列必须按次序出现（顺序颠倒就是 #17 复发）。
in_order() {
  local slice="$1"; shift
  local marker rest
  rest=$(cat "$slice")
  for marker in "$@"; do
    printf "%s" "$rest" | grep -q -- "$marker" || return 1
    rest=$(printf "%s" "$rest" | sed -n "/$marker/,\$p" | tail -n +2)
  done
  return 0
}

result_success() { [ -f "$1" ] && grep -q '"success":true' "$1"; }
result_reason() { sed -n 's/.*"message":"\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -1; }

# 失败阶段归因：从日志切片与落盘事实倒推「卡在哪一步」。顺序即优先级。
failure_stage() {
  local slice="$1" app="$2" pid_old="$3" pid_new="$4" result="$5"
  has() { grep -q -- "$1" "$slice"; }
  has "autopilot step=check" || { echo check; return; }
  has "autopilot step=check error=" && { echo check; return; }
  has "autopilot finished" && { echo check; return; }
  has "autopilot step=download" || { echo download; return; }
  has "autopilot step=download error=" && { echo download; return; }
  has "autopilot step=install" || { echo download; return; }
  has "preflight failed=" && { echo preflight; return; }
  has "install armed" || { echo armed; return; }
  has "sheet dismissed" || { echo terminate; return; }
  has "NSApp.terminate called" || { echo terminate; return; }
  has "reply=terminateNow" || { echo terminate; return; }
  if kill -0 "$pid_old" 2>/dev/null; then echo terminate; return; fi
  if [ -f "$result" ]; then
    case "$(result_reason "$result")" in
      app_not_quitting) echo terminate; return ;;
      backup_failed|replace_failed) echo replace; return ;;
    esac
  fi
  [ "$(app_version "$app")" = "$VB" ] || { echo replace; return; }
  [ -n "$pid_new" ] || { echo relaunch; return; }
  echo unknown
}

PASS_COUNT=0
FAIL_COUNT=0
SUMMARY=""

for n in $(seq 1 "$ROUNDS"); do
  dir="$WORK/rounds/$n"
  tmp="$dir/tmp"
  app="$tmp/Kairo.app"
  state="$dir/autopilot.state"
  result="$dir/install-result.json"
  rm -rf "$dir"; mkdir -p "$tmp"
  : > "$state"

  clean_pending_keys
  clean_tmp_residue "$TMP_ROOT" "$tmp"
  for pid in $(app_pids "$WORK"); do kill "$pid" 2>/dev/null || true; done

  cp -R "$WORK/base/Kairo.app" "$app" || die "第 $n 轮拷贝 App 失败"
  plist_set "$app" CFBundleShortVersionString "$VA"
  codesign --force --deep --sign - "$app" >/dev/null 2>&1 || die "第 $n 轮版本 A 重签失败"

  start_line=0
  [ -f "$LOG" ] && start_line=$(wc -l < "$LOG" | tr -d ' ')

  watch_result "$state" "$result" "$TIMEOUT" &
  watcher=$!

  round_start=$(date +%s)
  pid=$(launch_round_app "$app" "$tmp" "$state" "$dir")
  say "round $n 启动 pid=$pid 版本 A=$VA -> B=$VB"

  new_pid=""
  deadline=$((round_start + TIMEOUT))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if kill -0 "$pid" >/dev/null 2>&1; then sleep 0.3; continue; fi
    new_pid=$(app_pids "$app" | grep -v "^$pid$" | head -1 || true)
    [ -n "$new_pid" ] && break
    sleep 0.3
  done
  sleep 1
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  elapsed=$(( $(date +%s) - round_start ))

  slice="$dir/ota.log"
  : > "$slice"
  if [ -f "$LOG" ]; then
    tail -n +"$((start_line + 1))" "$LOG" > "$slice" 2>/dev/null || true
  fi
  cp -- "$state" "$dir/autopilot.state.snapshot" 2>/dev/null || true

  version_after=$(app_version "$app")
  terminate_ok=1
  in_order "$slice" "install requested" "preflight ok" "install armed" \
    "sheet dismissed" "NSApp.terminate called" "reply=terminateNow" || terminate_ok=0

  verdict=PASS
  detail=""
  [ "$version_after" = "$VB" ] || { verdict=FAIL; detail=" version=$version_after"; }
  [ -n "$new_pid" ] || { verdict=FAIL; detail="$detail pid=unchanged"; }
  [ "$terminate_ok" = 1 ] || { verdict=FAIL; detail="$detail terminate-sequence=incomplete"; }
  if ! result_success "$result"; then
    verdict=FAIL
    if [ -f "$result" ]; then detail="$detail result=$(result_reason "$result")"
    else detail="$detail result=missing"; fi
  fi

  if [ "$verdict" = PASS ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    printf '==> round %d PASS %s->%s %ss\n' "$n" "$VA" "$VB" "$elapsed"
    SUMMARY="${SUMMARY}round ${n} PASS ${VA}->${VB} ${elapsed}s"$'\n'
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    stage=$(failure_stage "$slice" "$app" "$pid" "$new_pid" "$result")
    tail -n 40 "$slice" > "$dir/failure-sample.txt" 2>/dev/null || true
    printf '==> round %d FAIL stage=%s %s->%s %ss (see %s)\n' \
      "$n" "$stage" "$VA" "$VB" "$elapsed" "$dir"
    [ -n "$detail" ] && echo "    信号：$detail"
    SUMMARY="${SUMMARY}round ${n} FAIL stage=${stage} ${VA}->${VB} ${elapsed}s (see ${dir})"$'\n'
  fi

  kill_round_apps "$app"
done

stop_server

echo
echo "==> 汇总（$ROUNDS 轮）"
printf "%s" "$SUMMARY"
echo
echo "PASS=$PASS_COUNT FAIL=$FAIL_COUNT  证据目录：$WORK/rounds"

[ "$FAIL_COUNT" -eq 0 ]
