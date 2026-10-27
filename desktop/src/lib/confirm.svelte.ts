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

/** The one pending ask, rendered by <Confirm />. Panels call `confirm(...)`. */
export const pending = $state<{ ask: Ask | null }>({ ask: null });

export function confirm(a: Ask) {
  pending.ask = a;
}
