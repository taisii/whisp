# Whisp Architecture (Current)

このドキュメントは、現行実装（大規模リファクタリング後）のアーキテクチャを固定化するための設計記録です。

## 1. 目的と方針

- プロダクトを `WhispCore`（ドメイン/基盤）と `WhispApp`（UI/OS統合）に分離する。
- デバッグ可能性を重視し、実行ごとの成果物をファイルとして再現可能に保存する。
- CLI (`whisp`) は read-only 診断専用とし、ベンチマーク実行は担わない。

## 2. ターゲット構成

`Package.swift` で以下を定義:

- `WhispCore` (library): 共通モデル、保存、STT/Prompt関連ロジック
- `WhispApp` (executable): メニューバーアプリ本体
- `whisp` (executable): CLI（read-only 診断）
- `WhispCoreTests`, `WhispAppTests`, `WhispCLITests`

## 3. レイヤー責務

### 3.1 WhispCore

主な責務:

- 設定/利用量保存（`ConfigStore`, `UsageStore`）
- 共通モデル（`Config`, `ContextInfo`, `STTUsage`, `LLMUsage`, `DailyUsage`）
- Prompt生成とトレース保存（`PromptBuilder`, `PromptTrace`）
- STTレスポンス解析
- デバッグキャプチャ永続化（`DebugCaptureStore` + 拡張）

依存方針:

- `WhispCore` は `AppKit` 非依存。

### 3.2 WhispApp

主な責務:

- メニューバーUIと設定画面
- 録音開始/停止、STT、ポストプロセス、直接入力のオーケストレーション
- OS依存処理（アクセシビリティ、スクリーンキャプチャ、直接入力）
- デバッグ保存のタイミング管理

中心コンポーネント:

- `AppCoordinator`
- `RecordingService`
- `STTService`
- `ContextService`
- `PostProcessorService`
- `OutputService`
- `DebugCaptureService`

### 3.3 whisp (CLI)

`Sources/whisp` は `swift-argument-parser` ベースの診断コマンド群で構成:

- `WhispCLI.swift`（エントリポイント）
- `DebugCommand.swift`（`debug` サブコマンド）
- `DebugSelfCheckCommand.swift`（疎通確認）
- `DebugBenchmarkStatusCommand.swift`（candidate/run状況の read-only 表示）
- `DebugBenchmarkIntegrityCommand.swift`（ケース不備の read-only スキャン）

## 4. パイプライン実行モデル

`PipelineStateMachine` の状態遷移:

- `idle` → `recording` → `sttStreaming` → `postProcessing` → `directInput` → `done` → `idle`
- 失敗時は `error` を経由し `reset` で `idle` に戻す。

`AppCoordinator` の大枠:

1. 録音開始時: 必要キー検証、debug runディレクトリを先行確保、STTストリーミング準備、録音開始。
2. 録音停止時: 音声データを予約済みrunへ確定保存し、非同期で処理継続。
3. STT:
   - `sttPreset=deepgram_stream`: Deepgram Streaming
   - `sttPreset=deepgram_rest`: Deepgram REST
   - `sttPreset=apple_speech_recognizer_stream`: Apple Speech Recognizer Streaming（Speech.framework on-device）
   - `sttPreset=apple_speech_recognizer_rest`: Apple Speech Recognizer REST（on-device URL request）
   - `sttPreset=chatgpt_whisper_stream`: OpenAI Realtime Streaming（gpt-4o-mini-transcribe）
   - Apple streaming は `sttSegmentation` に従って VAD区切り（`silence/max_segment/stop`）で segment commit し、セッションを回転する
   - `segments` と `vadIntervals` を保存し、後段LLMには `segments.map(\.text).joined(separator: "\n")` を渡す
   - Streaming失敗時はRESTへフォールバックせず、エラーで終了
   - 直接音声モデル時は LLMで音声→テキスト整形
4. Context:
   - アクセシビリティ文脈を収集
   - Visionは `save_only`（画像保存のみ）/`ocr`（OCR抽出）の2モード
   - Vision文脈を必要時のみ非同期収集し、準備済みなら合成
5. ポストプロセス: Prompt生成→LLM呼び出し
6. 出力: 直接入力を実行
7. 各段階でイベントを記録し、`manifest` の `status`/`sttText`/`outputText` を更新

## 5. デバッグ機能（収集対象と保存形式）

## 5.1 保存ルート

- ベース: `~/.config/whisp/debug`
- run保存先: `~/.config/whisp/debug/runs/<capture_id>/`
- 統計保存先: `~/.config/whisp/debug/stats/runtime_stats.json`
- 手動評価ケース: `~/.config/whisp/debug/manual_test_cases.jsonl`

`capture_id` は `yyyyMMdd-HHmmss-<runID>`。

## 5.2 runごとのファイル構成

`runs/<capture_id>/` に以下を保存:

- `audio.wav`: 録音音声
- `manifest.json`: runメタデータ（下記）
- `events.jsonl`: 実行イベントログ（1行1JSON）
- `prompts/`: LLM送信プロンプトの本文とメタ
- `vision.<ext>`: Vision画像（取得時のみ）

## 5.3 収集している情報

### A. manifest.json

主な項目:

- 識別情報: `id`, `runID`, `createdAt`
- パス: `runDirectoryPath`, `promptsDirectoryPath`, `eventsFilePath`, `audioFilePath`
- 実行結果: `sttText`, `outputText`, `status`, `errorMessage`
- 文脈: `context`（`visionSummary`, `visionTerms`, `accessibilityText`, `windowText` など）
  - `context` は postprocess / audio_transcribe 実行時に実際に組み立てた入力コンテキストを保存する。
- アクセシビリティ: `accessibilitySnapshot`
- Vision: `visionImageFilePath`, `visionImageMimeType`

generation テンプレート変数は `context` を入力源にする（`{選択テキスト}`, `{画面テキスト}`, `{画面要約}`, `{専門用語候補}`）。
`accessibilitySnapshot` はデバッグ保存用途で、現時点では generation テンプレート変数には直接マッピングしない。

`status` の代表値:

- `recording`
- `recorded`
- `skipped_empty_audio`
- `skipped_empty_stt`
- `skipped_empty_output`
- `done`
- `done_input_failed`
- `error`

### B. events.jsonl

1行ごとに `DebugRunLog`（`stage` ごとの厳密Union）を保存:

- 共通項目:
  - `run_id`, `capture_id`
  - `stage`（`recording` / `stt` / `vision` / `postprocess` / `direct_input` / `pipeline` / `context_summary`）
  - `started_at_ms`, `ended_at_ms`, `recorded_at_ms`
  - `status`（`ok` / `error` / `cancelled` / `skipped`）
  - `attrs`（stage固有の属性）
- `stage` ごとの主な `attrs`:
  - `recording`: `mode`, `model`, `stt_provider`, `stt_streaming`, `vision_enabled`, `accessibility_summary_started`, `sample_rate`, `pcm_bytes`
  - `stt`: `provider`, `route`, `source`, `text_chars`, `sample_rate`, `audio_bytes`, `attempts`
  - `vision`: `model`, `mode`, `context_present`, `image_bytes`, `image_width`, `image_height`, `error`
  - `postprocess`: `model`, `context_present`, `stt_chars`, `output_chars`, `kind`
  - `direct_input`: `success`, `output_chars`
  - `pipeline`: `stt_chars`, `output_chars`, `error`
  - `context_summary`: `source`, `app_name`, `source_chars`, `summary_chars`, `terms_count`, `error`

### C. prompts/

`PromptTrace.dump` により保存:

- `prompts/<trace_id>/request.txt`: 実際に送信したプロンプト本文
- `prompts/<trace_id>/request.json`: `traceID`, `stage`, `model`, `context`, `requestChars`, `extra` など
  - `context` はその stage のAPIに実際に渡した文脈（postprocess/audio_transcribe では sanitize 後）を保持する。

postprocess 系の sanitize では `accessibilityText`, `windowText`, `visionSummary`, `visionTerms` を保持する。
- `prompts/<trace_id>/response.txt`: 対応するレスポンス本文
- `prompts/<trace_id>/response.json`: `status(ok/error)`, `responseChars`, `usage`, `errorMessage` など

`extra.run_dir` がある場合は、そのrun配下 `prompts/` に保存される。App本体のパイプライン実行では録音開始時に run を確保するため、`accessibility_summary` を含むプロンプトは run 配下に保存される。

### D. manual_test_cases.jsonl

`appendManualTestCase` 実行で1行追加:

- run識別情報
- 音声/イベントファイルパス
- `stt_text`, `output_text`, `ground_truth_text`
- `labels.transcript_gold`（STT正解を保存した場合）
- `context`
- `accessibility`（取得済みなら）
- `vision_image_file`, `vision_image_mime_type`（取得済みなら）

## 5.4 アクセシビリティ収集の現行仕様

- 録音停止時に `ContextService.captureAccessibility` を実行し、snapshot/contextを取得する。
- 権限未許可でも `accessibility_not_trusted` を含むスナップショットとして記録可能。
- 取得値は debug保存と、後段の文脈合成（LLM入力）に利用される。
- `context_summary` イベントの `ended_at_ms` は、要約APIの応答完了時刻（ready時）またはキャンセル時刻（未完了で打ち切り時）を記録する。

## 5.5 Runtime統計（運用観測）

- `RuntimeStatsStore` が `runtime_stats.json` を保持し、録音1件ごとに増分更新する。
- 記録タイミングは `PipelineRunner` の全終了経路:
  - `completed`
  - `skipped`（`empty_audio` / `empty_stt` / `empty_output`）
  - `failed`
- 保存形式は「全体集計 + 時間バケット（1時間単位）」。
- 統計画面は `24h / 7d / 30d / all` を `RuntimeStatsSnapshot` から即時計算し、`runs/*/events.jsonl` の再走査は行わない。
- 保持期間は約45日（時間バケット）。`all` は累積集計を参照する。

## 6. 運用メモ

- デバッグUI (`DebugView`) から run単位の詳細、音声再生、画像確認、プロンプト確認、テストケース追加が可能。
- `PromptTrace` は失敗しても本処理を止めない（ベストエフォート保存）。
- Vision文脈は設定/タイミング条件によりスキップされる場合がある。

## 7. ベンチマーク設計（比較中心）

ベンチマークは「実行できたか」ではなく「candidate比較で意思決定できるか」を目的にする。
現行は `stt/generation/vision` の3種を同一保存規約で扱う。

### 7.1 保存ルート

```text
~/.config/whisp/debug/benchmarks/
├── candidates/
│   └── candidates.json
├── integrity/
│   ├── exclusions.json
│   ├── issues_stt.json
│   └── issues_generation.json
└── runs/
    └── <run_id>/
        ├── manifest.json
        ├── orchestrator_events.jsonl
        ├── cases_index.jsonl
        └── cases/
            └── <case_id>/
                ├── manifest.json
                ├── metrics.json
                ├── events.jsonl
                ├── io/
                └── artifacts/
```

### 7.2 主要データ

- `BenchmarkCandidate`: 比較対象定義（`task + model + promptName + generationPromptTemplate/hash + options`）
- `BenchmarkKey`: 比較セル識別子（`task + datasetPath/hash + candidateID + runtimeOptionsHash + evaluator/code version`）
- `BenchmarkRunRecord`: run正本（`schemaVersion=7`、run全体 `metrics`、`candidateID`、`benchmarkKey`）
  - generation pairwise は `options.compareMode=pairwise`、`pairCandidateAID`、`pairCandidateBID`、`pairJudgeModel` を保存
- `BenchmarkCaseResult`: `cases_index.jsonl` の軽量行（一覧表示向け）
- `BenchmarkCaseManifest` + `BenchmarkCaseMetrics`: ケース詳細の正本
  - generation pairwise は `BenchmarkCaseMetrics.pairwise` に winner/reason を保存
- `BenchmarkOrchestratorEvent`: run進捗（キュー投入/開始/完了/失敗）
- `BenchmarkIntegrityIssue`: ケース不備（欠落/参照不足/破損）を保持

### 7.3 実行フロー

- `benchmark_workers` で固定ワーカープール数を指定可能（未指定は `min(4, CPUコア数)`）。
- `compare_workers` は candidate比較時の並列数（既定2）として扱う。
- ケース処理はケース単位で独立実行し、保存は `cases/<case_id>/` 配下に分離する。
- run全体進捗は `orchestrator_events.jsonl`、UI一覧は `cases_index.jsonl` を参照する。
- App (`BenchmarkViewModel`) が `BenchmarkExecutionService` を介して `BenchmarkExecutor` を実行する。
  - `stt`: candidate単位で実行。candidate同士は並列実行可能
    - `apple_speech + stream` は内部 capability で同時実行1に制限（上位フローはモデル非依存）
  - `generation`: pairwise専用（A/B 2候補 + judgeモデル）で実行
- CLI は `debug benchmark-status` / `debug benchmark-integrity` の read-only 診断のみ提供する。

### 7.4 Generation 入力方針

- generation benchmark の入力は `stt_text` 必須。
- 欠落時は `skipped_missing_input_stt` としてスキップ記録する。
- `labels.transcript_*` へのフォールバックは行わない。

### 7.5 Generation Pairwise 評価

- 判定軸は `intent` / `hallucination` / `style_context` の3軸。
- judge は A→B と B→A の2回判定を実行し、軸ごとに一致時のみ winner を採用。不一致は `tie`。
- `overall_winner` は3軸多数決（同数は `tie`）。
- ケースI/Oは `prompt_generation_a/b.txt`, `output_generation_a/b.txt`, `prompt_pairwise_round1/2.txt`, `pairwise_round1/2_response.json`, `pairwise_decision.json` を保存する。

---

更新時ルール:

- パイプライン状態、保存形式、`status` 値、出力先パスを変更したら本書を同時更新する。
