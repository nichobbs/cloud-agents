/// Which harnesses actually have a runner image on this deployment (#523).
///
/// Every deployment path (the standalone-VM RUNBOOK flow and Coolify alike)
/// now builds all four runner images unconditionally, so this normally just
/// confirms "everything's available" — but a deployment CAN still narrow
/// this via CLOUD_AGENTS_ENABLED_HARNESSES if an operator wants to disable
/// one deliberately. Before harness images built unconditionally, a fresh
/// Coolify deploy only built claude-code:base by default and the other
/// three needed an operator to opt in via Compose profiles; the picker used
/// to offer all four regardless, and a session created with a not-yet-built
/// harness only failed at container-creation time with an opaque Docker "no
/// such image" error — this module exists to surface that ahead of time.
/// GET /api/harnesses reports which of the known harnesses the backend
/// believes are enabled; a missing/failing response means "unknown" and
/// every harness is treated as available — fail open, matching the
/// backend's own default when CLOUD_AGENTS_ENABLED_HARNESSES is unset.
import { api } from './api';

let cached: Set<string> | null = null;

/** Enabled harness ids for this deployment, or null when unknown (callers
 *  should then treat every harness as available). A successful response is
 *  cached for the page session — this rarely changes without a redeploy —
 *  but a null (getEnabledHarnesses never rejects; it resolves null on any
 *  network failure or non-ok response, per its own doc comment) is NOT
 *  cached, so a transient blip doesn't permanently disable this feature for
 *  the rest of the session (#584): the next call retries instead of
 *  replaying the same stale null forever. */
export async function enabledHarnesses(): Promise<Set<string> | null> {
  if (cached) return cached;
  const ids = await api.getEnabledHarnesses();
  if (!ids) return null;
  cached = new Set(ids);
  return cached;
}
