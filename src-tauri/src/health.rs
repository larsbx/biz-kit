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
    /// Peer name -> connected, from the local Syncthing REST API if present.
    pub syncthing: Option<SyncthingState>,
}

#[derive(Debug, Clone, Serialize)]
pub struct SyncthingState {
    pub running: bool,
    pub folders: usize,
    pub peers: Vec<(String, bool)>,
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
if command -v curl >/dev/null 2>&1; then
  cfg="$HOME/.local/state/syncthing/config.xml"
  if [ -f "$cfg" ]; then
    key=$(grep -oP '(?<=<apikey>)[^<]+' "$cfg" 2>/dev/null | head -1)
    if [ -n "$key" ]; then
      curl -s --max-time 4 -H "X-API-Key: $key" http://127.0.0.1:8384/rest/system/connections 2>/dev/null
      echo
      echo "@@@STF"
      curl -s --max-time 4 -H "X-API-Key: $key" http://127.0.0.1:8384/rest/config/folders 2>/dev/null
    fi
  fi
fi
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
    let conns = section(raw, "ST").trim();
    if !conns.is_empty() {
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(conns) {
            let mut peers = vec![];
            if let Some(map) = v.get("connections").and_then(|c| c.as_object()) {
                for (id, info) in map {
                    let connected = info.get("connected").and_then(|b| b.as_bool()).unwrap_or(false);
                    peers.push((id.chars().take(7).collect::<String>(), connected));
                }
            }
            let folders = serde_json::from_str::<serde_json::Value>(section(raw, "STF").trim())
                .ok()
                .and_then(|f| f.as_array().map(|a| a.len()))
                .unwrap_or(0);
            h.syncthing = Some(SyncthingState { running: true, folders, peers });
        }
    }
    Ok(h)
}
