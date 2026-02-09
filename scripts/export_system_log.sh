#!/usr/bin/env bash
set -euo pipefail

minutes="${1:-15}"
output_path="${2:-/tmp/whisp-system.log}"
subsystem="${3:-com.taisii.whisp}"

if ! [[ "$minutes" =~ ^[0-9]+$ ]] || [[ "$minutes" -lt 1 ]]; then
  echo "minutes must be a positive integer"
  exit 1
fi

dir="$(dirname "$output_path")"
mkdir -p "$dir"

predicate="subsystem == \"$subsystem\""
log show --style compact --info --debug --last "${minutes}m" --predicate "$predicate" >"$output_path"

echo "exported: $output_path"
echo "minutes: $minutes"
echo "subsystem: $subsystem"
