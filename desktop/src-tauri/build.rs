fn main() {
    let commands = &[
        "app_info",
        "run_on",
        "preview_command",
        "list_units",
        "unit_action_script",
        "host_health",
        "list_scripts",
        "run_script",
        "list_configs",
        "read_config",
        "diff_config",
        "write_config",
        "dispatch_status",
        "dispatch_sign_in",
        "dispatch_sign_out",
        "dispatch_request",
        "open_procurement",
        "operations_status",
        "operations_place",
        "operations_hide",
        "operations_reload",
    ];
    tauri_build::try_build(
        tauri_build::Attributes::new()
            .app_manifest(tauri_build::AppManifest::new().commands(commands)),
    )
    .expect("failed to build desktop command permissions");
}
