use super::{LABEL, toggle};
use anyhow::{Context as _, Result, ensure};
use std::time::Duration;
use tauri::{AppHandle, Manager as _, PhysicalPosition, WebviewUrl, WebviewWindowBuilder};

pub fn run_window_smoke() -> Result<i32> {
    ensure!(
        std::env::var("GITHUB_ACTIONS").as_deref() == Ok("true")
            && std::env::var("RUNNER_ENVIRONMENT").as_deref() == Ok("github-hosted"),
        "Run against a disposable hosted macOS GUI session"
    );
    let app = tauri::Builder::default()
        .setup(|app| {
            app.handle().set_activation_policy(tauri::ActivationPolicy::Regular)?;
            let app = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                let result = tokio::time::timeout(Duration::from_secs(15), exercise_window(&app)).await;
                let code = match result {
                    Ok(Ok(())) => {
                        println!("The native usage window toggled and dismissed when another window received focus.");
                        0
                    }
                    other => {
                        eprintln!("Could not validate the native usage window: {other:?}");
                        1
                    }
                };
                app.exit(code);
            });
            Ok(())
        })
        .build(tauri::generate_context!())?;
    Ok(app.run_return(|_, _| {}))
}

async fn exercise_window(app: &AppHandle) -> Result<()> {
    let monitor = app.primary_monitor()?.context("No primary monitor")?;
    let anchor = PhysicalPosition::new(
        f64::from(monitor.position().x) + 180.0,
        f64::from(monitor.position().y) + 20.0,
    );
    let other = WebviewWindowBuilder::new(app, "smoke-main", WebviewUrl::App("/".into()))
        .title("TunnelMaster smoke test")
        .inner_size(380.0, 260.0)
        .visible(true)
        .focused(true)
        .build()?;
    toggle(app, anchor).await?;
    let panel = app.get_webview_window(LABEL).context("Usage window was not created")?;
    await_window(|| panel.is_visible().unwrap_or(false) && panel.is_focused().unwrap_or(false)).await?;

    toggle(app, anchor).await?;
    await_window(|| !panel.is_visible().unwrap_or(true)).await?;
    tokio::time::sleep(Duration::from_millis(220)).await;

    toggle(app, anchor).await?;
    await_window(|| panel.is_visible().unwrap_or(false) && panel.is_focused().unwrap_or(false)).await?;
    other.set_focus()?;
    await_window(|| !panel.is_visible().unwrap_or(true)).await?;
    Ok(())
}

async fn await_window(check: impl Fn() -> bool) -> Result<()> {
    for _ in 0..30 {
        if check() {
            return Ok(());
        }
        tokio::time::sleep(Duration::from_millis(75)).await;
    }
    anyhow::bail!("Expected native focus or visibility did not arrive");
}
