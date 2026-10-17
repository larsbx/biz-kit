//! Fleet health: the numbers that actually bit us -- disk, memory, load, failed
//! units, tailnet reachability, Syncthing peers.

use crate::exec;
use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
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
    pub tailscale_ip: String,
    /// From `syncthing-policy status`; None when the host has no managed Syncthing.
    pub syncthing: Option<SyncthingState>,
}

#[derive(Debug, Clone, Serialize)]
pub struct SyncthingState {
    pub running: bool,
    pub folders: usize,
    pub connected_peers: u64,
    pub errors: Vec<String>,
}

const PROBE: &str = r#"
echo "@@@UPTIME"; uptime -p 2>/dev/null | sed 's/^up //'
echo "@@@LOAD"; awk '{print $1", "$2", "$3}' /proc/loadavg
echo "@@@DISK"; df -P / | tail -1 | awk '{print $5" "$3" "$2}'
echo "@@@MEM"; free -m | awk '/^Mem:/{print $3" "$2} /^Swap:/{print "swap "$3" "$2}'
echo "@@@FAILED"; systemctl --user --failed --no-legend --plain 2>/dev/null | awk '{print "user:"$1}'
systemctl --system --failed --no-legend --plain 2>/dev/null | awk '{print "system:"$1}'
echo "@@@TS"; ip -br addr show tailscale0 2>/dev/null | awk '{print $3}' | cut -d/ -f1
echo "@@@ST"
# Managed Syncthing keeps its state inside its sandbox; the policy command is
# the only supported read. ssh runs a non-login shell, so ~/.local/bin is not
# necessarily on PATH.
sp=$(command -v syncthing-policy || echo "$HOME/.local/bin/syncthing-policy")
[ -x "$sp" ] && timeout 20 "$sp" status 2>/dev/null
"#;

fn section<'a>(raw: &'a str, name: &str) -> &'a str {
    let tag = format!("@@@{name}\n");
    let Some(start) = raw.find(&tag) else { return "" };
    let rest = &raw[start + tag.len()..];
    match rest.find("\n@@@") {
        Some(e) => &rest[..e],
        None => rest,
    }
}

#[tauri::command]
pub async fn host_health(host: String) -> Result<Health, String> {
    let mut h = Health {
        host: host.clone(),
        reachable: false,
        error: None,
        uptime: String::new(),
        load: String::new(),
        disk_pct: 0,
        disk_used: String::new(),
        disk_total: String::new(),
        mem_used_mb: 0,
        mem_total_mb: 0,
        swap_used_mb: 0,
        swap_total_mb: 0,
        failed_units: vec![],
        tailscale_ip: String::new(),
        syncthing: None,
    };

    let out = match exec::run(&host, PROBE).await {
        Ok(o) => o,
        Err(e) => {
            h.error = Some(e);
            return Ok(h);
        }
    };
    if out.stdout.trim().is_empty() {
        h.error = Some(if out.stderr.trim().is_empty() {
            "no response".into()
        } else {
            out.stderr.trim().to_string()
        });
        return Ok(h);
    }
    h.reachable = true;
    let raw = &out.stdout;

    h.uptime = section(raw, "UPTIME").trim().to_string();
    h.load = section(raw, "LOAD").trim().to_string();

    let disk = section(raw, "DISK");
    let mut d = disk.split_whitespace();
    if let Some(p) = d.next() {
        h.disk_pct = p.trim_end_matches('%').parse().unwrap_or(0);
    }
    // df -P reports 1K blocks; render as GB.
    let gb = |kb: &str| {
        kb.parse::<f64>()
            .map(|v| format!("{:.0}G", v / 1024.0 / 1024.0))
            .unwrap_or_default()
    };
    h.disk_used = d.next().map(gb).unwrap_or_default();
    h.disk_total = d.next().map(gb).unwrap_or_default();

    for line in section(raw, "MEM").lines() {
        let f: Vec<&str> = line.split_whitespace().collect();
        if f.first() == Some(&"swap") && f.len() >= 3 {
            h.swap_used_mb = f[1].parse().unwrap_or(0);
            h.swap_total_mb = f[2].parse().unwrap_or(0);
        } else if f.len() >= 2 {
            h.mem_used_mb = f[0].parse().unwrap_or(0);
            h.mem_total_mb = f[1].parse().unwrap_or(0);
        }
    }

    h.failed_units = section(raw, "FAILED")
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .map(str::to_string)
        .collect();
    h.tailscale_ip = section(raw, "TS").trim().to_string();

    // Syncthing is optional; absent or unparseable simply means "no panel".
    h.syncthing = parse_syncthing(section(raw, "ST"));
    Ok(h)
}

/// Parse `syncthing-policy status`. It reports `errors` with no `folders` when
/// the managed transport is down, which is "installed but broken", not absent.
fn parse_syncthing(raw: &str) -> Option<SyncthingState> {
    let v = serde_json::from_str::<serde_json::Value>(raw.trim()).ok()?;
    let errors: Vec<String> = v
        .get("errors")
        .and_then(|e| e.as_array())
        .map(|a| a.iter().filter_map(|x| x.as_str().map(str::to_string)).collect())
        .unwrap_or_default();
    Some(SyncthingState {
        running: errors.is_empty(),
        folders: v.get("folders").and_then(|f| f.as_array()).map_or(0, |a| a.len()),
        connected_peers: v.get("connected_peers").and_then(|n| n.as_u64()).unwrap_or(0),
        errors,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_a_healthy_status() {
        let raw = r#"{"host":"adder-ws","errors":[],"connected_peers":1,
            "folders":[{"source":"papa","state":"idle"},{"source":"adder-ws","state":"idle"}]}"#;
        let s = parse_syncthing(raw).unwrap();
        assert!(s.running);
        assert_eq!((s.folders, s.connected_peers), (2, 1));
    }

    #[test]
    fn transport_down_is_reported_not_hidden() {
        let s = parse_syncthing(r#"{"host":"papa","errors":["API unavailable: URLError"]}"#).unwrap();
        assert!(!s.running);
        assert_eq!(s.errors, vec!["API unavailable: URLError"]);
    }

    #[test]
    fn no_policy_command_means_no_panel() {
        assert!(parse_syncthing("").is_none());
    }
}
