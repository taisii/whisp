use crate::error::{AppError, AppResult};

pub fn open_accessibility_settings() -> AppResult<()> {
    tauri_plugin_opener::open_url(
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        None::<&str>,
    )
    .map_err(|e| AppError::Other(e.to_string()))
}
