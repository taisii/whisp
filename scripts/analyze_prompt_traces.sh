#!/usr/bin/env bash
set -euo pipefail

result_root="${1:-}"

if [[ -z "$result_root" ]]; then
  echo "usage: $0 /path/to/fullbench-result-root"
  exit 1
fi

if [[ ! -d "$result_root/traces" ]]; then
  echo "traces directory not found: $result_root/traces"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required"
  exit 1
fi

echo "result_root: $result_root"
echo "mode run stage model prompt_chars context_summary_chars context_terms_count context_accessibility_chars prompt_file"

for mode in rest stream; do
  for run_dir in "$result_root"/traces/"$mode"-*; do
    [[ -d "$run_dir" ]] || continue
    run_name="$(basename "$run_dir")"
    meta_file="$(ls "$run_dir"/*.meta.json 2>/dev/null | head -n 1 || true)"
    if [[ -z "$meta_file" ]]; then
      continue
    fi

    stage="$(jq -r '.stage' "$meta_file")"
    model="$(jq -r '.model' "$meta_file")"
    prompt_chars="$(jq -r '.promptChars' "$meta_file")"
    summary_chars="$(jq -r '(.context.visionSummary // "") | length' "$meta_file")"
    terms_count="$(jq -r '(.context.visionTerms // []) | length' "$meta_file")"
    accessibility_chars="$(jq -r '(.context.accessibilityText // "") | length' "$meta_file")"
    prompt_file="$(jq -r '.promptFile' "$meta_file")"

    echo "$mode $run_name $stage $model $prompt_chars $summary_chars $terms_count $accessibility_chars $prompt_file"
  done
done

rest_prompt="$(ls "$result_root"/traces/rest-1/*.prompt.txt 2>/dev/null | head -n 1 || true)"
stream_prompt="$(ls "$result_root"/traces/stream-1/*.prompt.txt 2>/dev/null | head -n 1 || true)"

if [[ -n "$rest_prompt" && -n "$stream_prompt" ]]; then
  echo ""
  echo "diff: rest-1 vs stream-1 prompt"
  diff -u "$rest_prompt" "$stream_prompt" || true
fi
