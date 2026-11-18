//! Host health: disk, memory, load and failed units, plus any extra checks
//! configured in settings. One ssh round trip per host.

use crate::exec;
use crate::settings::{self, Check};
use serde::Serialize;

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Health {
    pub host: String,
    pub reachable: bool,
    pub error: Option<String>,
    pub uptime: String,
    pub load: String,
    pub disk_pct: u8,
    pub disk_used: String,
    pub disk_total: String,
    pub mem_used_mb: u64,
    pub mem_total_mb: u64,
    pub swap_used_mb: u64,
    pub swap_total_mb: u64,
    pub failed_units: Vec<String>,
    pub checks: Vec<CheckResult>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CheckResult {
    pub label: String,
    pub ok: bool,
    /// First lines of the command's combined output.
    pub detail: String,
}

/// The probe targets Linux (procfs, systemd, GNU coreutils); `OS` lets a
/// different kernel be reported instead of rendered as zeros.
const PROBE: &str = r#"
PATH="$HOME/.local/bin:$PATH"
echo "@@@OS"; uname -s
echo "@@@UPTIME"; uptime -p 2>/dev/null | sed 's/^up //'
echo "@@@LOAD"; awk '{print $1", "$2", "$3}' /proc/loadavg 2>/dev/null
echo "@@@DISK"; df -P / | tail -1 | awk '{print $5" "$3" "$2}'
echo "@@@MEM"; free -m 2>/dev/null | awk '/^Mem:/{print $3" "$2} /^Swap:/{print "swap "$3" "$2}'
echo "@@@FAILED"; systemctl --user --failed --no-legend --plain 2>/dev/null | awk '{print "user:"$1}'
systemctl --system --failed --no-legend --plain 2>/dev/null | awk '{print "system:"$1}'
"#;

/// Each check prints its exit code, then up to three lines of output. Checks
/// are bounded by `timeout` where it exists; macOS has none, and there a check
/// runs unbounded rather than failing as "command not found".
fn probe(checks: &[Check]) -> String {
    checks.iter().enumerate().fold(PROBE.to_string(), |acc, (i, c)| {
        acc + &format!(
            "echo \"@@@CHECK{i}\"; out=$($(command -v timeout >/dev/null && echo timeout 20) sh -c {} 2>&1); echo $?; printf '%s\\n' \"$out\" | head -n 3\n",
            exec::shq(&c.command)
        )
    })
}

/// The lines between `@@@name` and the next tag. An empty section is followed
/// directly by the next tag, so the terminator is a tag at any line start.
fn section<'a>(raw: &'a str, name: &str) -> &'a str {
    let tag = format!("@@@{name}\n");
    let Some(start) = raw.find(&tag) else { return "" };
    let rest = &raw[start + tag.len()..];
    let end = if rest.starts_with("@@@") { Some(0) } else { rest.find("\n@@@") };
    &rest[..end.unwrap_or(rest.len())]
}

fn parse(host: &str, raw: &str, checks: &[Check]) -> Health {
    let mut h = Health { host: host.to_string(), reachable: true, ..Default::default() };

    let os = section(raw, "OS").trim();
    if os != "Linux" {
        h.error = Some(format!("health probe supports Linux hosts; {host} reports {os:?}"));
        return h;
    }

    h.uptime = section(raw, "UPTIME").trim().to_string();
    h.load = section(raw, "LOAD").trim().to_string();

    let mut d = section(raw, "DISK").split_whitespace();
    h.disk_pct = d.next().and_then(|p| p.trim_end_matches('%').parse().ok()).unwrap_or(0);
    // df -P reports 1K blocks; render as GB.
    let gb = |kb: &str| kb.parse::<f64>().map(|v| format!("{:.0}G", v / 1024.0 / 1024.0)).unwrap_or_default();
    h.disk_used = d.next().map(gb).unwrap_or_default();
    h.disk_total = d.next().map(gb).unwrap_or_default();

    for line in section(raw, "MEM").lines() {
        let n: Vec<u64> = line.split_whitespace().filter_map(|x| x.parse().ok()).collect();
        match (line.starts_with("swap"), n.as_slice()) {
            (true, [used, total, ..]) => (h.swap_used_mb, h.swap_total_mb) = (*used, *total),
            (false, [used, total, ..]) => (h.mem_used_mb, h.mem_total_mb) = (*used, *total),
            _ => {}
        }
    }

    h.failed_units = section(raw, "FAILED")
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .map(str::to_string)
        .collect();

    h.checks = checks
        .iter()
        .enumerate()
        .map(|(i, c)| {
            let body = section(raw, &format!("CHECK{i}"));
            let (code, detail) = body.split_once('\n').unwrap_or((body, ""));
            CheckResult {
                label: c.label.clone(),
                ok: code.trim() == "0",
                detail: detail.trim().to_string(),
            }
        })
        .collect();
    h
}

#[tauri::command]
pub async fn host_health(host: String) -> Result<Health, String> {
    let unreachable = |e: String| Health { host: host.clone(), error: Some(e), ..Default::default() };
    let checks = settings::load()?.checks;
    let out = match exec::run(&host, &probe(&checks)).await {
        Ok(o) => o,
        Err(e) => return Ok(unreachable(e)),
    };
    if out.stdout.trim().is_empty() {
        let e = out.stderr.trim();
        return Ok(unreachable(if e.is_empty() { "no response".into() } else { e.into() }));
    }
    Ok(parse(&host, &out.stdout, &checks))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn check(label: &str, command: &str) -> Check {
        Check { label: label.into(), command: command.into() }
    }

    const RAW: &str = "@@@OS\nLinux\n@@@UPTIME\n3 days\n@@@LOAD\n0.1, 0.2, 0.3\n\
        @@@DISK\n42% 1048576 2097152\n@@@MEM\n512 2048\nswap 0 1024\n\
        @@@FAILED\nuser:a.service\n@@@CHECK0\n0\n100.64.0.1\n@@@CHECK1\n3\nAPI unavailable\n";

    #[test]
    fn parses_a_linux_probe() {
        let h = parse("h", RAW, &[check("vpn", "x"), check("sync", "y")]);
        assert!(h.reachable && h.error.is_none());
        assert_eq!((h.disk_pct, h.disk_used.as_str(), h.disk_total.as_str()), (42, "1G", "2G"));
        assert_eq!((h.mem_used_mb, h.mem_total_mb, h.swap_total_mb), (512, 2048, 1024));
        assert_eq!(h.failed_units, ["user:a.service"]);
        assert_eq!(h.checks, [
            CheckResult { label: "vpn".into(), ok: true, detail: "100.64.0.1".into() },
            CheckResult { label: "sync".into(), ok: false, detail: "API unavailable".into() },
        ]);
    }

    #[test]
    fn an_empty_section_does_not_swallow_the_next() {
        let raw = "@@@OS\nLinux\n@@@FAILED\n@@@CHECK0\n0\nfine\n";
        assert_eq!(section(raw, "FAILED"), "");
        let h = parse("h", raw, &[check("c", "x")]);
        assert!(h.failed_units.is_empty());
        assert_eq!(h.checks[0].detail, "fine");
    }

    #[test]
    fn non_linux_hosts_are_reported_not_zeroed() {
        let h = parse("mac", "@@@OS\nDarwin\n@@@LOAD\n\n", &[]);
        assert!(h.error.unwrap().contains("Darwin"));
    }

    #[test]
    #[cfg(unix)]
    fn check_commands_run_and_report_exit_codes() {
        let checks = [check("ok", "echo 'it''s fine'; echo two"), check("bad", "echo nope >&2; exit 4")];
        let script = probe(&checks)
            .split_once("echo \"@@@CHECK0")
            .map(|(_, rest)| format!("echo \"@@@CHECK0{rest}"))
            .unwrap();
        let out = std::process::Command::new("sh").arg("-c").arg(&script).output().unwrap();
        let h = parse("h", &format!("@@@OS\nLinux\n{}", String::from_utf8_lossy(&out.stdout)), &checks);
        assert_eq!(h.checks[0], CheckResult { label: "ok".into(), ok: true, detail: "its fine\ntwo".into() });
        assert_eq!(h.checks[1], CheckResult { label: "bad".into(), ok: false, detail: "nope".into() });
    }
}
