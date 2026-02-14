#!/usr/bin/env bash
set -euo pipefail

echo "scripts/benchmark_cases.sh is deprecated."
echo "Benchmark execution moved to WhispApp GUI (ベンチマーク画面)."
echo "For read-only diagnostics, use:"
echo "  swift run whisp debug benchmark-status --format json"
echo "  swift run whisp debug benchmark-integrity --task stt --cases ~/.config/whisp/debug/manual_test_cases.jsonl --format json"
exit 1
