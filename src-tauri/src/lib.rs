mod clipboard;
mod context;
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

use crate::config::{Config, ConfigManager, LlmModel, RecordingMode};
use crate::error::{AppError, AppResult};
use crate::tray::TrayState;
use serde::Serialize;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Instant, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager, State};
use tauri_plugin_autostart::ManagerExt;
use tauri_plugin_global_shortcut::ShortcutState;
use tokio::sync::mpsc::Receiver;

const MAX_RECORDING_SECS: u64 = 120;
const SILENCE_TIMEOUT_SECS: u64 = 30;
// Peak i16 amplitude threshold used to treat input as silence.
const SILENCE_THRESHOLD: u16 = 500;

enum SttTask {
    Deepgram(tauri::async_runtime::JoinHandle<AppResult<String>>),
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
}

struct AppState {
    config_manager: ConfigManager,
    config: Mutex<Config>,
    recording: Mutex<Option<RecordingSession>>,
    recording_counter: AtomicU64,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "camelCase")]
enum PipelineState {
    Idle,
    Recording,
    SttStreaming,
    PostProcessing,
    Clipboard,
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

    if config.shortcut != old_shortcut {
        if shortcut::is_registered(&app, &old_shortcut) {
            let _ = shortcut::unregister_shortcut(&app, &old_shortcut);
        }
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
    if let Err(err) = validate_llm_api_key(app, &config) {
        return Err(err);
    }

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

    let mut recorder = session.recorder;
    recorder.stop();

    let result = async {
        emit_log(app, "info", "recording", "録音停止");

        let config = state.config.lock().unwrap().clone();

        let (stt_result, processed) = match session.stt_task {
            SttTask::Deepgram(task) => {
                emit_log(app, "info", "stt", "Deepgram STT待機中");
                let stt_result = task
                    .await
                    .map_err(|e| AppError::Other(e.to_string()))??;
                emit_log(
                    app,
                    "info",
                    "stt",
                    format!("STT完了: {} chars", stt_result.chars().count()),
                );
                emit_log(app, "info", "stt", format!("STT結果: {stt_result}"));
                if is_empty_stt(&stt_result) {
                    emit_log(
                        app,
                        "info",
                        "pipeline",
                        "STT結果が空のためLLM処理をスキップします",
                    );
                    emit_state(app, PipelineState::Done);
                    return Ok(());
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
                let processed = post_processor::post_process(
                    config.llm_model,
                    llm_key,
                    &stt_result,
                    &config.input_language,
                    app_name.as_deref(),
                    &config.app_prompt_rules,
                )
                .await?;
                emit_log(
                    app,
                    "info",
                    "postprocess",
                    format!("LLM処理時間: {}ms", llm_started.elapsed().as_millis()),
                );
                (stt_result, processed)
            }
            SttTask::GeminiAudio {
                audio_task,
                sample_rate,
            } => {
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
                let result = post_processor::transcribe_audio_gemini(
                    gemini_key,
                    &wav_bytes,
                    "audio/wav",
                )
                .await?;
                emit_log(
                    app,
                    "info",
                    "stt",
                    format!("Gemini音声文字起こし完了: {}ms", llm_started.elapsed().as_millis()),
                );

                if is_empty_stt(&result) {
                    emit_log(app, "info", "pipeline", "文字起こし結果が空のためスキップします");
                    emit_state(app, PipelineState::Done);
                    return Ok(());
                }

                // For Gemini audio mode, the result is already formatted (no separate STT result)
                (result.clone(), result)
            }
        };

        let _ = app.emit(
            "pipeline-output",
            PipelineResult {
                stt: stt_result.clone(),
                output: processed.clone(),
            },
        );
        emit_log(
            app,
            "info",
            "postprocess",
            format!("処理完了: {} chars", processed.chars().count()),
        );
        emit_log(app, "info", "postprocess", format!("整形結果: {processed}"));

        emit_state(app, PipelineState::Clipboard);
        emit_log(app, "info", "clipboard", "クリップボードへ書き込み");
        clipboard::write_text(app, &processed, config.avoid_clipboard_history)?;

        if config.auto_paste {
            tokio::time::sleep(std::time::Duration::from_millis(30)).await;
            let app_for_paste = app.clone();
            if let Err(err) = app.run_on_main_thread(move || {
                if let Err(err) = key_sender::send_paste() {
                    emit_log(
                        &app_for_paste,
                        "error",
                        "paste",
                        format!("自動ペースト失敗: {err}"),
                    );
                }
            }) {
                emit_log(
                    app,
                    "error",
                    "paste",
                    format!("自動ペースト実行失敗: {err}"),
                );
            }
        }

        let _ = sound::play_completion_sound();
        emit_state(app, PipelineState::Done);

        let elapsed = session.started_at.elapsed();
        println!(
            "recording finished in {}ms (stt_result={} chars, output={} chars)",
            elapsed.as_millis(),
            stt_result.chars().count(),
            processed.chars().count()
        );

        Ok::<_, AppError>(())
    }
    .await;

    let _ = tray::set_tray_state(app, TrayState::Idle);
    emit_state(app, PipelineState::Idle);
    let _ = app.emit("recording-state-changed", false);

    result
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

#[derive(Debug, Serialize, Clone)]
struct PipelineResult {
    stt: String,
    output: String,
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

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .setup(|app| {
            let config_manager = ConfigManager::new()?;
            let config = config_manager.load_or_create()?;

            app.manage(AppState {
                config_manager,
                config: Mutex::new(config.clone()),
                recording: Mutex::new(None),
                recording_counter: AtomicU64::new(0),
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
            open_accessibility_settings
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
