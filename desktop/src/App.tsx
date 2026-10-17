import { useEffect, useState, ComponentType } from "react";
import { AppInfo, appInfo } from "./api";
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
  component: ComponentType<{ info: AppInfo }>;
};

const PANELS: Panel[] = [
  { id: "health", label: "Health", component: HealthPanel },
  { id: "services", label: "Services", component: ServicesPanel },
  { id: "scripts", label: "Scripts", component: ScriptsPanel },
  { id: "configs", label: "Configs", component: ConfigsPanel },
];

export default function App() {
  const [info, setInfo] = useState<AppInfo | null>(null);
  const [active, setActive] = useState(() => localStorage.getItem("panel") || "health");
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    appInfo().then(setInfo).catch((e) => setErr(String(e)));
  }, []);

  useEffect(() => { localStorage.setItem("panel", active); }, [active]);

  const Current = (PANELS.find((p) => p.id === active) ?? PANELS[0]).component;

  return (
    <ConfirmProvider>
      <div className="app">
        <aside className="side">
          <div className="brand">
            biz-kit
            <small className="trunc">{info?.hosts.map((h) => h.name).join(" · ")}</small>
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
          <div className="side-foot trunc" title={info?.configPath}>
            {info ? `${info.hosts.length} hosts · ${info.configPath}` : ""}
          </div>
        </aside>
        <main className="main">
          {err && <div className="body"><p className="err">{err}</p></div>}
          {!err && !info && <div className="body"><div className="empty">Loading…</div></div>}
          {info && info.hosts.length === 0 && (
            <div className="body">
              <div className="empty">
                No hosts configured. Add them to <code className="mono">{info.configPath}</code>
              </div>
            </div>
          )}
          {info && info.hosts.length > 0 && <Current info={info} />}
        </main>
      </div>
    </ConfirmProvider>
  );
}
