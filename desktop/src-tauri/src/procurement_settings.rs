//! Explicit, local-only setup for the Procurement launcher. No server or account
//! is provisioned here. Preserve unknown config fields and refuse stale saves.
use crate::{procurement::host_url, settings};
use serde::Serialize;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{fs, io::Write, path::{Path, PathBuf}};
use tauri::{AppHandle, Manager};

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProcurementStatus {
    pub origin: Option<String>,
    pub configured: bool,
    pub revision: String,
    pub problem: Option<String>,
}

fn read(path: &Path) -> Result<Option<String>, String> {
    match fs::symlink_metadata(path) {
        Ok(meta) if !meta.file_type().is_file() =>
            return Err("Desktop settings must be a regular file, not a symbolic link.".into()),
        Ok(_) => (),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(format!("Cannot inspect desktop settings: {e}")),
    }
    fs::read_to_string(path).map(Some).map_err(|e| format!("Cannot read desktop settings: {e}"))
}

fn revision(raw: &Option<String>) -> String {
    let mut hash = Sha256::new();
    hash.update(b"biz-kit-procurement-settings-v1\0");
    hash.update([u8::from(raw.is_some())]);
    if let Some(raw) = raw { hash.update(raw.as_bytes()); }
    format!("{:x}", hash.finalize())
}

fn document(raw: &Option<String>) -> Result<Value, String> {
    let text = raw.as_deref().unwrap_or("{}");
    // Validate known settings too; never silently repair/reset malformed files.
    settings::Settings::parse(text)?;
    let value: Value = serde_json::from_str(text).map_err(|e| e.to_string())?;
    if !value.is_object() { return Err("Desktop settings must be a JSON object.".into()); }
    Ok(value)
}

fn status_at(path: &Path) -> Result<ProcurementStatus, String> {
    let raw = read(path)?;
    let doc = document(&raw)?;
    let configured = doc.get("procurementOrigin").and_then(Value::as_str);
    let (origin, problem) = match configured {
        Some(value) => match host_url(value) {
            Ok(url) => (Some(url.to_string()), None),
            Err(problem) => (None, Some(problem)),
        },
        None => (None, Some("Add the HTTPS address of your running Procurement server.".into())),
    };
    Ok(ProcurementStatus { configured: origin.is_some(), origin, revision: revision(&raw), problem })
}

#[tauri::command]
pub fn procurement_status() -> Result<ProcurementStatus, String> {
    status_at(&settings::path())
}

// Use the same lock name as the existing Configs editor. This serializes
// cooperating writers; it is not an OS-wide lock on unrelated external editors.
struct SaveLock(PathBuf);
impl Drop for SaveLock {
    fn drop(&mut self) {
        let _ = fs::remove_file(self.0.join("new"));
        let _ = fs::remove_dir(&self.0);
    }
}

fn save_at(path: &Path, origin: &str, expected: &str) -> Result<ProcurementStatus, String> {
    let origin = host_url(origin.trim())?.to_string();
    let parent = path.parent().ok_or("Desktop settings path has no parent.")?;
    // Refuse malformed or stale input before creating anything.
    let initial = read(path)?;
    document(&initial)?;
    if revision(&initial) != expected {
        return Err("Desktop settings changed. Reload the connection before saving again.".into());
    }
    fs::create_dir_all(parent).map_err(|e| format!("Cannot create settings directory: {e}"))?;
    let mut lock_name = path.as_os_str().to_os_string();
    lock_name.push(".biz-kit-save-lock");
    let lock_path = PathBuf::from(lock_name);
    fs::create_dir(&lock_path).map_err(|e| format!("Cannot lock desktop settings (another save may be active): {e}"))?;
    let lock = SaveLock(lock_path);
    let raw = read(path)?;
    if revision(&raw) != expected {
        return Err("Desktop settings changed. Reload the connection before saving again.".into());
    }
    let mut doc = document(&raw)?;
    doc["procurementOrigin"] = Value::String(origin);
    let content = format!("{}\n", serde_json::to_string_pretty(&doc).map_err(|e| e.to_string())?);
    let temp = lock.0.join("new");
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)] {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&temp).map_err(|e| format!("Cannot stage settings: {e}"))?;
    file.write_all(content.as_bytes()).map_err(|e| format!("Cannot write staged settings: {e}"))?;
    if raw.is_some() {
        let original = fs::metadata(path).map_err(|e| e.to_string())?;
        #[cfg(unix)] {
            use std::os::unix::fs::MetadataExt;
            let staged = file.metadata().map_err(|e| e.to_string())?;
            if (original.uid(), original.gid()) != (staged.uid(), staged.gid()) {
                return Err("Cannot preserve settings owner/group. Edit the file with its owner's account.".into());
            }
        }
        file.set_permissions(original.permissions()).map_err(|e| e.to_string())?;
    }
    file.sync_all().map_err(|e| e.to_string())?;
    drop(file);
    if read(path)? != raw {
        return Err("Desktop settings changed during save. Reload and review again.".into());
    }
    fs::rename(&temp, path).map_err(|e| format!("Cannot replace desktop settings: {e}"))?;
    status_at(path)
}

#[tauri::command]
pub fn save_procurement_origin(app: AppHandle, origin: String, expected_revision: String) -> Result<ProcurementStatus, String> {
    let next = host_url(origin.trim())?;
    if let Some(window) = app.get_webview_window("procurement") {
        let current = window.url().map_err(|e| e.to_string())?;
        if current.origin() != next.origin() {
            return Err("Close the existing Procurement window before changing servers.".into());
        }
    }
    save_at(&settings::path(), next.as_str(), &expected_revision)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let dir = std::env::temp_dir().join(format!("procurement-connection-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)));
            fs::create_dir(&dir).unwrap();
            Self(dir)
        }
        fn path(&self) -> PathBuf { self.0.join("config.json") }
    }
    impl Drop for Fixture { fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); } }

    #[test]
    fn missing_configuration_can_be_saved_and_read_back() {
        let f = Fixture::new();
        let before = status_at(&f.path()).unwrap();
        assert!(!before.configured);
        let after = save_at(&f.path(), " https://procurement.example.org:8443 ", &before.revision).unwrap();
        assert_eq!(after.origin.as_deref(), Some("https://procurement.example.org:8443/"));
        assert!(after.configured);
        assert_ne!(before.revision, after.revision);
        assert_eq!(status_at(&f.path()).unwrap().revision, after.revision);
        assert_eq!(fs::read_dir(&f.0).unwrap().count(), 1);
    }

    #[test]
    fn saves_preserve_unrelated_and_unknown_settings() {
        let f = Fixture::new();
        let original = serde_json::json!({"hosts": [], "future": {"nested": [1, 2]}, "operationsUrl": "https://ops.example.org/operations"});
        fs::write(f.path(), original.to_string()).unwrap();
        let before = status_at(&f.path()).unwrap();
        save_at(&f.path(), "https://procurement.example.org", &before.revision).unwrap();
        let mut after: Value = serde_json::from_str(&fs::read_to_string(f.path()).unwrap()).unwrap();
        after.as_object_mut().unwrap().remove("procurementOrigin");
        assert_eq!(after, original);
    }

    #[test]
    fn stale_review_cannot_overwrite_a_changed_config() {
        let f = Fixture::new();
        let old = status_at(&f.path()).unwrap();
        fs::write(f.path(), "{\"hosts\": []}").unwrap();
        assert!(save_at(&f.path(), "https://procurement.example.org", &old.revision).is_err());
        assert_eq!(fs::read_to_string(f.path()).unwrap(), "{\"hosts\": []}");
    }

    #[test]
    fn invalid_origin_is_refused_without_creating_a_file() {
        let f = Fixture::new();
        let before = status_at(&f.path()).unwrap();
        for origin in ["", "http://localhost:4003", "https://user:secret@example.org", "https://example.org/login", "https://example.org/?key=x", "javascript:alert(1)"] {
            assert!(save_at(&f.path(), origin, &before.revision).is_err());
            assert!(!f.path().exists());
        }
    }

    #[test]
    fn malformed_config_is_not_replaced_with_defaults() {
        let f = Fixture::new();
        for text in ["{", "[]", "null", "{\"hosts\":17}"] {
            fs::write(f.path(), text).unwrap();
            assert!(status_at(&f.path()).is_err());
            assert!(save_at(&f.path(), "https://example.org", &revision(&Some(text.into()))).is_err());
            assert_eq!(fs::read_to_string(f.path()).unwrap(), text);
        }
    }

    #[test]
    fn invalid_legacy_origin_is_not_disclosed_and_can_be_corrected() {
        let f = Fixture::new();
        fs::write(f.path(), r#"{"procurementOrigin":"https://user:secret@example.org"}"#).unwrap();
        let before = status_at(&f.path()).unwrap();
        assert!(!before.configured);
        assert!(before.origin.is_none());
        assert!(!before.problem.unwrap().contains("secret"));
        assert!(save_at(&f.path(), "https://example.org", &before.revision).unwrap().configured);
    }

    #[test]
    fn held_editor_lock_refuses_save_without_removing_that_lock() {
        let f = Fixture::new();
        let before = status_at(&f.path()).unwrap();
        let lock = f.0.join("config.json.biz-kit-save-lock");
        fs::create_dir(&lock).unwrap();
        assert!(save_at(&f.path(), "https://example.org", &before.revision).is_err());
        assert!(lock.is_dir());
        assert!(!f.path().exists());
    }

    #[cfg(unix)]
    #[test]
    fn symlinks_are_refused_and_existing_permissions_are_preserved() {
        use std::os::unix::fs::{symlink, PermissionsExt};
        let f = Fixture::new();
        let target = f.0.join("target");
        fs::write(&target, "{}").unwrap();
        symlink(&target, f.path()).unwrap();
        assert!(status_at(&f.path()).is_err());
        assert!(save_at(&f.path(), "https://example.org", "anything").is_err());
        assert_eq!(fs::read_to_string(&target).unwrap(), "{}");
        fs::remove_file(f.path()).unwrap();
        fs::write(f.path(), "{}").unwrap();
        fs::set_permissions(f.path(), fs::Permissions::from_mode(0o640)).unwrap();
        let before = status_at(&f.path()).unwrap();
        save_at(&f.path(), "https://example.org", &before.revision).unwrap();
        assert_eq!(fs::metadata(f.path()).unwrap().permissions().mode() & 0o777, 0o640);
    }
}
