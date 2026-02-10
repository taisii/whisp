# Whisp

macOS menu bar app for real-time speech-to-text with AI post-processing.

**Stack**: Swift (SwiftPM), AppKit + SwiftUI

## Development Philosophy

- **Prototype stage**: No backward compatibility needed. Breaking changes are acceptable.
- **Simplicity first**: Keep code and design simple. Avoid over-engineering.

## Development

Use SwiftPM commands.

## Architecture

```
User speaks → Recording → Deepgram STT → LLM post-processing → Direct input
```

**Responsibilities**:
- **WhispApp (AppKit/SwiftUI)**: Menu bar UI, settings window, pipeline orchestration, OS integration.
  - Pipeline services: `RecordingService` / `STTService` / `PostProcessorService` / `OutputService` / `DebugCaptureService`
  - Provider interface: `LLMAPIProvider` (Gemini/OpenAI は provider として実装)
- **WhispCore**: Core models, prompt building, STT parsing, usage/config storage, API clients（`AppKit` 非依存）

**Pipeline states**: `Idle` → `Recording` → `SttStreaming` → `PostProcessing` → `DirectInput` → `Done`

## Domain Concepts

### Post-processing
Raw STT output contains filler words, lacks punctuation, and may have incorrect technical terms. The LLM refines this into clean, readable text. Target latency: ≤500ms from speech end to clipboard.

### App-specific prompts
Users can configure different prompt templates per application (e.g., code-style output for editors, casual style for chat apps). The active app is detected at recording time.

## Configuration

Stored at `~/.config/whisp/config.json`
