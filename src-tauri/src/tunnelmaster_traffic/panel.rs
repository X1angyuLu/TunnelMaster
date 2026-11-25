use crate::cmd::{CmdResult, CommandFailure};
use crate::utils::window_manager::WindowManager;
use tauri::{AppHandle, Manager as _, WebviewWindow, WindowEvent};

const LABEL: &str = "usage-tray";

#[tauri::command]
#[specta::specta]
pub async fn open_tunnelmaster_usage(app: AppHandle) -> CmdResult<()> {
    if let Some(panel) = app.get_webview_window(LABEL) {
        let _ = panel.hide();
    }

    WindowManager::show_main_window().await;
    let window = app
        .get_webview_window("main")
        .ok_or_else(|| CommandFailure::plain("Main window is unavailable"))?;
    let url = window
        .url()
        .map_err(CommandFailure::plain)?
        .join("/usage")
        .map_err(CommandFailure::plain)?;
    window.navigate(url).map_err(CommandFailure::plain)
}

#[cfg(target_os = "macos")]
pub async fn toggle(app: &AppHandle, cursor: tauri::PhysicalPosition<f64>) -> tauri::Result<()> {
    use tauri::{WebviewUrl, WebviewWindowBuilder};
    use tokio::sync::Mutex;

    static OPEN_LOCK: Mutex<()> = Mutex::const_new(());
    let _lock = OPEN_LOCK.lock().await;
    let panel = match app.get_webview_window(LABEL) {
        Some(panel) if panel.is_visible()? => return panel.hide(),
        Some(panel) => panel,
        None => {
            let panel = WebviewWindowBuilder::new(app, LABEL, WebviewUrl::App("/usage-tray".into()))
                .title("TunnelMaster Traffic")
                .inner_size(402.0, 510.0)
                .decorations(false)
                .resizable(false)
                .always_on_top(true)
                .skip_taskbar(true)
                .visible(false)
                .general_autofill_enabled(false)
                .build()?;
            let target = panel.clone();
            panel.on_window_event(move |event| on_window_event(&target, event));
            panel
        }
    };

    if let Some(monitor) = panel.monitor_from_point(cursor.x, cursor.y)? {
        let area = monitor.work_area();
        let size = panel.outer_size()?;
        let scale = monitor.scale_factor();
        let panel_width = f64::from(size.width);
        let panel_height = f64::from(size.height);
        let left = f64::from(area.position.x);
        let right = left + (f64::from(area.size.width) - panel_width).max(0.0);
        let top = f64::from(area.position.y);
        let bottom = top + (f64::from(area.size.height) - panel_height).max(0.0);
        let x = (cursor.x - panel_width / 2.0).clamp(left, right);
        let y = (cursor.y + 14.0 * scale).clamp(top, bottom);
        panel.set_position(tauri::PhysicalPosition::new(x, y))?;
    }
    panel.show()?;
    panel.set_focus()
}

#[cfg(target_os = "macos")]
fn on_window_event(panel: &WebviewWindow, event: &WindowEvent) {
    match event {
        WindowEvent::Focused(false) => {
            let _ = panel.hide();
        }
        WindowEvent::CloseRequested { api, .. } => {
            api.prevent_close();
            let _ = panel.hide();
        }
        _ => {}
    }
}
