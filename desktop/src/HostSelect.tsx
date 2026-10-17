import { Host } from "./api";

export default function HostSelect({ hosts, value, onChange }: {
  hosts: Host[];
  value: string;
  onChange: (name: string) => void;
}) {
  return (
    <select className="btn" value={value} onChange={(e) => onChange(e.target.value)}>
      {hosts.map((h) => <option key={h.name} value={h.name}>{h.name}</option>)}
    </select>
  );
}
