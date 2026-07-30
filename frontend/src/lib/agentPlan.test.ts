import { describe, expect, it } from 'vitest';
import { parseAgentPlan } from './agentPlan';

describe('parseAgentPlan', () => {
  it('parses a simple checkbox list with all three states', () => {
    const plan = parseAgentPlan(
      'Here is my plan:\n- [x] clone the repo\n- [~] fix the bug\n- [ ] run the tests\nDone for now.',
    );
    expect(plan).toEqual([
      { state: 'done', text: 'clone the repo' },
      { state: 'in_progress', text: 'fix the bug' },
      { state: 'pending', text: 'run the tests' },
    ]);
  });

  it('returns the LAST list when the agent restates its plan', () => {
    const plan = parseAgentPlan(
      '- [ ] step one\n- [ ] step two\n\nlater...\n\n- [x] step one\n- [~] step two',
    );
    expect(plan.map(p => p.state)).toEqual(['done', 'in_progress']);
  });

  it('ignores single-item lists (likely quoted output, not a plan)', () => {
    expect(parseAgentPlan('note:\n- [ ] lonely item\nmore prose')).toEqual([]);
  });

  it('handles numbered and star bullets, uppercase X, and ANSI codes', () => {
    const plan = parseAgentPlan(
      '1. [X] \x1b[32mfirst\x1b[0m\n2) [ ] second\n* [✓] third',
    );
    expect(plan).toEqual([
      { state: 'done', text: 'first' },
      { state: 'pending', text: 'second' },
      { state: 'done', text: 'third' },
    ]);
  });

  it('tolerates blank lines inside a list', () => {
    const plan = parseAgentPlan('- [ ] a\n\n- [x] b');
    expect(plan.length).toBe(2);
  });

  it('returns [] for text with no checkboxes', () => {
    expect(parseAgentPlan('just some prose\nwith lines')).toEqual([]);
  });
});

describe('parseAgentPlan server-parity edges (#784)', () => {
  it('parses a bullet without a trailing space', () => {
    expect(parseAgentPlan('-[ ] first\n-[x] second')).toHaveLength(2);
  });

  it('rejects a checkbox with no whitespace after the bracket', () => {
    expect(parseAgentPlan('- [x]crammed\n- [x]also')).toEqual([]);
  });

  it('rejects checkbox items with empty text', () => {
    expect(parseAgentPlan('- [ ] \n- [x] ')).toEqual([]);
  });
});

describe('parseAgentPlan bullet requirement (#790)', () => {
  it('rejects bullet-less checkbox lines, same as the server parser', () => {
    expect(parseAgentPlan('[ ] bare one\n[x] bare two')).toEqual([]);
  });
});

describe('parseAgentPlan whitespace parity (#807)', () => {
  it('parses a tab between the bullet and the checkbox on both sides', () => {
    expect(parseAgentPlan('-\t[ ] tabbed one\n-\t[x] tabbed two')).toHaveLength(2);
  });
});
