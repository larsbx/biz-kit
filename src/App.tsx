import { useEffect, useState, ComponentType } from "react";
import { Host, listHosts } from "./api";
import { ConfirmProvider } from "./Confirm";
import HealthPanel from "./panels/Health";
import ServicesPanel from "./panels/Services";
import ScriptsPanel from "./panels/Scripts";
import ConfigsPanel from "./panels/Configs";

/**
 * Panel registry. Adding a tool later means writing one component and adding one
 * row here -- that is the whole extension point.
 */
type Panel = {
  id: string;
  label: string;
  component: ComponentType<{ hosts: Host[] }>;
};

const PANELS: Panel[] = [
  { id: "health", label: "Health", component: HealthPanel },
  { id: "services", label: "Services", component: ServicesPanel },
  { id: "scripts", label: "Scripts", component: ScriptsPanel },
  { id: "configs", label: "Configs", component: ConfigsPanel },
];

export default function App() {
  const [hosts, setHosts] = useState<Host[]>([]);
  const [active, setActive] = useState(() => localStorage.getItem("panel") || "health");
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    listHosts().then(setHosts).catch((e) => setErr(String(e)));
  }, []);

  useEffect(() => { localStorage.setItem("panel", active); }, [active]);

  const Current = (PANELS.find((p) => p.id === active) ?? PANELS[0]).component;

  return (
    <ConfirmProvider>
      <div className="app">
        <aside className="side">
          <div className="brand">
            Fleet
            <small>adder-ws · papa</small>
          </div>
          <nav className="nav">
            {PANELS.map((p) => (
              <button
                key={p.id}
                className={active === p.id ? "on" : ""}
                onClick={() => setActive(p.id)}
              >
                {p.label}
              </button>
            ))}
          </nav>
          <div className="side-foot">
            {hosts.length} hosts · ssh config
          </div>
        </aside>
        <main className="main">
          {err && <div className="body"><p className="err">{err}</p></div>}
          {!err && hosts.length === 0 && <div className="body"><div className="empty">loading hosts…</div></div>}
          {!err && hosts.length > 0 && <Current hosts={hosts} />}
        </main>
      </div>
    </ConfirmProvider>
  );
}
