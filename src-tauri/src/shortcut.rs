use crate::error::{AppError, AppResult};
use std::sync::Arc;
use tauri::AppHandle;
use tauri_plugin_global_shortcut::{GlobalShortcutExt, ShortcutEvent, ShortcutState};

pub fn register_shortcut(
    app: &AppHandle,
    shortcut: &str,
    handler: impl Fn(AppHandle, ShortcutState) + Send + Sync + 'static,
) -> AppResult<()> {
    let handler = Arc::new(handler);
    app.global_shortcut()
        .on_shortcut(shortcut, move |app, _shortcut, event: ShortcutEvent| {
            handler(app.clone(), event.state);
        })
        .map_err(|e| AppError::Shortcut(e.to_string()))
}

pub fn unregister_shortcut(app: &AppHandle, shortcut: &str) -> AppResult<()> {
    app.global_shortcut()
        .unregister(shortcut)
        .map_err(|e| AppError::Shortcut(e.to_string()))
}

pub fn is_registered(app: &AppHandle, shortcut: &str) -> bool {
    app.global_shortcut().is_registered(shortcut)
}
