use crate::error::{AppError, AppResult};
use crate::notification;
use tauri::menu::{Menu, MenuItem};
    use tauri::tray::{MouseButton, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrayState {
    Idle,
    Recording,
}

pub fn build_tray(app: &AppHandle) -> AppResult<()> {
    let open_item = MenuItem::with_id(app, "open_settings", "設定を開く", true, None::<&str>)
        .map_err(|e| AppError::Other(e.to_string()))?;
    let quit_item = MenuItem::with_id(app, "quit", "終了", true, None::<&str>)
        .map_err(|e| AppError::Other(e.to_string()))?;
    let menu = Menu::with_items(app, &[&open_item, &quit_item])
        .map_err(|e| AppError::Other(e.to_string()))?;

    TrayIconBuilder::with_id("main")
        .menu(&menu)
        .icon(tray_icon(TrayState::Idle))
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "open_settings" => {
                if let Err(err) = show_settings_window(app) {
                    let _ = notification::notify_error(
                        app,
                        &format!("設定ウィンドウを開けませんでした: {err}"),
                    );
                }
            }
            "quit" => {
                app.exit(0);
            }
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                ..
            } = event
            {
                if let Err(err) = show_settings_window(tray.app_handle()) {
                    let app = tray.app_handle();
                    let _ = notification::notify_error(
                        app,
                        &format!("設定ウィンドウを開けませんでした: {err}"),
                    );
                }
            }
        })
        .build(app)
        .map_err(|e| AppError::Other(e.to_string()))?;

    Ok(())
}

pub fn set_tray_state(app: &AppHandle, state: TrayState) -> AppResult<()> {
    if let Some(tray) = app.tray_by_id("main") {
        tray.set_icon(Some(tray_icon(state)))
            .map_err(|e| AppError::Other(e.to_string()))?;
    }
    Ok(())
}

fn show_settings_window(app: &AppHandle) -> AppResult<()> {
    if let Some(window) = app.get_webview_window("main") {
        window
            .show()
            .and_then(|_| window.set_focus())
            .map_err(|e| AppError::Other(e.to_string()))?;
    }
    Ok(())
}

fn tray_icon(state: TrayState) -> tauri::image::Image<'static> {
    let size = 24u32;
    let mut rgba = vec![0u8; (size * size * 4) as usize];
    let center = (size as f32 - 1.0) / 2.0;
    let radius = size as f32 * 0.28;

    let color = match state {
        TrayState::Idle => [120u8, 120u8, 120u8, 255u8],
        TrayState::Recording => [210u8, 52u8, 44u8, 255u8],
    };

    for y in 0..size {
        for x in 0..size {
            let dx = x as f32 - center;
            let dy = y as f32 - center;
            let distance = (dx * dx + dy * dy).sqrt();
            if distance <= radius {
                let idx = ((y * size + x) * 4) as usize;
                rgba[idx] = color[0];
                rgba[idx + 1] = color[1];
                rgba[idx + 2] = color[2];
                rgba[idx + 3] = color[3];
            }
        }
    }

    tauri::image::Image::new_owned(rgba, size, size)
}
