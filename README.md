# Whisp

Whisp is a native macOS menu bar app for real-time speech-to-text with optional LLM post-processing and direct text input.

## Who This README Is For

This guide is for developers who want to:
- set up the project locally,
- build and test it,
- run the app from source,
- and launch the packaged `.app` build.

## Tech Stack

- Swift 6 (SwiftPM)
- AppKit + SwiftUI
- Targets:
  - `WhispCore` (core domain and infrastructure)
  - `WhispApp` (macOS menu bar app)
  - `whisp` (read-only diagnostics CLI)

## Repository Layout

```text
.
├── Package.swift
├── Sources
│   ├── WhispCore
│   ├── WhispApp
│   └── whisp
├── Tests
│   ├── WhispCoreTests
│   ├── WhispAppTests
│   └── WhispCLITests
├── docs
│   └── ARCHITECTURE.md
└── scripts
    ├── build_macos_app.sh
    ├── rebuild_reset_launch.sh
    └── reset_permissions.sh
```

## Prerequisites

- macOS
- Xcode (latest stable recommended)
- Swift toolchain compatible with `swift-tools-version: 6.0`

If Xcode command line tools are not fully initialized:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
```

## Setup

```bash
git clone git@github.com:taisii/whisp.git
cd whisp
```

No extra package manager is required for the Swift package itself.

## Build

```bash
swift build
```

## Test

### Full test run

```bash
swift test
```

### CI-equivalent non-UI run

This is the same scope as the current GitHub Actions CI:

```bash
swift test --skip Snapshot --skip Temporary
```

## Local Smoke Checks

```bash
swift run whisp debug self-check
swift run WhispApp --self-check
```

## Run the App From Source

```bash
swift run WhispApp
```

Whisp starts as a menu bar app.

## Build and Launch a Local `.app`

```bash
scripts/build_macos_app.sh
open .build/Whisp.app
```

## First-Run Permissions

Whisp may require these macOS permissions depending on features in use:
- Microphone
- Speech Recognition (for Apple Speech presets)
- Accessibility (for direct input)
- Screen Recording (when screenshot context is enabled)

If permissions get stuck, reset with:

```bash
tccutil reset Microphone com.taisii.whisp.swift
tccutil reset SpeechRecognition com.taisii.whisp.swift
tccutil reset Accessibility com.taisii.whisp.swift
tccutil reset ScreenCapture com.taisii.whisp.swift
```

## Configuration

Main config file:

- `~/.config/whisp/config.json`

Typical fields include API keys, hotkey, recording mode, STT preset, and LLM model.

## Helpful Developer Commands

```bash
# Enable verbose runtime logs
WHISP_DEV_LOG=1 swift run WhispApp

# Follow runtime log output
tail -f ~/.config/whisp/dev.log

# Read-only benchmark status from CLI
swift run whisp debug benchmark-status --format text

# Integrity scan for benchmark datasets
swift run whisp debug benchmark-integrity --task stt --cases ~/.config/whisp/debug/manual_test_cases.jsonl --format json
```

## Architecture Notes

See:

- `docs/ARCHITECTURE.md`

This is the source of truth for pipeline states, runtime artifacts, and benchmark data model.
