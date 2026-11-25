#[cfg(target_os = "macos")]
fn main() -> anyhow::Result<std::process::ExitCode> {
    let code = app_lib::run_window_smoke()?;
    Ok(std::process::ExitCode::from(if code == 0 { 0 } else { 1 }))
}

#[cfg(not(target_os = "macos"))]
fn main() -> std::process::ExitCode {
    eprintln!("This test requires macOS");
    std::process::ExitCode::FAILURE
}
