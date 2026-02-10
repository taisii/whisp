#!/usr/bin/env bash
set -euo pipefail

default_input="Tests/Fixtures/benchmark_ja_10s.wav"
input_wav="${1:-$default_input}"
runs="${2:-3}"
result_root="${3:-/tmp/whisp-sttbench-$(date +%Y%m%d-%H%M%S)}"

if [[ ! -f "$input_wav" ]]; then
  echo "input file not found: $input_wav"
  if [[ "$input_wav" == "$default_input" ]]; then
    echo "hint: create sample fixture first"
  fi
  exit 1
fi

if ! [[ "$runs" =~ ^[0-9]+$ ]] || [[ "$runs" -lt 1 ]]; then
  echo "runs must be positive integer"
  exit 1
fi

mkdir -p "$result_root/logs"

echo "building..."
swift build >/dev/null

echo "running rest benchmark..."
for i in $(seq 1 "$runs"); do
  ./.build/debug/whisp --stt-file "$input_wav" >"$result_root/logs/rest-$i.log"
done

echo "running streaming benchmark (realtime)..."
for i in $(seq 1 "$runs"); do
  ./.build/debug/whisp --stt-stream-file "$input_wav" --chunk-ms 120 --realtime >"$result_root/logs/stream-$i.log"
done

rest_avg_total="$(awk -F': ' '/^total_ms:/{sum+=$2; n++} END{if(n>0) printf "%.1f", sum/n; else printf "n/a"}' "$result_root"/logs/rest-*.log)"
stream_avg_total="$(awk -F': ' '/^total_ms:/{sum+=$2; n++} END{if(n>0) printf "%.1f", sum/n; else printf "n/a"}' "$result_root"/logs/stream-*.log)"
stream_avg_finalize="$(awk -F': ' '/^finalize_ms:/{sum+=$2; n++} END{if(n>0) printf "%.1f", sum/n; else printf "n/a"}' "$result_root"/logs/stream-*.log)"
stream_avg_send="$(awk -F': ' '/^send_ms:/{sum+=$2; n++} END{if(n>0) printf "%.1f", sum/n; else printf "n/a"}' "$result_root"/logs/stream-*.log)"
audio_seconds="$(awk -F': ' '/^audio_seconds:/{print $2; exit}' "$result_root/logs/rest-1.log" 2>/dev/null || true)"
rest_after_stop_ms="$rest_avg_total"
stream_after_stop_ms="$stream_avg_finalize"
after_stop_delta_ms="$(awk -v rest="$rest_after_stop_ms" -v stream="$stream_after_stop_ms" 'BEGIN{printf "%.1f", rest-stream}')"
after_stop_ratio="$(awk -v rest="$rest_after_stop_ms" -v stream="$stream_after_stop_ms" 'BEGIN{if(rest>0) printf "%.3f", stream/rest; else print "n/a"}')"

echo "==== result ===="
echo "input_wav: $input_wav"
echo "runs: $runs"
echo "result_root: $result_root"
echo "audio_seconds: ${audio_seconds:-n/a}"
echo "rest_avg_total_ms: $rest_avg_total"
echo "stream_realtime_avg_total_ms: $stream_avg_total"
echo "stream_realtime_avg_send_ms: $stream_avg_send"
echo "stream_realtime_avg_finalize_ms: $stream_avg_finalize"
echo "post_stop_latency_rest_ms: $rest_after_stop_ms"
echo "post_stop_latency_stream_ms: $stream_after_stop_ms"
echo "post_stop_delta_ms(rest-stream): $after_stop_delta_ms"
echo "post_stop_ratio(stream/rest): $after_stop_ratio"
echo "rest_transcript_sample: $(awk -F': ' '/^transcript:/{print $2; exit}' "$result_root/logs/rest-1.log")"
echo "stream_transcript_sample: $(awk -F': ' '/^transcript:/{print $2; exit}' "$result_root/logs/stream-1.log")"
