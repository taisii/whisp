#!/usr/bin/env bash
set -euo pipefail

out_path="${1:-Tests/Fixtures/benchmark_ja_10s.wav}"
tmp_aiff="/tmp/whisp-benchmark-raw.aiff"

mkdir -p "$(dirname "$out_path")"

say -o "$tmp_aiff" "今日は会議の要点を三つに整理します。第一に今週の開発課題、第二にリリース判定、第三に来週の実験計画です。"
afconvert -f WAVE -d LEI16@16000 -c 1 "$tmp_aiff" "$out_path"

echo "created: $out_path"
ls -lh "$out_path"
shasum -a 256 "$out_path"
