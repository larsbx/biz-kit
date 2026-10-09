// Location freshness thresholds (Section 26.6).
//
// These belong to no provider: Section 28.5 replaces the Google presentation
// adapter with MapLibre without changing what "stale" means to a viewer, so the
// thresholds live beside neither adapter and are shared by both.
//
// Section 8.2 is the reason the vocabulary stays deliberately flat. These
// describe how old a fix is and nothing else; no value here may become a
// priority, severity, or routing signal.

/** A marker older than this is drawn gray. */
export const GRAY_AFTER_SECONDS = 120;

/** A marker older than this also carries a STALE label. */
export const STALE_AFTER_SECONDS = 300;

const FRESH_COLOR = "#1d4ed8";
const STALE_COLOR = "#6b7280";

/**
 * Display treatment for a location sample of a given age.
 *
 * @param {number} ageSeconds seconds since the sample was acquired
 * @returns {{color: string, label: string|null}}
 */
export function freshness(ageSeconds) {
  if (ageSeconds >= STALE_AFTER_SECONDS) return { color: STALE_COLOR, label: "STALE" };
  if (ageSeconds >= GRAY_AFTER_SECONDS) return { color: STALE_COLOR, label: null };
  return { color: FRESH_COLOR, label: null };
}
