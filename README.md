# Whisp

A macOS menu bar app that transcribes speech in real time and applies AI post-processing.

- **Real-time speech recognition**: Streaming transcription via Deepgram
- **AI post-processing**: Remove filler words, add punctuation, and fix technical terms with Google Gemini
- **Low latency**: Targeting ≤500 ms from end of speech to clipboard

## Installation

### 1. Download the app

Download the latest `.dmg` from [Releases](https://github.com/your-repo/whisp/releases) and drag `Whisp.app` to the Applications folder.

### 2. First launch setup (required for unsigned apps)

Because this app is not enrolled in the Apple Developer Program, macOS Gatekeeper will block it on first launch. Use either method below to open it.

#### Method A: Allow from System Settings (recommended)

1. Double-click Whisp.app to open it
2. When the dialog says it cannot be opened because the developer cannot be verified, click **OK**
3. Open **System Settings** → **Privacy & Security**
4. Scroll down to see “\"Whisp\" was blocked because it is not from an identified developer”
5. Click **Open Anyway**
6. Enter your password to allow

#### Method B: Remove extended attributes from Terminal

Run the following command in Terminal:

```bash
xattr -cr /Applications/Whisp.app
```

Then open the app as usual.

### 3. Microphone permission

On first launch, you will be asked for microphone access. Click **Allow**.

To change it later: **System Settings** → **Privacy & Security** → **Microphone**, then enable Whisp.

## Configuration

### Get and set API keys

Whisp requires two API keys.

#### Deepgram (speech recognition)

1. Create an account at [Deepgram](https://deepgram.com/)
2. Generate an API key from the dashboard
3. Enter it in Whisp’s settings

#### Google Gemini (AI post-processing)

1. Go to [Google AI Studio](https://aistudio.google.com/)
2. **Get API key** → **Create API key**
3. Enter it in Whisp’s settings

### Global shortcut

Default is `Cmd+J`. You can change it in the settings screen.

## Usage

1. Click the Whisp menu bar icon or press the shortcut (default: `Cmd+J`) to start recording
2. Click again or press the shortcut to stop
3. The text is automatically copied to the clipboard (auto-paste is optional)

## Development

```bash
# Install dependencies
bun install

# Start in development mode
bun run tauri dev

# Production build
bun run tauri build
```

## Tech stack

- **Frontend**: React + TypeScript + Vite
- **Backend**: Rust + Tauri v2
- **Audio**: CPAL
- **STT**: Deepgram WebSocket API
- **Post-processing**: Google Gemini API
