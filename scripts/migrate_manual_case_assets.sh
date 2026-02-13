#!/usr/bin/env bash
set -euo pipefail

MANUAL_CASES_FILE="${1:-$HOME/.config/whisp/debug/manual_test_cases.jsonl}"

if [[ ! -f "$MANUAL_CASES_FILE" ]]; then
  echo "manual_test_cases.jsonl が見つかりません: $MANUAL_CASES_FILE" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq が必要です" >&2
  exit 1
fi

DEBUG_DIR="$(cd "$(dirname "$MANUAL_CASES_FILE")" && pwd)"
ASSETS_DIR="$DEBUG_DIR/manual_case_assets"
mkdir -p "$ASSETS_DIR"

TMP_FILE="$(mktemp "$DEBUG_DIR/manual_test_cases.migrate.XXXXXX.jsonl")"
BACKUP_FILE="$MANUAL_CASES_FILE.bak.$(date +%Y%m%d-%H%M%S)"

total=0
kept=0
dropped=0

copy_asset() {
  local src="$1"
  local dest="$2"
  cp -f "$src" "$dest"
}

asset_ext() {
  local path="$1"
  local ext="${path##*.}"
  ext="$(echo "$ext" | tr '[:upper:]' '[:lower:]')"
  if [[ "$ext" == "$path" || -z "$ext" ]]; then
    echo ""
  else
    echo "$ext"
  fi
}

vision_mime_from_ext() {
  local ext="$1"
  case "$ext" in
    png) echo "image/png" ;;
    webp) echo "image/webp" ;;
    jpg|jpeg) echo "image/jpeg" ;;
    *) echo "image/jpeg" ;;
  esac
}

while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ -z "${line//[[:space:]]/}" ]]; then
    continue
  fi
  total=$((total + 1))

  id="$(printf '%s' "$line" | jq -r '.id // empty')"
  if [[ -z "$id" ]]; then
    dropped=$((dropped + 1))
    continue
  fi

  run_dir="$(printf '%s' "$line" | jq -r '.run_dir // empty')"
  audio_src="$(printf '%s' "$line" | jq -r '.audio_file // empty')"
  vision_src="$(printf '%s' "$line" | jq -r '.vision_image_file // empty')"
  vision_mime="$(printf '%s' "$line" | jq -r '.vision_image_mime_type // empty')"

  if [[ -z "$audio_src" && -n "$run_dir" && -f "$run_dir/audio.wav" ]]; then
    audio_src="$run_dir/audio.wav"
  fi

  if [[ -z "$vision_src" && -n "$run_dir" ]]; then
    for candidate in "$run_dir"/vision.png "$run_dir"/vision.jpg "$run_dir"/vision.jpeg "$run_dir"/vision.webp; do
      if [[ -f "$candidate" ]]; then
        vision_src="$candidate"
        break
      fi
    done
  fi

  if [[ -z "$vision_src" || ! -f "$vision_src" ]]; then
    dropped=$((dropped + 1))
    continue
  fi

  if [[ -z "$audio_src" || ! -f "$audio_src" ]]; then
    dropped=$((dropped + 1))
    continue
  fi

  case_dir="$ASSETS_DIR/$id"
  mkdir -p "$case_dir"

  audio_ext="$(asset_ext "$audio_src")"
  if [[ -z "$audio_ext" ]]; then
    audio_ext="wav"
  fi
  audio_dst="$case_dir/audio.$audio_ext"
  copy_asset "$audio_src" "$audio_dst"

  vision_ext="$(asset_ext "$vision_src")"
  if [[ -z "$vision_ext" ]]; then
    vision_ext="jpg"
  fi
  vision_dst="$case_dir/vision.$vision_ext"
  copy_asset "$vision_src" "$vision_dst"

  if [[ -z "$vision_mime" ]]; then
    vision_mime="$(vision_mime_from_ext "$vision_ext")"
  fi

  updated="$(printf '%s' "$line" | jq -cS \
    --arg audio "$audio_dst" \
    --arg vision "$vision_dst" \
    --arg vision_mime "$vision_mime" \
    '.audio_file = $audio | .vision_image_file = $vision | .vision_image_mime_type = $vision_mime')"
  printf '%s\n' "$updated" >> "$TMP_FILE"
  kept=$((kept + 1))
done < "$MANUAL_CASES_FILE"

cp "$MANUAL_CASES_FILE" "$BACKUP_FILE"
mv "$TMP_FILE" "$MANUAL_CASES_FILE"

echo "manual_cases_file: $MANUAL_CASES_FILE"
echo "backup_file: $BACKUP_FILE"
echo "assets_dir: $ASSETS_DIR"
echo "total: $total"
echo "kept: $kept"
echo "dropped: $dropped"
