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
                │   ├── input_stt.txt
                │   ├── prompt_generation.txt                 (single candidate generation)
                │   ├── output_generation.txt                 (single candidate generation)
                │   ├── prompt_generation_a.txt               (pairwise generation)
                │   ├── output_generation_a.txt               (pairwise generation)
                │   ├── prompt_generation_b.txt               (pairwise generation)
                │   ├── output_generation_b.txt               (pairwise generation)
                │   ├── prompt_pairwise_round1.txt            (pairwise generation)
                │   ├── prompt_pairwise_round2.txt            (pairwise generation)
                │   ├── pairwise_round1_response.json         (pairwise generation)
                │   ├── pairwise_round2_response.json         (pairwise generation)
                │   ├── pairwise_decision.json                (pairwise generation)
                │   └── reference.txt
                └── artifacts/
                    └── error.json (必要時のみ)
```

## Candidate (`BenchmarkCandidate`)

比較対象の定義。1 candidate は「モデル + 設定 + generation prompt」を表す。

- `id`: candidate_id
- `task`: `stt|generation|vision`（比較UI phase1 は `stt|generation`）
- `model`: 例 `deepgram_stream`, `apple_speech_recognizer_stream`, `apple_speech_analyzer_stream`, `gemini-2.5-flash-lite`, `gpt-5-nano`
- `promptName`: generation 用の表示名（任意）
- `generationPromptTemplate`: generation 用のプロンプト本文（generation では必須）
- `generationPromptHash`: `sha256("prompt-v1|<canonical_prompt>")`
- `options`: 実行オプション文字列辞書（`chunk_ms`, `silence_ms`, `max_segment_ms`, `pre_roll_ms`, `realtime`, `require_context` など）
  - STT の実行モードは `model`（`STTPresetID`）で固定される

### Generation プロンプト変数（candidate内包テンプレート）

`generationPromptTemplate` では次の変数を使用できる。

- `{STT結果}`: `stt_text`
- `{選択テキスト}`: `context.accessibilityText`
- `{画面テキスト}`: `context.windowText`
- `{画面要約}`: `context.visionSummary`
- `{専門用語候補}`: `context.visionTerms` を `", "` で連結

欠損値は空文字で置換する。case 実行は失敗させない。
`{STT結果}` がテンプレートに無い場合は互換のため末尾に `入力: <stt_text>` を追記する。
テンプレート内に context 系変数（`{選択テキスト}` など）が含まれる場合、重複防止のため `画面コンテキスト:` の自動追記は行わない。

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

- `schemaVersion`: `5`
- `id`, `kind`, `status`, `createdAt`, `updatedAt`
- `options`: 実行条件（`sourceCasesPath`, `sttMode`, `chunkMs`, `useCache`, `llmEval...` など）
  - 比較メタも保持: `datasetHash`, `runtimeOptionsHash`, `candidateID`, `promptName`, `generationPromptHash`, `evaluatorVersion`, `codeVersion`
  - generation pairwise 時は `compareMode=pairwise`, `pairCandidateAID`, `pairCandidateBID`, `pairJudgeModel` を保持
- `candidateID`: run が属する candidate
- `benchmarkKey`: 比較キー
- `metrics`: 品質・レイテンシ集計の正本（generation pairwise 時は `pairwiseSummary` を保持）
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
  - generation pairwise 時は `metrics.pairwise` に `overall/intent/hallucination/style_context` の winner と理由を保存

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

`manual_test_cases.jsonl` の `accessibility`（`AccessibilitySnapshot`）は保存されるが、現時点では generation プロンプト変数の入力には利用しない（将来拡張予定）。

## Generation compare モード

- `--benchmark-compare --task generation` は pairwise 専用。
- `--candidate-id` は常に2件（A/B）必須。
- judge モデルは `--judge-model` で指定し、未指定時は `Config.llmModel` を使用。
- 判定軸は `intent` / `hallucination` / `style_context` の3軸。
- 判定は A→B と B→A の2回を実行し、軸ごとに一致した winner を採用。不一致は `tie`。
- `overall_winner` は3軸多数決。同数は `tie`。

## CLI 主要コマンド

- `--benchmark-compare --task stt --cases <path> --candidate-id <id> [--candidate-id <id> ...] [--force]`
- `--benchmark-compare --task generation --cases <path> --candidate-id <A> --candidate-id <B> [--judge-model <model>] [--force]`
- `--benchmark-list-candidates`
- `--benchmark-scan-integrity --task <stt|generation> --cases <path>`
- `--benchmark-workers <N>`（case並列数。未指定は `min(4, CPUコア数)`）
