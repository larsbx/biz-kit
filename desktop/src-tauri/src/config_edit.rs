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

fn staged(path: &str) -> String {
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
IFS= read -r expected_b64
IFS= read -r content_b64
printf '%s' "$expected_b64" | base64 -d > "$work/expected"
if ! cmp -s -- "$p" "$work/expected"; then
  echo 'File changed since it was opened. Keep your draft, reload the file and review again.' >&2; exit 74
fi
cp -p -- "$p" "$work/new"
printf '%s' "$content_b64" | base64 -d > "$work/new"
metadata() {{ stat -c '%u:%g:%a' -- "$1" 2>/dev/null || stat -f '%u:%g:%Lp' "$1"; }}
if [ "$(metadata "$p")" != "$(metadata "$work/new")" ]; then
  echo 'Cannot preserve config owner, group and permissions. Save refused; use an account that can preserve them.' >&2; exit 73
fi
"#, quote(path))
}

/// Base64 lines travel over stdin, never in a process argument or environment.
pub fn snapshots(expected: &str, content: &str) -> Vec<u8> {
    format!("{}\n{}\n", base64_encode(expected.as_bytes()), base64_encode(content.as_bytes())).into_bytes()
}

pub fn diff_script(path: &str) -> String {
    staged(path) + r#"
rc=0
diff -u -L "$p (opened)" -L "$p (edited)" "$work/expected" "$work/new" || rc=$?
[ "$rc" -le 1 ] || exit "$rc"
"#
}

pub fn write_script(path: &str) -> String {
    staged(path) + r#"
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
        use std::{fs, io::Write, os::unix::fs::PermissionsExt, path::PathBuf, process::{Command, Stdio}, sync::atomic::{AtomicUsize, Ordering}};
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
            fn run(&self, script: String, expected: &str, content: &str) -> std::process::Output {
                let mut child = Command::new("sh").arg("-c").arg(script)
                    .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().unwrap();
                let mut stdin = child.stdin.take().unwrap();
                let bytes = snapshots(expected, content);
                let writer = std::thread::spawn(move || stdin.write_all(&bytes));
                let out = child.wait_with_output().unwrap();
                let result = writer.join().unwrap();
                if out.status.success() { result.unwrap(); }
                out
            }
        }
        impl Drop for Fixture { fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); } }

        #[test]
        fn review_does_not_write_and_save_preserves_backup_and_mode() {
            let f = Fixture::new();
            fs::set_permissions(f.file(), fs::Permissions::from_mode(0o640)).unwrap();
            let content = "changed 'quotes' \"double\"\nUnicode: λ\n";
            let review = f.run(diff_script(&f.file()), "original\n", content);
            assert!(review.status.success(), "{:?}", review);
            assert!(String::from_utf8_lossy(&review.stdout).contains("+changed 'quotes'"));
            assert_eq!(fs::read_to_string(f.file()).unwrap(), "original\n");
            let saved = f.run(write_script(&f.file()), "original\n", content);
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
            for script in [diff_script(&f.file()), write_script(&f.file())] {
                let out = f.run(script, "original\n", "draft");
                assert!(!out.status.success());
                assert!(String::from_utf8_lossy(&out.stderr).contains("File changed"));
                assert_eq!(fs::read_to_string(f.file()).unwrap(), "external edit");
                assert_eq!(fs::read_dir(&f.0).unwrap().count(), 1);
            }
        }

        #[test]
        fn duplicate_editor_must_reload_after_first_save() {
            let f = Fixture::new();
            assert!(f.run(write_script(&f.file()), "original\n", "first draft").status.success());
            assert!(!f.run(write_script(&f.file()), "original\n", "second draft").status.success());
            assert_eq!(fs::read_to_string(f.file()).unwrap(), "first draft");
        }

        #[test]
        fn megabyte_snapshots_use_stdin_not_the_command_argument() {
            let f = Fixture::new();
            let original = "a".repeat(1_048_576);
            let content = "b".repeat(1_048_576);
            fs::write(f.file(), &original).unwrap();
            let script = write_script(&f.file());
            assert!(script.len() < 8_192);
            let out = f.run(script, &original, &content);
            assert!(out.status.success(), "{:?}", out);
            assert_eq!(fs::read_to_string(f.file()).unwrap(), content);
        }

        #[test]
        fn metadata_copy_failure_refuses_replacement() {
            let f = Fixture::new();
            fs::set_permissions(f.file(), fs::Permissions::from_mode(0o640)).unwrap();
            let bin = f.0.join("bin");
            fs::create_dir(&bin).unwrap();
            let cp = bin.join("cp");
            // Fault injection: copying succeeds but drops original metadata.
            fs::write(&cp, "#!/bin/sh\n/bin/cp \"$@\" || exit\nfor last; do :; done\nchmod 600 \"$last\"\n").unwrap();
            fs::set_permissions(&cp, fs::Permissions::from_mode(0o755)).unwrap();
            let mut child = Command::new("sh").arg("-c").arg(write_script(&f.file()))
                .env("PATH", format!("{}:{}", bin.display(), std::env::var("PATH").unwrap()))
                .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().unwrap();
            child.stdin.take().unwrap().write_all(&snapshots("original\n", "draft")).unwrap();
            let out = child.wait_with_output().unwrap();
            assert!(!out.status.success());
            assert!(String::from_utf8_lossy(&out.stderr).contains("Cannot preserve config owner"));
            assert_eq!(fs::read_to_string(f.file()).unwrap(), "original\n");
            assert_eq!(fs::metadata(f.file()).unwrap().permissions().mode() & 0o777, 0o640);
            assert!(!fs::read_dir(&f.0).unwrap().flatten().any(|p| p.file_name().to_string_lossy().contains(".bak-")));
        }

        #[test]
        fn held_lock_refuses_a_second_writer_without_changing_file() {
            let f = Fixture::new();
            fs::create_dir(format!("{}.biz-kit-save-lock", f.file())).unwrap();
            assert!(!f.run(write_script(&f.file()), "original\n", "draft").status.success());
            assert_eq!(fs::read_to_string(f.file()).unwrap(), "original\n");
        }

        #[test]
        fn symlink_is_refused_without_replacing_link_or_target() {
            let f = Fixture::new();
            let link = f.0.join("link");
            std::os::unix::fs::symlink(f.file(), &link).unwrap();
            assert!(!f.run(write_script(&link.display().to_string()), "original\n", "draft").status.success());
            assert!(link.is_symlink());
            assert_eq!(fs::read_to_string(f.file()).unwrap(), "original\n");
        }
    }
}
