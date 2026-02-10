#!/usr/bin/env bash
set -euo pipefail

manual_jsonl="${1:-$HOME/.config/whisp/debug/manual_test_cases.jsonl}"
input_wav="${2:-Tests/Fixtures/benchmark_ja_10s.wav}"
result_root="${3:-/tmp/whisp-eval-loop-$(date +%Y%m%d-%H%M%S)}"
min_audio_seconds="${4:-2.0}"
context_file="${5:-}"

if [[ ! -f "$manual_jsonl" ]]; then
  echo "manual case jsonl not found: $manual_jsonl"
  exit 1
fi

if [[ ! -f "$input_wav" ]]; then
  echo "input wav not found: $input_wav"
  exit 1
fi

if ! [[ "$min_audio_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "min_audio_seconds must be numeric"
  exit 1
fi

mkdir -p "$result_root"
manual_root="$result_root/manual"
stt_root="$result_root/stt"
full_root="$result_root/full"

mkdir -p "$manual_root" "$stt_root" "$full_root"

echo "[1/4] manual-case benchmark"
scripts/benchmark_manual_cases.sh "$manual_jsonl" \
  --result-root "$manual_root" \
  --min-audio-seconds "$min_audio_seconds" \
  --intent-source auto \
  --intent-judge

echo "[2/4] stt latency benchmark"
scripts/benchmark_stt_latency.sh "$input_wav" 3 "$stt_root" | tee "$stt_root/summary.txt"

echo "[3/4] full pipeline benchmark"
if [[ -n "$context_file" ]]; then
  scripts/benchmark_full_pipeline.sh "$input_wav" 3 discard "$full_root" "$context_file" | tee "$full_root/summary.txt"
else
  scripts/benchmark_full_pipeline.sh "$input_wav" 3 discard "$full_root" | tee "$full_root/summary.txt"
fi

echo "[4/4] pipeline log analysis (if exists)"
dev_log="$HOME/.config/whisp/dev.log"
if [[ -f "$dev_log" ]]; then
  scripts/analyze_pipeline_log.sh "$dev_log" 20 > "$result_root/pipeline_analysis.txt"
else
  echo "dev.log not found, skipped" > "$result_root/pipeline_analysis.txt"
fi

{
  echo "result_root: $result_root"
  echo "manual_summary_json: $manual_root/manual_summary.json"
  echo "manual_rows_jsonl: $manual_root/manual_case_rows.jsonl"
  echo "stt_summary_text: $stt_root/summary.txt"
  echo "full_summary_text: $full_root/summary.txt"
  echo "pipeline_analysis_text: $result_root/pipeline_analysis.txt"
  echo ""
  echo "[manual key metrics]"
  grep -E '^(executed_cases|skipped_too_short_audio|failed_runs|exact_match_rate|weighted_cer|intent_match_rate|avg_total_after_stop_ms):' "$manual_root/summary.txt" || true
  echo ""
  echo "[stt key metrics]"
  grep -E '^(post_stop_latency_rest_ms|post_stop_latency_stream_ms|post_stop_delta_ms|post_stop_ratio)' "$stt_root/summary.txt" || true
  echo ""
  echo "[full key metrics]"
  grep -E '^(avg_total_after_stop_ms|dominant_stage_after_stop|stream_vs_rest_after_stop_delta_ms|stream_vs_rest_after_stop_ratio):' "$full_root/summary.txt" || true
} > "$result_root/overview.txt"

echo "completed: $result_root"
echo "overview: $result_root/overview.txt"
