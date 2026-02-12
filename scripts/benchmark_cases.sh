#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <stt|generation|vision> [jsonl_path] [--result-root DIR] [extra args...]"
  exit 1
fi

kind="$1"
shift

case "$kind" in
  stt)
    bench_flag="--benchmark-stt-cases"
    default_prefix="whisp-sttbench-cases"
    summary_name="stt_summary.json"
    rows_name="stt_case_rows.jsonl"
    label="stt-case"
    ;;
  generation)
    bench_flag="--benchmark-generation-cases"
    default_prefix="whisp-generationbench"
    summary_name="generation_summary.json"
    rows_name="generation_case_rows.jsonl"
    label="generation-case"
    ;;
  vision)
    bench_flag="--benchmark-vision-cases"
    default_prefix="whisp-visionbench"
    summary_name="vision_summary.json"
    rows_name="vision_case_rows.jsonl"
    label="vision-case"
    ;;
  *)
    echo "unknown benchmark kind: $kind"
    exit 1
    ;;
esac

jsonl_path="$HOME/.config/whisp/debug/manual_test_cases.jsonl"
result_root="/tmp/${default_prefix}-$(date +%Y%m%d-%H%M%S)"

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

echo "running ${label} benchmark..."
./.build/debug/whisp "$bench_flag" "$jsonl_path" "${extra_args[@]}" | tee "$result_root/summary.txt"

echo "result_root: $result_root"
echo "summary_log: $result_root/$summary_name"
echo "case_rows_log: $result_root/$rows_name"
