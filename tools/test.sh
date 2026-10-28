#!/usr/bin/env bash
# tools/test.sh —— swift test 进度包装：总用例数 + 实时完成数 + 进度条 + 挂死看门狗。
#
# 用法：
#   tools/test.sh [swift test 参数...]   包装运行：进度条 + 看门狗，退出码透传
#   tools/test.sh --self-check           看门狗自检：假命令静默挂住，确认能抓栈并非零退出
#
# 环境变量：
#   KAIRO_TEST_NO_SANDBOX=0       关闭本机默认 --disable-sandbox（CI 口径 = 0）
#   KAIRO_TEST_STALL_TIMEOUT=120  连续多少秒日志无新增字节即判挂死（0 关闭看门狗）
#   KAIRO_TEST_STALL_POLL=5       采样间隔（秒）
#   KAIRO_TEST_LOG=<path>         指定日志文件（默认 /tmp/kairo-test-<时间戳>.log）
#   KAIRO_TEST_EVENT_STREAM=<path> 指定 Swift Testing 事件流文件（默认 /tmp/kairo-test-events-<时间戳>.jsonl）
#
# 为什么有看门狗：v1.3.0 / v1.3.1 的 CI「test · macOS」卡在测试步骤十余分钟且零输出，
# 日志要等作业结束才取得到，而作业结束恰恰是因为它挂死——挂死现场什么都没留下。
# 现在改成输出落盘 + 后台运行 + 连续无增长即 sample 抓栈，把现场留在
# /tmp/kairo-ci-hang-<时间戳>.txt，本轮作业自己失败并带出证据。
#
# 失败用例即时上屏；套件与汇总正常打印。
set -uo pipefail

SELF_CHECK=0
HAS_FILTER=0
HAS_EVENT_STREAM=0
ARGS=()
EVENT_ARGS=()
for a in "$@"; do
  if [ "${a}" = "--self-check" ]; then
    SELF_CHECK=1
    continue
  fi
  case "${a}" in
    --filter*|--skip*) HAS_FILTER=1 ;;
    --event-stream-output-path*) HAS_EVENT_STREAM=1 ;;
  esac
  ARGS+=("${a}")
done

is_uint() {
  case "${1}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}

if [ "${SELF_CHECK}" = 1 ]; then
  DEFAULT_STALL_TIMEOUT=8
  DEFAULT_STALL_POLL=2
else
  DEFAULT_STALL_TIMEOUT=120
  DEFAULT_STALL_POLL=5
fi
STALL_TIMEOUT="${KAIRO_TEST_STALL_TIMEOUT:-${DEFAULT_STALL_TIMEOUT}}"
STALL_POLL="${KAIRO_TEST_STALL_POLL:-${DEFAULT_STALL_POLL}}"
if ! is_uint "${STALL_TIMEOUT}" || ! is_uint "${STALL_POLL}" || [ "${STALL_POLL}" -lt 1 ]; then
  echo "tools/test.sh: KAIRO_TEST_STALL_TIMEOUT / KAIRO_TEST_STALL_POLL 必须是非负整数（收到 ${STALL_TIMEOUT} / ${STALL_POLL}）" >&2
  exit 2
fi

# 必须用绝对路径：PATH 上常有同名的第三方脚本（本机 python 版 sample 即直接报错退出）。
SAMPLE_BIN=""
for candidate in /usr/bin/sample /usr/bin/spindump; do
  if [ -x "${candidate}" ]; then SAMPLE_BIN="${candidate}"; break; fi
done
SAMPLE_TOP_SECS=5
SAMPLE_MAX_PIDS=4

if [ "${SELF_CHECK}" = 1 ]; then
  LOG="${KAIRO_TEST_LOG:-/tmp/kairo-test-selfcheck-$(date +%Y%m%d-%H%M%S)-$$.log}"
else
  LOG="${KAIRO_TEST_LOG:-/tmp/kairo-test-$(date +%Y%m%d-%H%M%S)-$$.log}"
fi
: > "${LOG}"

# Swift Testing 事件流（JSONL）：用例级 started/ended 的权威顺序。日志里的进度行会被并行输出
# 冲乱、也看不出「有没有用例还在跑」，挂死时靠它回答「卡在谁后面 / 是真在跑还是已经空转」。
# 版本 1 = 当前 Swift Testing 输出格式；只在非自检时启用（自检跑的是假命令）。
EVENT_LOG=""
if [ "${SELF_CHECK}" = 0 ] && [ "${HAS_EVENT_STREAM}" = 0 ]; then
  EVENT_LOG="${KAIRO_TEST_EVENT_STREAM:-/tmp/kairo-test-events-$(date +%Y%m%d-%H%M%S)-$$.jsonl}"
  if : > "${EVENT_LOG}" 2>/dev/null; then
    EVENT_ARGS+=(--event-stream-output-path "${EVENT_LOG}" --event-stream-version 1)
  else
    echo "==> 警告：事件流文件不可写（${EVENT_LOG}），本次挂死将缺少用例级归因" >&2
    EVENT_LOG=""
  fi
fi

TOTAL=0
if [ "${SELF_CHECK}" = 0 ]; then
  if [ "${HAS_FILTER}" = 0 ]; then
    echo "==> 统计用例总数（swift test list；首次会编译测试目标，静默数分钟属正常，不计入看门狗）…"
    TOTAL="$(swift test list "${ARGS[@]}" 2>/dev/null | grep -c . || true)"
  fi
  if [ "${TOTAL}" -gt 0 ]; then
    echo "==> 共 ${TOTAL} 个用例，运行中…"
  else
    echo "==> 总数未知（过滤运行或 list 失败），按完成计数显示"
  fi
else
  echo "==> 自检：用静默 200s 的假命令走同一条看门狗路径（判定阈值 ${STALL_TIMEOUT}s）"
fi
if [ "${STALL_TIMEOUT}" -gt 0 ]; then
  echo "==> 看门狗：连续 ${STALL_TIMEOUT}s 无输出即抓栈·日志 ${LOG}"
fi

AWK_PROG='
  function bar(d, t,   i, n, w, s) {
    w = 30
    n = (t > 0) ? int(d * w / t) : 0
    s = "["
    for (i = 0; i < w; i++) s = s (i < n ? "=" : (i == n ? ">" : " "))
    return s "]"
  }
  function report(color,   line) {
    if (total > 0) {
      line = sprintf("%s %d/%d 完成 · 失败 %d · 进行 %d",
          bar(done, total), done, total, failed, started - done)
    } else {
      line = sprintf("已完成 %d · 失败 %d · 进行 %d", done, failed, started - done)
    }
    if (color) printf "\r\033[%sm%-70s\033[0m", color, line
    else printf "\r%-70s", line
  }
  /Test .* started/ { started++ }
  /Test .* passed after/ && $0 !~ /Test run with/ { done++; report() }
  /Test .* failed after/ && $0 !~ /Test run with/ {
    failed++; done++
    printf "\r\033[31m✗ 失败：%s\033[0m\n", $0
    report("31")
  }
  /Suite .* passed after/ { printf "\r\033[32m%s\033[0m\n", $0 }
  /Suite .* failed after/ { printf "\r\033[31m%s\033[0m\n", $0 }
  /Test run with/ { printf "\r\033[1m%s\033[0m\n\n", $0 }
  END { printf "\n" }
'

# 递归收集进程树，后序输出（子进程在父进程之前）—— 杀进程和抓栈都要叶子优先：
# 真正卡住的是 swift-testing / XCTest 子进程，父 shell 的栈只是 wait4。
collect_tree() {
  local pid="$1" kid
  for kid in $(pgrep -P "${pid}" 2>/dev/null); do
    collect_tree "${kid}"
  done
  echo "${pid}"
}

# 事件流归因：最后 started / 最后 ended / 仍在进行中的用例。
# 看门狗只知道「没输出了」；要判断是某个用例把主线程吊住、还是所有用例都结束了进程却不退，
# 只能看 Swift Testing 的事件流——日志里的进度行会被并行输出冲乱，事件流是权威顺序。
summarize_event_stream() {
  echo "== 事件流归因 =="
  if [ -z "${EVENT_LOG}" ] || [ ! -s "${EVENT_LOG}" ]; then
    echo "（事件流为空或未启用：无法归因到用例）"
    return 0
  fi
  echo "文件：${EVENT_LOG}（$(wc -c < "${EVENT_LOG}" | tr -d ' ') 字节）"
  if ! command -v python3 >/dev/null 2>&1; then
    echo "（无 python3，退化为上面的日志末尾）"
    return 0
  fi
  python3 - "${EVENT_LOG}" <<'PY'
import json
import sys
from collections import Counter

path = sys.argv[1]
kinds = {}
started, ended = Counter(), Counter()
order_started, order_ended = [], []
last_ts = None
bad_lines = 0

with open(path, encoding="utf-8", errors="replace") as handle:
    for line in handle:
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            bad_lines += 1
            continue
        if record.get("kind") == "test":
            payload = record.get("payload", {})
            kinds[payload.get("id")] = payload.get("kind")
            continue
        payload = record.get("payload", {})
        kind = payload.get("kind")
        test_id = payload.get("testID")
        timestamp = payload.get("instant", {}).get("since1970")
        if timestamp is not None:
            last_ts = timestamp
        if kind == "testStarted" and test_id:
            started[test_id] += 1
            order_started.append(test_id)
        elif kind == "testEnded" and test_id:
            ended[test_id] += 1
            order_ended.append(test_id)


def label(test_id):
    kind = kinds.get(test_id, "?")
    if kind == "suite":
        return test_id + "  [suite]"
    return test_id.split("/", 1)[0] + " / " + test_id.split("/", 1)[-1].split("/")[0] + "  [test]"


def last_of(kind_needed, sequence):
    for test_id in reversed(sequence):
        if kinds.get(test_id) == kind_needed:
            return test_id
    return None


test_started = [t for t in order_started if kinds.get(t) != "suite"]
test_ended = [t for t in order_ended if kinds.get(t) != "suite"]
print("用例事件：started %d / ended %d（含套件共 started %d / ended %d）"
      % (len(test_started), len(test_ended), len(order_started), len(order_ended)))

in_flight = []
for test_id, count in started.items():
    remaining = count - ended.get(test_id, 0)
    if remaining > 0:
        in_flight.append((remaining, test_id))

last_started_test = last_of("function", order_started)
last_ended_test = last_of("function", order_ended)
print("最后 started 的用例：%s" % (label(last_started_test) if last_started_test else "（无）"))
print("最后 ended   的用例：%s" % (label(last_ended_test) if last_ended_test else "（无）"))

if in_flight:
    print("仍在进行中：%d 个 —— 挂死点在这些用例内部或其后继收尾" % len(in_flight))
    for remaining, test_id in in_flight[:8]:
        print("  · %s（未结束 %d 次）" % (label(test_id), remaining))
    if len(in_flight) > 8:
        print("  · …另有 %d 个" % (len(in_flight) - 8))
else:
    print("仍在进行中：0 个 —— 所有已开始的用例都已结束，挂死发生在用例之外（收尾 / 主线程空转）")

if bad_lines:
    print("（事件流有 %d 行无法解析：进程被杀时最后一行可能被截断）" % bad_lines)
PY
}

# 抓栈：$1 为看门狗观察的根 pid。报告路径写入全局 REPORT。
capture_stacks() {
  local root="$1" stamp report sample_file pid
  stamp="$(date +%Y%m%d-%H%M%S)"
  report="/tmp/kairo-ci-hang-${stamp}-$$.txt"
  REPORT="${report}"

  {
    echo "== 疑似挂死：连续 ${STALL_TIMEOUT}s 无输出 =="
    echo "时间  : $(date)"
    echo "根 pid: ${root}"
    echo "日志  : ${LOG}"
    echo
    echo "== 日志末尾 20 行（定位最后开始的用例）=="
    tail -20 "${LOG}" 2>/dev/null
    echo
    summarize_event_stream
    echo
    echo "== 进程树（pid ppid stat etime command）=="
    for pid in $(collect_tree "${root}"); do
      ps -o pid=,ppid=,stat=,etime=,command= -p "${pid}" 2>/dev/null | cut -c1-240
    done
  } > "${report}"

  if [ -z "${SAMPLE_BIN}" ]; then
    echo "== 未找到 /usr/bin/sample，跳过抓栈 ==" >> "${report}"
    echo "==> 警告：未找到 sample/spindump，无栈可抓，仅保留日志 ${LOG}" >&2
    return 0
  fi

  local count=0
  for pid in $(collect_tree "${root}"); do
    [ "${count}" -ge "${SAMPLE_MAX_PIDS}" ] && break
    count=$((count + 1))
    sample_file="${report}.pid${pid}.sample"
    # sample 自带采样窗口；进程已退出时失败无妨。
    "${SAMPLE_BIN}" "${pid}" "${SAMPLE_TOP_SECS}" -file "${sample_file}" >/dev/null 2>&1 || true
    if [ -s "${sample_file}" ]; then
      {
        echo
        echo "== sample pid ${pid}（调用栈前 160 行，含各线程）=="
        # 栈顶 40 行；Binary Images 段只是内存布局，先到先停，免得把前 40 行位子占掉。
        # 160 行而非 40：主线程的 CFRunLoopRun 只是「在等」，真正吊住它的线程往往在第 2 段之后。
        awk '/Call graph:/{show=1} show && /Binary Images:/{exit} show{print; n++} n>=160{exit}' "${sample_file}"
      } >> "${report}"
    fi
    rm -f "${sample_file}"
  done
}

kill_tree() {
  local root="$1" pid pids
  pids="$(collect_tree "${root}" | tr '\n' ' ')"
  # 先 TERM 整棵树（叶子优先），再补 KILL：根先死的话子进程被 init 收养还会攥着 .build 锁。
  for pid in ${pids}; do kill -TERM "${pid}" 2>/dev/null || true; done
  sleep 1
  for pid in ${pids}; do kill -KILL "${pid}" 2>/dev/null || true; done
}

start_suite() {
  if [ "${SELF_CHECK}" = 1 ]; then
    # 演示：先写一行再彻底静默，模拟「跑着跑着不出声」。
    bash -c 'echo "自检假命令：已输出一行，随后 sleep 200"; sleep 200' > "${LOG}" 2>&1 &
  elif [ "${KAIRO_TEST_NO_SANDBOX:-1}" = "1" ]; then
    swift test --disable-sandbox "${EVENT_ARGS[@]}" "${ARGS[@]}" > "${LOG}" 2>&1 &
  else
    swift test "${EVENT_ARGS[@]}" "${ARGS[@]}" > "${LOG}" 2>&1 &
  fi
  SUITE_PID=$!
}

DISPLAY_PID=""
REPORT=""
start_suite

if [ "${SELF_CHECK}" = 0 ]; then
  # 进度条从日志文件跟随：swift test 自己直接落盘，所以 $! 就是真进程 pid，
  # 抓栈与杀进程都打在它身上；显示侧只是旁观者。tail 是后台命令，$! 即 tail 的 pid。
  tail -n +1 -F "${LOG}" 2>/dev/null > >(awk -v total="${TOTAL}" "${AWK_PROG}") &
  DISPLAY_PID=$!
fi

WATCHDOG_STATUS=0
if [ "${STALL_TIMEOUT}" -gt 0 ]; then
  LAST_SIZE=-1
  IDLE_SINCE=${SECONDS}
  while kill -0 "${SUITE_PID}" 2>/dev/null; do
    sleep "${STALL_POLL}"
    kill -0 "${SUITE_PID}" 2>/dev/null || break
    NOW_SIZE="$(wc -c < "${LOG}" 2>/dev/null | tr -d ' ' || echo 0)"
    if [ "${NOW_SIZE:-0}" != "${LAST_SIZE}" ]; then
      LAST_SIZE="${NOW_SIZE}"
      IDLE_SINCE=${SECONDS}
      continue
    fi
    if [ $((SECONDS - IDLE_SINCE)) -ge "${STALL_TIMEOUT}" ]; then
      echo >&2
      echo "==> 看门狗：连续 $((SECONDS - IDLE_SINCE))s 无输出，判定挂死，开始抓栈…" >&2
      capture_stacks "${SUITE_PID}"
      echo "==> 现场报告：${REPORT}" >&2
      echo "==> ---- 报告 ----" >&2
      cat "${REPORT}" >&2
      echo "==> ---- 报告结束 ----" >&2
      kill_tree "${SUITE_PID}"
      WATCHDOG_STATUS=124
      break
    fi
  done
fi

wait "${SUITE_PID}" 2>/dev/null
STATUS=$?
if [ "${WATCHDOG_STATUS}" -ne 0 ]; then
  STATUS="${WATCHDOG_STATUS}"
fi

if [ -n "${DISPLAY_PID}" ]; then
  kill "${DISPLAY_PID}" 2>/dev/null || true
  wait "${DISPLAY_PID}" 2>/dev/null || true
  # 给 awk 一拍把末尾的汇总行刷出来。
  sleep 0.3
fi

if [ "${SELF_CHECK}" = 1 ]; then
  FAILURES=""
  [ "${STATUS}" -eq 124 ] || FAILURES="${FAILURES}看门狗未以 124 退出（实得 ${STATUS}）；"
  [ -s "${REPORT}" ] || FAILURES="${FAILURES}未生成现场报告；"
  if [ -n "${REPORT}" ] && ! grep -q 'Call graph:' "${REPORT}" 2>/dev/null; then
    FAILURES="${FAILURES}报告里没有 sample 调用栈；"
  fi
  grep -q '自检假命令' "${LOG}" 2>/dev/null || FAILURES="${FAILURES}日志缺假命令输出；"
  if kill -0 "${SUITE_PID}" 2>/dev/null; then
    FAILURES="${FAILURES}挂死进程未被清理（pid ${SUITE_PID} 仍存活）；"
  fi
  echo "==> 自检日志：${LOG}"
  echo "==> 自检报告：${REPORT:-（无）}"
  if [ -n "${FAILURES}" ]; then
    echo "==> 看门狗自检失败：${FAILURES}" >&2
    exit 1
  fi
  echo "==> 看门狗自检通过：静默 ${STALL_TIMEOUT}s 后被判定挂死、抓到调用栈、进程已清理、退出码 124"
  exit 0
fi

if [ "${STATUS}" -ne 0 ]; then
  echo "==> swift test 退出码：${STATUS}（完整日志 ${LOG}）" >&2
else
  echo "==> swift test 退出码：0（日志 ${LOG}）"
fi
exit "${STATUS}"
