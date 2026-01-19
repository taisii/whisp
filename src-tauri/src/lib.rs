mod billing;
mod context;
mod direct_input;
pub mod config;
pub mod error;
pub mod audio_file;
mod key_sender;
mod notification;
pub mod post_processor;
pub mod recorder;
mod shortcut;
mod sound;
pub mod stt_client;
mod tray;
pub mod usage;

use crate::billing::{calculate_daily_cost, calculate_total_cost};
use crate::config::{Config, ConfigManager, LlmModel, RecordingMode};
use crate::error::{AppError, AppResult};
use crate::stt_client::SttResult;
use crate::tray::TrayState;
use crate::usage::UsageManager;
use chrono::{Datelike, NaiveDate, Utc};
use serde::Serialize;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager, State};
use tauri_plugin_autostart::ManagerExt;
use tauri_plugin_global_shortcut::ShortcutState;
use tokio::sync::mpsc::Receiver;

const MAX_RECORDING_SECS: u64 = 120;
const SILENCE_TIMEOUT_SECS: u64 = 30;
// Peak i16 amplitude threshold used to treat input as silence.
const SILENCE_THRESHOLD: u16 = 500;

enum SttTask {
    Deepgram(tauri::async_runtime::JoinHandle<AppResult<SttResult>>),
    GeminiAudio {
        audio_task: tauri::async_runtime::JoinHandle<Vec<u8>>,
        sample_rate: u32,
    },
}

struct RecordingSession {
    recorder: recorder::RecorderHandle,
    stt_task: SttTask,
    started_at: Instant,
    session_id: u64,
    vision_task: Option<tauri::async_runtime::JoinHandle<Option<post_processor::VisionContext>>>,
}

struct AppState {
    config_manager: ConfigManager,
    config: Mutex<Config>,
    recording: Mutex<Option<RecordingSession>>,
    recording_counter: AtomicU64,
    usage_manager: UsageManager,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "camelCase")]
enum PipelineState {
    Idle,
    Recording,
    SttStreaming,
    PostProcessing,
    DirectInput,
    Done,
    Error,
}

#[derive(Debug, Serialize, Clone)]
struct DebugLog {
    ts_ms: u128,
    level: String,
    stage: String,
    message: String,
}

fn emit_state(app: &AppHandle, state: PipelineState) {
    let _ = app.emit("pipeline-state", state);
}

fn emit_log(app: &AppHandle, level: &str, stage: &str, message: impl Into<String>) {
    let message = message.into();
    println!("[{level}][{stage}] {message}");
    let log = DebugLog {
        ts_ms: SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis(),
        level: level.to_string(),
        stage: stage.to_string(),
        message,
    };
    let _ = app.emit("debug-log", log);
}

#[tauri::command]
async fn get_config(state: State<'_, AppState>) -> Result<Config, String> {
    Ok(state.config.lock().unwrap().clone())
}

#[tauri::command]
async fn save_config(app: AppHandle, state: State<'_, AppState>, config: Config) -> Result<(), String> {
    let old_shortcut = state.config.lock().unwrap().shortcut.clone();
    emit_log(&app, "info", "config", "保存開始");
    if config.shortcut != old_shortcut {
        register_global_shortcut(&app, &config.shortcut).map_err(|e| e.to_string())?;
    }

    if let Err(err) = state.config_manager.save(&config) {
        emit_log(&app, "error", "config", err.to_string());
        if config.shortcut != old_shortcut {
            let _ = shortcut::unregister_shortcut(&app, &config.shortcut);
            if !shortcut::is_registered(&app, &old_shortcut) {
                let _ = register_global_shortcut(&app, &old_shortcut);
            }
        }
        return Err(err.to_string());
    }

    if config.shortcut != old_shortcut
        && shortcut::is_registered(&app, &old_shortcut)
    {
        let _ = shortcut::unregister_shortcut(&app, &old_shortcut);
    }

    *state.config.lock().unwrap() = config.clone();
    let _ = app.emit("config-updated", config.clone());
    emit_log(&app, "info", "config", "保存完了");

    Ok(())
}

#[tauri::command]
async fn toggle_recording(app: AppHandle) -> Result<(), String> {
    toggle_recording_internal(&app)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
fn open_microphone_settings() -> Result<(), String> {
    open_mic_settings().map_err(|e| e.to_string())
}

#[tauri::command]
fn open_accessibility_settings() -> Result<(), String> {
    key_sender::open_accessibility_settings().map_err(|e| e.to_string())
}

async fn toggle_recording_internal(app: &AppHandle) -> AppResult<()> {
    let state = app.state::<AppState>();
    let is_recording = state.recording.lock().unwrap().is_some();
    if is_recording {
        stop_recording(app, &state).await
    } else {
        start_recording(app, &state).await
    }
}

async fn handle_shortcut_event(app: &AppHandle, state: ShortcutState) -> AppResult<()> {
    match state {
        ShortcutState::Pressed => handle_shortcut_pressed(app).await,
        ShortcutState::Released => handle_shortcut_released(app).await,
    }
}

async fn handle_shortcut_pressed(app: &AppHandle) -> AppResult<()> {
    let state = app.state::<AppState>();
    let recording_mode = state.config.lock().unwrap().recording_mode.clone();
    match recording_mode {
        RecordingMode::Toggle => toggle_recording_internal(app).await,
        RecordingMode::PushToTalk => start_recording_if_idle(app, &state).await,
    }
}

async fn handle_shortcut_released(app: &AppHandle) -> AppResult<()> {
    let state = app.state::<AppState>();
    let recording_mode = state.config.lock().unwrap().recording_mode.clone();
    if recording_mode == RecordingMode::PushToTalk {
        stop_recording(app, &state).await
    } else {
        Ok(())
    }
}

async fn start_recording_if_idle(app: &AppHandle, state: &AppState) -> AppResult<()> {
    if state.recording.lock().unwrap().is_some() {
        return Ok(());
    }
    start_recording(app, state).await
}

fn record_known_app(app: &AppHandle, state: &AppState) {
    let Some(app_name) = context::capture_app_name() else {
        return;
    };
    let trimmed = app_name.trim();
    if trimmed.is_empty() {
        return;
    }
    let mut config = state.config.lock().unwrap();
    if config.known_apps.iter().any(|name| name == trimmed) {
        return;
    }
    config.known_apps.push(trimmed.to_string());
    let updated = config.clone();
    drop(config);
    if let Err(err) = state.config_manager.save(&updated) {
        emit_log(app, "error", "config", format!("known_apps保存失敗: {err}"));
        return;
    }
    let _ = app.emit("config-updated", updated);
}

async fn start_recording(app: &AppHandle, state: &AppState) -> AppResult<()> {
    let config = state.config.lock().unwrap().clone();
    let uses_direct_audio = config.llm_model.uses_direct_audio();

    // Deepgram API key is only required for non-audio modes
    if !uses_direct_audio && config.api_keys.deepgram.trim().is_empty() {
        emit_log(app, "error", "recording", "Deepgram APIキーが未設定です");
        return Err(AppError::MissingApiKey("deepgram"));
    }
    validate_llm_api_key(app, &config)?;

    record_known_app(app, state);

    let (audio_tx, audio_rx) = tokio::sync::mpsc::channel(8);
    let (meter_tx, meter_rx) = tokio::sync::mpsc::channel(32);
    let recorder = match recorder::RecorderHandle::spawn(audio_tx, Some(meter_tx)) {
        Ok(recorder) => recorder,
        Err(err) => {
            if matches!(err, AppError::Audio(_)) {
                let _ = open_mic_settings();
            }
            emit_log(app, "error", "recording", err.to_string());
            return Err(err);
        }
    };
    let sample_rate = recorder.sample_rate();
    let vision_task = spawn_vision_task(app, &config);

    let stt_task = if uses_direct_audio {
        emit_log(app, "info", "recording", "Gemini音声直接入力モードで録音開始");
        let audio_task = tauri::async_runtime::spawn(collect_audio(audio_rx));
        SttTask::GeminiAudio {
            audio_task,
            sample_rate,
        }
    } else {
        let deepgram_key = config.api_keys.deepgram.clone();
        let language = language_param(&config.input_language);
        let app_for_events = app.clone();
        let on_event = std::sync::Arc::new(move |event: stt_client::SttEvent| match event {
            stt_client::SttEvent::Connected => {
                emit_state(&app_for_events, PipelineState::SttStreaming);
                emit_log(&app_for_events, "info", "stt", "Deepgramに接続しました");
            }
            stt_client::SttEvent::AudioStreamEnded => {
                emit_log(&app_for_events, "info", "stt", "音声送信が完了しました");
            }
            stt_client::SttEvent::FinalTranscript(text) => {
                emit_log(
                    &app_for_events,
                    "info",
                    "stt",
                    format!("最終セグメント受信: {} chars", text.chars().count()),
                );
            }
            stt_client::SttEvent::Error(message) => {
                emit_state(&app_for_events, PipelineState::Error);
                emit_log(&app_for_events, "error", "stt", message);
            }
        });
        let task = tauri::async_runtime::spawn(async move {
            stt_client::run_deepgram_stream_with_events(
                &deepgram_key,
                sample_rate,
                audio_rx,
                Some(on_event),
                language,
            )
            .await
        });
        SttTask::Deepgram(task)
    };

    let session_id = state.recording_counter.fetch_add(1, Ordering::Relaxed) + 1;
    *state.recording.lock().unwrap() = Some(RecordingSession {
        recorder,
        stt_task,
        started_at: Instant::now(),
        session_id,
        vision_task,
    });

    tray::set_tray_state(app, TrayState::Recording)?;
    emit_state(app, PipelineState::Recording);
    let _ = sound::play_start_sound();
    emit_log(
        app,
        "info",
        "recording",
        format!("録音開始 (sample_rate={}Hz)", sample_rate),
    );
    let _ = app.emit("recording-state-changed", true);

    spawn_max_duration_watchdog(app.clone(), session_id);
    spawn_silence_watchdog(app.clone(), session_id, meter_rx);

    Ok(())
}

fn spawn_vision_task(
    app: &AppHandle,
    config: &Config,
) -> Option<tauri::async_runtime::JoinHandle<Option<post_processor::VisionContext>>> {
    if !config.context.vision_enabled {
        return None;
    }
    let llm_key = match required_llm_key(config) {
        Ok(key) => key.to_string(),
        Err(err) => {
            emit_log(app, "error", "vision", format!("Vision APIキー未設定: {err}"));
            return None;
        }
    };
    let model = config.llm_model;
    let app_for_task = app.clone();
    Some(tauri::async_runtime::spawn(async move {
        emit_log(&app_for_task, "info", "vision", "スクリーンショット取得開始");
        let screenshot = match context::capture_screenshot() {
            Ok(Some(bytes)) => bytes,
            Ok(None) => {
                emit_log(&app_for_task, "info", "vision", "スクリーンショットが取得できませんでした");
                return None;
            }
            Err(err) => {
                emit_log(
                    &app_for_task,
                    "error",
                    "vision",
                    format!("スクリーンショット取得失敗: {err}"),
                );
                return None;
            }
        };
        emit_log(
            &app_for_task,
            "info",
            "vision",
            format!("スクリーンショット取得完了: {} bytes", screenshot.len()),
        );
        let analysis_started = Instant::now();
        match post_processor::analyze_screen_context(model, &llm_key, &screenshot).await {
            Ok(context) => {
                emit_log(
                    &app_for_task,
                    "info",
                    "vision",
                    format!(
                        "Vision解析完了: {}ms",
                        analysis_started.elapsed().as_millis()
                    ),
                );
                Some(context)
            }
            Err(err) => {
                emit_log(
                    &app_for_task,
                    "error",
                    "vision",
                    format!("Vision解析失敗: {err}"),
                );
                None
            }
        }
    }))
}

fn open_mic_settings() -> AppResult<()> {
    tauri_plugin_opener::open_url(
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
        None::<&str>,
    )
    .map_err(|e| AppError::Other(e.to_string()))
}

fn language_param(value: &str) -> Option<String> {
    match value {
        "auto" => None,
        "ja" => Some("ja".to_string()),
        "en" => Some("en".to_string()),
        _ => None,
    }
}

fn spawn_max_duration_watchdog(app: AppHandle, session_id: u64) {
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_secs(MAX_RECORDING_SECS)).await;
        let state = app.state::<AppState>();
        if let Err(err) = stop_recording_if_current(
            &app,
            &state,
            session_id,
            "録音が2分に達したため自動停止します",
        )
        .await
        {
            emit_log(
                &app,
                "error",
                "recording",
                format!("自動停止失敗: {err}"),
            );
        }
    });
}

fn spawn_silence_watchdog(app: AppHandle, session_id: u64, mut meter_rx: Receiver<u16>) {
    tauri::async_runtime::spawn(async move {
        let mut last_sound = Instant::now();
        while let Some(peak) = meter_rx.recv().await {
            if peak >= SILENCE_THRESHOLD {
                last_sound = Instant::now();
                continue;
            }

            if last_sound.elapsed().as_secs() >= SILENCE_TIMEOUT_SECS {
                let state = app.state::<AppState>();
                if let Err(err) = stop_recording_if_current(
                    &app,
                    &state,
                    session_id,
                    "無音が30秒続いたため自動停止します",
                )
                .await
                {
                    emit_log(
                        &app,
                        "error",
                        "recording",
                        format!("自動停止失敗: {err}"),
                    );
                }
                break;
            }
        }
    });
}

async fn stop_recording_if_current(
    app: &AppHandle,
    state: &AppState,
    session_id: u64,
    reason: &str,
) -> AppResult<()> {
    let is_current = {
        let guard = state.recording.lock().unwrap();
        guard
            .as_ref()
            .is_some_and(|session| session.session_id == session_id)
    };
    if !is_current {
        return Ok(());
    }
    emit_log(app, "info", "recording", reason);
    stop_recording(app, state).await
}

fn is_empty_stt(text: &str) -> bool {
    text.trim().is_empty()
}

async fn collect_audio(mut audio_rx: Receiver<Vec<u8>>) -> Vec<u8> {
    let mut pcm_data = Vec::new();
    while let Some(chunk) = audio_rx.recv().await {
        pcm_data.extend_from_slice(&chunk);
    }
    pcm_data
}

#[cfg(test)]
mod tests {
    use super::is_empty_stt;
    use super::collect_audio;
    use tokio::sync::mpsc;

    #[test]
    fn is_empty_stt_treats_whitespace_as_empty() {
        assert!(is_empty_stt(""));
        assert!(is_empty_stt("   "));
        assert!(is_empty_stt("\n\t"));
        assert!(!is_empty_stt("テスト"));
    }

    #[tokio::test]
    async fn collect_audio_drains_all_chunks_until_closed() {
        let (tx, rx) = mpsc::channel(8);
        let task = tokio::spawn(collect_audio(rx));
        for _ in 0..32 {
            tx.send(vec![1, 2, 3, 4]).await.unwrap();
        }
        drop(tx);
        let pcm_data = task.await.unwrap();
        assert_eq!(pcm_data.len(), 32 * 4);
    }
}

async fn stop_recording(app: &AppHandle, state: &AppState) -> AppResult<()> {
    let session = state.recording.lock().unwrap().take();
    let Some(session) = session else {
        return Ok(());
    };

    let RecordingSession {
        mut recorder,
        stt_task,
        started_at,
        session_id: _,
        vision_task,
    } = session;
    recorder.stop();
    let mut vision_task = vision_task;

    let result = async {
        emit_log(app, "info", "recording", "録音停止");

        let config = state.config.lock().unwrap().clone();

        let (stt_text, stt_usage, processed, llm_usage) = match stt_task {
            SttTask::Deepgram(task) => {
                emit_log(app, "info", "stt", "Deepgram STT待機中");
                let stt_result = task
                    .await
                    .map_err(|e| AppError::Other(e.to_string()))??;

                let stt_usage = stt_result.usage.clone();
                let stt_text = stt_result.transcript;

                emit_log(
                    app,
                    "info",
                    "stt",
                    format!("STT完了: {} chars", stt_text.chars().count()),
                );
                emit_log(app, "info", "stt", format!("STT結果: {stt_text}"));

                if let Some(ref usage) = stt_usage {
                    emit_log(
                        app,
                        "info",
                        "stt",
                        format!("STT使用量: {:.2}秒", usage.duration_seconds),
                    );
                }

                if is_empty_stt(&stt_text) {
                    emit_log(
                        app,
                        "info",
                        "pipeline",
                        "STT結果が空のためLLM処理をスキップします",
                    );
                    // Record STT usage even if no LLM processing
                    if stt_usage.is_some() {
                        state.usage_manager.record_usage(stt_usage.clone(), None);
                        let cost = calculate_total_cost(stt_usage.as_ref(), None);
                        let _ = app.emit("usage-metrics", UsageMetricsEvent {
                            timestamp_ms: Utc::now().timestamp_millis(),
                            stt_provider: stt_usage.as_ref().map(|_| "deepgram".to_string()),
                            stt_duration_seconds: stt_usage.as_ref().map(|u| u.duration_seconds),
                            stt_request_id: stt_usage.as_ref().and_then(|u| u.request_id.clone()),
                            llm_provider: None,
                            llm_prompt_tokens: None,
                            llm_completion_tokens: None,
                            llm_model: None,
                            cost_estimate_usd: cost,
                        });
                    }
                    emit_state(app, PipelineState::Done);
                    return Ok(());
                }

                let mut context_info = post_processor::ContextInfo::default();
                if config.context.accessibility_enabled {
                    match context::capture_accessibility_text() {
                        Ok(Some(text)) => {
                            emit_log(
                                app,
                                "info",
                                "context",
                                format!("選択テキスト取得: {} chars", text.chars().count()),
                            );
                            context_info.accessibility_text = Some(text);
                        }
                        Ok(None) => {
                            emit_log(app, "info", "context", "選択テキストなし");
                        }
                        Err(err) => {
                            emit_log(
                                app,
                                "error",
                                "context",
                                format!("選択テキスト取得失敗: {err}"),
                            );
                        }
                    }
                }

                if let Some(vision_task) = vision_task.take() {
                    match tokio::time::timeout(Duration::from_secs(2), vision_task).await {
                        Ok(Ok(Some(vision))) => {
                            if !vision.summary.trim().is_empty() {
                                context_info.vision_summary = Some(vision.summary);
                            }
                            context_info.vision_terms = vision.terms;
                        }
                        Ok(Ok(None)) => {
                            emit_log(app, "info", "vision", "Visionコンテキストなし");
                        }
                        Ok(Err(err)) => {
                            emit_log(
                                app,
                                "error",
                                "vision",
                                format!("Visionタスク失敗: {err}"),
                            );
                        }
                        Err(_) => {
                            emit_log(app, "info", "vision", "Vision解析タイムアウト");
                        }
                    }
                }

                let app_name = context::capture_app_name();
                if let Some(app_name) = app_name.as_ref() {
                    emit_log(app, "info", "context", format!("アクティブアプリ: {app_name}"));
                }
                emit_state(app, PipelineState::PostProcessing);
                emit_log(
                    app,
                    "info",
                    "postprocess",
                    format!("LLM後処理開始: {}", config.llm_model.as_str()),
                );
                let llm_started = Instant::now();
                let llm_key = required_llm_key(&config)?;
                let llm_result = post_processor::post_process(
                    config.llm_model,
                    llm_key,
                    &stt_text,
                    &config.input_language,
                    app_name.as_deref(),
                    &config.app_prompt_rules,
                    if context_info.is_empty() {
                        None
                    } else {
                        Some(&context_info)
                    },
                )
                .await?;

                let llm_usage = llm_result.usage.clone();
                let processed = llm_result.text;

                emit_log(
                    app,
                    "info",
                    "postprocess",
                    format!("LLM処理時間: {}ms", llm_started.elapsed().as_millis()),
                );

                if let Some(ref usage) = llm_usage {
                    emit_log(
                        app,
                        "info",
                        "postprocess",
                        format!(
                            "LLM使用量: prompt={}, completion={}",
                            usage.prompt_tokens, usage.completion_tokens
                        ),
                    );
                }

                (stt_text, stt_usage, processed, llm_usage)
            }
            SttTask::GeminiAudio {
                audio_task,
                sample_rate,
            } => {
                let _ = vision_task.take();
                emit_log(app, "info", "stt", "Gemini音声文字起こし開始");
                emit_state(app, PipelineState::PostProcessing);

                // Collect all audio data
                let pcm_data = audio_task
                    .await
                    .map_err(|e| AppError::Other(e.to_string()))?;

                if pcm_data.is_empty() {
                    emit_log(app, "info", "pipeline", "音声データが空のためスキップします");
                    emit_state(app, PipelineState::Done);
                    return Ok(());
                }

                emit_log(
                    app,
                    "info",
                    "stt",
                    format!("音声データ: {} bytes, sample_rate={}Hz", pcm_data.len(), sample_rate),
                );

                // Build WAV and call Gemini
                let wav_bytes = audio_file::build_wav_bytes(sample_rate, &pcm_data);
                let gemini_key = config.api_keys.gemini.as_str();
                let llm_started = Instant::now();
                let gemini_result = post_processor::transcribe_audio_gemini(
                    gemini_key,
                    &wav_bytes,
                    "audio/wav",
                )
                .await?;

                let llm_usage = gemini_result.usage.clone();
                let processed = gemini_result.text;

                emit_log(
                    app,
                    "info",
                    "stt",
                    format!("Gemini音声文字起こし完了: {}ms", llm_started.elapsed().as_millis()),
                );

                if let Some(ref usage) = llm_usage {
                    emit_log(
                        app,
                        "info",
                        "stt",
                        format!(
                            "Gemini使用量: prompt={}, completion={}",
                            usage.prompt_tokens, usage.completion_tokens
                        ),
                    );
                }

                if is_empty_stt(&processed) {
                    emit_log(app, "info", "pipeline", "文字起こし結果が空のためスキップします");
                    emit_state(app, PipelineState::Done);
                    return Ok(());
                }

                // For Gemini audio mode: no STT usage (Deepgram not used), LLM usage from transcribe call
                (processed.clone(), None, processed, llm_usage)
            }
        };

        // Record usage
        state.usage_manager.record_usage(stt_usage.clone(), llm_usage.clone());

        // Emit usage metrics event
        let cost = calculate_total_cost(stt_usage.as_ref(), llm_usage.as_ref());
        let _ = app.emit("usage-metrics", UsageMetricsEvent {
            timestamp_ms: Utc::now().timestamp_millis(),
            stt_provider: stt_usage.as_ref().map(|_| "deepgram".to_string()),
            stt_duration_seconds: stt_usage.as_ref().map(|u| u.duration_seconds),
            stt_request_id: stt_usage.as_ref().and_then(|u| u.request_id.clone()),
            llm_provider: llm_usage.as_ref().map(|u| llm_provider_from_model(&u.model)),
            llm_prompt_tokens: llm_usage.as_ref().map(|u| u.prompt_tokens),
            llm_completion_tokens: llm_usage.as_ref().map(|u| u.completion_tokens),
            llm_model: llm_usage.as_ref().map(|u| u.model.clone()),
            cost_estimate_usd: cost,
        });

        // Clone before move into closure (recommended fix for E0382)
        let processed_char_count = processed.chars().count();
        emit_log(
            app,
            "info",
            "postprocess",
            format!("処理完了: {processed_char_count} chars"),
        );
        emit_log(app, "info", "postprocess", format!("整形結果: {processed}"));

        emit_state(app, PipelineState::DirectInput);
        emit_log(app, "info", "direct_input", "直接入力を開始");
        let app_for_input = app.clone();
        if let Err(err) = app.run_on_main_thread(move || {
            if let Err(err) = direct_input::send_text(&processed) {
                emit_log(
                    &app_for_input,
                    "error",
                    "direct_input",
                    format!("直接入力失敗: {err}"),
                );
                if matches!(err, AppError::AccessibilityPermissionRequired) {
                    let _ = app_for_input.emit("accessibility-required", true);
                }
            }
        }) {
            emit_log(
                app,
                "error",
                "direct_input",
                format!("直接入力実行失敗: {err}"),
            );
        }

        let _ = sound::play_completion_sound();
        emit_state(app, PipelineState::Done);

        let elapsed = started_at.elapsed();
        println!(
            "recording finished in {}ms (stt_result={} chars, output={} chars)",
            elapsed.as_millis(),
            stt_text.chars().count(),
            processed_char_count
        );

        Ok::<_, AppError>(())
    }
    .await;

    let _ = tray::set_tray_state(app, TrayState::Idle);
    emit_state(app, PipelineState::Idle);
    let _ = app.emit("recording-state-changed", false);

    result
}

#[derive(Debug, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct UsageMetricsEvent {
    timestamp_ms: i64,
    stt_provider: Option<String>,
    stt_duration_seconds: Option<f64>,
    stt_request_id: Option<String>,
    llm_provider: Option<String>,
    llm_prompt_tokens: Option<u32>,
    llm_completion_tokens: Option<u32>,
    llm_model: Option<String>,
    cost_estimate_usd: f64,
}

fn llm_provider_from_model(model: &str) -> String {
    if model.contains("gemini") {
        "gemini".to_string()
    } else {
        "openai".to_string()
    }
}

fn register_global_shortcut(app: &AppHandle, shortcut: &str) -> AppResult<()> {
    shortcut::register_shortcut(app, shortcut, move |app, state| {
        tauri::async_runtime::spawn(async move {
            if let Err(err) = handle_shortcut_event(&app, state).await {
                emit_state(&app, PipelineState::Error);
                emit_log(&app, "error", "pipeline", err.to_string());
                let _ = notification::notify_error(&app, &err.to_string());
            }
        });
    })
}

fn required_llm_key(config: &Config) -> AppResult<&str> {
    match config.llm_model {
        LlmModel::Gemini25FlashLite | LlmModel::Gemini25FlashLiteAudio => {
            if config.api_keys.gemini.trim().is_empty() {
                return Err(AppError::MissingApiKey("gemini"));
            }
            Ok(config.api_keys.gemini.as_str())
        }
        LlmModel::Gpt4oMini | LlmModel::Gpt5Nano => {
            if config.api_keys.openai.trim().is_empty() {
                return Err(AppError::MissingApiKey("openai"));
            }
            Ok(config.api_keys.openai.as_str())
        }
    }
}

fn validate_llm_api_key(app: &AppHandle, config: &Config) -> AppResult<()> {
    if let Err(err) = required_llm_key(config) {
        let message = match config.llm_model {
            LlmModel::Gemini25FlashLite | LlmModel::Gemini25FlashLiteAudio => {
                "Gemini APIキーが未設定です"
            }
            LlmModel::Gpt4oMini | LlmModel::Gpt5Nano => "OpenAI APIキーが未設定です",
        };
        emit_log(app, "error", "recording", message);
        return Err(err);
    }
    Ok(())
}

#[derive(Debug, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct DailyUsageSummary {
    deepgram_seconds: f64,
    deepgram_cost_usd: f64,
    gemini_tokens: u32,
    gemini_cost_usd: f64,
    openai_tokens: u32,
    openai_cost_usd: f64,
    total_cost_usd: f64,
}

#[derive(Debug, Serialize, Clone)]
struct UsageSummary {
    today: DailyUsageSummary,
    this_month: DailyUsageSummary,
}

fn daily_usage_to_summary(daily: &usage::DailyUsage) -> DailyUsageSummary {
    let cost = calculate_daily_cost(daily);
    DailyUsageSummary {
        deepgram_seconds: daily.deepgram_seconds,
        deepgram_cost_usd: cost.deepgram_cost_usd,
        gemini_tokens: daily.gemini_prompt_tokens + daily.gemini_completion_tokens,
        gemini_cost_usd: cost.gemini_cost_usd,
        openai_tokens: daily.openai_prompt_tokens + daily.openai_completion_tokens,
        openai_cost_usd: cost.openai_cost_usd,
        total_cost_usd: cost.total_cost_usd,
    }
}

#[tauri::command]
async fn get_usage_summary(state: State<'_, AppState>) -> Result<UsageSummary, String> {
    let today = state.usage_manager.get_today();
    let this_month = state.usage_manager.get_current_month();

    Ok(UsageSummary {
        today: daily_usage_to_summary(&today),
        this_month: daily_usage_to_summary(&this_month),
    })
}

#[derive(Debug, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct DeepgramBillingSummary {
    project_id: String,
    start_date: String,
    end_date: String,
    fetched_at_ms: i64,
    total_cost_usd: Option<f64>,
    total_seconds: Option<f64>,
    balance_usd: Option<f64>,
    raw_usage: serde_json::Value,
    raw_balance: serde_json::Value,
}

fn extract_number(value: &serde_json::Value, keys: &[&str]) -> Option<f64> {
    keys.iter()
        .find_map(|key| value.get(*key).and_then(|v| v.as_f64()))
}

fn sum_numbers(value: &serde_json::Value, keys: &[&str]) -> Option<f64> {
    let array = value.as_array()?;
    let mut sum = 0.0;
    let mut found = false;
    for item in array {
        if let Some(obj) = item.as_object() {
            if let Some(number) = keys
                .iter()
                .find_map(|key| obj.get(*key).and_then(|v| v.as_f64()))
            {
                sum += number;
                found = true;
            }
        }
    }
    if found {
        Some(sum)
    } else {
        None
    }
}

fn extract_deepgram_total_cost(value: &serde_json::Value) -> Option<f64> {
    if let Some(cost) = extract_number(value, &["total_cost", "total_cost_usd"]) {
        return Some(cost);
    }
    value
        .get("results")
        .and_then(|results| sum_numbers(results, &["cost", "total_cost", "total_cost_usd"]))
}

fn extract_deepgram_total_seconds(value: &serde_json::Value) -> Option<f64> {
    if let Some(seconds) = extract_number(value, &["total_seconds", "total_duration", "seconds"]) {
        return Some(seconds);
    }
    value
        .get("results")
        .and_then(|results| sum_numbers(results, &["seconds", "duration", "total_seconds"]))
}

fn extract_deepgram_balance(value: &serde_json::Value) -> Option<f64> {
    if let Some(balance) = extract_number(value, &["balance", "amount", "total_balance"]) {
        return Some(balance);
    }
    value
        .get("balances")
        .and_then(|balances| sum_numbers(balances, &["balance", "amount", "total_balance"]))
}

#[tauri::command]
async fn get_deepgram_billing_summary(
    state: State<'_, AppState>,
) -> Result<DeepgramBillingSummary, String> {
    let config = state.config.lock().unwrap().clone();
    if !config.billing.deepgram_enabled {
        return Err("Deepgram Billing APIが無効です".to_string());
    }
    let api_key = config.api_keys.deepgram.trim();
    if api_key.is_empty() {
        return Err("Deepgram APIキーが未設定です".to_string());
    }
    let project_id = config.billing.deepgram_project_id.trim();
    if project_id.is_empty() {
        return Err("Deepgram Project IDが未設定です".to_string());
    }

    let today = Utc::now().date_naive();
    let start_date = NaiveDate::from_ymd_opt(today.year(), today.month(), 1)
        .unwrap_or(today)
        .format("%Y-%m-%d")
        .to_string();
    let end_date = today.format("%Y-%m-%d").to_string();

    let client = reqwest::Client::new();
    let usage_url = format!(
        "https://api.deepgram.com/v1/projects/{project_id}/usage"
    );
    let usage_response = client
        .get(&usage_url)
        .query(&[("start", &start_date), ("end", &end_date)])
        .header("Authorization", format!("Token {api_key}"))
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let usage_status = usage_response.status();
    let usage_body = usage_response.text().await.map_err(|e| e.to_string())?;
    if !usage_status.is_success() {
        return Err(format!("Deepgram usage API error: {usage_status} {usage_body}"));
    }
    let raw_usage: serde_json::Value =
        serde_json::from_str(&usage_body).map_err(|e| e.to_string())?;

    let balances_url = format!(
        "https://api.deepgram.com/v1/projects/{project_id}/balances"
    );
    let balance_response = client
        .get(&balances_url)
        .header("Authorization", format!("Token {api_key}"))
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let balance_status = balance_response.status();
    let balance_body = balance_response.text().await.map_err(|e| e.to_string())?;
    if !balance_status.is_success() {
        return Err(format!(
            "Deepgram balance API error: {balance_status} {balance_body}"
        ));
    }
    let raw_balance: serde_json::Value =
        serde_json::from_str(&balance_body).map_err(|e| e.to_string())?;

    Ok(DeepgramBillingSummary {
        project_id: project_id.to_string(),
        start_date,
        end_date,
        fetched_at_ms: Utc::now().timestamp_millis(),
        total_cost_usd: extract_deepgram_total_cost(&raw_usage),
        total_seconds: extract_deepgram_total_seconds(&raw_usage),
        balance_usd: extract_deepgram_balance(&raw_balance),
        raw_usage,
        raw_balance,
    })
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .setup(|app| {
            let config_manager = ConfigManager::new()?;
            let config = config_manager.load_or_create()?;
            let usage_manager = UsageManager::new()?;

            app.manage(AppState {
                config_manager,
                config: Mutex::new(config.clone()),
                recording: Mutex::new(None),
                recording_counter: AtomicU64::new(0),
                usage_manager,
            });

            let _ = notification::request_permission(app.app_handle());
            let _ = app.autolaunch().enable();

            tray::build_tray(app.app_handle())?;
            register_global_shortcut(app.app_handle(), &config.shortcut)?;
            emit_state(app.app_handle(), PipelineState::Idle);
            emit_log(app.app_handle(), "info", "app", "Whisp起動完了");

            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                let _ = window.hide();
                api.prevent_close();
            }
        })
        .invoke_handler(tauri::generate_handler![
            get_config,
            save_config,
            toggle_recording,
            open_microphone_settings,
            open_accessibility_settings,
            get_usage_summary,
            get_deepgram_billing_summary
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
