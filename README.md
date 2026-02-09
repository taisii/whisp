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

## STT smoke check (Swift)

```bash
# 1) prepare fixed benchmark sample
scripts/prepare_benchmark_sample.sh Tests/Fixtures/benchmark_ja_10s.wav

# 2) run Deepgram STT through Swift implementation
swift run whisp --stt-file Tests/Fixtures/benchmark_ja_10s.wav

# 3) run Deepgram STT streaming (simulated realtime)
swift run whisp --stt-stream-file Tests/Fixtures/benchmark_ja_10s.wav --chunk-ms 120 --realtime
```

Requirements:
- `~/.config/whisp/config.json` に `apiKeys.deepgram` が設定されていること

### STT latency benchmark example

```bash
# one-command benchmark cycle
scripts/benchmark_stt_latency.sh Tests/Fixtures/benchmark_ja_10s.wav 3
```

`benchmark_stt_latency.sh` は次を出力します。
- `post_stop_latency_rest_ms`: REST方式での「録音停止後→STT完了」
- `post_stop_latency_stream_ms`: Streaming方式での「録音停止後→最終確定」

今回の最適化目標は、この `post_stop_latency_*` を下げることです。

### Manual case benchmark (音声 + 人手正解)

`manual_test_cases.jsonl` を使って、実録音データに対する精度を定量評価できます。

```bash
scripts/benchmark_manual_cases.sh
# パスや件数を指定する例
scripts/benchmark_manual_cases.sh ~/.config/whisp/debug/manual_test_cases.jsonl --limit 20
# context保存済みケースのみで比較する例
scripts/benchmark_manual_cases.sh ~/.config/whisp/debug/manual_test_cases.jsonl --require-context
```

主指標:
- `exact_match_rate`: 完全一致率
- `avg_cer`: ケース平均CER（文字誤り率）
- `weighted_cer`: 全文字数で重み付けしたCER
- `avg_total_after_stop_ms`: 録音停止後レイテンシ平均

補足:
- この更新以前に保存されたケースには `context` / `vision_image_file` が無い場合があります。
- `--require-context` を付けると、同条件比較に必要な `context` 付きケースだけを評価します。

### Full pipeline benchmark (stop -> final output)

```bash
scripts/benchmark_full_pipeline.sh Tests/Fixtures/benchmark_ja_10s.wav 3
# output段も測るなら emit を指定
scripts/benchmark_full_pipeline.sh Tests/Fixtures/benchmark_ja_10s.wav 3 pbcopy
# 画面コンテキストを模擬する場合
scripts/benchmark_full_pipeline.sh Tests/Fixtures/benchmark_ja_10s.wav 3 discard /tmp/whisp-fullbench-context Tests/Fixtures/context_sample.json
```

主指標:
- `avg_total_after_stop_ms` (録音停止後から最終出力まで)
- `dominant_stage_after_stop` (`stt_after_stop` / `post` / `output`)

この結果を基準に、改善優先度を決めます。

プロンプト比較:

`benchmark_full_pipeline.sh` は `result_root` 配下に `traces/` を保存します。  
比較は次で実行できます。

```bash
scripts/analyze_prompt_traces.sh /tmp/whisp-fullbench-context
```

実アプリでの実プロンプト採取:

```bash
WHISP_PROMPT_TRACE_DIR=/tmp/whisp-prompts WHISP_DEV_LOG=1 swift run WhispApp
```

`WHISP_PROMPT_TRACE_DIR` を指定すると、以下が保存されます。
- `*.prompt.txt`: 実際に送信するプロンプト本文
- `*.meta.json`: モデル、context、文字数など

### Full pipeline bottleneck analysis (real app flow)

`WHISP_DEV_LOG=1` でアプリを動かして数回録音し、`dev.log` を解析します。

```bash
# 1) launch app with dev logging
WHISP_DEV_LOG=1 swift run WhispApp

# 2) in app: record a few times (Cmd+J start/stop)

# 3) analyze latest runs (default: ~/.config/whisp/dev.log)
scripts/analyze_pipeline_log.sh ~/.config/whisp/dev.log 10
```

出力される主な指標:
- `recording_ms`: 録音区間
- `pipeline_ms`: 録音停止後の処理全体
- `stt_ms`: 音声認識
- `vision_wait_ms`: Vision結果待ち（クリティカルパス上の待ち時間）
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
- 録音/メタ: `~/.config/whisp/debug/captures`
- プロンプト: `~/.config/whisp/debug/prompts`
- 手動テストケース: `~/.config/whisp/debug/manual_test_cases.jsonl`

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

## First-run permissions

Whisp requires these permissions:
- Microphone
- Accessibility (for direct input)
- Screen Recording (when screenshot analysis is enabled)

If permission state gets stuck:

```bash
tccutil reset Microphone com.taisii.whisp.swift
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
- `llmModel`

## Current test status

- `swift test`: Swift core tests passing
