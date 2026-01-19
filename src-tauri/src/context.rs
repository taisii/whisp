use crate::error::AppResult;

pub fn capture_app_name() -> Option<String> {
    platform::frontmost_app_name()
}

pub fn capture_accessibility_text() -> AppResult<Option<String>> {
    platform::selected_text().map(|text| {
        let trimmed = text.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        }
    })
}

pub fn capture_screenshot() -> AppResult<Option<Vec<u8>>> {
    let bytes = platform::screenshot_png()?;
    if bytes.is_empty() {
        Ok(None)
    } else {
        Ok(Some(bytes))
    }
}

#[cfg(target_os = "macos")]
mod platform {
    use crate::error::{AppError, AppResult};
    use get_selected_text::get_selected_text;
    use objc2::rc::autoreleasepool;
    use objc2_app_kit::NSWorkspace;
    use objc2_foundation::NSString;
    use std::process::Command;
    use std::time::{SystemTime, UNIX_EPOCH};

    pub fn frontmost_app_name() -> Option<String> {
        autoreleasepool(|_| {
            let workspace = NSWorkspace::sharedWorkspace();
            let app = workspace.frontmostApplication()?;
            let name: RetainedNSString = app.localizedName()?;
            Some(name.to_string())
        })
    }

    pub fn selected_text() -> AppResult<String> {
        get_selected_text()
            .map_err(|err| AppError::Other(format!("selected text error: {err}")))
    }

    pub fn screenshot_png() -> AppResult<Vec<u8>> {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis();
        let path = std::env::temp_dir().join(format!("whisp-context-{now}.png"));
        let status = Command::new("screencapture")
            .arg("-x")
            .arg("-t")
            .arg("png")
            .arg(&path)
            .status()
            .map_err(|err| AppError::Other(format!("screencapture failed: {err}")))?;
        if !status.success() {
            return Err(AppError::Other(format!(
                "screencapture failed: {status}"
            )));
        }
        let bytes = std::fs::read(&path)?;
        let _ = std::fs::remove_file(&path);
        Ok(bytes)
    }
    type RetainedNSString = objc2::rc::Retained<NSString>;
}

#[cfg(not(target_os = "macos"))]
mod platform {
    use super::AppResult;

    pub fn frontmost_app_name() -> Option<String> {
        None
    }

    pub fn selected_text() -> AppResult<String> {
        Ok(String::new())
    }

    pub fn screenshot_png() -> AppResult<Vec<u8>> {
        Ok(Vec::new())
    }
}
