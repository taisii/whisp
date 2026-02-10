#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$ROOT_DIR/.build/Whisp.app"
BUNDLE_ID="com.taisii.whisp.swift"

do_build=1
do_reset=1
do_kill=1
do_launch=1
open_settings=0

usage() {
  cat <<'USAGE'
usage: scripts/rebuild_reset_launch.sh [options]

options:
  --skip-build      skip app build
  --skip-reset      skip TCC reset
  --skip-kill       skip killing existing app process
  --skip-launch     skip app launch
  --open-settings   open privacy settings pages after launch
  -h, --help        show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      do_build=0
      ;;
    --skip-reset)
      do_reset=0
      ;;
    --skip-kill)
      do_kill=0
      ;;
    --skip-launch)
      do_launch=0
      ;;
    --open-settings)
      open_settings=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

cd "$ROOT_DIR"

if [[ "$do_build" -eq 1 ]]; then
  scripts/build_macos_app.sh
fi

if [[ "$do_kill" -eq 1 ]]; then
  pkill -f "$APP_PATH" || true
fi

if [[ "$do_reset" -eq 1 ]]; then
  scripts/reset_permissions.sh --bundle-id "$BUNDLE_ID"
fi

if [[ "$do_launch" -eq 1 ]]; then
  open "$APP_PATH"
  sleep 2
  pgrep -fl "WhispApp|Whisp" | head || true
fi

if [[ "$open_settings" -eq 1 ]]; then
  scripts/reset_permissions.sh --bundle-id "$BUNDLE_ID" --skip-reset --open-settings
fi

echo "done: $APP_PATH"
