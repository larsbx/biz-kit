//! Portable config-edit scripts. The expected bytes are the file opened by the
//! editor. A per-path lock serializes biz-kit writers; replacing a staged file
//! avoids leaving a truncated config when a write fails.

fn quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

pub fn base64_encode(data: &[u8]) -> String {
    const T: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut s = String::new();
    for c in data.chunks(3) {
        let b = [c[0], *c.get(1).unwrap_or(&0), *c.get(2).unwrap_or(&0)];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        s.push(T[(n >> 18 & 63) as usize] as char);
        s.push(T[(n >> 12 & 63) as usize] as char);
        s.push(if c.len() > 1 { T[(n >> 6 & 63) as usize] as char } else { '=' });
        s.push(if c.len() > 2 { T[(n & 63) as usize] as char } else { '=' });
    }
    s
}

fn staged(path: &str, expected: &str, content: &str) -> String {
    format!(r#"set -eu
p={}
if [ -L "$p" ]; then
  echo 'Open the target file directly to edit it; saving through a symbolic link is not supported.' >&2; exit 73
fi
lock="$p.biz-kit-save-lock"
if ! mkdir -- "$lock"; then
  echo 'Another config review or save is in progress. Retry when it completes.' >&2; exit 75
fi
work=''
cleanup() {{
  if [ -n "$work" ]; then rm -f -- "$work/expected" "$work/new"; rmdir -- "$work"; fi
  rmdir -- "$lock"
}}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
work=$(mktemp -d "$p.biz-kit.XXXXXX")
printf '%s' {} | base64 -d > "$work/expected"
if ! cmp -s -- "$p" "$work/expected"; then
  echo 'File changed since it was opened. Keep your draft, reload the file and review again.' >&2; exit 74
fi
cp -p -- "$p" "$work/new"
printf '%s' {} | base64 -d > "$work/new"
"#, quote(path), quote(&base64_encode(expected.as_bytes())), quote(&base64_encode(content.as_bytes())))
}

pub fn diff_script(path: &str, expected: &str, content: &str) -> String {
    staged(path, expected, content) + r#"
rc=0
diff -u -L "$p (opened)" -L "$p (edited)" "$work/expected" "$work/new" || rc=$?
[ "$rc" -le 1 ] || exit "$rc"
"#
}

pub fn write_script(path: &str, expected: &str, content: &str) -> String {
    staged(path, expected, content) + r#"
backup="$p.bak-$(date +%Y%m%d%H%M%S)-$$"
cp -p -- "$p" "$backup"
if ! cmp -s -- "$p" "$work/expected"; then
  echo 'File changed while preparing the save. Keep your draft, reload the file and review again.' >&2; exit 74
fi
mv -f -- "$work/new" "$p"
printf 'wrote %s (backup: %s)\n' "$p" "$backup"
"#
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_reference_vectors() {
        for (raw, encoded) in [("", ""), ("f", "Zg=="), ("fo", "Zm8="), ("foo", "Zm9v"), ("foobar", "Zm9vYmFy")] {
            assert_eq!(base64_encode(raw.as_bytes()), encoded);
        }
    }

    #[cfg(unix)]
    mod host {
        use super::*;
        use std::{fs, os::unix::fs::PermissionsExt, path::PathBuf, process::Command, sync::atomic::{AtomicUsize, Ordering}};
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        struct Fixture(PathBuf);
        impl Fixture {
            fn new() -> Self {
                let p = std::env::temp_dir().join(format!("biz-kit-edit-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)));
                fs::create_dir(&p).unwrap();
                fs::write(p.join("app's config.json"), "original\n").unwrap();
                Self(p)
            }
            fn file(&self) -> String { self.0.join("app's config.json").display().to_string() }
            fn run(&self, script: String) -> std::process::Output { Command::new("sh").arg("-c").arg(script).output().unwrap() }
        }
        impl Drop for Fixture { fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); } }

        #[test]
        fn review_does_not_write_and_save_preserves_backup_and_mode() {
            let f = Fixture::new();
            fs::set_permissions(f.file(), fs::Permissions::from_mode(0o640)).unwrap();
            let content = "changed 'quotes' \"double\"\nUnicode: λ\n";
            let review = f.run(diff_script(&f.file(), "original\n", content));
            assert!(review.status.success(), "{:?}", review);
            assert!(String::from_utf8_lossy(&review.stdout).contains("+changed 'quotes'"));
            assert_eq!(fs::read_to_string(f.file()).unwrap(), "original\n");
            let saved = f.run(write_script(&f.file(), "original\n", content));
            assert!(saved.status.success(), "{:?}", saved);
            assert_eq!(fs::read_to_string(f.file()).unwrap(), content);
            assert_eq!(fs::metadata(f.file()).unwrap().permissions().mode() & 0o777, 0o640);
            let backups: Vec<_> = fs::read_dir(&f.0).unwrap().flatten().filter(|e| e.file_name().to_string_lossy().contains(".bak-")).collect();
            assert_eq!(backups.len(), 1);
            assert_eq!(fs::read_to_string(backups[0].path()).unwrap(), "original\n");
            assert_eq!(fs::read_dir(&f.0).unwrap().count(), 2, "temporary files or lock leaked");
        }

        #[test]
        fn stale_review_and_save_cannot_replace_external_changes() {
            let f = Fixture::new();
            fs::write(f.file(), "external edit").unwrap();
            for script in [diff_script(&f.file(), "original\n", "draft"), write_script(&f.file(), "original\n", "draft")] {
                let out = f.run(script);
                assert!(!out.status.success());
                assert!(String::from_utf8_lossy(&out.stderr).contains("File changed"));
                assert_eq!(fs::read_to_string(f.file()).unwrap(), "external edit");
                assert_eq!(fs::read_dir(&f.0).unwrap().count(), 1);
            }
        }

        #[test]
        fn duplicate_editor_must_reload_after_first_save() {
            let f = Fixture::new();
            assert!(f.run(write_script(&f.file(), "original\n", "first draft")).status.success());
            assert!(!f.run(write_script(&f.file(), "original\n", "second draft")).status.success());
            assert_eq!(fs::read_to_string(f.file()).unwrap(), "first draft");
        }

        #[test]
        fn held_lock_refuses_a_second_writer_without_changing_file() {
            let f = Fixture::new();
            fs::create_dir(format!("{}.biz-kit-save-lock", f.file())).unwrap();
            assert!(!f.run(write_script(&f.file(), "original\n", "draft")).status.success());
            assert_eq!(fs::read_to_string(f.file()).unwrap(), "original\n");
        }

        #[test]
        fn symlink_is_refused_without_replacing_link_or_target() {
            let f = Fixture::new();
            let link = f.0.join("link");
            std::os::unix::fs::symlink(f.file(), &link).unwrap();
            assert!(!f.run(write_script(&link.display().to_string(), "original\n", "draft")).status.success());
            assert!(link.is_symlink());
            assert_eq!(fs::read_to_string(f.file()).unwrap(), "original\n");
        }
    }
}
