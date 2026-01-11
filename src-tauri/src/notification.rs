use crate::error::{AppError, AppResult};
use tauri::AppHandle;
use tauri_plugin_notification::{NotificationExt, PermissionState};

pub fn request_permission(app: &AppHandle) -> AppResult<()> {
    let permission = app
        .notification()
        .permission_state()
        .map_err(|e| AppError::Other(e.to_string()))?;
    if permission != PermissionState::Granted {
        let _ = app
            .notification()
            .request_permission()
            .map_err(|e| AppError::Other(e.to_string()))?;
    }
    Ok(())
}

pub fn notify_error(app: &AppHandle, message: &str) -> AppResult<()> {
    let notification = app
        .notification()
        .builder()
        .title("Whisp")
        .body(message);
    notification
        .show()
        .map_err(|e| AppError::Other(e.to_string()))
}
