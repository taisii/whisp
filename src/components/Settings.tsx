import { useEffect, useMemo, useState } from "react";
import { invoke, isTauri } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { buildShortcutString, formatShortcutDisplay } from "@/lib/shortcut";
import type { UsageSummary } from "@/types/usage";

type ApiKeys = {
  deepgram: string;
  gemini: string;
  openai: string;
};

type RecordingMode = "toggle" | "push_to_talk";

type LlmModel = "gemini-2.5-flash-lite" | "gemini-2.5-flash-lite-audio" | "gpt-4o-mini" | "gpt-5-nano";

type AppPromptRule = {
  app_name: string;
  template: string;
};

type Config = {
  api_keys: ApiKeys;
  shortcut: string;
  auto_paste: boolean;
  avoid_clipboard_history: boolean;
  input_language: string;
  recording_mode: RecordingMode;
  known_apps: string[];
  app_prompt_rules: AppPromptRule[];
  llm_model: LlmModel;
};

type DebugLog = {
  ts_ms: number;
  level: string;
  stage: string;
  message: string;
};

const DEFAULT_PROMPT_TEMPLATE = `以下の音声認識結果を修正してください。修正後のテキストのみを出力してください。

修正ルール:
1. フィラー（えーと、あのー、えー、なんか、こう、まあ、ちょっと）を除去
2. 技術用語の誤認識を修正（例: "リアクト"→"React", "ユーズステート"→"useState"）
3. 句読点を適切に追加
4. 出力は{言語}にしてください

入力: {STT結果}`;

const emptyConfig: Config = {
  api_keys: { deepgram: "", gemini: "", openai: "" },
  shortcut: "Cmd+J",
  auto_paste: true,
  avoid_clipboard_history: true,
  input_language: "ja",
  recording_mode: "toggle",
  known_apps: [],
  app_prompt_rules: [],
  llm_model: "gemini-2.5-flash-lite",
};

function formatCost(usd: number): string {
  if (usd < 0.01) {
    return `$${usd.toFixed(4)}`;
  }
  return `$${usd.toFixed(2)}`;
}

function formatDuration(seconds: number): string {
  if (seconds < 60) {
    return `${seconds.toFixed(1)}秒`;
  }
  const rounded = Math.round(seconds);
  const minutes = Math.floor(rounded / 60);
  const remaining = rounded % 60;
  return `${minutes}分${remaining}秒`;
}

export default function Settings() {
  const tauriReady = isTauri();
  const [config, setConfig] = useState<Config>(emptyConfig);
  const [status, setStatus] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [pipelineState, setPipelineState] = useState("idle");
  const [logs, setLogs] = useState<DebugLog[]>([]);
  const [captureActive, setCaptureActive] = useState(false);
  const [shortcutHint, setShortcutHint] = useState<string | null>(null);
  const [selectedApp, setSelectedApp] = useState<string | null>(null);
  const [usageSummary, setUsageSummary] = useState<UsageSummary | null>(null);

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
    let unlistenConfig: (() => void) | null = null;
    let unlistenUsage: (() => void) | null = null;

    const setup = async () => {
      unlistenState = await listen("pipeline-state", (event) => {
        setPipelineState(String(event.payload ?? "idle"));
      });
      unlistenLog = await listen("debug-log", (event) => {
        const payload = event.payload as DebugLog;
        setLogs((prev) => [payload, ...prev].slice(0, 200));
      });
      unlistenConfig = await listen("config-updated", (event) => {
        const payload = event.payload as Config;
        setConfig(payload);
      });
      unlistenUsage = await listen("usage-metrics", (_event) => {
        invoke<UsageSummary>("get_usage_summary")
          .then(setUsageSummary)
          .catch(() => {});
      });
    };

    setup();
    return () => {
      if (unlistenState) unlistenState();
      if (unlistenLog) unlistenLog();
      if (unlistenConfig) unlistenConfig();
      if (unlistenUsage) unlistenUsage();
    };
  }, [tauriReady]);

  useEffect(() => {
    if (!tauriReady) return;
    invoke<UsageSummary>("get_usage_summary")
      .then(setUsageSummary)
      .catch(() => {});
  }, [tauriReady]);

  useEffect(() => {
    if (!captureActive) return;

    const handleKeyDown = (event: KeyboardEvent) => {
      event.preventDefault();
      event.stopPropagation();

      if (event.key === "Escape") {
        setCaptureActive(false);
        setShortcutHint("ショートカットの変更をキャンセルしました");
        return;
      }

      const shortcut = buildShortcutString({
        key: event.key,
        metaKey: event.metaKey,
        ctrlKey: event.ctrlKey,
        altKey: event.altKey,
        shiftKey: event.shiftKey,
      });

      if (!shortcut) {
        setShortcutHint("修飾キー（Cmd/Ctrl/Alt/Shift）+ 通常キーを入力してください");
        return;
      }

      setConfig((prev) => ({ ...prev, shortcut }));
      setCaptureActive(false);
      setShortcutHint(`ショートカットを ${formatShortcutDisplay(shortcut)} に変更しました`);
    };

    window.addEventListener("keydown", handleKeyDown, true);
    return () => {
      window.removeEventListener("keydown", handleKeyDown, true);
    };
  }, [captureActive]);

  const canSave = useMemo(() => {
    return tauriReady && !loading && !saving;
  }, [loading, saving, tauriReady]);

  const updateApiKey = (key: keyof ApiKeys, value: string) => {
    setConfig((prev) => ({
      ...prev,
      api_keys: { ...prev.api_keys, [key]: value },
    }));
  };

  const appPromptMap = useMemo(() => {
    const map = new Map<string, AppPromptRule>();
    for (const rule of config.app_prompt_rules) {
      const key = rule.app_name.trim();
      if (!key) continue;
      if (!map.has(key)) {
        map.set(key, rule);
      }
    }
    return map;
  }, [config.app_prompt_rules]);

  const knownApps = useMemo(() => {
    const names = new Map<string, string>();
    const add = (value: string) => {
      const trimmed = value.trim();
      if (!trimmed) return;
      if (!names.has(trimmed)) {
        names.set(trimmed, trimmed);
      }
    };
    config.known_apps.forEach(add);
    return Array.from(names.values()).sort((a, b) =>
      a.localeCompare(b, "en", { sensitivity: "base" }),
    );
  }, [config.known_apps]);

  useEffect(() => {
    if (knownApps.length === 0) {
      setSelectedApp(null);
      return;
    }
    if (!selectedApp || !knownApps.includes(selectedApp)) {
      setSelectedApp(knownApps[0]);
    }
  }, [knownApps, selectedApp]);

  const updateAppPrompt = (appName: string, value: string) => {
    const trimmed = appName.trim();
    if (!trimmed) return;
    setConfig((prev) => {
      const nextRules = prev.app_prompt_rules.filter(
        (rule) => rule.app_name.trim() !== trimmed,
      );
      const template = value.trim();
      if (template) {
        nextRules.push({ app_name: trimmed, template: value });
      }
      return { ...prev, app_prompt_rules: nextRules };
    });
  };

  const selectedTemplate = useMemo(() => {
    if (!selectedApp) return "";
    const rule = appPromptMap.get(selectedApp);
    return rule?.template ?? DEFAULT_PROMPT_TEMPLATE;
  }, [appPromptMap, selectedApp]);

  const hasCustomTemplate = selectedApp
    ? appPromptMap.has(selectedApp)
    : false;

  const removeKnownApp = (appName: string) => {
    const trimmed = appName.trim();
    if (!trimmed) return;
    setConfig((prev) => ({
      ...prev,
      known_apps: prev.known_apps.filter((name) => name.trim() !== trimmed),
      app_prompt_rules: prev.app_prompt_rules.filter(
        (rule) => rule.app_name.trim() !== trimmed,
      ),
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


  return (
    <div className="app">
      <header className="hero">
        <div>
          <p className="badge">Whisp</p>
          <h1>声から即座に、整ったテキストへ。</h1>
          <p className="subtitle">
            ショートカットで録音を切り替え、完了後にクリップボードへ。句読点とフィラー除去は自動です。
          </p>
          <div className="meta-row">
            <span>現在のショートカット: {formatShortcutDisplay(config.shortcut)}</span>
            <span>入力言語: {config.input_language.toUpperCase()}</span>
          </div>
        </div>
        <div className="status-panel">
          <p className="status-title">録音状態</p>
          <p className="status-value">メニューバーの色で確認できます。</p>
          <p className="status-hint">赤: 録音中 / グレー: 待機中</p>
          <div className="status-panel-line">
            <p className="status-title">パイプライン</p>
            <p className="status-value">{pipelineState}</p>
          </div>
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
            <span>OpenAI APIキー</span>
            <input
              type="password"
              value={config.api_keys.openai}
              onChange={(e) => updateApiKey("openai", e.target.value)}
              placeholder="sk-..."
              disabled={loading}
            />
          </label>
          <div className="field">
            <span>ショートカット</span>
            <div className="shortcut-row">
              <input type="text" value={config.shortcut} readOnly />
              <button
                className="ghost"
                onClick={() => {
                  setShortcutHint(null);
                  setCaptureActive((prev) => !prev);
                }}
                disabled={loading}
              >
                {captureActive ? "キーを押してください..." : "ショートカットを変更"}
              </button>
              {captureActive ? (
                <button
                  className="ghost"
                  onClick={() => {
                    setCaptureActive(false);
                    setShortcutHint("ショートカットの変更をキャンセルしました");
                  }}
                  disabled={loading}
                >
                  キャンセル
                </button>
              ) : null}
            </div>
            <small>
              修飾キー（Cmd/Ctrl/Alt/Shift）+ 通常キーの組み合わせが必須です。
            </small>
            {shortcutHint ? (
              <small className="shortcut-hint">{shortcutHint}</small>
            ) : null}
          </div>
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
          <label className="field">
            <span>LLMモデル</span>
            <select
              value={config.llm_model}
              onChange={(e) =>
                setConfig((prev) => ({
                  ...prev,
                  llm_model: e.target.value as LlmModel,
                }))
              }
              disabled={loading}
            >
              <option value="gemini-2.5-flash-lite">Gemini 2.5 Flash Lite</option>
              <option value="gemini-2.5-flash-lite-audio">Gemini 2.5 Flash Lite（音声直接入力）</option>
              <option value="gpt-4o-mini">GPT-4o mini</option>
              <option value="gpt-5-nano">GPT-5 nano</option>
            </select>
            <small>モデルに応じたAPIキーが必要です。</small>
          </label>
          <label className="field">
            <span>録音モード</span>
            <select
              value={config.recording_mode}
              onChange={(e) =>
                setConfig((prev) => ({
                  ...prev,
                  recording_mode: e.target.value as RecordingMode,
                }))
              }
              disabled={loading}
            >
              <option value="toggle">トグル（押すたびに開始/停止）</option>
              <option value="push_to_talk">長押し（押下中のみ録音）</option>
            </select>
            <small>長押しはアクセシビリティ許可が必要です。</small>
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
          {config.auto_paste ? (
            <label className="field toggle">
              <span>クリップボード履歴を汚染しない</span>
              <input
                type="checkbox"
                checked={config.avoid_clipboard_history}
                onChange={(e) =>
                  setConfig((prev) => ({
                    ...prev,
                    avoid_clipboard_history: e.target.checked,
                  }))
                }
                disabled={loading}
              />
              <small>履歴アプリに残らないようマーカーを付与します。</small>
            </label>
          ) : null}
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
          <h2>アプリ別プロンプト</h2>
          <p>
            アプリごとに完全なテンプレートを設定します（{`{STT結果}`} /
            {`{言語}`}）。
          </p>
        </div>
        {knownApps.length === 0 ? (
          <p className="context-empty">履歴にアプリがありません</p>
        ) : (
          <div className="app-prompt-layout">
            <div className="app-list">
              {knownApps.map((appName) => (
                <button
                  key={`app-${appName}`}
                  className={`ghost ${selectedApp === appName ? "active" : ""}`}
                  onClick={() => setSelectedApp(appName)}
                  disabled={loading}
                >
                  {appName}
                </button>
              ))}
              {selectedApp ? (
                <button
                  className="ghost"
                  onClick={() => removeKnownApp(selectedApp)}
                  disabled={loading}
                >
                  履歴から削除
                </button>
              ) : null}
            </div>
            <div className="prompt-body">
              <textarea
                value={selectedTemplate}
                onChange={(e) => {
                  if (!selectedApp) return;
                  updateAppPrompt(selectedApp, e.target.value);
                }}
                disabled={loading || !selectedApp}
                rows={10}
              />
              <small>{`{STT結果}`}が含まれない場合、末尾に入力を自動追加します。</small>
              <div className="prompt-actions">
                <button
                  className="ghost"
                  onClick={() => {
                    if (!selectedApp) return;
                    updateAppPrompt(selectedApp, "");
                  }}
                  disabled={loading || !selectedApp || !hasCustomTemplate}
                >
                  デフォルトに戻す
                </button>
              </div>
            </div>
          </div>
        )}
      </section>

      <section className="card">
        <div className="card-header">
          <h2>API利用状況</h2>
          <p>APIの使用量と推定コストを表示します。</p>
        </div>
        {usageSummary ? (
          <div className="usage-grid">
            <div className="usage-panel">
              <p className="usage-label">今日の利用</p>
              <div className="usage-details">
                <div className="usage-row">
                  <span>Deepgram (STT)</span>
                  <span>
                    {formatDuration(usageSummary.today.deepgramSeconds)} /{" "}
                    {formatCost(usageSummary.today.deepgramCostUsd)}
                  </span>
                </div>
                {usageSummary.today.geminiTokens > 0 && (
                  <div className="usage-row">
                    <span>Gemini</span>
                    <span>
                      {usageSummary.today.geminiTokens.toLocaleString()} tokens /{" "}
                      {formatCost(usageSummary.today.geminiCostUsd)}
                    </span>
                  </div>
                )}
                {usageSummary.today.openaiTokens > 0 && (
                  <div className="usage-row">
                    <span>OpenAI</span>
                    <span>
                      {usageSummary.today.openaiTokens.toLocaleString()} tokens /{" "}
                      {formatCost(usageSummary.today.openaiCostUsd)}
                    </span>
                  </div>
                )}
                <div className="usage-row usage-total">
                  <span>合計</span>
                  <span>{formatCost(usageSummary.today.totalCostUsd)}</span>
                </div>
              </div>
            </div>
            <div className="usage-panel">
              <p className="usage-label">今月の利用</p>
              <div className="usage-details">
                <div className="usage-row">
                  <span>Deepgram (STT)</span>
                  <span>
                    {formatDuration(usageSummary.this_month.deepgramSeconds)} /{" "}
                    {formatCost(usageSummary.this_month.deepgramCostUsd)}
                  </span>
                </div>
                {usageSummary.this_month.geminiTokens > 0 && (
                  <div className="usage-row">
                    <span>Gemini</span>
                    <span>
                      {usageSummary.this_month.geminiTokens.toLocaleString()} tokens /{" "}
                      {formatCost(usageSummary.this_month.geminiCostUsd)}
                    </span>
                  </div>
                )}
                {usageSummary.this_month.openaiTokens > 0 && (
                  <div className="usage-row">
                    <span>OpenAI</span>
                    <span>
                      {usageSummary.this_month.openaiTokens.toLocaleString()} tokens /{" "}
                      {formatCost(usageSummary.this_month.openaiCostUsd)}
                    </span>
                  </div>
                )}
                <div className="usage-row usage-total">
                  <span>合計</span>
                  <span>{formatCost(usageSummary.this_month.totalCostUsd)}</span>
                </div>
              </div>
            </div>
          </div>
        ) : (
          <p className="usage-empty">利用データがありません</p>
        )}
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
        </div>
      </section>
    </div>
  );
}
