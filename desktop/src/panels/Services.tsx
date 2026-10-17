import { useEffect, useMemo, useState } from "react";
import { AppInfo, Unit, listUnits, unitActionScript, runOn, previewCommand } from "../api";
import { useConfirm } from "../Confirm";
import HostSelect from "../HostSelect";

const ACTIONS = ["start", "stop", "restart", "enable", "disable"] as const;
const DESTRUCTIVE = new Set(["stop", "disable", "restart"]);

function fmt(s: number) {
  if (!isFinite(s)) return "∞";
  return s >= 60 ? `${Math.round(s / 60)}min` : `${+s.toFixed(s < 1 ? 3 : 0)}s`;
}

export default function ServicesPanel({ info: { hosts } }: { info: AppInfo }) {
  const [host, setHost] = useState(hosts[0]?.name ?? "");
  const [units, setUnits] = useState<Unit[]>([]);
  const [q, setQ] = useState("");
  const [only, setOnly] = useState<"all" | "active" | "limit">("all");
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const confirm = useConfirm();

  async function load(h = host) {
    if (!h) return;
    setLoading(true); setErr(null);
    try { setUnits(await listUnits(h)); }
    catch (e: any) { setErr(String(e)); setUnits([]); }
    finally { setLoading(false); }
  }
  useEffect(() => { load(); }, [host]);

  const shown = useMemo(() => {
    const needle = q.toLowerCase();
    return units
      .filter((u) => (only === "active" ? u.active === "active" : only === "limit" ? u.limitUnreachable : true))
      .filter((u) => !needle || u.id.toLowerCase().includes(needle))
      .sort((a, b) => Number(b.limitUnreachable) - Number(a.limitUnreachable) || a.id.localeCompare(b.id));
  }, [units, q, only]);

  const badCount = units.filter((u) => u.limitUnreachable).length;

  async function act(u: Unit, action: string) {
    const script = await unitActionScript(u.scope, u.id, action);
    const command = await previewCommand(u.host, script);
    confirm({
      title: `${action} ${u.id} on ${u.host}?`,
      why:
        u.scope === "system"
          ? "System scope runs through sudo -n: it fails instead of prompting unless the user has passwordless sudo for this command."
          : undefined,
      command,
      host: u.host,
      danger: DESTRUCTIVE.has(action),
      run: async () => {
        const out = await runOn(u.host, script);
        if (out.code !== 0) throw new Error(out.stderr.trim() || `exit ${out.code}`);
        await load();
      },
    });
  }

  return (
    <>
      <div className="bar">
        <h1>Services</h1>
        <HostSelect hosts={hosts} value={host} onChange={setHost} />
        <div className="chips">
          {(["all", "active", "limit"] as const).map((k) => (
            <button key={k} className={"chip" + (only === k ? " on" : "")} onClick={() => setOnly(k)}>
              {k === "limit" ? `restart loop risk (${badCount})` : k}
            </button>
          ))}
        </div>
        <input
          type="text" placeholder="Filter…" value={q}
          onChange={(e) => setQ(e.target.value)} style={{ width: 160 }}
        />
        <div className="spacer" />
        <button className="btn" onClick={() => load()} disabled={loading}>
          {loading ? "Loading…" : "Refresh"}
        </button>
      </div>
      <div className="body">
        {err && <p className="err">{err}</p>}
        {!err && !loading && shown.length === 0 && <div className="empty">no units match</div>}
        {shown.length > 0 && (
          <table>
            <thead>
              <tr>
                <th>unit</th><th>scope</th><th>active</th><th>enabled</th>
                <th>restart</th><th>limit</th><th style={{ width: 250 }} />
              </tr>
            </thead>
            <tbody>
              {shown.map((u) => (
                <tr key={u.scope + u.id}>
                  <td className="mono">{u.id}</td>
                  <td><span className="pill">{u.scope}</span></td>
                  <td>
                    <span className={"pill " + (u.active === "active" ? "ok" : u.active === "failed" ? "bad" : "")}>
                      {u.active}
                    </span>
                  </td>
                  <td><span className="pill">{u.enabled}</span></td>
                  <td className="mono" style={{ color: "var(--dim)" }}>
                    {u.restart && u.restart !== "no" ? `${u.restart} / ${fmt(u.restartSec)}` : "—"}
                  </td>
                  <td>
                    {u.limitUnreachable ? (
                      <span className="pill bad" title={`${fmt(u.restartSec)} × ${u.limitBurst} ≥ ${fmt(u.limitInterval)} — limiter can never trip`}>
                        unreachable
                      </span>
                    ) : u.restart && u.restart !== "no" ? (
                      <span className="pill ok">{u.limitBurst}/{fmt(u.limitInterval)}</span>
                    ) : <span className="pill">—</span>}
                  </td>
                  <td>
                    <div className="row" style={{ justifyContent: "flex-end" }}>
                      {ACTIONS.map((a) => (
                        <button
                          key={a}
                          className={"btn" + (DESTRUCTIVE.has(a) ? " danger" : "")}
                          onClick={() => act(u, a)}
                        >
                          {a}
                        </button>
                      ))}
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </>
  );
}
