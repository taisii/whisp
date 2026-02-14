# Whisp (Swift Native)

Whisp is now implemented as a native macOS app in Swift.

## What is implemented

- Menu bar resident app (`WhispApp`)
- Global shortcut (`Cmd+J` default, configurable)
- Recording modes: Toggle / Push-to-talk
- Microphone recording (AVAudioEngine, mono PCM)
- STT preset: Deepgram (Streaming/REST) / Apple Speech (Streaming/REST) / ChatGPT Whisper (Streaming)
- LLM post processing (Gemini / OpenAI)
- Direct text input via Accessibility (CGEvent)
- Optional screenshot context collection at recording start (`save_only` / `ocr`)
- Settings window (SwiftUI)
- Local config and usage storage

## Repository structure

- `Package.swift`: SwiftPM manifest
- `Sources/WhispCore`: core logic and utilities
- `Sources/WhispApp`: native menu bar GUI app
  - `Pipeline/`: `RecordingService` / `STTService` / `PostProcessorService` / `OutputService` / `DebugCaptureService`
  - `Benchmark*View`: candidate比較中心UI（`Comparison` / `Case Integrity`）
- `Sources/whisp`: read-only diagnostics CLI (`debug self-check/status/integrity`)
- `Tests/WhispCoreTests`: migrated tests
- `Tests/WhispAppTests`: app-layer tests (pipeline state transitions)
- `docs/ARCHITECTURE.md`: current architecture and debug data model
- `scripts/build_macos_app.sh`: local `.app` bundle builder
- `scripts/reset_permissions.sh`: TCC reset / privacy settings helper
- `scripts/benchmark_cases.sh`: deprecated helper (benchmark実行はGUIへ移行)

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
swift run whisp debug self-check
swift run WhispApp --self-check
```

## Development latency logs

Enable detailed pipeline logs:

```bash
WHISP_DEV_LOG=1 swift run WhispApp
```

For `.app` launch:

```bash
launchctl setenv WHISP_DEV_LOG 1
open .build/Whisp.app
```

Log file:
- `~/.config/whisp/dev.log`

To inspect in real time:

```bash
tail -f ~/.config/whisp/dev.log
```

### macOS system log export (Unified Logging)

`WhispApp` / `whisp` は `com.taisii.whisp` サブシステムへ主要イベントを記録します。
検証ログをファイル保存する場合:

```bash
# 直近15分を /tmp/whisp-system.log に保存
scripts/export_system_log.sh 15 /tmp/whisp-system.log
```

主な確認イベント:
- `stt` category: `stream_finalize_start`, `stream_finalize_done`, `app_stream_chunks_drained`
- `audio` category: `recording_stop`
- `app` category: pipeline各段の開始/終了イベント（`DevLog` と同名）

## CLI diagnostics (read-only)

```bash
# basic check
swift run whisp debug self-check

# benchmark candidates + latest runs
swift run whisp debug benchmark-status --format text
swift run whisp debug benchmark-status --format json

# dataset integrity (read-only scan)
swift run whisp debug benchmark-integrity \
  --task stt \
  --cases ~/.config/whisp/debug/manual_test_cases.jsonl \
  --format json
```

### Benchmark execution policy

ベンチマーク実行（STT / Generation / Vision / Pairwise）は `WhispApp` の `ベンチマーク` 画面からのみ行います。  
`whisp` CLI は read-only 診断専用です。

注記:
- `scripts/benchmark_*.sh` は互換維持のため残っていますが、実行系としては廃止（deprecated）です。
- 実行状態の確認は `whisp debug benchmark-status` と `whisp debug benchmark-integrity` を使ってください。

### Candidate 比較（GUI実行）

ベンチマーク実行（candidate比較・pairwise判定）は `WhispApp` の `ベンチマーク` 画面から実行します。  
`whisp` CLI は実行機能を持たず、状態確認用の read-only 診断のみ提供します。

STT candidate 設計メモ:
- `model` は `STTPresetID` を指定（例: `deepgram_stream`, `apple_speech_recognizer_stream`）
- STT候補のモードは `model`（preset）で決まり、`stt_mode` option は不要
- 無音区切り系は `silence_ms` / `max_segment_ms` / `pre_roll_ms` を option に保持する

Generation入力ポリシー:
- `stt_text` は必須
- 欠落時は `skipped_missing_input_stt` としてスキップ
- `labels.transcript_*` へのフォールバックは行わない

### Runtime statistics (運用統計)

メニューの `統計を開く` では、実録音の運用統計のみを表示します。

- 保存先: `~/.config/whisp/debug/stats/runtime_stats.json`
- 更新単位: 録音1件ごと（`completed` / `skipped` / `failed` の全終了経路）
- 期間: `24h / 7d / 30d / all`
- 主な表示: `Run Counts`、`Phase Averages`、`Dominant Stage`

表示時に `runs/*/events.jsonl` 全走査は行わず、統計ファイルを直接参照します。

### Full pipeline benchmark (deprecated script)

`scripts/benchmark_full_pipeline.sh` は deprecated です。  
実行時のボトルネック分析は、`WhispApp` のベンチマーク画面と `debug/runs/*/events.jsonl` を基準に行ってください。

実アプリでの実プロンプト採取:

```bash
WHISP_DEV_LOG=1 swift run WhispApp
```

`WHISP_PROMPT_TRACE_DIR` を指定すると保存先を上書きできます。

保存されるもの:
- `*.prompt.txt`: 実際に送信するプロンプト本文
- `*.meta.json`: モデル、context、文字数など

### Full pipeline bottleneck analysis (real app flow)

`WHISP_DEV_LOG=1` でアプリを動かして数回録音し、`events.jsonl` を解析します。

```bash
# 1) launch app with dev logging
WHISP_DEV_LOG=1 swift run WhispApp

# 2) in app: record a few times (Cmd+J start/stop)

# 3) analyze latest runs (default: ~/.config/whisp/debug/runs)
scripts/analyze_pipeline_log.sh ~/.config/whisp/debug/runs 10
# or single capture
scripts/analyze_pipeline_log.sh ~/.config/whisp/debug/runs/<capture-id>/events.jsonl
```

出力される主な指標:
- `recording_ms`: 録音区間
- `pipeline_ms`: 録音停止後の処理全体
- `stt_ms`: 音声認識
- `context_ms`: 文脈収集（`log_type=context_summary` があればそれを優先、なければ `log_type=vision`）
- `post_ms`: LLM整形
- `direct_ms`: 直接入力
- `other_ms`: 未分解時間

`dominant_stage_by_average` が、改善優先度の最上位ステージです。
この解析は `pipeline_ms` ベースなので、録音中の発話時間は支配判定に含めません。

## In-app debug window

メニューバーの `デバッグを開く` から、次を確認できます。
- 録音ごとの STT 結果
- 最終出力
- run_id に紐づく実際の送信プロンプト
- 録音ファイル（WAV）

追加機能:
- 正解テキスト（ground truth）の手入力保存
- 手入力済みデータを JSONL テストケースへ追記
- Visionコンテキスト（summary/terms）をキャプチャごとに保存
- Visionで解析したスクリーンショット（JPEG/PNG）をキャプチャごとに保存

保存先:
- 録音/メタ/イベント: `~/.config/whisp/debug/runs/<capture-id>/`
- プロンプト: `~/.config/whisp/debug/runs/<capture-id>/prompts`
- 手動テストケース: `~/.config/whisp/debug/manual_test_cases.jsonl`

### DebugViewスクリーンショット（実データ優先）

UI確認用のスクリーンショットは、実際の `events.jsonl` を持つ run を使って生成できます。

```bash
# 実データ（推奨: STT + pipeline + postprocess/context_summary がある最新run）
scripts/capture_debug_view_snapshot.sh -o .codex-artifacts/debugview-real.png

# 特定の capture_id を使う場合
scripts/capture_debug_view_snapshot.sh --capture-id <capture-id> -o .codex-artifacts/debugview-real.png

# 実データが無い場合のみサンプルデータ
scripts/capture_debug_view_snapshot.sh --sample -o .codex-artifacts/debugview-sample.png
```

`events.jsonl` は 1 行 1 JSON で、`log_type` ごとの厳密Unionを保存します。例:

```json
{
  "run_id": "a1b2c3d4",
  "capture_id": "20260211-....",
  "log_type": "stt",
  "event_start_ms": 1770757820523,
  "event_end_ms": 1770757820829,
  "recorded_at_ms": 1770757820831,
  "status": "ok",
  "provider": "deepgram_stream",
  "route": "streaming",
  "source": "stream_finalize",
  "text_chars": 16,
  "sample_rate": 16000,
  "audio_bytes": 240000,
  "attempts": [
    {
      "kind": "stream_finalize",
      "status": "ok",
      "event_start_ms": 1770757820523,
      "event_end_ms": 1770757820829,
      "source": "stream_finalize",
      "text_chars": 16
    }
  ]
}
```

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

`build_macos_app.sh` が埋め込む権限説明キー:
- `NSMicrophoneUsageDescription`
- `NSSpeechRecognitionUsageDescription`
- `NSAccessibilityUsageDescription`
- `NSScreenCaptureUsageDescription`

## 最新版ビルド + 権限初期化 + 起動（運用手順）

以下のスクリプトを実行するだけで、最新版ビルド・権限初期化・起動まで完了します。

```bash
cd /Users/macbookair/Projects/whisp
scripts/rebuild_reset_launch.sh
```

権限設定画面も同時に開く場合:

```bash
scripts/rebuild_reset_launch.sh --open-settings
```

補足:
- macOS仕様により、最終的な「許可」操作は手動で必要です。
- 起動確認は `pgrep -fl "WhispApp|Whisp"` で確認できます。
- オプション確認は `scripts/rebuild_reset_launch.sh --help`

## 権限だけ初期化/設定画面を開く

```bash
scripts/reset_permissions.sh
scripts/reset_permissions.sh --open-settings
```

補足:
- オプション確認は `scripts/reset_permissions.sh --help`

## First-run permissions

Whisp requires these permissions:
- Microphone
- Speech Recognition (when `sttPreset=apple_speech_recognizer_stream|apple_speech_recognizer_rest`)
- Accessibility (for direct input)
- Screen Recording (when screenshot analysis is enabled)

If permission state gets stuck:

```bash
tccutil reset Microphone com.taisii.whisp.swift
tccutil reset SpeechRecognition com.taisii.whisp.swift
tccutil reset Accessibility com.taisii.whisp.swift
tccutil reset ScreenCapture com.taisii.whisp.swift
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
- `sttPreset` (`deepgram_stream` / `deepgram_rest` / `apple_speech_recognizer_stream` / `apple_speech_recognizer_rest` / `chatgpt_whisper_stream`)
- `sttSegmentation.silenceMs` / `sttSegmentation.maxSegmentMs` / `sttSegmentation.preRollMs` / `sttSegmentation.livePreviewEnabled`
- `llmModel`
- `generationPrimary` (optional)
  - `candidateID`
  - `snapshot.model`
  - `snapshot.promptTemplate`
  - `snapshot.promptHash`
  - `snapshot.options`
  - `selectedAt`

`generationPrimary` is set from Settings > Generation主設定.
When present and valid, the pipeline prioritizes `snapshot.model` and `snapshot.promptTemplate`.
If invalid (unknown model or empty prompt), it falls back to legacy behavior (`llmModel` + `appPromptRules`).

## Current test status

- `swift test`: Swift core tests passing
