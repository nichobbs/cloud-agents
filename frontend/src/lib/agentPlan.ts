/// Parses a markdown checkbox plan out of an agent's response text.
///
/// Harnesses whose images can't run the cloud-agents MCP shim (opencode,
/// codex, gemini — no dotnet in those images) are instructed (see
/// docker/session-tools-guide.md) to maintain their plan as a markdown
/// checkbox list instead: `- [ ]` pending, `- [~]` in progress, `- [x]`
/// done. OpenCode's own todo tool also renders this shape into its output.
/// The session todo panel shows the parsed plan read-only next to the
/// database-backed todos, so a plan is visible even when the agent never
/// called our tools.

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
 * The LAST contiguous checkbox list in `text` (ANSI codes stripped), or []
 * when none. "Last" because agents restate their plan as they update it —
 * the final statement is the current one. Lists shorter than 2 items are
 * ignored: a lone checkbox is more likely quoted output than a plan.
 */
export function parseAgentPlan(text: string): PlanItem[] {
  const clean = text.replace(/\x1b\[[0-9;]*m/g, '');
  const lines = clean.split('\n');
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
