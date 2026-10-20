#!/usr/bin/env bash
# tools/test.sh —— swift test 进度包装：总用例数 + 实时完成数 + 进度条。
# 用法：tools/test.sh [swift test 参数...]；KAIRO_TEST_NO_SANDBOX=0 关闭本机默认 --disable-sandbox。
# 失败用例即时上屏；套件与汇总正常打印；退出码透传 swift test。
set -uo pipefail

HAS_FILTER=0
for a in "$@"; do
  case "$a" in --filter*|--skip*) HAS_FILTER=1 ;; esac
done

TOTAL=0
if [ "$HAS_FILTER" = 0 ]; then
  echo "==> 统计用例总数（swift test list）…"
  TOTAL="$(swift test list "$@" 2>/dev/null | grep -c . || true)"
fi
if [ "$TOTAL" -gt 0 ]; then
  echo "==> 共 $TOTAL 个用例，开始运行…"
else
  echo "==> 总数未知（过滤运行或 list 失败），按完成计数显示"
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
      line = sprintf("%s %d/%d 完成 · 失败 %d · 运行中 %d",
          bar(done, total), done, total, failed, started - done)
    } else {
      line = sprintf("已完成 %d · 失败 %d · 运行中 %d", done, failed, started - done)
    }
    if (color) printf "\r\033[%sm%-70s\033[0m", color, line
    else printf "\r%-70s", line
  }
  /◇ Test .* started/ { started++ }
  /✔ Test .* passed after/ && $0 !~ /Test run with/ { done++; report() }
  /✘ Test .* failed after/ && $0 !~ /Test run with/ {
    failed++; done++
    printf "\r\033[31m✘ 失败：%s\033[0m\n", $0
    report("31")
  }
  /✔ Suite .* passed after/ { printf "\r\033[32m%s\033[0m\n", $0 }
  /✘ Suite .* failed after/ { printf "\r\033[31m%s\033[0m\n", $0 }
  /Test run with/ { printf "\r\033[1m%s\033[0m\n\n", $0 }
  END { printf "\n" }
'

if [ "${KAIRO_TEST_NO_SANDBOX:-1}" = "1" ]; then
  swift test --disable-sandbox "$@" 2>&1 | awk -v total="$TOTAL" "$AWK_PROG"
else
  swift test "$@" 2>&1 | awk -v total="$TOTAL" "$AWK_PROG"
fi

STATUS="${PIPESTATUS[0]}"
echo "==> swift test 退出码：$STATUS"
exit "$STATUS"
