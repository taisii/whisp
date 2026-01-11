use crate::error::{AppError, AppResult};
use tauri::AppHandle;
use tauri_plugin_clipboard_manager::ClipboardExt;

pub fn write_text(app: &AppHandle, text: &str) -> AppResult<()> {
    app.clipboard()
        .write_text(text.to_string())
        .map_err(|e| AppError::Other(e.to_string()))
}
