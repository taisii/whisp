# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Whisp is a macOS menu bar app for real-time speech-to-text transcription with AI post-processing. It captures voice input, streams to Deepgram for STT, then refines output using Google Gemini to remove filler words, fix technical terminology, and add punctuation. Target latency is ≤500ms from speech end to clipboard.

**Stack**: Tauri v2 (Rust backend + React frontend), TypeScript, Bun

## Development Commands

```bash
# Install dependencies
bun install

# Development (launches Tauri app with hot reload)
bun run tauri dev

# Build production macOS app
bun run tauri build

# Frontend only (Vite dev server on port 1420)
bun run dev

# Run Rust tests
cd src-tauri && cargo test

# Run a single Rust test
cd src-tauri && cargo test test_name
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Frontend (React)           │  Backend (Rust/Tauri)         │
│  src/                       │  src-tauri/src/               │
│  └─ Settings.tsx (main UI)  │  ├─ lib.rs (orchestrator)     │
│                             │  ├─ recorder.rs (CPAL audio)  │
│                             │  ├─ stt_client.rs (Deepgram)  │
│                             │  ├─ post_processor.rs (Gemini)│
│                             │  ├─ config.rs (persistence)   │
│                             │  └─ tray.rs, shortcut.rs, ... │
└─────────────────────────────────────────────────────────────┘
```

### Data Flow

1. User triggers global shortcut (default: Cmd+J)
2. `recorder.rs` captures audio via CPAL, streams to Deepgram WebSocket
3. `stt_client.rs` receives transcript chunks in real-time
4. On recording stop, `post_processor.rs` sends to Gemini for refinement
5. Result written to clipboard, optionally auto-pasted

### Pipeline States

`Idle` → `Recording` → `SttStreaming` → `PostProcessing` → `Clipboard` → `Done` (or `Error`)

Events emitted to frontend: `pipeline-state`, `debug-log`, `recording-state-changed`, `pipeline-output`

### Key IPC Commands (lib.rs)

- `get_config()` / `save_config(config)` - Config management
- `toggle_recording()` - Start/stop recording
- `process_audio_file(path)` - Playground: process WAV file

## Configuration

Config stored at `~/.config/whisp/config.toml`:
```toml
[api_keys]
deepgram = "..."
gemini = "..."

shortcut = "Cmd+J"
auto_paste = true
input_language = "ja"  # or "en" or "auto"
```

## Code Patterns

- Frontend uses Tauri's `invoke()` for commands and `listen()` for events
- Backend state managed via `AppState` with `Mutex<Option<RecordingSession>>`
- Async operations use Tokio runtime
- Audio: mono i16 PCM at device sample rate, resampled to 16kHz for Deepgram
