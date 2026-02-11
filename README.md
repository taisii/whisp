# Whisp (Swift Native)

Whisp is now implemented as a native macOS app in Swift.

## What is implemented

- Menu bar resident app (`WhispApp`)
- Global shortcut (`Cmd+J` default, configurable)
- Recording modes: Toggle / Push-to-talk
- Microphone recording (AVAudioEngine, mono PCM)
- STT provider: Deepgram / Whisper (OpenAI) / Apple Speech (OS built-in)
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
  - `LLM/`: provider abstraction (`LLMAPIProvider`) and provider implementations
- `Sources/whisp`: small CLI smoke-check target
- `Tests/WhispCoreTests`: migrated tests
- `Tests/WhispAppTests`: app-layer tests (pipeline state transitions)
- `docs/ARCHITECTURE.md`: current architecture and debug data model
- `scripts/build_macos_app.sh`: local `.app` bundle builder
- `scripts/reset_permissions.sh`: TCC reset / privacy settings helper
- `scripts/benchmark_cases.sh`: benchmark entrypoint (`manual|stt|generation|vision|e2e`)

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
- `~/.config/whisp/config.json` に必要なAPIキーが設定されていること
  - `sttProvider=deepgram` の場合: `apiKeys.deepgram`
  - `sttProvider=whisper` の場合: `apiKeys.openai`
  - `sttProvider=apple_speech` の場合: APIキー不要（音声認識権限は必要）

### STT latency benchmark example

```bash
# one-command benchmark cycle
scripts/benchmark_stt_latency.sh Tests/Fixtures/benchmark_ja_10s.wav 3
# ログ保存先を指定する例
scripts/benchmark_stt_latency.sh Tests/Fixtures/benchmark_ja_10s.wav 3 /tmp/whisp-sttbench
```

`benchmark_stt_latency.sh` は次を出力します（各runログは `result_root/logs/` に保存）。
- `post_stop_latency_rest_ms`: REST方式での「録音停止後→STT完了」
- `post_stop_latency_stream_ms`: Streaming方式での「録音停止後→最終確定」

今回の最適化目標は、この `post_stop_latency_*` を下げることです。

### Manual case benchmark (音声 + 人手正解)

`manual_test_cases.jsonl` を使って、実録音データに対する精度を定量評価できます。
この評価は **ベンチマーク（モデル/処理性能）** 用で、運用件数統計は別の統計ストアに分離されています。

```bash
scripts/benchmark_manual_cases.sh
# パスや件数を指定する例
scripts/benchmark_manual_cases.sh ~/.config/whisp/debug/manual_test_cases.jsonl --limit 20
# context保存済みケースのみで比較する例
scripts/benchmark_manual_cases.sh ~/.config/whisp/debug/manual_test_cases.jsonl --require-context
# 音声長2.5秒未満を除外し、結果を保存する例
scripts/benchmark_manual_cases.sh ~/.config/whisp/debug/manual_test_cases.jsonl --result-root /tmp/whisp-manualbench --min-audio-seconds 2.5
```

主指標:
- `exact_match_rate`: 完全一致率
- `avg_cer`: ケース平均CER（文字誤り率）
- `weighted_cer`: 全文字数で重み付けしたCER
- `intent_match_rate`: 意図一致率（intent judge 有効時）
- `stt_total_ms`: STT全体レイテンシ分布（`avg/p50/p95/p99`）
- `stt_after_stop_ms`: 録音停止後STTレイテンシ分布（`avg/p50/p95/p99`）
- `post_ms`: 生成/整形レイテンシ分布（`avg/p50/p95/p99`）
- `total_after_stop_ms`: 録音停止後E2Eレイテンシ分布（`avg/p50/p95/p99`）
- `intent_preservation_score` / `hallucination_score` / `hallucination_rate`: LLM評価（`--llm-eval` 有効時）

補足:
- この更新以前に保存されたケースには `context` / `vision_image_file` が無い場合があります。
- `--require-context` を付けると、同条件比較に必要な `context` 付きケースだけを評価します。
- `--min-audio-seconds` 未満の短い音声は `skipped_too_short_audio` として自動除外されます。
- ケース別ログは `manual_case_rows.jsonl`、集計ログは `manual_summary.json` に保存されます。
- intent評価は `intent_gold` / `intent_silver`（または `labels.intent_gold` / `labels.intent_silver`）を参照します。
- 生成品質のLLM評価は `--llm-eval` / `--no-llm-eval` / `--llm-eval-model` で制御できます（デフォルトOFF）。

### Component benchmarks (1:Vision / 2:STT / 3:Generation / 4:E2E)

同じ `manual_test_cases.jsonl` を使って、4つの能力を分離して評価できます。

```bash
# 1) 画像 -> OCRコンテキスト抽出
scripts/benchmark_cases.sh vision ~/.config/whisp/debug/manual_test_cases.jsonl

# 2) 音声 -> transcript（STT）
scripts/benchmark_cases.sh stt ~/.config/whisp/debug/manual_test_cases.jsonl --stt stream --min-audio-seconds 2.0

# 3) stt_text + context -> 最終テキスト（生成）
scripts/benchmark_cases.sh generation ~/.config/whisp/debug/manual_test_cases.jsonl

# 4) 音声 + context -> 最終テキスト（E2E）
scripts/benchmark_cases.sh e2e ~/.config/whisp/debug/manual_test_cases.jsonl --min-audio-seconds 2.0
```

各ベンチは `--result-root` で保存先を指定できます。保存物:
- `*_case_rows.jsonl`: ケース別ログ
- `*_summary.json`: 集計結果
- `summary.txt`: 実行時コンソール出力

集計の基本方針:
- ベンチマーク画面は性能中心表示（品質 + レイテンシ分布）で、件数系は主表示しません。
- レイテンシは平均値だけでなく `P50/P95/P99` を必須指標として扱います。
- `generation` / `e2e` では `--llm-eval` で意図保持と幻覚率を追加評価できます。

キャッシュ:
- 1/2/3 は `~/.config/whisp/benchmark_cache/` を参照し、同一入力・同一設定の結果を再利用します。
- キャッシュ無効化は `--no-cache`。

一括で回す場合:

```bash
scripts/run_component_eval_loop.sh ~/.config/whisp/debug/manual_test_cases.jsonl
```

`run_component_eval_loop.sh` は `1_vision/2_stt/3_generation/4_e2e` を同一 `result_root` に出力し、`overview.txt` を生成します。

### Runtime statistics (運用統計)

メニューの `統計を開く` では、実録音の運用統計のみを表示します。

- 保存先: `~/.config/whisp/debug/stats/runtime_stats.json`
- 更新単位: 録音1件ごと（`completed` / `skipped` / `failed` の全終了経路）
- 期間: `24h / 7d / 30d / all`
- 主な表示: `Run Counts`、`Phase Averages`、`Dominant Stage`

表示時に `runs/*/events.jsonl` 全走査は行わず、統計ファイルを直接参照します。

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

### End-to-end eval loop (manual + stt + full)

評価ループをまとめて回す場合:

```bash
# 1) manualケース評価（短音声除外、intent judge含む）
# 2) STT latency
# 3) full pipeline
# 4) events.jsonl解析
scripts/run_eval_loop.sh ~/.config/whisp/debug/manual_test_cases.jsonl Tests/Fixtures/benchmark_ja_10s.wav
```

出力:
- `overview.txt`: 主要指標の要約
- `manual/`: ケース別評価ログと集計JSON
- `stt/`: STT latencyログ
- `full/`: full pipelineログ

プロンプト比較:

`benchmark_full_pipeline.sh` は `result_root` 配下に `traces/` を保存します。  
比較は次で実行できます。

```bash
scripts/analyze_prompt_traces.sh /tmp/whisp-fullbench-context
```

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
  "provider": "deepgram",
  "route": "streaming_fallback_rest",
  "source": "rest_fallback",
  "text_chars": 16,
  "sample_rate": 16000,
  "audio_bytes": 240000,
  "attempts": [
    {
      "kind": "stream_finalize",
      "status": "error",
      "event_start_ms": 1770757820523,
      "event_end_ms": 1770757820600,
      "source": "stream_finalize",
      "error": "timeout"
    },
    {
      "kind": "rest_fallback",
      "status": "ok",
      "event_start_ms": 1770757820601,
      "event_end_ms": 1770757820829,
      "source": "rest_fallback",
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
- Speech Recognition (when `sttProvider=apple_speech`)
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
- `sttProvider` (`deepgram` / `whisper` / `apple_speech`)
- `llmModel`

## Current test status

- `swift test`: Swift core tests passing
