# Benchmark Data Model

ベンチマーク専用の保存形式。運用統計（実録音件数や平均処理時間）は別ストア
`~/.config/whisp/debug/stats/runtime_stats.json` に分離している。

## 保存先

- run manifest: `~/.config/whisp/debug/benchmarks/runs/<run_id>/manifest.json`
- case rows: `~/.config/whisp/debug/benchmarks/runs/<run_id>/cases.jsonl`
- case events: `~/.config/whisp/debug/benchmarks/runs/<run_id>/events.jsonl`
- artifacts: `~/.config/whisp/debug/benchmarks/runs/<run_id>/artifacts/...`

## Run (`BenchmarkRunRecord`)

- 目的: 実験条件と性能結果の管理
- `schemaVersion`: `2`
- 主項目:
  - `id`, `kind`, `status`, `createdAt`, `updatedAt`
  - `options`:
    - 実行条件（`sttMode`, `chunkMs`, `requireContext`, `useCache` など）
    - LLM評価設定（`llmEvalEnabled`, `llmEvalModel`）
  - `metrics`:
    - 品質: `exactMatchRate`, `avgCER`, `weightedCER`, `avgTermsF1`,
      `intentMatchRate`, `intentPreservationScore`, `hallucinationScore`, `hallucinationRate`
    - レイテンシ分布: `latencyMs`, `afterStopLatencyMs`, `postLatencyMs`, `totalAfterStopLatencyMs`
      （各分布は `avg/p50/p95/p99`）
  - `paths`: 正規化済み `cases/events/artifacts` と元ログのパス

### Percentile 定義

`p50/p95/p99` は `WhispCLI+Utils.percentile` で算出する。

- 入力値を昇順ソート
- rank = `(percentile / 100) * (n - 1)`
- 線形補間で値を求める（lower/upper間）

## Case (`BenchmarkCaseResult`)

- 目的: ケース単位の再現と比較
- 主項目:
  - `id`, `status`, `reason`
  - `cache`（`hit`, `key`, `namespace`, `keyMaterialRef`）
  - `sources`（`transcript`, `input`, `reference`, `intent`）
  - `metrics`:
    - 品質: `exactMatch`, `cer`, `termPrecision/Recall/F1`, `intentMatch`, `intentScore`
    - LLM評価: `intentPreservationScore`, `hallucinationScore`, `hallucinationRate`
    - レイテンシ: `sttTotalMs`, `sttAfterStopMs`, `postMs`, `totalAfterStopMs`, `latencyMs`

## Event (`BenchmarkCaseEvent`)

- 目的: 再現性・監査・再集計
- 共通項目:
  - `run_id`, `case_id`, `stage`, `status`
  - `started_at_ms`, `ended_at_ms`, `recorded_at_ms`
  - `attrs`（stage固有の厳密型）
- `stage`:
  - `load_case`
  - `stt`
  - `context`
  - `generation`
  - `judge`
  - `aggregate`
  - `cache`
  - `error`
  - `artifact_write_failed`

## Artifact (`BenchmarkArtifactRef`)

本文をJSONに埋め込まず参照で保持する。

- `relativePath`
- `mimeType`
- `sha256`
- `bytes`
- `maskRuleID`（任意）

対象例:

- prompt / response
- judge request / response
- raw provider response
- cache key material
- summary / row raw

## CLI summary 取り込み方針（完全切替）

- importerは現行スキーマのみ厳密decodeする。
- `kind=stt|vision|generation` は `ComponentSummaryLog` 形式を読む。
- `kind=e2e` は `ManualBenchmarkSummaryLog` 形式を読む。
- 旧キーfallback（例: `sttTotalMs` を `latencyMs` として読む等）は行わない。
- decode不能な旧形式は `BenchmarkStore.listRuns` で一覧対象外（スキップ）になる。
