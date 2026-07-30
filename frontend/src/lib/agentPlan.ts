/// Parses a markdown checkbox plan out of an agent's response text.
///
/// All four harness images now ship the cloud-agents MCP shim, but this
/// fallback still matters (#820): older images built before the shim
/// rollout, repos where the harness's config file is git-tracked (the
/// token guard skips registration there — register-callbacks-mcp.sh),
/// agents that simply don't call the tools, and OpenCode's own todo tool
/// rendering this shape into its output. The session-tools guide
/// (docker/session-tools-guide.md) prescribes the format: `- [ ]` pending,
/// `- [~]` in progress, `- [x]` done. The session todo panel shows the
/// parsed plan read-only next to the database-backed todos, so a plan is
/// visible even when the agent never called our tools.

export type PlanState = 'pending' | 'in_progress' | 'done';

export interface PlanItem {
  text: string;
  state: PlanState;
}

// Kept aligned with the server-side parser in
// src/handlers/interactions.l's parsePlanLine (#784) — change both
// together. `(\S.*)` requires non-empty item text: a checkbox with nothing
// after it is more likely quoted output than a plan step.
const CHECKBOX_RE = /^\s*(?:[-*+]|\d+[.)])\s*\[([ xX~✓])\]\s+(\S.*)$/;

function stateOf(marker: string): PlanState {
  if (marker === '~') return 'in_progress';
  if (marker === ' ') return 'pending';
  return 'done';
}

/**
 * Only the message tail is scanned (#809): plans are restated at the END of
 * responses per the session-tools guide, full run logs can be megabytes,
 * and the server-side parser applies the same cap so the two stay in
 * lockstep. Keep in sync with interactions.l's maxPlanScanChars.
 */
const PLAN_SCAN_TAIL_CHARS = 32768;

/**
 * The LAST contiguous checkbox list in `text`'s tail (ANSI codes stripped),
 * or [] when none. "Last" because agents restate their plan as they update
 * it — the final statement is the current one. Lists shorter than 2 items
 * are ignored: a lone checkbox is more likely quoted output than a plan.
 */
export function parseAgentPlan(text: string): PlanItem[] {
  const clean = text.slice(-PLAN_SCAN_TAIL_CHARS).replace(/\x1b\[[0-9;]*m/g, '');
  // Split on \r?\n (#830): `.` and `$` treat \r as a line terminator in JS,
  // so a CRLF transcript would otherwise match no checkbox lines at all —
  // while the server parser trims \r and parses it fine.
  const lines = clean.split(/\r?\n/);
  let last: PlanItem[] = [];
  let current: PlanItem[] = [];
  for (const line of lines) {
    const m = CHECKBOX_RE.exec(line);
    if (m) {
      current.push({ state: stateOf(m[1] ?? ' '), text: (m[2] ?? '').trim() });
    } else if (current.length > 0) {
      // A blank line inside a list is tolerated; anything else ends it.
      if (line.trim() !== '') {
        if (current.length >= 2) last = current;
        current = [];
      }
    }
  }
  if (current.length >= 2) last = current;
  return last;
}
