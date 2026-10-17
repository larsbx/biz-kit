import { useEffect, useState, createContext, useContext, ReactNode } from "react";

/** A pending destructive action: what will run, where, and why we are asking. */
export type Ask = {
  title: string;
  why?: string;
  /** The literal command, shown verbatim. Never paraphrase it. */
  command: string;
  host?: string;
  danger?: boolean;
  run: () => Promise<void>;
};

const Ctx = createContext<(a: Ask) => void>(() => {});
export const useConfirm = () => useContext(Ctx);

export function ConfirmProvider({ children }: { children: ReactNode }) {
  const [ask, setAsk] = useState<Ask | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      if (e.key === "Escape" && !busy) { setAsk(null); setErr(null); }
    };
    window.addEventListener("keydown", k);
    return () => window.removeEventListener("keydown", k);
  }, [busy]);

  async function go() {
    if (!ask) return;
    setBusy(true);
    setErr(null);
    try {
      await ask.run();
      setAsk(null);
    } catch (e: any) {
      setErr(String(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Ctx.Provider value={(a) => { setErr(null); setAsk(a); }}>
      {children}
      {ask && (
        <div className="scrim" onMouseDown={(e) => { if (e.target === e.currentTarget && !busy) setAsk(null); }}>
          <div className="modal">
            <h2>{ask.title}</h2>
            {ask.why && <p className="why">{ask.why}</p>}
            <pre className="out">{ask.host ? `# on ${ask.host}\n` : ""}{ask.command}</pre>
            {err && <p className="err" style={{ marginTop: 10 }}>{err}</p>}
            <div className="actions">
              <button className="btn" disabled={busy} onClick={() => setAsk(null)}>Cancel</button>
              <button
                className={"btn " + (ask.danger ? "danger" : "go")}
                disabled={busy}
                onClick={go}
              >
                {busy ? "Running…" : "Run"}
              </button>
            </div>
          </div>
        </div>
      )}
    </Ctx.Provider>
  );
}
