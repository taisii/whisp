use crate::config::{Config, ContextRule};

#[derive(Debug, Clone, Default)]
pub struct ContextInfo {
    pub app_name: Option<String>,
    pub selected_text: Option<String>,
    pub instruction: Option<String>,
}

const CODE_STYLE_INSTRUCTION: &str =
    "出力はコード形式（技術用語優先、簡潔）でお願いします。";

const DEFAULT_RULES: &[(&[&str], &str)] = &[
    (&["Visual Studio Code", "VSCode", "Cursor", "Xcode", "Terminal"], CODE_STYLE_INSTRUCTION),
    (&["Claude Code"], CODE_STYLE_INSTRUCTION),
    (&["Codex"], CODE_STYLE_INSTRUCTION),
];

pub fn build_context_info(config: &Config) -> ContextInfo {
    let (app_name, selected_text) = platform::capture_context();
    let instruction = resolve_instruction(app_name.as_deref(), &config.context_rules);
    ContextInfo {
        app_name,
        selected_text,
        instruction,
    }
}

pub fn capture_app_name() -> Option<String> {
    platform::frontmost_app_name()
}

pub fn format_context_block(info: &ContextInfo) -> Option<String> {
    let mut sections = Vec::new();

    if let Some(text) = info
        .selected_text
        .as_ref()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
    {
        sections.push(format!("選択テキスト:\n{text}"));
    }

    if let Some(instruction) = info
        .instruction
        .as_ref()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
    {
        sections.push(format!("追加指示: {instruction}"));
    }

    if sections.is_empty() {
        None
    } else {
        Some(sections.join("\n"))
    }
}

fn resolve_instruction(app_name: Option<&str>, user_rules: &[ContextRule]) -> Option<String> {
    let app_name = app_name?.trim();
    if app_name.is_empty() {
        return None;
    }
    let app_lower = app_name.to_lowercase();

    for rule in user_rules {
        let pattern = rule.app_name.trim();
        let instruction = rule.instruction.trim();
        if pattern.is_empty() || instruction.is_empty() {
            continue;
        }
        if app_lower.contains(&pattern.to_lowercase()) {
            return Some(instruction.to_string());
        }
    }

    for (patterns, instruction) in DEFAULT_RULES {
        if patterns
            .iter()
            .any(|pattern| app_lower.contains(&pattern.to_lowercase()))
        {
            return Some((*instruction).to_string());
        }
    }

    None
}

#[cfg(target_os = "macos")]
mod platform {
    use core_foundation_sys::base::{kCFAllocatorDefault, CFRelease, CFTypeRef};
    use core_foundation_sys::string::{
        CFStringCreateWithCString, CFStringGetCString, CFStringGetLength,
        CFStringGetMaximumSizeForEncoding, CFStringRef, kCFStringEncodingUTF8,
    };
    use objc2::rc::autoreleasepool;
    use objc2_app_kit::NSWorkspace;
    use objc2_foundation::NSString;
    use std::ffi::{c_void, CStr, CString};
    use std::ptr;

    type AXUIElementRef = *const c_void;
    type AXError = i32;
    const AX_ERROR_SUCCESS: AXError = 0;

    extern "C" {
        fn AXUIElementCreateSystemWide() -> AXUIElementRef;
        fn AXUIElementCopyAttributeValue(
            element: AXUIElementRef,
            attribute: CFStringRef,
            value: *mut CFTypeRef,
        ) -> AXError;
        fn CFGetTypeID(cf: CFTypeRef) -> u64;
        fn CFStringGetTypeID() -> u64;
    }

    pub fn capture_context() -> (Option<String>, Option<String>) {
        (frontmost_app_name(), selected_text())
    }

    pub fn frontmost_app_name() -> Option<String> {
        autoreleasepool(|_| {
            let workspace = NSWorkspace::sharedWorkspace();
            let app = workspace.frontmostApplication()?;
            let name: RetainedNSString = app.localizedName()?;
            Some(name.to_string())
        })
    }

    fn selected_text() -> Option<String> {
        unsafe {
            let system = AXUIElementCreateSystemWide();
            if system.is_null() {
                return None;
            }

            let focused_attr = match cfstring_from_static("AXFocusedUIElement") {
                Some(attr) => attr,
                None => {
                    CFRelease(system as CFTypeRef);
                    return None;
                }
            };
            let mut focused: CFTypeRef = ptr::null_mut();
            let err = AXUIElementCopyAttributeValue(system, focused_attr, &mut focused);
            CFRelease(focused_attr as CFTypeRef);
            CFRelease(system as CFTypeRef);
            if err != AX_ERROR_SUCCESS || focused.is_null() {
                return None;
            }

            let selected_attr = match cfstring_from_static("AXSelectedText") {
                Some(attr) => attr,
                None => {
                    CFRelease(focused);
                    return None;
                }
            };
            let mut selected: CFTypeRef = ptr::null_mut();
            let err =
                AXUIElementCopyAttributeValue(focused as AXUIElementRef, selected_attr, &mut selected);
            CFRelease(selected_attr as CFTypeRef);
            CFRelease(focused);
            if err != AX_ERROR_SUCCESS || selected.is_null() {
                return None;
            }

            let text = cf_type_to_string(selected);
            CFRelease(selected);
            text
        }
    }

    unsafe fn cf_type_to_string(value: CFTypeRef) -> Option<String> {
        if value.is_null() {
            return None;
        }
        if CFGetTypeID(value) != CFStringGetTypeID() {
            return None;
        }
        cfstring_to_string(value as CFStringRef)
    }

    unsafe fn cfstring_to_string(value: CFStringRef) -> Option<String> {
        if value.is_null() {
            return None;
        }
        let length = CFStringGetLength(value);
        if length <= 0 {
            return Some(String::new());
        }
        let max_size = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
        let mut buffer = vec![0u8; max_size as usize];
        let success = CFStringGetCString(
            value,
            buffer.as_mut_ptr() as *mut i8,
            buffer.len() as isize,
            kCFStringEncodingUTF8,
        );
        if success == 0 {
            return None;
        }
        let cstr = CStr::from_ptr(buffer.as_ptr() as *const i8);
        Some(cstr.to_string_lossy().into_owned())
    }

    unsafe fn cfstring_from_static(value: &str) -> Option<CFStringRef> {
        let cstring = CString::new(value).ok()?;
        let cfstring =
            CFStringCreateWithCString(kCFAllocatorDefault, cstring.as_ptr(), kCFStringEncodingUTF8);
        if cfstring.is_null() {
            None
        } else {
            Some(cfstring)
        }
    }

    type RetainedNSString = objc2::rc::Retained<NSString>;
}

#[cfg(not(target_os = "macos"))]
mod platform {
    pub fn capture_context() -> (Option<String>, Option<String>) {
        (None, None)
    }

    pub fn frontmost_app_name() -> Option<String> {
        None
    }
}
