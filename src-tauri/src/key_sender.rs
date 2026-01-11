use crate::error::{AppError, AppResult};
use enigo::{Direction, Enigo, Key, Keyboard, Settings};

pub fn send_paste() -> AppResult<()> {
    let mut enigo =
        Enigo::new(&Settings::default()).map_err(|e| AppError::Other(e.to_string()))?;
    enigo
        .key(Key::Meta, Direction::Press)
        .map_err(|e| AppError::Other(e.to_string()))?;
    enigo
        .key(Key::Unicode('v'), Direction::Click)
        .map_err(|e| AppError::Other(e.to_string()))?;
    enigo
        .key(Key::Meta, Direction::Release)
        .map_err(|e| AppError::Other(e.to_string()))?;
    Ok(())
}

pub fn open_accessibility_settings() -> AppResult<()> {
    tauri_plugin_opener::open_url(
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        None::<&str>,
    )
    .map_err(|e| AppError::Other(e.to_string()))
}
