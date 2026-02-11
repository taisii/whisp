# Benchmark Data Model

ベンチマーク閲覧用の保存形式。`Run` と `Case` を分離し、
さらに `events.jsonl` + `artifacts/` で Full raw を保持する。

## 保存先

- run manifest: `~/.config/whisp/debug/benchmarks/runs/<run_id>/manifest.json`
- case rows: `~/.config/whisp/debug/benchmarks/runs/<run_id>/cases.jsonl`
- case events: `~/.config/whisp/debug/benchmarks/runs/<run_id>/events.jsonl`
- artifacts: `~/.config/whisp/debug/benchmarks/runs/<run_id>/artifacts/...`

## Run (`BenchmarkRunRecord`)

- 目的: 一覧表示と集計表示の高速化
- 主な項目:
  - `id`, `kind`, `status`, `createdAt`, `updatedAt`
  - `options`（実行条件）
  - `metrics`（集計値）
  - `paths`（元ログ/summary + 正規化後 cases/events/artifacts パス）
- `schemaVersion`: `2`

## Case (`BenchmarkCaseResult`)

- 目的: Case一覧表示
- 主な項目:
  - `id`, `status`, `reason`
  - `cache`（`hit`, `key`, `namespace`, `keyMaterialRef`）
  - `sources`（transcript/input/reference/intent）
  - `metrics`（CER, intent, latency など）

## Event (`BenchmarkCaseEvent`)

- 目的: 再現性・監査・再集計
- 共通項目:
  - `run_id`, `case_id`, `stage`, `status`
  - `started_at_ms`, `ended_at_ms`, `recorded_at_ms`
  - `attrs`（stage固有の厳密型）
- stage:
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

大きい本文は JSON に埋め込まず、参照で持つ。

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
- legacy row / summary raw

## 既存CLIログとの併存

- 既存の `rows/summary` は削除しない
- 実行後に importer で `BenchmarkStore` へ正規化保存する
- UIは `BenchmarkStore` の `Run/Case/Event/Artifact` を表示する
