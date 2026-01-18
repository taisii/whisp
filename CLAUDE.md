# Whisp

macOS menu bar app for real-time speech-to-text with AI post-processing.

**Stack**: Tauri v2 (Rust backend + React frontend), Bun

## Development Philosophy

- **Prototype stage**: No backward compatibility needed. Breaking changes are acceptable.
- **Simplicity first**: Keep code and design simple. Avoid over-engineering.

## Development

Use `bun` for frontend, `cargo` for Rust (`src-tauri/`). See `package.json` for available scripts.

## Architecture

```
User speaks → Recording → Deepgram STT (streaming) → Gemini post-processing → Clipboard
```

**Responsibilities**:
- **Frontend (React)**: Settings UI only. No business logic.
- **Backend (Rust)**: All core logic. Audio capture, STT streaming, LLM post-processing, clipboard, global shortcut.

**Pipeline states**: `Idle` → `Recording` → `SttStreaming` → `PostProcessing` → `Clipboard` → `Done`

## Domain Concepts

### Post-processing
Raw STT output contains filler words, lacks punctuation, and may have incorrect technical terms. The LLM refines this into clean, readable text. Target latency: ≤500ms from speech end to clipboard.

### App-specific prompts
Users can configure different prompt templates per application (e.g., code-style output for editors, casual style for chat apps). The active app is detected at recording time.

## Configuration

Stored at `~/.config/whisp/config.toml`
