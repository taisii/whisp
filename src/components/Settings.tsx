import { useEffect, useMemo, useState } from "react";
import { invoke, isTauri } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { writeText } from "@tauri-apps/plugin-clipboard-manager";
import { buildShortcutString, formatShortcutDisplay } from "@/lib/shortcut";

type ApiKeys = {
  deepgram: string;
  gemini: string;
  openai: string;
};

type RecordingMode = "toggle" | "push_to_talk";

type LlmModel = "gemini-2.5-flash-lite" | "gpt-4o-mini" | "gpt-5-nano";

type ContextRule = {
  app_name: string;
  instruction: string;
};

type Config = {
  api_keys: ApiKeys;
  shortcut: string;
  auto_paste: boolean;
  avoid_clipboard_history: boolean;
  input_language: string;
  recording_mode: RecordingMode;
  context_rules: ContextRule[];
  known_apps: string[];
  custom_prompt: string | null;
  llm_model: LlmModel;
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
  context_rules: [],
  known_apps: [],
  custom_prompt: null,
  llm_model: "gemini-2.5-flash-lite",
};

const normalizeCustomPrompt = (value: string | null) => {
  const trimmed = value?.trim();
  return trimmed ? value : null;
};

const DEFAULT_CONTEXT_RULES = [
  {
    patterns: ["Visual Studio Code", "VSCode", "Cursor", "Xcode", "Terminal"],
    label: "コード形式",
  },
  { patterns: ["Claude Code"], label: "コード形式" },
  { patterns: ["Codex"], label: "コード形式" },
];

const getDefaultRuleLabel = (appName: string) => {
  const lower = appName.toLowerCase();
  for (const rule of DEFAULT_CONTEXT_RULES) {
    if (rule.patterns.some((pattern) => lower.includes(pattern.toLowerCase()))) {
      return rule.label;
    }
  }
  return null;
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
  const [captureActive, setCaptureActive] = useState(false);
  const [shortcutHint, setShortcutHint] = useState<string | null>(null);

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
    let unlistenConfig: (() => void) | null = null;

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
      unlistenConfig = await listen("config-updated", (event) => {
        const payload = event.payload as Config;
        setConfig(payload);
      });
    };

    setup();
    return () => {
      if (unlistenState) unlistenState();
      if (unlistenLog) unlistenLog();
      if (unlistenOutput) unlistenOutput();
      if (unlistenConfig) unlistenConfig();
    };
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

  const contextRuleMap = useMemo(() => {
    const map = new Map<string, ContextRule>();
    for (const rule of config.context_rules) {
      const key = rule.app_name.trim().toLowerCase();
      if (!key) continue;
      if (!map.has(key)) {
        map.set(key, rule);
      }
    }
    return map;
  }, [config.context_rules]);

  const contextApps = useMemo(() => {
    const names = new Map<string, string>();
    const add = (value: string) => {
      const trimmed = value.trim();
      if (!trimmed) return;
      const key = trimmed.toLowerCase();
      if (!names.has(key)) {
        names.set(key, trimmed);
      }
    };
    config.known_apps.forEach(add);
    config.context_rules.forEach((rule) => add(rule.app_name));
    return Array.from(names.values()).sort((a, b) =>
      a.localeCompare(b, "en", { sensitivity: "base" }),
    );
  }, [config.known_apps, config.context_rules]);

  const updateContextInstruction = (appName: string, value: string) => {
    const trimmed = appName.trim();
    if (!trimmed) return;
    setConfig((prev) => {
      const nextRules = prev.context_rules.filter(
        (rule) => rule.app_name.trim() !== "",
      );
      const key = trimmed.toLowerCase();
      const index = nextRules.findIndex(
        (rule) => rule.app_name.trim().toLowerCase() === key,
      );
      const instruction = value.trim();
      if (!instruction) {
        if (index !== -1) {
          nextRules.splice(index, 1);
        }
      } else {
        const entry = { app_name: trimmed, instruction: value };
        if (index === -1) {
          nextRules.push(entry);
        } else {
          nextRules[index] = entry;
        }
      }
      return { ...prev, context_rules: nextRules };
    });
  };

  const removeKnownApp = (appName: string) => {
    const trimmed = appName.trim();
    if (!trimmed) return;
    const key = trimmed.toLowerCase();
    setConfig((prev) => ({
      ...prev,
      known_apps: prev.known_apps.filter(
        (name) => name.trim().toLowerCase() !== key,
      ),
      context_rules: prev.context_rules.filter(
        (rule) => rule.app_name.trim().toLowerCase() !== key,
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
      const payload = {
        ...config,
        custom_prompt: normalizeCustomPrompt(config.custom_prompt),
      };
      await invoke("save_config", { config: payload });
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
          <h2>カスタムプロンプト</h2>
          <p>{`{STT結果}`}/{`{言語}`} を使って出力スタイルを調整できます。</p>
        </div>
        <div className="prompt-body">
          <textarea
            value={config.custom_prompt ?? DEFAULT_PROMPT_TEMPLATE}
            onChange={(e) =>
              setConfig((prev) => ({
                ...prev,
                custom_prompt: e.target.value,
              }))
            }
            disabled={loading}
            rows={8}
          />
          <small>{`{STT結果}`}が含まれない場合、末尾に入力を自動追加します。</small>
          <div className="prompt-actions">
            <button
              className="ghost"
              onClick={() =>
                setConfig((prev) => ({ ...prev, custom_prompt: null }))
              }
              disabled={loading}
            >
              デフォルトに戻す
            </button>
          </div>
        </div>
      </section>

      <section className="card">
        <div className="card-header">
          <h2>コンテキストルール</h2>
          <p>
            アプリ別に後処理の指示を追加できます（選択テキスト取得にはアクセシビリティ許可が必要です）。
          </p>
        </div>
        <div className="context-rules">
          <div className="context-list">
            {contextApps.length === 0 ? (
              <p className="context-empty">履歴にアプリがありません</p>
            ) : (
              contextApps.map((appName) => {
                const rule = contextRuleMap.get(appName.toLowerCase());
                const instruction = rule?.instruction ?? "";
                const hasInstruction = instruction.trim().length > 0;
                const defaultLabel =
                  hasInstruction ? null : getDefaultRuleLabel(appName);
                return (
                  <div className="context-row" key={`context-${appName}`}>
                    <div className="context-app">
                      <span className="context-app-name">{appName}</span>
                      {defaultLabel ? (
                        <span className="context-default">
                          （デフォルト: {defaultLabel}）
                        </span>
                      ) : null}
                    </div>
                    <textarea
                      placeholder="指示を入力..."
                      value={instruction}
                      onChange={(e) =>
                        updateContextInstruction(appName, e.target.value)
                      }
                      disabled={loading}
                    />
                    <button
                      className="ghost"
                      onClick={() => removeKnownApp(appName)}
                      disabled={loading}
                    >
                      削除
                    </button>
                  </div>
                );
              })
            )}
          </div>
        </div>
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
      </section>
    </div>
  );
}
