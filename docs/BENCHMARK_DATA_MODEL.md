# Benchmark Data Model

ベンチマークは「比較で意思決定するためのデータ」を保存する。
運用統計（録音件数や日次平均など）は
`~/.config/whisp/debug/stats/runtime_stats.json` に分離する。

## 保存先

```text
~/.config/whisp/debug/benchmarks/
├── candidates/
│   └── candidates.json
├── integrity/
│   ├── exclusions.json
│   ├── issues_stt.json
│   └── issues_generation.json
├── runs/
│   └── <run_id>/
│       ├── manifest.json
│       ├── orchestrator_events.jsonl
│       ├── cases_index.jsonl
│       └── cases/
│           └── <case_id>/
│               ├── manifest.json
│               ├── metrics.json
│               ├── events.jsonl
│               ├── io/
│               │   ├── input_stt.txt
│               │   ├── output_stt.txt
│               │   ├── output_generation.txt
│               │   └── reference.txt
│               └── artifacts/
│                   └── error.json (必要時のみ)
```

## Candidate (`BenchmarkCandidate`)

比較対象の定義。1 candidate は「モデル + 設定 + prompt profile」を表す。

- `id`: candidate_id
- `task`: `stt|generation|vision`（比較UI phase1 は `stt|generation`）
- `model`: 例 `deepgram`, `apple_speech`, `gemini-2.5-flash-lite`, `gpt-5-nano`
- `promptProfileID`: generation 用（任意）
- `options`: 実行オプション文字列辞書（`chunk_ms`, `realtime`, `require_context` など）
  - STT では `whisper` / `apple_speech` は `stt_mode=rest` のみ対応

## BenchmarkKey (`BenchmarkKey`)

比較セルを一意に識別するキー。

- `task`
- `datasetPath`
- `datasetHash`
- `candidateID`
- `runtimeOptionsHash`
- `evaluatorVersion`
- `codeVersion`

同一 `BenchmarkKey` の成功 run が存在する場合、`--benchmark-compare` は再実行をスキップできる（`--force` 除く）。

## Run (`BenchmarkRunRecord`)

- `schemaVersion`: `4`
- `id`, `kind`, `status`, `createdAt`, `updatedAt`
- `options`: 実行条件（`sourceCasesPath`, `sttMode`, `chunkMs`, `useCache`, `llmEval...` など）
  - 比較メタも保持: `datasetHash`, `runtimeOptionsHash`, `candidateID`, `evaluatorVersion`, `codeVersion`
- `candidateID`: run が属する candidate
- `benchmarkKey`: 比較キー
- `metrics`: 品質・レイテンシ集計の正本
- `paths`: `manifest/orchestrator_events/cases_index/cases_directory` のパス

## Run配下ファイル

- `manifest.json`: run全体メタデータと集計メトリクスの正本
- `orchestrator_events.jsonl`: runオーケストレーターの進捗（キュー投入/開始/完了/失敗）
- `cases_index.jsonl`: UI一覧向けのケース単位軽量行（1行1JSON）

## Case配下ファイル

- `cases/<case_id>/manifest.json`: ケースの身分情報（status/reason/source名/audio参照/context有無）
- `cases/<case_id>/metrics.json`: ケース詳細メトリクスの正本
- `cases/<case_id>/events.jsonl`: ケース処理イベント時系列
- `cases/<case_id>/io/*.txt`: 入出力テキストの保存（必要なもののみ）
- `cases/<case_id>/artifacts/*`: ケース固有の追加成果物（必要時のみ）

## Case (`BenchmarkCaseResult`)

- `id`, `status`, `reason`
- `cache`: `hit`, `key`, `namespace`
- `sources`: 参照元（`transcript/input/reference/intent`）
- `metrics`: `cer`, `exactMatch`, `sttTotalMs`, `postMs`, `totalAfterStopMs` など

## Event (`BenchmarkCaseEvent`)

ケースイベントは `cases/<case_id>/events.jsonl` に保存する。

- 共通: `run_id`, `case_id`, `stage`, `status`, `started_at_ms`, `ended_at_ms`, `recorded_at_ms`
- `stage`: `load_case | stt | context | generation | judge | aggregate | cache | error | artifact_write_failed`

## Orchestrator Event (`BenchmarkOrchestratorEvent`)

run全体イベントは `orchestrator_events.jsonl` に保存する。

- 共通: `run_id`, `case_id?`, `stage`, `status`, `recorded_at_ms`, `attrs`
- `stage`: `run_start | case_queued | case_started | case_finished | case_failed | run_completed | run_failed | run_cancelled`

## Integrity (`BenchmarkIntegrityIssue`)

ケース不備の検出結果。

- `id`: `task + case_id + issue_type` ハッシュ
- `caseID`
- `task`
- `issueType`: 例 `missing_stt_text`, `missing_audio_file`, `missing_reference`
- `missingFields`
- `sourcePath`
- `excluded`
- `detectedAt`

`exclusions.json` で除外状態を永続化する。

## Generation 入力ポリシー

`generation` は `stt_text` を必須とする。

- `stt_text` が空/欠落: `skipped_missing_input_stt`
- `labels.transcript_gold/silver` へのフォールバックは行わない

## CLI 主要コマンド

- `--benchmark-compare --task <stt|generation> --cases <path> --candidate-id <id> [--force]`
- `--benchmark-list-candidates`
- `--benchmark-scan-integrity --task <stt|generation> --cases <path>`
- `--benchmark-workers <N>`（case並列数。未指定は `min(4, CPUコア数)`）
