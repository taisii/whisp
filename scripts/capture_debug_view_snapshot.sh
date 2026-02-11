#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_PATH="${ROOT_DIR}/.codex-artifacts/debugview-real.png"
CAPTURE_ID=""
SOURCE_MODE="real"

usage() {
  cat <<'USAGE'
usage: scripts/capture_debug_view_snapshot.sh [options]

options:
  -o, --output PATH      output PNG path
  -c, --capture-id ID    specific capture id to render
  --sample               use synthetic sample data instead of real runs
  -h, --help             show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output)
      shift
      if [[ $# -eq 0 ]]; then
        echo "missing value for --output" >&2
        exit 1
      fi
      OUTPUT_PATH="$1"
      ;;
    -c|--capture-id)
      shift
      if [[ $# -eq 0 ]]; then
        echo "missing value for --capture-id" >&2
        exit 1
      fi
      CAPTURE_ID="$1"
      ;;
    --sample)
      SOURCE_MODE="sample"
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

mkdir -p "$(dirname "$OUTPUT_PATH")"

cd "$ROOT_DIR"
DEBUG_VIEW_SNAPSHOT_PATH="$OUTPUT_PATH" \
DEBUG_VIEW_SOURCE_MODE="$SOURCE_MODE" \
DEBUG_VIEW_CAPTURE_ID="$CAPTURE_ID" \
swift test --filter DebugViewSnapshotTests/testCaptureDebugViewSnapshot

echo "snapshot: $OUTPUT_PATH"
