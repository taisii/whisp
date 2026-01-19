use crate::error::{AppError, AppResult};

#[cfg(target_os = "macos")]
mod macos {
    use super::{AppError, AppResult};
    use core_foundation_sys::base::CFRelease;
    use std::ffi::c_void;

    type CGEventRef = *mut c_void;
    type CGEventSourceRef = *mut c_void;
    type CGEventSourceStateID = u32;
    type CGEventTapLocation = u32;

    const CG_EVENT_SOURCE_STATE_COMBINED_SESSION_STATE: CGEventSourceStateID = 0;
    const CG_EVENT_TAP_LOCATION_HID: CGEventTapLocation = 0;
    const MAX_UNICODE_CHUNK: usize = 20;

    #[link(name = "ApplicationServices", kind = "framework")]
    extern "C" {
        fn AXIsProcessTrusted() -> bool;
    }

    #[link(name = "CoreGraphics", kind = "framework")]
    extern "C" {
        fn CGEventSourceCreate(state_id: CGEventSourceStateID) -> CGEventSourceRef;
        fn CGEventCreateKeyboardEvent(
            source: CGEventSourceRef,
            virtual_key: u16,
            key_down: bool,
        ) -> CGEventRef;
        fn CGEventKeyboardSetUnicodeString(
            event: CGEventRef,
            string_length: usize,
            unicode_string: *const u16,
        );
        fn CGEventPost(tap: CGEventTapLocation, event: CGEventRef);
    }

    fn is_accessibility_trusted() -> bool {
        unsafe { AXIsProcessTrusted() }
    }

    /// Request accessibility permission, showing a dialog if not already granted.
    /// Returns true if permission is granted.
    #[allow(dead_code)]
    pub fn request_accessibility_permission() -> bool {
        is_accessibility_trusted()
    }

    pub fn send_text(text: &str) -> AppResult<()> {
        if !is_accessibility_trusted() {
            return Err(AppError::AccessibilityPermissionRequired);
        }

        let utf16: Vec<u16> = text.encode_utf16().collect();
        if utf16.is_empty() {
            return Ok(());
        }

        for chunk in utf16.chunks(MAX_UNICODE_CHUNK) {
            unsafe {
                let source = CGEventSourceCreate(CG_EVENT_SOURCE_STATE_COMBINED_SESSION_STATE);
                if source.is_null() {
                    return Err(AppError::Other("CGEventSourceCreate failed".to_string()));
                }

                let key_down = CGEventCreateKeyboardEvent(source, 0, true);
                if key_down.is_null() {
                    CFRelease(source);
                    return Err(AppError::Other("CGEventCreateKeyboardEvent failed".to_string()));
                }
                CGEventKeyboardSetUnicodeString(key_down, chunk.len(), chunk.as_ptr());
                CGEventPost(CG_EVENT_TAP_LOCATION_HID, key_down);
                CFRelease(key_down);

                let key_up = CGEventCreateKeyboardEvent(source, 0, false);
                if key_up.is_null() {
                    CFRelease(source);
                    return Err(AppError::Other("CGEventCreateKeyboardEvent failed".to_string()));
                }
                CGEventKeyboardSetUnicodeString(key_up, chunk.len(), chunk.as_ptr());
                CGEventPost(CG_EVENT_TAP_LOCATION_HID, key_up);
                CFRelease(key_up);

                CFRelease(source);
            }
        }

        Ok(())
    }
}

#[cfg(target_os = "macos")]
pub fn send_text(text: &str) -> AppResult<()> {
    macos::send_text(text)
}

#[cfg(not(target_os = "macos"))]
pub fn send_text(_text: &str) -> AppResult<()> {
    Err(AppError::Other(
        "direct input is only supported on macOS".to_string(),
    ))
}

/// Request accessibility permission, showing a dialog if not already granted.
/// Returns true if permission is granted.
#[cfg(target_os = "macos")]
#[allow(dead_code)]
pub fn request_accessibility_permission() -> bool {
    macos::request_accessibility_permission()
}

#[cfg(not(target_os = "macos"))]
#[allow(dead_code)]
pub fn request_accessibility_permission() -> bool {
    true // Non-macOS platforms don't need accessibility permission
}
