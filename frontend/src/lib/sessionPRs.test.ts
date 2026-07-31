import { describe, expect, it } from 'vitest';
import { extractSessionPRs } from './sessionPRs';
import type { Message } from '../types';

function msg(id: string, content: string): Message {
  return { id, sessionId: 's', role: 'agent', content, seq: '1', createdAt: '1' };
}

describe('extractSessionPRs', () => {
  it('extracts and dedupes PR URLs across messages, first-seen order', () => {
    const prs = extractSessionPRs([
      msg('m1', 'Opened https://github.com/acme/widgets/pull/42 for review.'),
      msg('m2', 'CI green on https://github.com/acme/widgets/pull/42 — also opened https://github.com/acme/gadgets/pull/7.'),
    ]);
    expect(prs).toHaveLength(2);
    expect(prs[0]).toMatchObject({ owner: 'acme', repo: 'widgets', number: 42, messageId: 'm1' });
    expect(prs[1]).toMatchObject({ owner: 'acme', repo: 'gadgets', number: 7, messageId: 'm2' });
  });

  it('strips ANSI codes before matching and normalizes the URL', () => {
    const prs = extractSessionPRs([
      msg('m1', 'see \x1b[36mhttps://github.com/a-b/c.d/pull/9\x1b[0m today'),
    ]);
    expect(prs).toHaveLength(1);
    expect(prs[0]!.url).toBe('https://github.com/a-b/c.d/pull/9');
  });

  it('ignores non-PR GitHub links and prose', () => {
    const prs = extractSessionPRs([
      msg('m1', 'https://github.com/acme/widgets/issues/3 and https://github.com/acme/widgets plain text'),
    ]);
    expect(prs).toHaveLength(0);
  });
});

describe('extractSessionPRs case-insensitive dedupe (#804)', () => {
  it('treats owner/repo case variants as the same PR, keeping first-seen casing', () => {
    const prs = extractSessionPRs([
      msg('m1', 'https://github.com/Acme/Widgets/pull/42'),
      msg('m2', 'https://github.com/acme/widgets/pull/42'),
    ]);
    expect(prs).toHaveLength(1);
    expect(prs[0]!.owner).toBe('Acme');
  });
});
