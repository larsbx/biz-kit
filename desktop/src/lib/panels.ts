import type { Component } from "svelte";
import type { AppInfo } from "./api";
import Health from "./panels/Health.svelte";
import Services from "./panels/Services.svelte";
import Scripts from "./panels/Scripts.svelte";
import Configs from "./panels/Configs.svelte";
import Dispatch from "./panels/Dispatch.svelte";

/**
 * Panel registry. Adding a tool later means writing one component and adding one
 * row here -- that is the whole extension point.
 */
export type Panel = {
  id: string;
  label: string;
  requiresHosts: boolean;
  component: Component<{ info: AppInfo }>;
};

export const PANELS: Panel[] = [
  { id: "health", label: "Health", requiresHosts: true, component: Health },
  { id: "services", label: "Services", requiresHosts: true, component: Services },
  { id: "scripts", label: "Scripts", requiresHosts: true, component: Scripts },
  { id: "configs", label: "Configs", requiresHosts: true, component: Configs },
  { id: "dispatch", label: "Dispatch", requiresHosts: false, component: Dispatch },
];
