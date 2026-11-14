//! Focused JSON settings migration for the installed desktop. Never reserialize
//! Settings: that would discard unknown keys belonging to another app version.
use serde::Serialize;
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use std::fs::{self, File, Metadata, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

const LIMIT: u64 = 1024 * 1024;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Connection {
    pub config_path: String,
    pub origin: Option<String>,
    pub revision: String,
    pub desktop_version: String,
}

struct Snapshot {
    raw: Option<String>,
    value: Map<String, Value>,
    metadata: Option<Metadata>,
}

impl Snapshot {
    fn revision(&self) -> String {
        match &self.raw {
            Some(raw) => format!("sha256:{:x}", Sha256::digest(raw.as_bytes())),
            None => "missing".into(),
        }
    }

    fn connection(&self, path: &Path) -> Connection {
        let config: Value = serde_json::from_str(include_str!("../tauri.conf.json"))
            .expect("compiled Tauri configuration");
        Connection {
            config_path: path.display().to_string(),
            origin: self.value.get("procurementOrigin").and_then(Value::as_str).map(str::to_owned),
            revision: self.revision(),
            desktop_version: config["version"].as_str().unwrap_or("unknown").to_owned(),
        }
    }
}

fn snapshot(path: &Path) -> Result<Snapshot, String> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(m) => m,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Ok(Snapshot { raw: None, value: Map::new(), metadata: None });
        }
        Err(e) => return Err(e.to_string()),
    };
    if !metadata.is_file() || metadata.file_type().is_symlink() || metadata.len() > LIMIT {
        return Err("Settings must be a regular, non-symlink JSON file of at most 1 MiB.".into());
    }
    let raw = fs::read_to_string(path).map_err(|e| e.to_string())?;
    crate::settings::Settings::parse(&raw)?;
    let value = serde_json::from_str::<Value>(&raw).map_err(|e| e.to_string())?
        .as_object().cloned().ok_or("Settings must be a JSON object.")?;
    Ok(Snapshot { raw: Some(raw), value, metadata: Some(metadata) })
}

struct Cleanup(PathBuf, bool);
impl Drop for Cleanup {
    fn drop(&mut self) {
        if self.1 { let _ = fs::remove_dir(&self.0); }
        else { let _ = fs::remove_file(&self.0); }
    }
}

fn private_file(path: &Path) -> Result<File, String> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path).map_err(|e| e.to_string())
}

fn same_permissions(a: &Metadata, b: &Metadata) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        a.uid() == b.uid() && a.gid() == b.gid() && a.mode() == b.mode()
    }
    #[cfg(not(unix))]
    { a.permissions().readonly() == b.permissions().readonly() }
}

fn save_at(path: &Path, origin: &str, expected: &str) -> Result<Connection, String> {
    let origin = crate::procurement::host_url(origin.trim())?.origin().ascii_serialization();
    let parent = path.parent().ok_or("Settings path has no parent.")?;
    fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    // Same lock convention as the general config editor. Never break a stale lock automatically.
    let lock = PathBuf::from(format!("{}.biz-kit-save-lock", path.display()));
    fs::create_dir(&lock).map_err(|_| "Settings are being edited; reload after the other save finishes.".to_string())?;
    let _lock = Cleanup(lock, true);
    let mut old = snapshot(path)?;
    if old.revision() != expected {
        return Err("Settings changed since opening. Reload before saving; your draft was not written.".into());
    }
    let settings = crate::settings::Settings::parse(old.raw.as_deref().unwrap_or("{}"))?;
    if settings.is_protected(&path.to_string_lossy()) {
        return Err("The desktop settings file is protected.".into());
    }
    if old.value.get("procurementOrigin").and_then(Value::as_str) == Some(origin.as_str()) {
        return Ok(old.connection(path));
    }
    if old.metadata.as_ref().is_some_and(|m| m.permissions().readonly()) {
        return Err("Settings are read-only.".into());
    }
    old.value.insert("procurementOrigin".into(), Value::String(origin));
    let text = serde_json::to_string_pretty(&old.value).map_err(|e| e.to_string())? + "\n";
    let nonce = rand::random::<u64>();
    let staged = parent.join(format!(".biz-kit-settings-{nonce:016x}.tmp"));
    let _staged = Cleanup(staged.clone(), false);
    let mut file = private_file(&staged)?;
    if let Some(m) = &old.metadata {
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            let new = file.metadata().map_err(|e| e.to_string())?;
            if m.uid() != new.uid() || m.gid() != new.gid() {
                return Err("Refusing to change settings ownership.".into());
            }
        }
        file.set_permissions(m.permissions()).map_err(|e| e.to_string())?;
    }
    file.write_all(text.as_bytes()).and_then(|_| file.sync_all()).map_err(|e| e.to_string())?;
    drop(file);
    if let Some(raw) = &old.raw {
        let backup = parent.join(format!("config.json.{nonce:016x}.bak"));
        let mut backup = private_file(&backup)?;
        backup.write_all(raw.as_bytes()).and_then(|_| backup.sync_all()).map_err(|e| e.to_string())?;
    }
    let current = snapshot(path)?;
    if current.revision() != expected
        || match (&old.metadata, &current.metadata) {
            (Some(a), Some(b)) => !same_permissions(a, b),
            (None, None) => false,
            _ => true,
        }
    {
        return Err("Settings changed during save; no replacement was made.".into());
    }
    fs::rename(&staged, path).map_err(|e| e.to_string())?;
    snapshot(path).map(|s| s.connection(path))
}

#[tauri::command]
pub fn procurement_connection() -> Result<Connection, String> {
    let path = crate::settings::path();
    snapshot(&path).map(|s| s.connection(&path))
}

#[tauri::command]
pub fn save_procurement_connection(origin: String, expected_revision: String) -> Result<Connection, String> {
    save_at(&crate::settings::path(), &origin, &expected_revision)
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let dir = std::env::temp_dir().join(format!("bizkit-connection-{:x}", rand::random::<u64>()));
            fs::create_dir(&dir).unwrap(); Self(dir)
        }
        fn path(&self) -> PathBuf { self.0.join("config.json") }
    }
    impl Drop for Fixture { fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); } }
    #[test]
    fn upgrade_preserves_unknown_and_existing_settings_and_backup() {
        let f = Fixture::new(); let p = f.path();
        let original = r#"{"hosts":[],"operationsUrl":"https://ops.test/operations","future":{"v":7}}"#;
        fs::write(&p, original).unwrap();
        let rev = snapshot(&p).unwrap().revision();
        let result = save_at(&p, "https://procurement.test/", &rev).unwrap();
        let value: Value = serde_json::from_str(&fs::read_to_string(&p).unwrap()).unwrap();
        assert_eq!(value["future"]["v"], 7); assert_eq!(value["hosts"], serde_json::json!([]));
        assert_eq!(value["operationsUrl"], "https://ops.test/operations");
        assert_eq!(result.origin.as_deref(), Some("https://procurement.test"));
        let backup = fs::read_dir(&f.0).unwrap().flatten().map(|e| e.path()).find(|p| p.extension().is_some_and(|e| e == "bak")).unwrap();
        assert_eq!(fs::read_to_string(backup).unwrap(), original);
    }
    #[test]
    fn missing_settings_can_be_created_without_host_defaults() {
        let f = Fixture::new(); let p = f.path();
        let result = save_at(&p, "https://procurement.test", "missing").unwrap();
        assert_ne!(result.revision, "missing");
        assert_eq!(snapshot(&p).unwrap().value.len(), 1);
    }
    #[test]
    fn stale_revision_does_not_overwrite_another_edit() {
        let f = Fixture::new(); let p = f.path(); fs::write(&p, "{}").unwrap();
        let rev = snapshot(&p).unwrap().revision(); fs::write(&p, "{\"hosts\":[]}").unwrap();
        assert!(save_at(&p, "https://procurement.test", &rev).is_err());
        assert_eq!(fs::read_to_string(&p).unwrap(), "{\"hosts\":[]}");
    }
    #[test]
    fn invalid_addresses_and_malformed_settings_are_not_replaced() {
        let f = Fixture::new(); let p = f.path();
        for value in ["http://p.test", "https://user@p.test", "https://p.test/login", "https://p.test/?token=x"] {
            assert!(save_at(&p, value, "missing").is_err()); assert!(!p.exists());
        }
        fs::write(&p, "{broken").unwrap();
        assert!(save_at(&p, "https://p.test", "missing").is_err());
        assert_eq!(fs::read_to_string(&p).unwrap(), "{broken");
    }
    #[test]
    fn another_writer_lock_is_never_removed() {
        let f = Fixture::new(); let p = f.path();
        let lock = PathBuf::from(format!("{}.biz-kit-save-lock", p.display())); fs::create_dir(&lock).unwrap();
        assert!(save_at(&p, "https://p.test", "missing").is_err()); assert!(lock.is_dir());
    }
    #[test]
    fn protected_settings_cannot_be_changed() {
        let f = Fixture::new(); let p = f.path();
        fs::write(&p, r#"{"protectedPaths":["config.json"]}"#).unwrap();
        let rev = snapshot(&p).unwrap().revision(); assert!(save_at(&p, "https://p.test", &rev).is_err());
    }
    #[cfg(unix)]
    #[test]
    fn symlink_settings_are_refused() {
        let f = Fixture::new(); let real = f.0.join("real.json"); fs::write(&real, "{}").unwrap();
        std::os::unix::fs::symlink(&real, f.path()).unwrap();
        assert!(snapshot(&f.path()).is_err()); assert!(save_at(&f.path(), "https://p.test", "missing").is_err());
        assert_eq!(fs::read_to_string(real).unwrap(), "{}");
    }
}
