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
summary_log="$result_root/summary.txt"

echo "building..."
swift build >/dev/null

echo "running ${label} benchmark..."
./.build/debug/whisp "$bench_flag" "$jsonl_path" "${extra_args[@]}" | tee "$summary_log"

manifest_path="$(awk -F': ' '/^benchmark_manifest: /{print $2}' "$summary_log" | tail -n 1 | tr -d '\r')"
if [[ -z "$manifest_path" || ! -f "$manifest_path" ]]; then
  echo "benchmark manifest not found in output. see: $summary_log"
  exit 1
fi

run_dir="$(dirname "$manifest_path")"
rows_src="$run_dir/cases_index.jsonl"
rows_dst="$result_root/$rows_name"
if [[ -f "$rows_src" ]]; then
  cp "$rows_src" "$rows_dst"
else
  : > "$rows_dst"
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to build $summary_name"
  exit 1
fi

summary_dst="$result_root/$summary_name"
jq '{
  runID: .id,
  kind: .kind,
  executedCases: (.metrics.executedCases // 0),
  skippedCases: (.metrics.skippedCases // 0),
  failedCases: (.metrics.failedCases // 0),
  cachedHits: (.metrics.cachedHits // 0),
  exactMatchRate: .metrics.exactMatchRate,
  avgCER: .metrics.avgCER,
  weightedCER: .metrics.weightedCER,
  avgTermsF1: .metrics.avgTermsF1,
  avgLatencyMs: .metrics.latencyMs.avg,
  avgAfterStopMs: .metrics.afterStopLatencyMs.avg,
  avgPostMs: .metrics.postLatencyMs.avg,
  manifestPath: .paths.manifestPath,
  casesIndexPath: .paths.casesIndexPath
}' "$manifest_path" > "$summary_dst"

echo "result_root: $result_root"
echo "summary_log: $summary_log"
echo "summary_json: $summary_dst"
echo "case_rows_log: $rows_dst"
