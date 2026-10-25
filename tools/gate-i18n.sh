#!/usr/bin/env bash
# tools/gate-i18n.sh —— 多语言发布门禁（docs/features/06-localization.md §11 判据 1 / §13）。
#
# ci.yml 与 release.yml 共用本脚本：发版前的门禁口径必须与合入前完全一致，
# 两处各自内联一份脚本迟早会漂移（改了一边忘了另一边，发版就多跑或少跑一项）。
#
# 判据：视图层零未登记中文 + 两侧键完整 + 占位符一致 + 白名单必须为空。
# 白名单在开发期是迁移基线，发版时它必须消失，因此这里固定 --fail-if-whitelist-nonempty。
#
# 前提：macOS + Xcode 命令行工具（xcstringstool）。Linux 不参与（App target 不构建）。
#
# 用法: tools/gate-i18n.sh
# 退出码: 0 通过；1 门禁未通过；2 环境缺失（Catalog / xcstringstool 不可用）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CATALOG="Apps/macos/Resources/Localizable.xcstrings"
if [[ ! -f "$CATALOG" ]]; then
  echo "ERROR: 缺少 ${CATALOG} —— 键完整性无法校验。F-0705（视图接入 Catalog）未合入前本步骤保持红色，这是门禁的预期行为，不要加跳过开关。" >&2
  exit 1
fi

# 与 i18n-compile.sh 同一判定方式：xcstringstool 不在 PATH 上，要经 xcrun 找。
if ! xcrun --find xcstringstool >/dev/null 2>&1; then
  echo "ERROR: 未找到 xcstringstool（需要 Xcode 命令行工具）；本门禁只在 macOS 上跑" >&2
  exit 2
fi

# 临时目录由本脚本独占：i18n-compile.sh 会重建输出目录，不受上一次构建残留影响。
WORK="$(mktemp -d "${TMPDIR:-/tmp}/kairo-i18n-gate.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

bash tools/i18n-compile.sh "$WORK/lproj"
bash tools/i18n-lint.sh --require-catalog --fail-if-whitelist-nonempty --lproj-dir "$WORK/lproj"
