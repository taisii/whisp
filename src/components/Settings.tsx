import { useEffect, useMemo, useState } from "react";
import { invoke, isTauri } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { writeText } from "@tauri-apps/plugin-clipboard-manager";

type ApiKeys = {
  deepgram: string;
  gemini: string;
};

type Config = {
  api_keys: ApiKeys;
  shortcut: string;
  auto_paste: boolean;
  input_language: string;
};

type DebugLog = {
  ts_ms: number;
  level: string;
  stage: string;
  message: string;
};

type PipelineResult = {
  stt: string;
  output: string;
};

const emptyConfig: Config = {
  api_keys: { deepgram: "", gemini: "" },
  shortcut: "Cmd+J",
  auto_paste: true,
  input_language: "ja",
};

export default function Settings() {
  const tauriReady = isTauri();
  const [config, setConfig] = useState<Config>(emptyConfig);
  const [status, setStatus] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [pipelineState, setPipelineState] = useState("idle");
  const [logs, setLogs] = useState<DebugLog[]>([]);
  const [lastOutput, setLastOutput] = useState<PipelineResult | null>(null);
  const [playgroundPath, setPlaygroundPath] = useState("");
  const [playgroundResult, setPlaygroundResult] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    if (!tauriReady) {
      setStatus(
        "Tauriで起動していないため設定は保存できません（bun run tauri dev）",
      );
      setLoading(false);
      return () => {
        active = false;
      };
    }
    invoke<Config>("get_config")
      .then((data) => {
        if (!active) return;
        setConfig(data);
      })
      .catch(() => {
        if (!active) return;
        setStatus("設定の読み込みに失敗しました");
      })
      .finally(() => {
        if (active) setLoading(false);
      });
    return () => {
      active = false;
    };
  }, [tauriReady]);

  useEffect(() => {
    if (!tauriReady) return;
    let unlistenState: (() => void) | null = null;
    let unlistenLog: (() => void) | null = null;
    let unlistenOutput: (() => void) | null = null;

    const setup = async () => {
      unlistenState = await listen("pipeline-state", (event) => {
        setPipelineState(String(event.payload ?? "idle"));
      });
      unlistenLog = await listen("debug-log", (event) => {
        const payload = event.payload as DebugLog;
        setLogs((prev) => [payload, ...prev].slice(0, 200));
      });
      unlistenOutput = await listen("pipeline-output", (event) => {
        const payload = event.payload as PipelineResult;
        setLastOutput(payload);
      });
    };

    setup();
    return () => {
      if (unlistenState) unlistenState();
      if (unlistenLog) unlistenLog();
      if (unlistenOutput) unlistenOutput();
    };
  }, [tauriReady]);

  const canSave = useMemo(() => {
    return tauriReady && !loading && !saving;
  }, [loading, saving, tauriReady]);

  const updateApiKey = (key: keyof ApiKeys, value: string) => {
    setConfig((prev) => ({
      ...prev,
      api_keys: { ...prev.api_keys, [key]: value },
    }));
  };

  const save = async () => {
    if (!tauriReady) {
      setStatus("Tauriで起動していないため保存できません");
      return;
    }
    setSaving(true);
    setStatus(null);
    try {
      await invoke("save_config", { config });
      setStatus("保存しました");
    } catch (error) {
      const message =
        typeof error === "string"
          ? error
          : error && typeof error === "object" && "message" in error
            ? String((error as { message?: unknown }).message)
            : "保存に失敗しました";
      setStatus(message);
    } finally {
      setSaving(false);
    }
  };

  const runPlayground = async () => {
    if (!tauriReady) {
      setStatus("Tauriで起動していないため実行できません");
      return;
    }
    setStatus(null);
    setPlaygroundResult(null);
    try {
      const result = await invoke<{ stt: string; output: string }>(
        "process_audio_file",
        { path: playgroundPath },
      );
      setPlaygroundResult(
        `--- STT ---\n${result.stt}\n\n--- OUTPUT ---\n${result.output}`,
      );
    } catch (error) {
      const message =
        typeof error === "string"
          ? error
          : error && typeof error === "object" && "message" in error
            ? String((error as { message?: unknown }).message)
            : "実行に失敗しました";
      setStatus(message);
    }
  };

  const copyOutput = async () => {
    if (!lastOutput || !tauriReady) return;
    try {
      await writeText(lastOutput.output);
      setStatus("出力をクリップボードにコピーしました");
    } catch (error) {
      const message =
        typeof error === "string"
          ? error
          : error && typeof error === "object" && "message" in error
            ? String((error as { message?: unknown }).message)
            : "コピーに失敗しました";
      setStatus(message);
    }
  };

  return (
    <div className="app">
      <header className="hero">
        <div>
          <p className="badge">Whisp</p>
          <h1>声から即座に、整ったテキストへ。</h1>
          <p className="subtitle">
            Option+Spaceで録音を切り替え、完了後にクリップボードへ。句読点とフィラー除去は自動です。
          </p>
        </div>
        <div className="status-panel">
          <p className="status-title">録音状態</p>
          <p className="status-value">メニューバーの色で確認</p>
          <p className="status-hint">赤: 録音中 / グレー: 待機中</p>
        </div>
      </header>

      <section className="card">
        <div className="card-header">
          <h2>設定</h2>
          <p>APIキーとショートカットを登録します。</p>
        </div>

        <div className="grid">
          <label className="field">
            <span>Deepgram APIキー</span>
            <input
              type="password"
              value={config.api_keys.deepgram}
              onChange={(e) => updateApiKey("deepgram", e.target.value)}
              placeholder="dg_..."
              disabled={loading}
            />
          </label>
          <label className="field">
            <span>Gemini APIキー</span>
            <input
              type="password"
              value={config.api_keys.gemini}
              onChange={(e) => updateApiKey("gemini", e.target.value)}
              placeholder="AIza..."
              disabled={loading}
            />
          </label>
          <label className="field">
            <span>ショートカット</span>
            <input
              type="text"
              value={config.shortcut}
              onChange={(e) =>
                setConfig((prev) => ({ ...prev, shortcut: e.target.value }))
              }
              placeholder="Cmd+J"
              disabled={loading}
            />
            <small>例: CmdOrCtrl+Shift+V / Cmd+J</small>
          </label>
          <label className="field">
            <span>入力言語</span>
            <select
              value={config.input_language}
              onChange={(e) =>
                setConfig((prev) => ({
                  ...prev,
                  input_language: e.target.value,
                }))
              }
              disabled={loading}
            >
              <option value="ja">日本語</option>
              <option value="en">English</option>
              <option value="auto">自動判定</option>
            </select>
            <small>Deepgramと後処理の言語を指定します。</small>
          </label>
          <label className="field toggle">
            <span>自動ペースト</span>
            <input
              type="checkbox"
              checked={config.auto_paste}
              onChange={(e) =>
                setConfig((prev) => ({
                  ...prev,
                  auto_paste: e.target.checked,
                }))
              }
              disabled={loading}
            />
            <small>ONで変換後にCmd+Vを送信します。</small>
          </label>
        </div>

        <div className="actions">
          <button onClick={save} disabled={!canSave}>
            {saving ? "保存中..." : "保存"}
          </button>
          <button
            className="ghost"
            onClick={() => invoke("open_microphone_settings")}
            disabled={loading || !tauriReady}
          >
            マイク設定を開く
          </button>
          <button
            className="ghost"
            onClick={() => invoke("open_accessibility_settings")}
            disabled={loading || !tauriReady}
          >
            アクセシビリティ設定を開く
          </button>
        </div>
        {status ? <p className="status-message">{status}</p> : null}
      </section>

      <section className="card">
        <div className="card-header">
          <h2>デバッグ</h2>
          <p>現在の状態とログを可視化します。</p>
        </div>
        <div className="debug-grid">
          <div className="debug-panel">
            <p className="debug-label">パイプライン状態</p>
            <p className="debug-value">{pipelineState}</p>
          </div>
          <div className="debug-panel">
            <p className="debug-label">ログ</p>
            <div className="log-list">
              {logs.length === 0 ? (
                <p className="log-empty">まだログがありません</p>
              ) : (
                logs.map((log, idx) => (
                  <div className="log-item" key={`${log.ts_ms}-${idx}`}>
                    <span>
                      {new Date(log.ts_ms).toLocaleTimeString()} [{log.level}]
                      [{log.stage}] {log.message}
                    </span>
                  </div>
                ))
              )}
            </div>
          </div>
          <div className="debug-panel">
            <p className="debug-label">最新の出力</p>
            {lastOutput ? (
              <div className="output-panel">
                <pre>{lastOutput.output}</pre>
                <button className="ghost" onClick={copyOutput}>
                  出力をコピー
                </button>
              </div>
            ) : (
              <p className="log-empty">まだ出力がありません</p>
            )}
          </div>
        </div>

        <div className="playground">
          <p className="debug-label">統合プレイグラウンド（WAV 16-bit PCM）</p>
          <input
            type="text"
            placeholder="/path/to/audio.wav"
            value={playgroundPath}
            onChange={(e) => setPlaygroundPath(e.target.value)}
            disabled={!tauriReady}
          />
          <button
            className="ghost"
            onClick={runPlayground}
            disabled={!tauriReady || playgroundPath.trim().length === 0}
          >
            ファイルでテスト実行
          </button>
          {playgroundResult ? (
            <pre className="playground-result">{playgroundResult}</pre>
          ) : null}
        </div>
      </section>
    </div>
  );
}
