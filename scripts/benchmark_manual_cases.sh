#!/usr/bin/env bash
set -euo pipefail

jsonl_path="${1:-$HOME/.config/whisp/debug/manual_test_cases.jsonl}"
shift || true

echo "building..."
swift build >/dev/null

echo "running manual-case benchmark..."
./.build/debug/whisp --benchmark-manual-cases "$jsonl_path" "$@"
