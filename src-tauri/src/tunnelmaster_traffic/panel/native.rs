use super::LABEL;
use crate::{config::Config, process::AsyncHandler};
use std::{
    sync::atomic::{AtomicU64, Ordering},
    time::{Duration, Instant},
};
use tauri::{
    AppHandle, Manager as _, PhysicalPosition, Rect, WebviewUrl, WebviewWindow, WebviewWindowBuilder, WindowEvent,
    tray::{MouseButton, TrayIconEvent},
};

const DWELL: Duration = Duration::from_millis(310);
const LEAVE_GRACE: Duration = Duration::from_millis(430);
const BLUR_CLICK_GRACE: Duration = Duration::from_millis(180);

static REQUEST: AtomicU64 = AtomicU64::new(0);
static PREVIEW: AtomicU64 = AtomicU64::new(0);
static PRESENTATION: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
static DISMISSED_BY_BLUR: parking_lot::Mutex<Option<Instant>> = parking_lot::Mutex::new(None);

pub fn observe_pointer(app: &AppHandle, event: &TrayIconEvent) {
    match event {
        TrayIconEvent::Enter { position, rect, .. } => {
            let request = new_request();
            let (app, position, rect) = (app.clone(), *position, *rect);
            AsyncHandler::spawn(move || async move {
                tokio::time::sleep(DWELL).await;
                if let Err(error) = maybe_preview(app, request, position, rect).await {
                    clash_verge_logging::logging!(debug, clash_verge_logging::Type::Tray, "Traffic preview: {error}");
                }
            });
        }
        TrayIconEvent::Leave { .. } => {
            new_request();
        }
        TrayIconEvent::Click { button, .. } => {
            new_request();
            if *button != MouseButton::Left
                && PREVIEW.swap(0, Ordering::AcqRel) != 0
                && let Some(panel) = app.get_webview_window(LABEL)
            {
                let _ = panel.hide();
            }
        }
        _ => {}
    }
}

fn new_request() -> u64 {
    REQUEST.fetch_add(1, Ordering::AcqRel).wrapping_add(1)
}

async fn maybe_preview(app: AppHandle, request: u64, anchor: PhysicalPosition<f64>, icon: Rect) -> tauri::Result<()> {
    let settings = Config::verge().await.data_arc();
    if !settings.tray_event.as_deref().is_none_or(|value| value == "usage") {
        return Ok(());
    }
    let _guard = PRESENTATION.lock().await;
    if REQUEST.load(Ordering::Acquire) != request {
        return Ok(());
    }
    let scale = app
        .monitor_from_point(anchor.x, anchor.y)?
        .map_or(1.0, |monitor| monitor.scale_factor());
    let icon = Bounds::new(icon.position.to_physical(scale), icon.size.to_physical(scale));
    if !icon.contains(app.cursor_position()?) {
        return Ok(());
    }
    let panel = panel(&app)?;
    if panel.is_visible()? {
        return Ok(());
    }
    position_panel(&panel, anchor)?;
    PREVIEW.store(request, Ordering::Release);
    if let Err(error) = panel.show() {
        PREVIEW.store(0, Ordering::Release);
        return Err(error);
    }
    AsyncHandler::spawn(move || async move {
        monitor_preview(&panel, request, icon).await;
    });
    Ok(())
}

async fn monitor_preview(panel: &WebviewWindow, request: u64, icon: Bounds) {
    let mut last_inside = Instant::now();
    loop {
        tokio::time::sleep(Duration::from_millis(80)).await;
        if PREVIEW.load(Ordering::Acquire) != request || !panel.is_visible().unwrap_or(false) {
            return;
        }
        let inside = panel.cursor_position().ok().is_some_and(|pointer| {
            icon.contains(pointer)
                || panel
                    .outer_position()
                    .and_then(|position| panel.outer_size().map(|size| Bounds::new(position, size)))
                    .is_ok_and(|bounds| bounds.contains(pointer))
        });
        if inside {
            last_inside = Instant::now();
            continue;
        }
        if last_inside.elapsed() >= LEAVE_GRACE {
            let _guard = PRESENTATION.lock().await;
            if PREVIEW
                .compare_exchange(request, 0, Ordering::AcqRel, Ordering::Acquire)
                .is_ok()
            {
                let _ = panel.hide();
            }
            return;
        }
    }
}

pub async fn toggle(app: &AppHandle, cursor: PhysicalPosition<f64>) -> tauri::Result<()> {
    let _guard = PRESENTATION.lock().await;
    PREVIEW.store(0, Ordering::Release);
    let panel = panel(app)?;
    if panel.is_visible()? {
        return panel.hide();
    }
    if DISMISSED_BY_BLUR
        .lock()
        .take()
        .is_some_and(|instant| instant.elapsed() < BLUR_CLICK_GRACE)
    {
        return Ok(());
    }
    position_panel(&panel, cursor)?;
    panel.show()?;
    panel.set_focus()
}

fn panel(app: &AppHandle) -> tauri::Result<WebviewWindow> {
    if let Some(panel) = app.get_webview_window(LABEL) {
        return Ok(panel);
    }
    let panel = WebviewWindowBuilder::new(app, LABEL, WebviewUrl::App("/usage-tray".into()))
        .title("TunnelMaster Traffic")
        .inner_size(402.0, 510.0)
        .decorations(false)
        .resizable(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .visible(false)
        .focused(false)
        .general_autofill_enabled(false)
        .build()?;
    let target = panel.clone();
    panel.on_window_event(move |event| match event {
        WindowEvent::Focused(false) if target.is_visible().unwrap_or(false) => {
            PREVIEW.store(0, Ordering::Release);
            *DISMISSED_BY_BLUR.lock() = Some(Instant::now());
            let _ = target.hide();
        }
        WindowEvent::CloseRequested { api, .. } => {
            api.prevent_close();
            PREVIEW.store(0, Ordering::Release);
            let _ = target.hide();
        }
        _ => {}
    });
    Ok(panel)
}

fn position_panel(panel: &WebviewWindow, cursor: PhysicalPosition<f64>) -> tauri::Result<()> {
    if let Some(monitor) = panel.monitor_from_point(cursor.x, cursor.y)? {
        let area = monitor.work_area();
        let size = panel.outer_size()?;
        let left = f64::from(area.position.x);
        let right = left + (f64::from(area.size.width) - f64::from(size.width)).max(0.0);
        let top = f64::from(area.position.y);
        let bottom = top + (f64::from(area.size.height) - f64::from(size.height)).max(0.0);
        let x = (cursor.x - f64::from(size.width) / 2.0).clamp(left, right);
        let y = (cursor.y + 14.0 * monitor.scale_factor()).clamp(top, bottom);
        panel.set_position(PhysicalPosition::new(x, y))?;
    }
    Ok(())
}

#[derive(Clone, Copy)]
struct Bounds {
    position: PhysicalPosition<i32>,
    size: tauri::PhysicalSize<u32>,
}

impl Bounds {
    const fn new(position: PhysicalPosition<i32>, size: tauri::PhysicalSize<u32>) -> Self {
        Self { position, size }
    }

    fn contains(self, point: PhysicalPosition<f64>) -> bool {
        let dx = point.x - f64::from(self.position.x);
        let dy = point.y - f64::from(self.position.y);
        dx >= 0.0 && dx <= f64::from(self.size.width) && dy >= 0.0 && dy <= f64::from(self.size.height)
    }
}
