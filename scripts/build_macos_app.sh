#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

swift build -c release --product WhispApp

APP_DIR="$ROOT_DIR/.build/Whisp.app"
BIN_SRC="$ROOT_DIR/.build/release/WhispApp"
BIN_DST="$APP_DIR/Contents/MacOS/WhispApp"
PLIST_PATH="$APP_DIR/Contents/Info.plist"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"

cp "$BIN_SRC" "$BIN_DST"
chmod +x "$BIN_DST"

cat > "$PLIST_PATH" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>ja</string>
  <key>CFBundleExecutable</key>
  <string>WhispApp</string>
  <key>CFBundleIdentifier</key>
  <string>com.taisii.whisp.swift</string>
  <key>CFBundleName</key>
  <string>Whisp</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Whisp needs microphone access to transcribe your voice to text.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Whisp needs speech recognition access to transcribe audio using Apple Speech.</string>
  <key>NSAccessibilityUsageDescription</key>
  <string>Whisp needs accessibility access to input transcribed text directly into your applications.</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>Whisp needs screen recording access to analyze screenshot context.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_DIR"

echo "Built: $APP_DIR"
echo "Run: open $APP_DIR"
