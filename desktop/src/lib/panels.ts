import type { Component } from "svelte";
import type { AppInfo } from "./api";
import type { IconName } from "./Icon.svelte";
import Health from "./panels/Health.svelte";
import Services from "./panels/Services.svelte";
import Scripts from "./panels/Scripts.svelte";
import Configs from "./panels/Configs.svelte";
import Dispatch from "./panels/Dispatch.svelte";
import Settings from "./panels/Settings.svelte";

/**
 * Panel registry. Adding a tool later means writing one component and adding one
 * row here -- that is the whole extension point. The sidebar lists panels in
 * this order under their group; Settings is pinned to the bottom.
 */
export type Panel = {
  id: string;
  label: string;
  /** One line under the label in the sidebar: what you go there to do. */
  hint: string;
  icon: IconName;
  group: "Hosts" | "Business" | "App";
  requiresHosts: boolean;
  component: Component<{ info: AppInfo }>;
};

export const PANELS: Panel[] = [
  { id: "health", label: "Health", hint: "Disk, memory, failures", icon: "health", group: "Hosts", requiresHosts: true, component: Health },
  { id: "services", label: "Services", hint: "Start, stop, restart units", icon: "services", group: "Hosts", requiresHosts: true, component: Services },
  { id: "scripts", label: "Scripts", hint: "Run with live output", icon: "scripts", group: "Hosts", requiresHosts: true, component: Scripts },
  { id: "configs", label: "Configs", hint: "Edit files, diff first", icon: "configs", group: "Hosts", requiresHosts: true, component: Configs },
  { id: "dispatch", label: "Dispatch", hint: "Loads, stops and trips", icon: "dispatch", group: "Business", requiresHosts: false, component: Dispatch },
  { id: "settings", label: "Settings", hint: "Theme and text size", icon: "settings", group: "App", requiresHosts: false, component: Settings },
];

export const GROUPS = ["Hosts", "Business"] as const;
