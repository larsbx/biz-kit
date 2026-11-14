//! biz-kit.
//!
//! A desktop app for the services, scripts, configs and health of a small set
//! of Linux hosts. Remote work goes over the user's existing ssh config, so
//! there is no new credential path and a host alias means what it means in a
//! shell. Everything installation-specific lives in `settings`.
//!
//! Write posture: nothing that stops, disables, deletes or overwrites happens
//! without the UI first showing the exact command or diff and the user
//! confirming it. The backend enforces the half that matters -- action verbs and
//! script arguments are allowlisted here, not merely hidden in the frontend.

mod config_edit;
mod configs;
mod dispatch;
mod exec;
mod health;
mod operations;
mod procurement;
mod procurement_settings;
mod scripts;
mod services;
mod settings;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .setup(|app| {
            main_window(app.handle())?;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            settings::app_info,
            exec::run_on,
            exec::preview_command,
            services::list_units,
            services::unit_action_script,
            health::host_health,
            scripts::list_scripts,
            scripts::run_script,
            configs::list_configs,
            configs::read_config,
            configs::diff_config,
            configs::write_config,
            dispatch::dispatch_status,
            dispatch::dispatch_sign_in,
            dispatch::dispatch_sign_out,
            dispatch::dispatch_request,
            procurement::open_procurement,
            procurement_settings::procurement_status,
            procurement_settings::save_procurement_origin,
            operations::operations_status,
            operations::operations_place,
            operations::operations_hide,
            operations::operations_reload,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

/// The window is built here rather than in tauri.conf.json because it holds
/// two webviews: the app itself (`main`, filling the window) and, once its tile
/// is open, the Operations page laid over that tile (`operations.rs`). Only
/// `main` is named by the capability, so only it reaches the commands.
fn main_window(app: &tauri::AppHandle) -> Result<(), Box<dyn std::error::Error>> {
    use tauri::{LogicalPosition, LogicalSize, WebviewBuilder, WebviewUrl, WindowBuilder};
    let (w, h) = (1280.0, 840.0);
    let window = WindowBuilder::new(app, "main")
        .title("biz-kit")
        .inner_size(w, h)
        .min_inner_size(900.0, 560.0)
        .resizable(true)
        // The Crew Deck's own title bar (ui/index.html) replaces the system one.
        .decorations(false)
        .build()?;
    window.add_child(
        WebviewBuilder::new("main", WebviewUrl::App("index.html".into())).auto_resize(),
        LogicalPosition::new(0.0, 0.0),
        LogicalSize::new(w, h),
    )?;
    operations::install(&window)?;
    Ok(())
}
