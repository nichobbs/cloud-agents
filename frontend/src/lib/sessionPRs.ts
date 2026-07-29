import type { Message } from '../types';

/// Extraction of pull-request references from a session's transcript, for
/// the "PRs this session" panel: agents paste PR URLs when they open them
/// (and "merged #123" style references when they act on them), but those
/// links scroll away into collapsed messages. Display-only — no GitHub API
/// call — so it works for any host the transcript mentions.

export interface SessionPRRef {
  owner: string;
  repo: string;
  number: number;
  url: string;
  /** The transcript message the reference FIRST appeared in, for deep-linking. */
  messageId: string;
}

const PR_URL_RE = /https?:\/\/github\.com\/([\w.-]+)\/([\w.-]+)\/pull\/(\d+)/g;

/**
 * Every distinct GitHub PR URL referenced anywhere in the transcript, in
 * first-seen order, each anchored to the message it first appeared in.
 * ANSI codes are stripped before matching (agent output is full of them).
 */
export function extractSessionPRs(messages: Message[]): SessionPRRef[] {
  const seen = new Set<string>();
  const out: SessionPRRef[] = [];
  for (const m of messages) {
    const clean = m.content.replace(/\x1b\[[0-9;]*m/g, '');
    let match: RegExpExecArray | null;
    PR_URL_RE.lastIndex = 0;
    while ((match = PR_URL_RE.exec(clean)) !== null) {
      const owner = match[1] ?? '';
      const repo = match[2] ?? '';
      const number = parseInt(match[3] ?? '0', 10);
      if (!owner || !repo || !number) continue;
      const key = `${owner}/${repo}#${number}`;
      if (seen.has(key)) continue;
      seen.add(key);
      out.push({
        owner,
        repo,
        number,
        url: `https://github.com/${owner}/${repo}/pull/${number}`,
        messageId: m.id,
      });
    }
  }
  return out;
}
