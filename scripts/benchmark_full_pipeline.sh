#!/usr/bin/env bash
set -euo pipefail

input_wav="${1:-Tests/Fixtures/benchmark_ja_10s.wav}"
runs="${2:-3}"
emit_mode="${3:-discard}"
result_root="${4:-/tmp/whisp-fullbench-$(date +%Y%m%d-%H%M%S)}"
context_file="${5:-}"

if [[ ! -f "$input_wav" ]]; then
  echo "input file not found: $input_wav"
  exit 1
fi

if ! [[ "$runs" =~ ^[0-9]+$ ]] || [[ "$runs" -lt 1 ]]; then
  echo "runs must be positive integer"
  exit 1
fi

if [[ "$emit_mode" != "discard" && "$emit_mode" != "stdout" && "$emit_mode" != "pbcopy" ]]; then
  echo "emit mode must be discard|stdout|pbcopy"
  exit 1
fi

if [[ -n "$context_file" && ! -f "$context_file" ]]; then
  echo "context file not found: $context_file"
  exit 1
fi

mkdir -p "$result_root/logs"
mkdir -p "$result_root/traces"

avg_key() {
  local key="$1"
  shift
  awk -F': ' -v target="$key" '
    $1 == target {sum += $2; n += 1}
    END {if (n > 0) printf "%.1f", sum / n; else printf "n/a"}
  ' "$@"
}

median_key() {
  local key="$1"
  shift
  awk -F': ' -v target="$key" '$1 == target {print $2}' "$@" | sort -n | awk '
    {vals[++n] = $1}
    END {
      if (n == 0) { printf "n/a"; exit }
      if (n % 2 == 1) {
        printf "%.1f", vals[(n + 1) / 2]
      } else {
        printf "%.1f", (vals[n / 2] + vals[n / 2 + 1]) / 2
      }
    }
  '
}

stddev_key() {
  local key="$1"
  shift
  awk -F': ' -v target="$key" '
    $1 == target {vals[++n] = $2 + 0; sum += $2 + 0}
    END {
      if (n == 0) { printf "n/a"; exit }
      mean = sum / n
      sq = 0
      for (i = 1; i <= n; i++) {
        d = vals[i] - mean
        sq += d * d
      }
      printf "%.1f", sqrt(sq / n)
    }
  ' "$@"
}

dominant_stage() {
  local stt="$1"
  local post="$2"
  local output="$3"
  awk -v stt="$stt" -v post="$post" -v output="$output" '
    BEGIN {
      stage = "stt_after_stop"
      max = stt + 0
      if ((post + 0) > max) { stage = "post"; max = post + 0 }
      if ((output + 0) > max) { stage = "output"; max = output + 0 }
      print stage
    }
  '
}

echo "building..."
swift build >/dev/null

echo "running full pipeline benchmark (rest)..."
for i in $(seq 1 "$runs"); do
  trace_dir="$result_root/traces/rest-$i"
  mkdir -p "$trace_dir"
  if [[ -n "$context_file" ]]; then
    WHISP_PROMPT_TRACE_DIR="$trace_dir" ./.build/debug/whisp --pipeline-file "$input_wav" --stt rest --emit "$emit_mode" --context-file "$context_file" >"$result_root/logs/rest-$i.log"
  else
    WHISP_PROMPT_TRACE_DIR="$trace_dir" ./.build/debug/whisp --pipeline-file "$input_wav" --stt rest --emit "$emit_mode" >"$result_root/logs/rest-$i.log"
  fi
done

echo "running full pipeline benchmark (stream realtime)..."
for i in $(seq 1 "$runs"); do
  trace_dir="$result_root/traces/stream-$i"
  mkdir -p "$trace_dir"
  if [[ -n "$context_file" ]]; then
    WHISP_PROMPT_TRACE_DIR="$trace_dir" ./.build/debug/whisp --pipeline-file "$input_wav" --stt stream --chunk-ms 120 --realtime --emit "$emit_mode" --context-file "$context_file" >"$result_root/logs/stream-$i.log"
  else
    WHISP_PROMPT_TRACE_DIR="$trace_dir" ./.build/debug/whisp --pipeline-file "$input_wav" --stt stream --chunk-ms 120 --realtime --emit "$emit_mode" >"$result_root/logs/stream-$i.log"
  fi
done

rest_stt_after="$(avg_key stt_after_stop_ms "$result_root"/logs/rest-*.log)"
rest_post="$(avg_key post_ms "$result_root"/logs/rest-*.log)"
rest_output="$(avg_key output_ms "$result_root"/logs/rest-*.log)"
rest_after_total="$(avg_key total_after_stop_ms "$result_root"/logs/rest-*.log)"
rest_stt_after_med="$(median_key stt_after_stop_ms "$result_root"/logs/rest-*.log)"
rest_post_med="$(median_key post_ms "$result_root"/logs/rest-*.log)"
rest_output_med="$(median_key output_ms "$result_root"/logs/rest-*.log)"
rest_after_total_med="$(median_key total_after_stop_ms "$result_root"/logs/rest-*.log)"
rest_after_total_std="$(stddev_key total_after_stop_ms "$result_root"/logs/rest-*.log)"
rest_dominant="$(dominant_stage "$rest_stt_after_med" "$rest_post_med" "$rest_output_med")"

stream_stt_after="$(avg_key stt_after_stop_ms "$result_root"/logs/stream-*.log)"
stream_post="$(avg_key post_ms "$result_root"/logs/stream-*.log)"
stream_output="$(avg_key output_ms "$result_root"/logs/stream-*.log)"
stream_after_total="$(avg_key total_after_stop_ms "$result_root"/logs/stream-*.log)"
stream_stt_after_med="$(median_key stt_after_stop_ms "$result_root"/logs/stream-*.log)"
stream_post_med="$(median_key post_ms "$result_root"/logs/stream-*.log)"
stream_output_med="$(median_key output_ms "$result_root"/logs/stream-*.log)"
stream_after_total_med="$(median_key total_after_stop_ms "$result_root"/logs/stream-*.log)"
stream_after_total_std="$(stddev_key total_after_stop_ms "$result_root"/logs/stream-*.log)"
stream_dominant="$(dominant_stage "$stream_stt_after_med" "$stream_post_med" "$stream_output_med")"

after_delta="$(awk -v rest="$rest_after_total" -v stream="$stream_after_total" 'BEGIN{printf "%.1f", rest-stream}')"
after_ratio="$(awk -v rest="$rest_after_total" -v stream="$stream_after_total" 'BEGIN{if(rest>0) printf "%.3f", stream/rest; else print "n/a"}')"
audio_seconds="$(awk -F': ' '/^audio_seconds:/{print $2; exit}' "$result_root/logs/rest-1.log" 2>/dev/null || true)"

echo "==== full pipeline result ===="
echo "input_wav: $input_wav"
echo "runs: $runs"
echo "emit_mode: $emit_mode"
echo "result_root: $result_root"
echo "context_file: ${context_file:-none}"
echo "audio_seconds: ${audio_seconds:-n/a}"
echo ""
echo "[rest]"
echo "avg_stt_after_stop_ms: $rest_stt_after"
echo "avg_post_ms: $rest_post"
echo "avg_output_ms: $rest_output"
echo "avg_total_after_stop_ms: $rest_after_total"
echo "median_total_after_stop_ms: $rest_after_total_med"
echo "stddev_total_after_stop_ms: $rest_after_total_std"
echo "dominant_stage_after_stop: $rest_dominant"
echo ""
echo "[stream_realtime]"
echo "avg_stt_after_stop_ms: $stream_stt_after"
echo "avg_post_ms: $stream_post"
echo "avg_output_ms: $stream_output"
echo "avg_total_after_stop_ms: $stream_after_total"
echo "median_total_after_stop_ms: $stream_after_total_med"
echo "stddev_total_after_stop_ms: $stream_after_total_std"
echo "dominant_stage_after_stop: $stream_dominant"
echo ""
echo "stream_vs_rest_after_stop_delta_ms: $after_delta"
echo "stream_vs_rest_after_stop_ratio: $after_ratio"

echo ""
echo "suggestions:"
if [[ "$stream_dominant" == "stt_after_stop" ]]; then
  echo "- STT停止後が支配的: streaming finalize最適化、無音トリム、より軽量STT設定を優先"
elif [[ "$stream_dominant" == "post" ]]; then
  echo "- LLM整形が支配的: prompt短縮、context圧縮、軽量モデルを優先"
else
  echo "- 出力処理が支配的: 出力方式最適化（イベント回数削減、paste優先）を優先"
fi
