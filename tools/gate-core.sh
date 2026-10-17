#!/bin/bash
# 编译门禁：KairoCore 不得依赖任何平台绑定框架（ADR-004 / 架构文档 §5 边界规则）。
# 违规（import AppKit / SwiftUI / Cocoa）时非零退出。
set -u

CORE_DIR="$(cd "$(dirname "$0")/../Sources/KairoCore" && pwd)"

if [[ ! -d "$CORE_DIR" ]]; then
    echo "gate-core: 未找到 KairoCore 目录：$CORE_DIR" >&2
    exit 2
fi

VIOLATIONS=$(grep -rn --include='*.swift' -E '^\s*import\s+(AppKit|SwiftUI|Cocoa)\b' "$CORE_DIR" || true)

if [[ -n "$VIOLATIONS" ]]; then
    echo "gate-core: KairoCore 存在平台绑定 import，违反 ADR-004：" >&2
    echo "$VIOLATIONS" >&2
    exit 1
fi

echo "gate-core: KairoCore 无 AppKit/SwiftUI/Cocoa import，通过（$(find "$CORE_DIR" -name '*.swift' | wc -l | tr -d ' ') 个 Swift 文件）"
exit 0
