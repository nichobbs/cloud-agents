/// Which harnesses actually have a runner image on this deployment (#523).
///
/// A fresh Coolify deploy only builds the claude-code:base runner image by
/// default (see deploy/docker-compose.coolify.yml); codex/opencode/gemini
/// need an operator to opt in via COMPOSE_PROFILES. Before this, the picker
/// offered all four unconditionally and a session created with a disabled
/// harness only failed at container-creation time with an opaque Docker
/// "no such image" error. GET /api/harnesses reports which of the known
/// harnesses the backend believes are enabled; a missing/failing response
/// means "unknown" and every harness is treated as available — fail open,
/// matching the backend's own default for a deployment that never set
/// CLOUD_AGENTS_ENABLED_HARNESSES (e.g. the standalone-VM RUNBOOK path,
/// whose install-docker.sh builds all four unconditionally).
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
