#!/usr/bin/env bash
set -euo pipefail

input_path="${1:-$HOME/.config/whisp/debug/runs}"
runs="${2:-10}"

if ! [[ "$runs" =~ ^[0-9]+$ ]] || [[ "$runs" -lt 1 ]]; then
  echo "runs must be positive integer"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required"
  exit 1
fi

collect_event_files() {
  local path="$1"
  local limit="$2"

  if [[ -f "$path" ]]; then
    echo "$path"
    return
  fi

  if [[ ! -d "$path" ]]; then
    echo "path not found: $path" >&2
    exit 1
  fi

  while IFS= read -r -d '' file; do
    printf "%s\t%s\n" "$(stat -f '%m' "$file")" "$file"
  done < <(find "$path" -type f -name "events.jsonl" -print0) \
    | sort -rn \
    | cut -f2- \
    | head -n "$limit"
}

mapfile -t event_files < <(collect_event_files "$input_path" "$runs")

if [[ "${#event_files[@]}" -eq 0 ]]; then
  echo "no events.jsonl found"
  exit 2
fi

echo "analyzed_runs=${#event_files[@]} (latest $runs)"
echo "run recording_ms pipeline_ms stt_ms context_ms post_ms direct_ms other_ms dominant_stage stt_source status"

total_recording=0
total_pipeline=0
total_end_to_end=0
total_stt=0
total_context=0
total_post=0
total_direct=0
total_other=0
completed=0

dominant_stt=0
dominant_context=0
dominant_post=0
dominant_direct=0
dominant_other=0

for file in "${event_files[@]}"; do
  [[ -s "$file" ]] || continue

  row="$(jq -sr '
    def duration($type):
      (first(.[] | select(.stage == $type) | (.ended_at_ms - .started_at_ms)) // 0);
    def context_duration:
      (first(.[] | select(.stage == "context_summary") | (.ended_at_ms - .started_at_ms))
       // first(.[] | select(.stage == "vision") | (.ended_at_ms - .started_at_ms))
       // 0);

    [
      (first(.[] | .run_id) // "unknown"),
      duration("recording"),
      duration("pipeline"),
      duration("stt"),
      context_duration,
      duration("postprocess"),
      duration("direct_input"),
      (first(.[] | select(.stage == "stt") | .attrs.source) // "n/a"),
      (first(.[] | select(.stage == "pipeline") | .status) // "unknown")
    ] | @tsv
  ' "$file")"

  IFS=$'\t' read -r run recording pipeline stt context post direct source status <<< "$row"

  if [[ "$pipeline" -le 0 && "$recording" -le 0 ]]; then
    continue
  fi

  other=$((pipeline - stt - context - post - direct))
  if [[ "$other" -lt 0 ]]; then
    other=0
  fi

  dominant="stt"
  dominant_value="$stt"
  if [[ "$context" -gt "$dominant_value" ]]; then dominant="context"; dominant_value="$context"; fi
  if [[ "$post" -gt "$dominant_value" ]]; then dominant="post"; dominant_value="$post"; fi
  if [[ "$direct" -gt "$dominant_value" ]]; then dominant="direct"; dominant_value="$direct"; fi
  if [[ "$other" -gt "$dominant_value" ]]; then dominant="other"; dominant_value="$other"; fi

  printf "%s %.1f %.1f %.1f %.1f %.1f %.1f %.1f %s %s %s\n" \
    "$run" "$recording" "$pipeline" "$stt" "$context" "$post" "$direct" "$other" "$dominant" "$source" "$status"

  total_recording=$((total_recording + recording))
  total_pipeline=$((total_pipeline + pipeline))
  total_end_to_end=$((total_end_to_end + pipeline + recording))
  total_stt=$((total_stt + stt))
  total_context=$((total_context + context))
  total_post=$((total_post + post))
  total_direct=$((total_direct + direct))
  total_other=$((total_other + other))
  completed=$((completed + 1))

  case "$dominant" in
    stt) dominant_stt=$((dominant_stt + 1)) ;;
    context) dominant_context=$((dominant_context + 1)) ;;
    post) dominant_post=$((dominant_post + 1)) ;;
    direct) dominant_direct=$((dominant_direct + 1)) ;;
    other) dominant_other=$((dominant_other + 1)) ;;
  esac

done

if [[ "$completed" -eq 0 ]]; then
  echo "no analyzable runs found"
  exit 3
fi

avg_recording="$(awk -v t="$total_recording" -v c="$completed" 'BEGIN { printf "%.1f", t / c }')"
avg_pipeline="$(awk -v t="$total_pipeline" -v c="$completed" 'BEGIN { printf "%.1f", t / c }')"
avg_end_to_end="$(awk -v t="$total_end_to_end" -v c="$completed" 'BEGIN { printf "%.1f", t / c }')"
avg_stt="$(awk -v t="$total_stt" -v c="$completed" 'BEGIN { printf "%.1f", t / c }')"
avg_context="$(awk -v t="$total_context" -v c="$completed" 'BEGIN { printf "%.1f", t / c }')"
avg_post="$(awk -v t="$total_post" -v c="$completed" 'BEGIN { printf "%.1f", t / c }')"
avg_direct="$(awk -v t="$total_direct" -v c="$completed" 'BEGIN { printf "%.1f", t / c }')"
avg_other="$(awk -v t="$total_other" -v c="$completed" 'BEGIN { printf "%.1f", t / c }')"

echo ""
echo "avg_recording_ms=$avg_recording"
echo "avg_pipeline_ms=$avg_pipeline"
echo "avg_end_to_end_ms=$avg_end_to_end"
echo "avg_stt_ms=$avg_stt"
echo "avg_context_ms=$avg_context"
echo "avg_post_ms=$avg_post"
echo "avg_direct_ms=$avg_direct"
echo "avg_other_ms=$avg_other"

dominant_average="stt"
dominant_average_value="$avg_stt"
if awk -v a="$avg_context" -v b="$dominant_average_value" 'BEGIN { exit !(a > b) }'; then dominant_average="context"; dominant_average_value="$avg_context"; fi
if awk -v a="$avg_post" -v b="$dominant_average_value" 'BEGIN { exit !(a > b) }'; then dominant_average="post"; dominant_average_value="$avg_post"; fi
if awk -v a="$avg_direct" -v b="$dominant_average_value" 'BEGIN { exit !(a > b) }'; then dominant_average="direct"; dominant_average_value="$avg_direct"; fi
if awk -v a="$avg_other" -v b="$dominant_average_value" 'BEGIN { exit !(a > b) }'; then dominant_average="other"; dominant_average_value="$avg_other"; fi

echo "dominant_stage_by_average=$dominant_average (${dominant_average_value}ms)"
echo "dominant_count stt=$dominant_stt post=$dominant_post context=$dominant_context direct=$dominant_direct other=$dominant_other"

echo ""
echo "suggestions:"
if [[ "$dominant_average" == "stt" ]]; then
  echo "- STT支配: 音声長の短縮やSTT設定を見直す"
elif [[ "$dominant_average" == "post" ]]; then
  echo "- Post-process支配: プロンプトとコンテキスト量を削減する"
elif [[ "$dominant_average" == "context" ]]; then
  echo "- 文脈取得支配: context_summary / vision を必要時のみに絞る"
elif [[ "$dominant_average" == "direct" ]]; then
  echo "- DirectInput支配: 入力先アプリ状態と権限を確認する"
else
  echo "- その他支配: pipeline内の待機区間（I/Oや同期）を調査する"
fi
