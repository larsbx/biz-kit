//! Fleet multi-tool.
//!
//! One local desktop app for the services, scripts, configs and health of
//! adder-ws / papa. Remote work goes over the user's existing ssh config,
//! so there is no new credential path and `papa` means what it means in a shell.
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

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![
            exec::list_hosts,
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
