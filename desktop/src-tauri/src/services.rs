//! systemd units on every configured host, in both user and system scope.
//!
//! Carries the restart-limit audit inline: systemd only stops a unit after
//! StartLimitBurst restarts within StartLimitIntervalSec, so when
//! RestartSec * Burst >= Interval the window always resets first and a
//! permanently-failing unit restarts forever, flooding the journal. Every unit
//! is checked on load.

use crate::exec;
use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Unit {
    pub host: String,
    pub scope: String, // "user" | "system"
    pub id: String,
    pub active: String,
    pub enabled: String,
    pub restart: String,
    pub restart_sec: f64,
    pub limit_interval: f64,
    pub limit_burst: i64,
    /// True when the start limiter can never trip.
    pub limit_unreachable: bool,
}

/// One round trip per host: enumerate units, then ask systemd for every
/// property we need in a single `show` call per scope.
const PROBE: &str = r#"
for scope in system user; do
  units=$(systemctl --$scope list-unit-files --type=service --no-legend --plain 2>/dev/null \
          | awk '{print $1}' | grep -v '@' | tr '\n' ' ')
  [ -n "$units" ] || continue
  echo "@@@SCOPE $scope"
  systemctl --$scope show $units \
    -p Id -p ActiveState -p UnitFileState -p Restart \
    -p RestartUSec -p StartLimitIntervalUSec -p StartLimitBurst 2>/dev/null
done
"#;

/// systemd prints durations as "3s", "1min 30s", "500ms", "infinity".
fn parse_dur(v: &str) -> f64 {
    let v = v.trim();
    if v.is_empty() || v == "infinity" {
        return f64::INFINITY;
    }
    let mut total = 0.0;
    let mut num = String::new();
    let mut unit = String::new();
    let flush = |num: &mut String, unit: &mut String, total: &mut f64| {
        if num.is_empty() {
            return;
        }
        let n: f64 = num.parse().unwrap_or(0.0);
        *total += n * match unit.as_str() {
            "us" => 1e-6,
            "ms" => 1e-3,
            "min" | "m" => 60.0,
            "h" => 3600.0,
            "d" => 86400.0,
            _ => 1.0, // "s" and bare numbers
        };
        num.clear();
        unit.clear();
    };
    for c in v.chars() {
        if c.is_ascii_digit() || c == '.' {
            if !unit.is_empty() {
                flush(&mut num, &mut unit, &mut total);
            }
            num.push(c);
        } else if c.is_alphabetic() {
            unit.push(c);
        } else {
            flush(&mut num, &mut unit, &mut total);
        }
    }
    flush(&mut num, &mut unit, &mut total);
    total
}

fn parse(host: &str, raw: &str) -> Vec<Unit> {
    let mut out = Vec::new();
    let mut scope = String::from("system");
    let mut cur: std::collections::HashMap<String, String> = Default::default();

    let flush = |cur: &mut std::collections::HashMap<String, String>,
                     scope: &str,
                     out: &mut Vec<Unit>| {
        let Some(id) = cur.get("Id").cloned() else {
            cur.clear();
            return;
        };
        if id.is_empty() {
            cur.clear();
            return;
        }
        let get = |k: &str| cur.get(k).cloned().unwrap_or_default();
        let restart = get("Restart");
        let restart_sec = parse_dur(&get("RestartUSec"));
        let limit_interval = parse_dur(&get("StartLimitIntervalUSec"));
        let limit_burst: i64 = get("StartLimitBurst").parse().unwrap_or(0);
        let restarts = !(restart.is_empty() || restart == "no");
        let unreachable = restarts
            && limit_burst > 0
            && restart_sec.is_finite()
            && limit_interval.is_finite()
            && restart_sec * (limit_burst as f64) >= limit_interval;
        out.push(Unit {
            host: host.to_string(),
            scope: scope.to_string(),
            id,
            active: get("ActiveState"),
            enabled: get("UnitFileState"),
            restart,
            restart_sec,
            limit_interval,
            limit_burst,
            limit_unreachable: unreachable,
        });
        cur.clear();
    };

    for line in raw.lines() {
        if let Some(s) = line.strip_prefix("@@@SCOPE ") {
            flush(&mut cur, &scope, &mut out);
            scope = s.trim().to_string();
            continue;
        }
        if line.trim().is_empty() {
            flush(&mut cur, &scope, &mut out);
            continue;
        }
        if let Some((k, v)) = line.split_once('=') {
            // A new Id means systemd started the next block without a blank line.
            if k == "Id" && cur.contains_key("Id") {
                flush(&mut cur, &scope, &mut out);
            }
            cur.insert(k.to_string(), v.to_string());
        }
    }
    flush(&mut cur, &scope, &mut out);
    // An alias (dbus-org.bluez.service) resolves to the unit it names, so the
    // same Id can arrive twice in one scope. Keep the first.
    let mut seen = std::collections::HashSet::new();
    out.retain(|u| seen.insert((u.scope.clone(), u.id.clone())));
    out
}

#[tauri::command]
pub async fn list_units(host: String) -> Result<Vec<Unit>, String> {
    let out = exec::run(&host, PROBE).await?;
    if out.stdout.trim().is_empty() && out.code != 0 {
        return Err(format!("could not list units on {host}: {}", out.stderr.trim()));
    }
    Ok(parse(&host, &out.stdout))
}

/// Build the exact shell line for a unit action. Returned to the UI first so the
/// confirmation dialog shows the real command, then run unchanged. System scope
/// uses `sudo -n`: a GUI has no terminal to prompt on, so it fails fast instead.
#[tauri::command]
pub fn unit_action_script(scope: String, unit: String, action: String) -> Result<String, String> {
    if !matches!(action.as_str(), "start" | "stop" | "enable" | "disable" | "restart") {
        return Err(format!("refusing unknown action: {action}"));
    }
    if !matches!(scope.as_str(), "user" | "system") {
        return Err(format!("bad scope: {scope}"));
    }
    let sudo = if scope == "system" { "sudo -n " } else { "" };
    Ok(format!(
        "{sudo}systemctl --{scope} {action} {}",
        exec::shq(&unit)
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn durations() {
        assert_eq!(parse_dur("3s"), 3.0);
        assert_eq!(parse_dur("500ms"), 0.5);
        assert_eq!(parse_dur("1min 30s"), 90.0);
        assert_eq!(parse_dur("5min"), 300.0);
        assert!(parse_dur("infinity").is_infinite());
    }

    #[test]
    fn flags_a_limiter_that_can_never_trip() {
        // RestartSec=3s with the default 5 starts / 10s: 5*3=15 >= 10, so the
        // limiter can never trip.
        let raw = "@@@SCOPE user\nId=worker.service\nActiveState=active\n\
                   UnitFileState=enabled\nRestart=on-failure\nRestartUSec=3s\n\
                   StartLimitIntervalUSec=10s\nStartLimitBurst=5\n";
        let u = &parse("h", raw)[0];
        assert!(u.limit_unreachable);
    }

    #[test]
    fn an_alias_does_not_list_a_unit_twice() {
        let raw = "@@@SCOPE system\nId=bluetooth.service\nActiveState=active\n\n\
                   Id=bluetooth.service\nActiveState=active\n\n\
                   @@@SCOPE user\nId=bluetooth.service\nActiveState=inactive\n";
        let units = parse("h", raw);
        assert_eq!(units.len(), 2);
        assert_eq!((units[0].scope.as_str(), units[1].scope.as_str()), ("system", "user"));
    }

    #[test]
    fn accepts_a_widened_window() {
        let raw = "@@@SCOPE user\nId=worker.service\nActiveState=active\n\
                   UnitFileState=enabled\nRestart=on-failure\nRestartUSec=3s\n\
                   StartLimitIntervalUSec=5min\nStartLimitBurst=5\n";
        assert!(!parse("h", raw)[0].limit_unreachable);
    }

    #[test]
    fn restart_no_is_never_flagged() {
        let raw = "@@@SCOPE system\nId=oneshot.service\nActiveState=inactive\n\
                   UnitFileState=static\nRestart=no\nRestartUSec=100ms\n\
                   StartLimitIntervalUSec=10s\nStartLimitBurst=5\n";
        assert!(!parse("h", raw)[0].limit_unreachable);
    }

    #[test]
    fn rejects_unknown_actions() {
        assert!(unit_action_script("user".into(), "x.service".into(), "rm -rf".into()).is_err());
        assert!(unit_action_script("global".into(), "x.service".into(), "stop".into()).is_err());
    }

    #[test]
    fn system_scope_never_prompts() {
        assert_eq!(
            unit_action_script("system".into(), "a b.service".into(), "restart".into()).unwrap(),
            "sudo -n systemctl --system restart 'a b.service'"
        );
    }
}
