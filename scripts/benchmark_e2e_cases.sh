#!/usr/bin/env bash
set -euo pipefail

jsonl_path="$HOME/.config/whisp/debug/manual_test_cases.jsonl"
result_root="/tmp/whisp-e2ebench-$(date +%Y%m%d-%H%M%S)"

if [[ $# -gt 0 && "$1" != --* ]]; then
  jsonl_path="$1"
  shift
fi

extra_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --result-root)
      if [[ $# -lt 2 ]]; then
        echo "--result-root requires a value"
        exit 1
      fi
      result_root="$2"
      shift 2
      ;;
    *)
      extra_args+=("$1")
      shift
      ;;
  esac
done

mkdir -p "$result_root"

echo "building..."
swift build >/dev/null

echo "running e2e-case benchmark..."
./.build/debug/whisp --benchmark-e2e-cases "$jsonl_path" --benchmark-log-dir "$result_root" "${extra_args[@]}" | tee "$result_root/summary.txt"
echo "result_root: $result_root"
echo "summary_log: $result_root/manual_summary.json"
echo "case_rows_log: $result_root/manual_case_rows.jsonl"
