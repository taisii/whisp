#!/usr/bin/env bash
set -euo pipefail

manual_jsonl="${1:-$HOME/.config/whisp/debug/manual_test_cases.jsonl}"
result_root="${2:-/tmp/whisp-component-eval-$(date +%Y%m%d-%H%M%S)}"
min_audio_seconds="${3:-2.0}"

if [[ ! -f "$manual_jsonl" ]]; then
  echo "manual case jsonl not found: $manual_jsonl"
  exit 1
fi

if ! [[ "$min_audio_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "min_audio_seconds must be numeric"
  exit 1
fi

mkdir -p "$result_root"

vision_root="$result_root/1_vision"
stt_root="$result_root/2_stt"
generation_root="$result_root/3_generation"
mkdir -p "$vision_root" "$stt_root" "$generation_root"

echo "[1/3] vision benchmark"
scripts/benchmark_vision_cases.sh "$manual_jsonl" --result-root "$vision_root"

echo "[2/3] stt benchmark"
scripts/benchmark_stt_cases.sh "$manual_jsonl" --result-root "$stt_root" --min-audio-seconds "$min_audio_seconds"

echo "[3/3] generation benchmark"
scripts/benchmark_generation_cases.sh "$manual_jsonl" --result-root "$generation_root"

{
  echo "result_root: $result_root"
  echo "vision_summary: $vision_root/vision_summary.json"
  echo "stt_summary: $stt_root/stt_summary.json"
  echo "generation_summary: $generation_root/generation_summary.json"
  echo ""
  echo "[vision]"
  jq -r '"executed_cases=\(.executedCases) avg_summary_cer=\(.avgCER // "n/a") avg_terms_f1=\(.avgTermsF1 // "n/a") avg_latency_ms=\(.avgLatencyMs // "n/a") cached_hits=\(.cachedHits)"' "$vision_root/vision_summary.json"
  echo "[stt]"
  jq -r '"executed_cases=\(.executedCases) exact_match_rate=\(.exactMatchRate // "n/a") weighted_cer=\(.weightedCER // "n/a") avg_total_ms=\(.avgLatencyMs // "n/a") avg_after_stop_ms=\(.avgAfterStopMs // "n/a") cached_hits=\(.cachedHits)"' "$stt_root/stt_summary.json"
  echo "[generation]"
  jq -r '"executed_cases=\(.executedCases) exact_match_rate=\(.exactMatchRate // "n/a") weighted_cer=\(.weightedCER // "n/a") avg_post_ms=\(.avgLatencyMs // "n/a") cached_hits=\(.cachedHits)"' "$generation_root/generation_summary.json"
} > "$result_root/overview.txt"

echo "completed: $result_root"
echo "overview: $result_root/overview.txt"
