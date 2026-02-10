#!/usr/bin/env bash
set -euo pipefail

BUNDLE_ID="com.taisii.whisp.swift"
do_reset=1
open_settings=0

usage() {
  cat <<'USAGE'
usage: scripts/reset_permissions.sh [options]

options:
  --bundle-id ID    bundle identifier (default: com.taisii.whisp.swift)
  --skip-reset      skip TCC reset (open settings only)
  --open-settings   open privacy settings pages
  -h, --help        show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-id)
      shift
      if [[ $# -eq 0 ]]; then
        echo "missing value for --bundle-id" >&2
        exit 1
      fi
      BUNDLE_ID="$1"
      ;;
    --skip-reset)
      do_reset=0
      ;;
    --open-settings)
      open_settings=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

reset_one() {
  local service="$1"
  if tccutil reset "$service" "$BUNDLE_ID"; then
    echo "reset: $service ($BUNDLE_ID)"
  else
    echo "warn: failed to reset $service ($BUNDLE_ID)" >&2
  fi
}

if [[ "$do_reset" -eq 1 ]]; then
  reset_one Microphone
  reset_one SpeechRecognition
  reset_one Accessibility
  reset_one ScreenCapture
fi

if [[ "$open_settings" -eq 1 ]]; then
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
fi

echo "done: permissions ($BUNDLE_ID)"
