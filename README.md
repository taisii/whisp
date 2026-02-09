# Whisp (Swift Native)

Whisp is now implemented as a native macOS app in Swift.

## What is implemented

- Menu bar resident app (`WhispApp`)
- Global shortcut (`Cmd+J` default, configurable)
- Recording modes: Toggle / Push-to-talk
- Microphone recording (AVAudioEngine, mono PCM)
- Deepgram STT
- LLM post processing (Gemini / OpenAI)
- Direct text input via Accessibility (CGEvent)
- Optional screenshot context analysis at recording start
- Settings window (SwiftUI)
- Local config and usage storage

## Repository structure

- `Package.swift`: SwiftPM manifest
- `Sources/WhispCore`: core logic and utilities
- `Sources/WhispApp`: native menu bar GUI app
- `Sources/whisp`: small CLI smoke-check target
- `Tests/WhispCoreTests`: migrated tests
- `scripts/build_macos_app.sh`: local `.app` bundle builder

## Prerequisites

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
```

## Development commands

```bash
# build and test
swift build
swift test

# smoke checks
swift run whisp --self-check
swift run WhispApp --self-check
```

## STT smoke check (Swift)

```bash
# 1) generate sample speech audio
say -o /tmp/whisp-stt-check.aiff "これは音声認識の動作確認です"
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/whisp-stt-check.aiff /tmp/whisp-stt-check.wav

# 2) run Deepgram STT through Swift implementation
swift run whisp --stt-file /tmp/whisp-stt-check.wav
```

Requirements:
- `~/.config/whisp/config.json` に `apiKeys.deepgram` が設定されていること

## Run as menu bar app (debug)

```bash
swift run WhispApp
```

## Build local `.app` and run on real machine

```bash
scripts/build_macos_app.sh
open .build/Whisp.app
```

Built app path:
- `/Users/macbookair/Projects/whisp/.build/Whisp.app`

## First-run permissions

Whisp requires these permissions:
- Microphone
- Accessibility (for direct input)
- Screen Recording (when screenshot analysis is enabled)

If permission state gets stuck:

```bash
tccutil reset Microphone com.taisii.whisp.swift
tccutil reset Accessibility com.taisii.whisp.swift
```

## Configuration

Config file path:
- `~/.config/whisp/config.json`

Main fields:
- `apiKeys.deepgram`
- `apiKeys.gemini`
- `apiKeys.openai`
- `shortcut` (e.g. `Cmd+J`, `Ctrl+Alt+Shift+F1`)
- `recordingMode` (`toggle` / `push_to_talk`)
- `inputLanguage` (`auto` / `ja` / `en`)
- `llmModel`

## Current test status

- `swift test`: Swift core tests passing
