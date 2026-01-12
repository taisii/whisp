use crate::error::{AppError, AppResult};
use tauri::AppHandle;
use tauri_plugin_clipboard_manager::ClipboardExt;

#[cfg(target_os = "macos")]
mod macos {
    use objc2::rc::autoreleasepool;
    use objc2_app_kit::{NSPasteboard, NSPasteboardTypeString};
    use objc2_foundation::{NSData, NSString};

    const TRANSIENT_TYPE: &str = "org.nspasteboard.TransientType";

    pub fn write_text_transient(text: &str) -> Result<(), String> {
        autoreleasepool(|_| {
            let pasteboard = NSPasteboard::generalPasteboard();
            pasteboard.clearContents();

            let ns_text = NSString::from_str(text);
            let string_type = unsafe { NSPasteboardTypeString };
            if !pasteboard.setString_forType(&ns_text, string_type) {
                return Err("NSPasteboard setString failed".to_string());
            }

            let marker = NSString::from_str(TRANSIENT_TYPE);
            let data = NSData::new();
            if !pasteboard.setData_forType(Some(&data), &marker) {
                return Err("NSPasteboard setData failed".to_string());
            }

            Ok(())
        })
    }
}

pub fn write_text(app: &AppHandle, text: &str, avoid_history: bool) -> AppResult<()> {
    #[cfg(target_os = "macos")]
    if avoid_history {
        if macos::write_text_transient(text).is_ok() {
            return Ok(());
        }
    }

    app.clipboard()
        .write_text(text.to_string())
        .map_err(|e| AppError::Other(e.to_string()))
}
