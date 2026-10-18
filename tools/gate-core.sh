#!/bin/bash
# 编译门禁：核心与呈现层不得依赖任何平台绑定框架（ADR-004 / ADR-013）。
# 扫描 KairoCore、KairoCommands、KairoPresentation；违规（AppKit/SwiftUI/Cocoa/Combine）时非零退出。
set -u

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIRS=(
    "$ROOT_DIR/Sources/KairoCore"
    "$ROOT_DIR/Sources/KairoCommands"
    "$ROOT_DIR/Sources/KairoPresentation"
)

FAILED=0
for DIR in "${DIRS[@]}"; do
    NAME="$(basename "$DIR")"
    if [[ ! -d "$DIR" ]]; then
        echo "gate-core: 未找到 $NAME 目录：$DIR" >&2
        exit 2
    fi
    VIOLATIONS=$(
        find -L "$DIR" -type f -name '*.swift' -print0 \
            | xargs -0 grep -nE '^\s*(@_exported\s+)?import\s+.*\b(AppKit|SwiftUI|Cocoa|Combine)\b' 2>/dev/null \
            || true
    )
    if [[ -n "$VIOLATIONS" ]]; then
        echo "gate-core: $NAME 存在平台绑定 import，违反 ADR-004 / ADR-013：" >&2
        echo "$VIOLATIONS" >&2
        FAILED=1
    fi
done

if [[ "$FAILED" -ne 0 ]]; then
    exit 1
fi

COUNT=0
for DIR in "${DIRS[@]}"; do
    COUNT=$((COUNT + $(find "$DIR" -name '*.swift' | wc -l | tr -d ' ')))
done
echo "gate-core: KairoCore/KairoCommands/KairoPresentation 无 AppKit/SwiftUI/Cocoa/Combine import，通过（$COUNT 个 Swift 文件）"
exit 0
