import { useEffect, useMemo, useState } from "react";
import { invoke, isTauri } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { buildShortcutString, formatShortcutDisplay } from "@/lib/shortcut";
import type { UsageSummary } from "@/types/usage";
import {
  Key,
  Mic,
  ClipboardCopy,
  AppWindow,
  BarChart3,
  Bug,
  Save,
  Settings as SettingsIcon,
  Accessibility,
  ChevronDown,
  ChevronUp,
  Loader2,
  Circle,
  CheckCircle2,
  Radio,
  Sparkles,
  X,
} from "lucide-react";

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
1. フィラー（えーと、あのー）を除去
2. 技術用語の誤認識を修正（例: "リアクト"→"React", "ユーズステート"→"useState"）

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

type PipelineStateInfo = {
  label: string;
  color: string;
  icon: React.ReactNode;
};

function getPipelineStateInfo(state: string): PipelineStateInfo {
  switch (state.toLowerCase()) {
    case "idle":
      return { label: "待機中", color: "var(--state-idle)", icon: <Circle size={14} /> };
    case "recording":
      return { label: "録音中", color: "var(--state-recording)", icon: <Radio size={14} /> };
    case "stt_streaming":
    case "sttstreaming":
      return { label: "文字起こし中", color: "var(--state-processing)", icon: <Loader2 size={14} className="animate-spin" /> };
    case "post_processing":
    case "postprocessing":
      return { label: "後処理中", color: "var(--state-processing)", icon: <Sparkles size={14} /> };
    case "clipboard":
      return { label: "クリップボード", color: "var(--state-success)", icon: <ClipboardCopy size={14} /> };
    case "done":
      return { label: "完了", color: "var(--state-success)", icon: <CheckCircle2 size={14} /> };
    default:
      return { label: state, color: "var(--state-idle)", icon: <Circle size={14} /> };
  }
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
  const [debugExpanded, setDebugExpanded] = useState(false);

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
        setShortcutHint("修飾キー + 通常キーを入力してください");
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

  const pipelineInfo = getPipelineStateInfo(pipelineState);

  return (
    <div className="app">
      <header className="hero">
        <div>
          <p className="badge">Whisp</p>
          <h1>声から即座に、整ったテキストへ。</h1>
          <p className="subtitle">
            ショートカットで録音を切り替え、完了後にクリップボードへ。
          </p>
          <div className="meta-row">
            <span>{formatShortcutDisplay(config.shortcut)}</span>
            <span>{config.input_language.toUpperCase()}</span>
          </div>
        </div>
        <div className="status-panel">
          <div className="pipeline-status" style={{ "--pipeline-color": pipelineInfo.color } as React.CSSProperties}>
            <span className="pipeline-icon">{pipelineInfo.icon}</span>
            <span className="pipeline-label">{pipelineInfo.label}</span>
          </div>
        </div>
      </header>

      {/* Settings Card */}
      <section className="card">
        <div className="card-header">
          <div className="card-title-row">
            <SettingsIcon size={20} />
            <h2>設定</h2>
          </div>
        </div>

        {/* Auth Section */}
        <div className="settings-section">
          <div className="section-header">
            <Key size={16} />
            <span>認証</span>
          </div>
          <div className="section-content">
            <label className="field">
              <span>Deepgram</span>
              <input
                type="password"
                value={config.api_keys.deepgram}
                onChange={(e) => updateApiKey("deepgram", e.target.value)}
                placeholder="dg_..."
                disabled={loading}
              />
            </label>
            <label className="field">
              <span>Gemini</span>
              <input
                type="password"
                value={config.api_keys.gemini}
                onChange={(e) => updateApiKey("gemini", e.target.value)}
                placeholder="AIza..."
                disabled={loading}
              />
            </label>
            <label className="field">
              <span>OpenAI</span>
              <input
                type="password"
                value={config.api_keys.openai}
                onChange={(e) => updateApiKey("openai", e.target.value)}
                placeholder="sk-..."
                disabled={loading}
              />
            </label>
          </div>
        </div>

        {/* Input Section */}
        <div className="settings-section">
          <div className="section-header">
            <Mic size={16} />
            <span>入力</span>
          </div>
          <div className="section-content">
            <div className="field">
              <span>ショートカット</span>
              <div className="shortcut-row">
                <input type="text" value={formatShortcutDisplay(config.shortcut)} readOnly />
                <button
                  className="ghost icon-button"
                  onClick={() => {
                    setShortcutHint(null);
                    setCaptureActive((prev) => !prev);
                  }}
                  disabled={loading}
                >
                  {captureActive ? "キーを押す..." : "変更"}
                </button>
                {captureActive && (
                  <button
                    className="ghost icon-button"
                    onClick={() => {
                      setCaptureActive(false);
                      setShortcutHint("キャンセルしました");
                    }}
                    disabled={loading}
                  >
                    <X size={14} />
                  </button>
                )}
              </div>
              {shortcutHint && <small className="shortcut-hint">{shortcutHint}</small>}
            </div>
            <div className="field-row">
              <label className="field compact">
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
                  <option value="auto">自動</option>
                </select>
              </label>
              <label className="field compact">
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
                  <option value="toggle">トグル</option>
                  <option value="push_to_talk">長押し</option>
                </select>
              </label>
            </div>
          </div>
        </div>

        {/* Output Section */}
        <div className="settings-section">
          <div className="section-header">
            <ClipboardCopy size={16} />
            <span>出力</span>
          </div>
          <div className="section-content">
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
                <option value="gemini-2.5-flash-lite" disabled={!config.api_keys.gemini.trim()}>
                  Gemini 2.5 Flash Lite{!config.api_keys.gemini.trim() ? " (APIキー未設定)" : ""}
                </option>
                <option value="gemini-2.5-flash-lite-audio" disabled={!config.api_keys.gemini.trim()}>
                  Gemini 2.5 Flash Lite (Audio){!config.api_keys.gemini.trim() ? " (APIキー未設定)" : ""}
                </option>
                <option value="gpt-4o-mini" disabled={!config.api_keys.openai.trim()}>
                  GPT-4o mini{!config.api_keys.openai.trim() ? " (APIキー未設定)" : ""}
                </option>
                <option value="gpt-5-nano" disabled={!config.api_keys.openai.trim()}>
                  GPT-5 nano{!config.api_keys.openai.trim() ? " (APIキー未設定)" : ""}
                </option>
              </select>
            </label>
            <div className="toggle-group">
              <label className="toggle-item">
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
                <span>完了後に自動で貼り付け</span>
              </label>
              {config.auto_paste && (
                <label className="toggle-item nested">
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
                  <span>履歴アプリに残さない</span>
                </label>
              )}
            </div>
          </div>
        </div>

        {/* System Settings Buttons */}
        <div className="system-buttons">
          <button
            className="ghost system-button"
            onClick={() => invoke("open_microphone_settings")}
            disabled={loading || !tauriReady}
          >
            <Mic size={14} />
            マイク設定
          </button>
          <button
            className="ghost system-button"
            onClick={() => invoke("open_accessibility_settings")}
            disabled={loading || !tauriReady}
          >
            <Accessibility size={14} />
            アクセシビリティ設定
          </button>
        </div>
      </section>

      {/* App Prompts Card */}
      <section className="card">
        <div className="card-header">
          <div className="card-title-row">
            <AppWindow size={20} />
            <h2>アプリ別プロンプト</h2>
          </div>
          <p>アプリごとにテンプレートを設定（{`{STT結果}`} / {`{言語}`}）</p>
        </div>
        {knownApps.length === 0 ? (
          <p className="empty-state">アプリの履歴がありません</p>
        ) : (
          <div className="app-prompt-layout">
            <div className="app-list">
              {knownApps.map((appName) => (
                <button
                  key={`app-${appName}`}
                  className={`app-item ${selectedApp === appName ? "active" : ""}`}
                  onClick={() => setSelectedApp(appName)}
                  disabled={loading}
                >
                  {appName}
                </button>
              ))}
            </div>
            <div className="prompt-body">
              <textarea
                value={selectedTemplate}
                onChange={(e) => {
                  if (!selectedApp) return;
                  updateAppPrompt(selectedApp, e.target.value);
                }}
                disabled={loading || !selectedApp}
                rows={8}
              />
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
                {selectedApp && (
                  <button
                    className="ghost remove-button"
                    onClick={() => removeKnownApp(selectedApp)}
                    disabled={loading}
                  >
                    <X size={14} />
                    履歴から除外
                  </button>
                )}
              </div>
            </div>
          </div>
        )}
      </section>

      {/* Usage Card */}
      <section className="card">
        <div className="card-header">
          <div className="card-title-row">
            <BarChart3 size={20} />
            <h2>API利用状況</h2>
          </div>
        </div>
        {usageSummary ? (
          <div className="usage-grid">
            <div className="usage-panel">
              <p className="usage-label">今日</p>
              <div className="usage-details">
                <div className="usage-row">
                  <span>Deepgram</span>
                  <span>
                    {formatDuration(usageSummary.today.deepgramSeconds)} / {formatCost(usageSummary.today.deepgramCostUsd)}
                  </span>
                </div>
                {usageSummary.today.geminiTokens > 0 && (
                  <div className="usage-row">
                    <span>Gemini</span>
                    <span>
                      {usageSummary.today.geminiTokens.toLocaleString()} tokens / {formatCost(usageSummary.today.geminiCostUsd)}
                    </span>
                  </div>
                )}
                {usageSummary.today.openaiTokens > 0 && (
                  <div className="usage-row">
                    <span>OpenAI</span>
                    <span>
                      {usageSummary.today.openaiTokens.toLocaleString()} tokens / {formatCost(usageSummary.today.openaiCostUsd)}
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
              <p className="usage-label">今月</p>
              <div className="usage-details">
                <div className="usage-row">
                  <span>Deepgram</span>
                  <span>
                    {formatDuration(usageSummary.this_month.deepgramSeconds)} / {formatCost(usageSummary.this_month.deepgramCostUsd)}
                  </span>
                </div>
                {usageSummary.this_month.geminiTokens > 0 && (
                  <div className="usage-row">
                    <span>Gemini</span>
                    <span>
                      {usageSummary.this_month.geminiTokens.toLocaleString()} tokens / {formatCost(usageSummary.this_month.geminiCostUsd)}
                    </span>
                  </div>
                )}
                {usageSummary.this_month.openaiTokens > 0 && (
                  <div className="usage-row">
                    <span>OpenAI</span>
                    <span>
                      {usageSummary.this_month.openaiTokens.toLocaleString()} tokens / {formatCost(usageSummary.this_month.openaiCostUsd)}
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
          <p className="empty-state">利用データがありません</p>
        )}
      </section>

      {/* Debug Card (Collapsible) */}
      <section className="card collapsible">
        <button
          className="card-header clickable"
          onClick={() => setDebugExpanded(!debugExpanded)}
        >
          <div className="card-title-row">
            <Bug size={20} />
            <h2>デバッグ</h2>
          </div>
          {debugExpanded ? <ChevronUp size={20} /> : <ChevronDown size={20} />}
        </button>
        {debugExpanded && (
          <div className="debug-content">
            <div className="debug-panel">
              <p className="debug-label">パイプライン</p>
              <div className="pipeline-status" style={{ "--pipeline-color": pipelineInfo.color } as React.CSSProperties}>
                <span className="pipeline-icon">{pipelineInfo.icon}</span>
                <span className="pipeline-label">{pipelineInfo.label}</span>
              </div>
            </div>
            <div className="debug-panel">
              <p className="debug-label">ログ</p>
              <div className="log-list">
                {logs.length === 0 ? (
                  <p className="log-empty">ログなし</p>
                ) : (
                  logs.map((log, idx) => (
                    <div className="log-item" key={`${log.ts_ms}-${idx}`}>
                      <span>
                        {new Date(log.ts_ms).toLocaleTimeString()} [{log.level}][{log.stage}] {log.message}
                      </span>
                    </div>
                  ))
                )}
              </div>
            </div>
          </div>
        )}
      </section>

      {/* Fixed Save Bar */}
      <div className="save-bar">
        <div className="save-bar-content">
          {status && <span className="save-status">{status}</span>}
          <button className="save-button" onClick={save} disabled={!canSave}>
            {saving ? (
              <Loader2 size={16} className="animate-spin" />
            ) : (
              <Save size={16} />
            )}
            {saving ? "保存中..." : "設定を保存"}
          </button>
        </div>
      </div>
    </div>
  );
}
