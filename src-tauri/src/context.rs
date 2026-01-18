pub fn capture_app_name() -> Option<String> {
    platform::frontmost_app_name()
}

#[cfg(target_os = "macos")]
mod platform {
    use objc2::rc::autoreleasepool;
    use objc2_app_kit::NSWorkspace;
    use objc2_foundation::NSString;

    pub fn frontmost_app_name() -> Option<String> {
        autoreleasepool(|_| {
            let workspace = NSWorkspace::sharedWorkspace();
            let app = workspace.frontmostApplication()?;
            let name: RetainedNSString = app.localizedName()?;
            Some(name.to_string())
        })
    }
    type RetainedNSString = objc2::rc::Retained<NSString>;
}

#[cfg(not(target_os = "macos"))]
mod platform {
    pub fn frontmost_app_name() -> Option<String> {
        None
    }
}
