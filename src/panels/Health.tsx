import { useEffect, useState } from "react";
import { Host, Health, hostHealth } from "../api";

function Meter({ pct }: { pct: number }) {
  const cls = pct >= 90 ? "bad" : pct >= 80 ? "warn" : "";
  return <div className="meter"><i className={cls} style={{ width: `${Math.min(pct, 100)}%` }} /></div>;
}

export default function HealthPanel({ hosts }: { hosts: Host[] }) {
  const [data, setData] = useState<Record<string, Health | null>>({});
  const [loading, setLoading] = useState(false);

  async function load() {
    setLoading(true);
    // Hosts are probed in parallel: one unreachable box must not stall the rest.
    await Promise.all(
      hosts.map(async (h) => {
        try {
          const r = await hostHealth(h.name);
          setData((d) => ({ ...d, [h.name]: r }));
        } catch {
          setData((d) => ({ ...d, [h.name]: null }));
        }
      })
    );
    setLoading(false);
  }

  useEffect(() => { if (hosts.length) load(); }, [hosts.length]);

  return (
    <>
      <div className="bar">
        <h1>Health</h1>
        <div className="spacer" />
        <button className="btn" onClick={load} disabled={loading}>
          {loading ? "Refreshing…" : "Refresh"}
        </button>
      </div>
      <div className="body">
        <div className="cards">
          {hosts.map((h) => {
            const d = data[h.name];
            const memPct = d && d.memTotalMb ? Math.round((d.memUsedMb / d.memTotalMb) * 100) : 0;
            return (
              <div className="card" key={h.name}>
                <h3>
                  {h.name}{" "}
                  {d && !d.reachable && <span className="pill bad">unreachable</span>}
                </h3>
                <div className="sub">{h.label}</div>
                {!d && <div className="empty">probing…</div>}
                {d?.error && <div className="err">{d.error}</div>}
                {d?.reachable && (
                  <>
                    <div className="kv"><span>uptime</span><span>{d.uptime || "—"}</span></div>
                    <div className="kv"><span>load</span><span className="mono">{d.load}</span></div>

                    <div className="kv" style={{ marginTop: 6 }}>
                      <span>disk /</span>
                      <span>{d.diskPct}% · {d.diskUsed}/{d.diskTotal}</span>
                    </div>
                    <Meter pct={d.diskPct} />

                    <div className="kv" style={{ marginTop: 6 }}>
                      <span>memory</span>
                      <span>{(d.memUsedMb / 1024).toFixed(1)}/{(d.memTotalMb / 1024).toFixed(1)} GB</span>
                    </div>
                    <Meter pct={memPct} />

                    {d.swapTotalMb > 0 && (
                      <>
                        <div className="kv" style={{ marginTop: 6 }}>
                          <span>swap</span>
                          <span>{(d.swapUsedMb / 1024).toFixed(1)}/{(d.swapTotalMb / 1024).toFixed(1)} GB</span>
                        </div>
                        <Meter pct={Math.round((d.swapUsedMb / d.swapTotalMb) * 100)} />
                      </>
                    )}

                    <div className="kv" style={{ marginTop: 8 }}>
                      <span>tailnet</span>
                      <span className="mono">{d.tailscaleIp || <span className="pill bad">down</span>}</span>
                    </div>

                    <div className="kv">
                      <span>failed units</span>
                      <span className={d.failedUnits.length ? "pill warn" : "pill ok"}>
                        {d.failedUnits.length}
                      </span>
                    </div>
                    {d.failedUnits.length > 0 && (
                      <div className="mono" style={{ fontSize: 11, color: "var(--dim)", marginTop: 4 }}>
                        {d.failedUnits.slice(0, 6).map((u) => <div key={u} className="trunc">{u}</div>)}
                        {d.failedUnits.length > 6 && <div>+{d.failedUnits.length - 6} more</div>}
                      </div>
                    )}

                    <div className="kv" style={{ marginTop: 8 }}>
                      <span>syncthing</span>
                      <span>
                        {d.syncthing
                          ? <>{d.syncthing.folders} folders · {d.syncthing.peers.filter((p) => p[1]).length}/{d.syncthing.peers.length} peers</>
                          : <span className="pill">not running</span>}
                      </span>
                    </div>
                  </>
                )}
              </div>
            );
          })}
        </div>
      </div>
    </>
  );
}
