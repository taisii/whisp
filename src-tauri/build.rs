fn main() {
    tauri_build::build();
    #[cfg(target_os = "macos")]
    {
        println!("cargo:rustc-link-lib=framework=ApplicationServices");
        println!("cargo:rustc-link-lib=framework=Accessibility");
    }
}
