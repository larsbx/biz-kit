import { useEffect, useRef, useState } from "react";
import { AppInfo, Script, Line, listScripts, runScript } from "../api";
import { useConfirm } from "../Confirm";

export default function ScriptsPanel({ info: { scriptsDir } }: { info: AppInfo }) {
  const [scripts, setScripts] = useState<Script[]>([]);
  const [sel, setSel] = useState<Script | null>(null);
  const [lines, setLines] = useState<Line[]>([]);
  const [running, setRunning] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const outRef = useRef<HTMLPreElement>(null);
  const confirm = useConfirm();

  async function load() {
    try { setScripts(await listScripts()); }
    catch (e: any) { setErr(String(e)); }
  }
  useEffect(() => { load(); }, []);

  // Follow the tail while a long run streams in.
  useEffect(() => {
    if (outRef.current) outRef.current.scrollTop = outRef.current.scrollHeight;
  }, [lines.length]);

  function start(s: Script, apply: boolean) {
    setSel(s);
    setLines([]);
    setRunning(true);
    setErr(null);
    runScript(s.path, apply ? ["--apply"] : [], (l) => {
      setLines((p) => [...p, l]);
      if (l.kind === "done") setRunning(false);
    }).catch((e) => { setErr(String(e)); setRunning(false); });
  }

  function onApply(s: Script) {
    confirm({
      title: `Run ${s.name} with --apply?`,
      why: "This makes real changes. The dry run shows exactly what it would do.",
      command: `${s.interpreter} ${s.path} --apply`,
      danger: true,
      run: async () => start(s, true),
    });
  }

  const done = lines.find((l) => l.kind === "done") as { kind: "done"; code: number } | undefined;

  return (
    <>
      <div className="bar">
        <h1>Scripts</h1>
        <span className="mono trunc" style={{ color: "var(--dim)", fontSize: 12 }}>{scriptsDir}</span>
        <div className="spacer" />
        <button className="btn" onClick={load} disabled={running}>Rescan</button>
      </div>
      <div className="body">
        {err && <p className="err">{err}</p>}
        {scripts.length === 0 && <div className="empty">No .sh or .py scripts in {scriptsDir}</div>}

        <div className="cards" style={{ marginBottom: 16 }}>
          {scripts.map((s) => (
            <div className="card" key={s.path}>
              <h3 className="mono" style={{ fontSize: 12 }}>{s.name}</h3>
              <div className="sub">{s.summary || "—"}</div>
              <div className="row">
                <button className="btn" disabled={running} onClick={() => start(s, false)}>
                  {s.hasApply ? "Dry run" : "Run"}
                </button>
                {s.hasApply && (
                  <button className="btn danger" disabled={running} onClick={() => onApply(s)}>
                    Apply
                  </button>
                )}
              </div>
            </div>
          ))}
        </div>

        {(lines.length > 0 || running) && (
          <>
            <div className="row" style={{ marginBottom: 6 }}>
              <strong className="mono" style={{ fontSize: 12 }}>{sel?.name}</strong>
              {running && <span className="pill warn">running…</span>}
              {done && (
                <span className={"pill " + (done.code === 0 ? "ok" : "bad")}>
                  exit {done.code}
                </span>
              )}
              <div className="spacer" />
              <button className="btn" onClick={() => setLines([])} disabled={running}>Clear</button>
            </div>
            <pre className="out" ref={outRef}>
              {lines.map((l, i) =>
                l.kind === "done" ? null : (
                  <div key={i} className={l.kind === "stderr" ? "e" : undefined}>{l.text}</div>
                )
              )}
            </pre>
          </>
        )}
      </div>
    </>
  );
}
