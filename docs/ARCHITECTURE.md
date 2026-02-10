# Whisp Architecture (Current)

このドキュメントは、現行実装（大規模リファクタリング後）のアーキテクチャを固定化するための設計記録です。

## 1. 目的と方針

- プロダクトを `WhispCore`（ドメイン/基盤）と `WhispApp`（UI/OS統合）に分離する。
- デバッグ可能性を重視し、実行ごとの成果物をファイルとして再現可能に保存する。
- CLI (`whisp`) は用途別に責務分割し、検証・ベンチマーク実行を担う。

## 2. ターゲット構成

`Package.swift` で以下を定義:

- `WhispCore` (library): 共通モデル、保存、STT/Prompt関連ロジック
- `WhispApp` (executable): メニューバーアプリ本体
- `whisp` (executable): CLI（STT検証・ベンチマーク・補助ツール）
- `WhispCoreTests`, `WhispAppTests`

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

`Sources/whisp` は以下に分割:

- `WhispCLI+Main.swift`（エントリポイント）
- `WhispCLI+Entry.swift`（サブコマンド分岐）
- `WhispCLI+Commands.swift`（実行処理）
- `WhispCLI+Parsing.swift`（引数解析）
- `WhispCLI+BenchmarkSupport.swift`（ベンチ補助）
- `WhispCLI+AI.swift`（API連携補助）
- `WhispCLI+Utils.swift`（共通関数）
- `WhispCLI+Models.swift`（CLI用モデル）

## 4. パイプライン実行モデル

`PipelineStateMachine` の状態遷移:

- `idle` → `recording` → `sttStreaming` → `postProcessing` → `directInput` → `done` → `idle`
- 失敗時は `error` を経由し `reset` で `idle` に戻す。

`AppCoordinator` の大枠:

1. 録音開始時: 必要キー検証、STTストリーミング準備、録音開始。
2. 録音停止時: 音声データ確定、デバッグrun作成、非同期で処理継続。
3. STT:
   - `sttProvider=deepgram`: stream優先、失敗時restフォールバック
   - `sttProvider=whisper`: OpenAI Whisper REST
   - `sttProvider=apple_speech`: Apple Speech（OS内蔵）
   - 直接音声モデル時は LLMで音声→テキスト整形
4. Context:
   - アクセシビリティ文脈を収集
   - Vision文脈を必要時のみ非同期収集し、準備済みなら合成
5. ポストプロセス: Prompt生成→LLM呼び出し
6. 出力: 直接入力を実行
7. 各段階でイベントを記録し、`manifest` の `status`/`sttText`/`outputText` を更新

## 5. デバッグ機能（収集対象と保存形式）

## 5.1 保存ルート

- ベース: `~/.config/whisp/debug`
- run保存先: `~/.config/whisp/debug/runs/<capture_id>/`
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
- 文脈: `context`（`visionSummary`, `visionTerms`, `accessibilityText`）
- アクセシビリティ: `accessibilitySnapshot`
- Vision: `visionImageFilePath`, `visionImageMimeType`

`status` の代表値:

- `recorded`
- `skipped_empty_audio`
- `skipped_empty_stt`
- `skipped_empty_output`
- `done`
- `done_input_failed`
- `error`

### B. events.jsonl

1行ごとに以下の形式:

- `timestamp`
- `event`（例: `recording_start`, `stt_start`, `postprocess_done`, `pipeline_done`, `pipeline_error`）
- `fields`（処理時間、文字数、モデル名、失敗理由など）

### C. prompts/

`PromptTrace.dump` により保存:

- `*.prompt.txt`: 実際に送信したプロンプト本文
- `*.meta.json`: `stage`, `model`, `context`, `promptChars`, `extra` など

`extra.run_dir` がある場合は、そのrun配下 `prompts/` に保存される。

### D. manual_test_cases.jsonl

`appendManualTestCase` 実行で1行追加:

- run識別情報
- 音声/イベントファイルパス
- `stt_text`, `output_text`, `ground_truth_text`
- `context`
- `accessibility`（取得済みなら）
- `vision_image_file`, `vision_image_mime_type`（取得済みなら）

## 5.4 アクセシビリティ収集の現行仕様

- 録音停止時に `ContextService.captureAccessibility` を実行し、snapshot/contextを取得する。
- 権限未許可でも `accessibility_not_trusted` を含むスナップショットとして記録可能。
- 取得値は debug保存と、後段の文脈合成（LLM入力）に利用される。

## 6. 運用メモ

- デバッグUI (`DebugView`) から run単位の詳細、音声再生、画像確認、プロンプト確認、テストケース追加が可能。
- `PromptTrace` は失敗しても本処理を止めない（ベストエフォート保存）。
- Vision文脈は設定/キー/タイミング条件によりスキップされる場合がある。

---

更新時ルール:

- パイプライン状態、保存形式、`status` 値、出力先パスを変更したら本書を同時更新する。
