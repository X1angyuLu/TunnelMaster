use crate::cmd::{CmdResult, CommandFailure};
use crate::utils::window_manager::WindowManager;
use tauri::{AppHandle, Manager as _};

#[cfg(target_os = "macos")]
mod native;
#[cfg(target_os = "macos")]
pub(crate) use native::{observe_pointer, toggle};

#[cfg(all(target_os = "macos", feature = "usage-window-smoke"))]
mod smoke;
#[cfg(all(target_os = "macos", feature = "usage-window-smoke"))]
pub use smoke::run_window_smoke;

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
