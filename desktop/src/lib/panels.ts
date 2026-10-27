import type { Component } from "svelte";
import type { AppInfo } from "./api";
import Health from "./panels/Health.svelte";
import Services from "./panels/Services.svelte";
import Scripts from "./panels/Scripts.svelte";
import Configs from "./panels/Configs.svelte";

/**
 * Panel registry. Adding a tool later means writing one component and adding one
 * row here -- that is the whole extension point.
 */
export type Panel = {
  id: string;
  label: string;
  component: Component<{ info: AppInfo }>;
};

export const PANELS: Panel[] = [
  { id: "health", label: "Health", component: Health },
  { id: "services", label: "Services", component: Services },
  { id: "scripts", label: "Scripts", component: Scripts },
  { id: "configs", label: "Configs", component: Configs },
];
