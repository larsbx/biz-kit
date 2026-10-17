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

mod configs;
mod exec;
mod health;
mod scripts;
mod services;
mod settings;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
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
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
