#!/usr/bin/env bash
set -euo pipefail

log_file="${1:-$HOME/.config/whisp/dev.log}"
runs="${2:-10}"

if [[ ! -f "$log_file" ]]; then
  echo "log file not found: $log_file"
  exit 1
fi

if ! [[ "$runs" =~ ^[0-9]+$ ]] || [[ "$runs" -lt 1 ]]; then
  echo "runs must be positive integer"
  exit 1
fi

awk -v max_runs="$runs" '
function num(raw) {
  if (raw == "") {
    return 0
  }
  return raw + 0
}

BEGIN {
  dominantCount["stt"] = 0
  dominantCount["vision_wait"] = 0
  dominantCount["post"] = 0
  dominantCount["direct"] = 0
  dominantCount["other"] = 0
}

{
  if ($0 !~ /^\[dev\]/) {
    next
  }

  if (NF < 2) {
    next
  }
  event = $2

  delete fields
  for (i = 3; i <= NF; i++) {
    split($i, kv, "=")
    if (length(kv) >= 2) {
      key = kv[1]
      value = substr($i, length(key) + 2)
      fields[key] = value
    }
  }

  run = fields["run"]
  if (run == "") {
    next
  }

  if (!(run in seen)) {
    seen[run] = 1
    order[++runCount] = run
  }

  if (event == "recording_stop") {
    recordingMs[run] = num(fields["recording_ms"])
  } else if (event == "vision_done") {
    visionWaitMs[run] = num(fields["wait_ms"])
    visionTotalMs[run] = num(fields["total_ms"])
  } else if (event == "stt_done") {
    sttMs[run] = num(fields["duration_ms"])
    sttSource[run] = fields["source"]
  } else if (event == "stt_stream_finalize_done") {
    sttMs[run] = num(fields["duration_ms"])
    sttSource[run] = "stream_finalize"
  } else if (event == "postprocess_done") {
    postMs[run] = num(fields["duration_ms"])
  } else if (event == "direct_input_done") {
    directMs[run] = num(fields["duration_ms"])
  } else if (event == "pipeline_done") {
    pipelineMs[run] = num(fields["pipeline_ms"])
    endToEndMs[run] = num(fields["end_to_end_ms"])
  } else if (event == "pipeline_error") {
    hasError[run] = 1
  }
}

END {
  if (runCount == 0) {
    print "no run events found"
    exit 2
  }

  start = runCount - max_runs + 1
  if (start < 1) {
    start = 1
  }

  print "analyzed_runs=" (runCount - start + 1) " (latest " max_runs ")"
  print "run recording_ms pipeline_ms stt_ms vision_wait_ms post_ms direct_ms other_ms dominant_stage stt_source status"

  totalRecording = 0
  totalPipeline = 0
  totalEndToEnd = 0
  totalStt = 0
  totalVisionWait = 0
  totalPost = 0
  totalDirect = 0
  totalOther = 0
  completed = 0

  for (i = start; i <= runCount; i++) {
    run = order[i]
    if (pipelineMs[run] <= 0 && endToEndMs[run] <= 0) {
      continue
    }

    rec = recordingMs[run] + 0
    pipe = pipelineMs[run] + 0
    stt = sttMs[run] + 0
    visionWait = visionWaitMs[run] + 0
    post = postMs[run] + 0
    direct = directMs[run] + 0

    other = pipe - stt - visionWait - post - direct
    if (other < 0) {
      other = 0
    }

    dominant = "stt"
    dominantValue = stt
    if (visionWait > dominantValue) {
      dominant = "vision_wait"
      dominantValue = visionWait
    }
    if (post > dominantValue) {
      dominant = "post"
      dominantValue = post
    }
    if (direct > dominantValue) {
      dominant = "direct"
      dominantValue = direct
    }
    if (other > dominantValue) {
      dominant = "other"
      dominantValue = other
    }

    source = sttSource[run]
    if (source == "") {
      source = "n/a"
    }
    status = (hasError[run] ? "error" : "ok")

    printf "%s %.1f %.1f %.1f %.1f %.1f %.1f %.1f %s %s %s\n",
      run, rec, pipe, stt, visionWait, post, direct, other, dominant, source, status

    totalRecording += rec
    totalPipeline += pipe
    totalEndToEnd += endToEndMs[run]
    totalStt += stt
    totalVisionWait += visionWait
    totalPost += post
    totalDirect += direct
    totalOther += other
    completed++
    dominantCount[dominant]++
  }

  if (completed == 0) {
    print "no completed pipeline_done runs found"
    exit 3
  }

  avgRecording = totalRecording / completed
  avgPipeline = totalPipeline / completed
  avgEndToEnd = totalEndToEnd / completed
  avgStt = totalStt / completed
  avgVisionWait = totalVisionWait / completed
  avgPost = totalPost / completed
  avgDirect = totalDirect / completed
  avgOther = totalOther / completed

  print ""
  printf "avg_recording_ms=%.1f\n", avgRecording
  printf "avg_pipeline_ms=%.1f\n", avgPipeline
  printf "avg_end_to_end_ms=%.1f\n", avgEndToEnd
  printf "avg_stt_ms=%.1f\n", avgStt
  printf "avg_vision_wait_ms=%.1f\n", avgVisionWait
  printf "avg_post_ms=%.1f\n", avgPost
  printf "avg_direct_ms=%.1f\n", avgDirect
  printf "avg_other_ms=%.1f\n", avgOther

  dominantAverage = "stt"
  dominantAverageValue = avgStt
  if (avgVisionWait > dominantAverageValue) {
    dominantAverage = "vision_wait"
    dominantAverageValue = avgVisionWait
  }
  if (avgPost > dominantAverageValue) {
    dominantAverage = "post"
    dominantAverageValue = avgPost
  }
  if (avgDirect > dominantAverageValue) {
    dominantAverage = "direct"
    dominantAverageValue = avgDirect
  }
  if (avgOther > dominantAverageValue) {
    dominantAverage = "other"
    dominantAverageValue = avgOther
  }

  printf "dominant_stage_by_average=%s (%.1fms)\n", dominantAverage, dominantAverageValue
  printf "dominant_count stt=%d post=%d vision_wait=%d direct=%d other=%d\n",
    dominantCount["stt"],
    dominantCount["post"],
    dominantCount["vision_wait"],
    dominantCount["direct"],
    dominantCount["other"]

  print ""
  print "suggestions:"
  if (dominantAverage == "stt") {
    print "- STT支配: 無音区間トリム、入力長制限、モデル設定を見直す"
  } else if (dominantAverage == "post") {
    print "- Post-process支配: プロンプト短縮、コンテキスト量削減、軽量モデルへ切替"
  } else if (dominantAverage == "vision_wait") {
    print "- Vision待ち支配: 画像をさらに縮小、Visionタイムアウト短縮、必要時のみ有効化"
  } else if (dominantAverage == "direct") {
    print "- DirectInput支配: 入力方式見直し（paste優先）と送信イベント回数削減"
  } else {
    print "- other支配: 未計測区間をさらにログ分割して原因特定を進める"
  }
}
' "$log_file"
