import { useEffect, useState } from "react";
import { AppInfo, ConfigEntry, listConfigs, readConfig, diffConfig, writeConfig } from "../api";
import { useConfirm } from "../Confirm";
import HostSelect from "../HostSelect";

function Diff({ text }: { text: string }) {
  return (
    <pre className="out">
      {text.split("\n").map((l, i) => {
        const cls = l.startsWith("+++") || l.startsWith("---") || l.startsWith("@@")
          ? "diff-hdr"
          : l.startsWith("+") ? "diff-add"
          : l.startsWith("-") ? "diff-del"
          : undefined;
        return <div key={i} className={cls}>{l || " "}</div>;
      })}
    </pre>
  );
}

export default function ConfigsPanel({ info: { hosts, configPath } }: { info: AppInfo }) {
  const [host, setHost] = useState(hosts[0]?.name ?? "");
  const [items, setItems] = useState<ConfigEntry[]>([]);
  const [open, setOpen] = useState<ConfigEntry | null>(null);
  const [orig, setOrig] = useState("");
  const [text, setText] = useState("");
  const [diff, setDiff] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const confirm = useConfirm();

  async function load(h = host) {
    if (!h) return;
    setBusy(true); setErr(null); setOpen(null); setDiff(null);
    try { setItems(await listConfigs(h)); }
    catch (e: any) { setErr(String(e)); setItems([]); }
    finally { setBusy(false); }
  }
  useEffect(() => { load(); }, [host]);

  async function openFile(c: ConfigEntry) {
    setBusy(true); setErr(null); setDiff(null);
    try {
      const s = await readConfig(c.host, c.path);
      setOrig(s); setText(s); setOpen(c);
    } catch (e: any) { setErr(String(e)); }
    finally { setBusy(false); }
  }

  async function review() {
    if (!open) return;
    setBusy(true); setErr(null);
    try { setDiff(await diffConfig(open.host, open.path, text)); }
    catch (e: any) { setErr(String(e)); }
    finally { setBusy(false); }
  }

  function save() {
    if (!open) return;
    confirm({
      title: `Overwrite ${open.path}?`,
      why: "A timestamped .bak copy is written first. JSON files are validated before the write.",
      command: `# on ${open.host}\ncp -a ${open.path} ${open.path}.bak-<timestamp>\n# then replace with your edited contents`,
      host: open.host,
      danger: true,
      run: async () => {
        await writeConfig(open.host, open.path, text);
        setOrig(text);
        setDiff(null);
        await load();
      },
    });
  }

  const dirty = text !== orig;

  return (
    <>
      <div className="bar">
        <h1>Configs</h1>
        <HostSelect hosts={hosts} value={host} onChange={setHost} />
        <div className="spacer" />
        {open && (
          <>
            {open.protected && <span className="pill">read-only</span>}
            {dirty && <span className="pill warn">unsaved</span>}
            <button className="btn" onClick={review} disabled={busy || !dirty}>Review diff</button>
            <button className="btn danger" onClick={save} disabled={busy || !dirty || open.protected}>Save…</button>
            <button className="btn" onClick={() => { setOpen(null); setDiff(null); }} disabled={busy}>Close</button>
          </>
        )}
        {!open && <button className="btn" onClick={() => load()} disabled={busy}>Refresh</button>}
      </div>

      <div className="body">
        {err && <p className="err">{err}</p>}

        {!open && (
          <table>
            <thead><tr><th>Type</th><th>Path</th><th style={{ width: 80 }}>Size</th></tr></thead>
            <tbody>
              {items.map((c) => (
                <tr key={c.path} style={{ cursor: "pointer" }} onClick={() => openFile(c)}>
                  <td>{c.label} {c.protected && <span className="pill">read-only</span>}</td>
                  <td className="mono trunc" style={{ maxWidth: 460 }}>{c.path}</td>
                  <td style={{ color: "var(--dim)" }}>{c.size}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
        {!open && !busy && items.length === 0 && (
          <div className="empty">No matching files on {host}. Patterns are set under <code className="mono">configs</code> in {configPath}</div>
        )}

        {open && (
          <>
            <div className="mono" style={{ fontSize: 12, color: "var(--dim)", marginBottom: 8 }}>
              {open.host}:{open.path}
            </div>
            {diff ? (
              <>
                <div className="row" style={{ marginBottom: 6 }}>
                  <strong style={{ fontSize: 12 }}>Pending change</strong>
                  <div className="spacer" />
                  <button className="btn" onClick={() => setDiff(null)}>Back to editor</button>
                </div>
                <Diff text={diff} />
              </>
            ) : (
              <textarea
                className="editor"
                value={text}
                spellCheck={false}
                readOnly={open.protected}
                onChange={(e) => setText(e.target.value)}
              />
            )}
          </>
        )}
      </div>
    </>
  );
}
