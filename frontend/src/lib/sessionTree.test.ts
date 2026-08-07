import { describe, it, expect } from 'vitest';
import {
  buildSessionTree,
  byAttention,
  byText,
  countSessions,
  flattenGroups,
  pruneEmptyGroups,
  rollupAttention,
} from './sessionTree';
import type { Session, SessionGroup } from '../types';

function group(id: string, name: string, parentId = ''): SessionGroup {
  return { id, name, parentId, createdAt: '0' };
}

function session(id: string, over: Partial<Session> = {}): Session {
  return {
    sessionId: id,
    repoUrl: 'https://github.com/nic/app',
    branch: 'main',
    createdAt: '1700000000000',
    ...over,
  };
}

describe('buildSessionTree', () => {
  it('nests groups by parentId and name-sorts siblings', () => {
    const tree = buildSessionTree(
      [group('b', 'Beta'), group('a', 'Alpha'), group('c', 'Child', 'a')],
      [],
    );
    expect(tree.roots.map(r => r.group.name)).toEqual(['Alpha', 'Beta']);
    expect(tree.roots[0]?.children.map(c => c.group.name)).toEqual(['Child']);
    expect(tree.roots[1]?.children).toEqual([]);
  });

  it('treats a group with an unknown parentId as a root (orphan)', () => {
    const tree = buildSessionTree([group('x', 'Orphan', 'missing')], []);
    expect(tree.roots.map(r => r.group.id)).toEqual(['x']);
  });

  it('breaks parent cycles instead of looping forever', () => {
    const a = group('a', 'A', 'b');
    const b = group('b', 'B', 'a');
    const tree = buildSessionTree([a, b], []);
    // One cycle member is promoted to a root, the other stays nested under it.
    expect(tree.roots).toHaveLength(1);
    const root = tree.roots[0];
    expect(root?.children).toHaveLength(1);
    expect(root?.children[0]?.children).toEqual([]);
    const ids = [root?.group.id, root?.children[0]?.group.id].sort();
    expect(ids).toEqual(['a', 'b']);
  });

  it('a self-parenting group becomes a root', () => {
    const tree = buildSessionTree([group('a', 'A', 'a')], []);
    expect(tree.roots.map(r => r.group.id)).toEqual(['a']);
    expect(tree.roots[0]?.children).toEqual([]);
  });

  it('attaches sessions by groupId and puts unknown/absent groupIds in ungrouped', () => {
    const tree = buildSessionTree(
      [group('a', 'Alpha')],
      [
        session('s1', { groupId: 'a' }),
        session('s2', { groupId: 'nope' }),
        session('s3'),
        session('s4', { groupId: '' }),
      ],
    );
    expect(tree.roots[0]?.sessions.map(s => s.sessionId)).toEqual(['s1']);
    expect(tree.ungrouped.map(s => s.sessionId)).toEqual(['s2', 's3', 's4']);
  });
});

describe('rollupAttention', () => {
  it('is idle for an empty subtree', () => {
    const tree = buildSessionTree([group('a', 'A')], []);
    expect(rollupAttention(tree.roots[0]!)).toBe('idle');
  });

  it('prefers pending over working over viewed over idle, across descendants', () => {
    const groups = [group('a', 'A'), group('b', 'B', 'a')];
    const mk = (attn: { child: string; parent: string }) =>
      buildSessionTree(groups, [
        session('p', { groupId: 'a', attention: attn.parent }),
        session('c', { groupId: 'b', attention: attn.child }),
      ]).roots[0]!;
    expect(rollupAttention(mk({ parent: 'viewed', child: 'pending' }))).toBe('pending');
    expect(rollupAttention(mk({ parent: 'working', child: 'viewed' }))).toBe('working');
    expect(rollupAttention(mk({ parent: 'idle', child: 'viewed' }))).toBe('viewed');
    expect(rollupAttention(mk({ parent: 'idle', child: 'idle' }))).toBe('idle');
    expect(rollupAttention(mk({ parent: 'pending', child: 'working' }))).toBe('pending');
  });
});

describe('countSessions', () => {
  it('counts sessions across the whole subtree', () => {
    const tree = buildSessionTree(
      [group('a', 'A'), group('b', 'B', 'a')],
      [
        session('s1', { groupId: 'a' }),
        session('s2', { groupId: 'b' }),
        session('s3', { groupId: 'b' }),
      ],
    );
    expect(countSessions(tree.roots[0]!)).toBe(3);
  });
});

describe('byAttention', () => {
  it("'all' passes every session", () => {
    expect(byAttention('all')(session('s'))).toBe(true);
  });

  it('matches the server-provided attention state', () => {
    expect(byAttention('pending')(session('s', { attention: 'pending' }))).toBe(true);
    expect(byAttention('pending')(session('s', { attention: 'viewed' }))).toBe(false);
  });

  it('falls back to client-side derivation when the server omits attention', () => {
    // RUNNING with no attention field (older backend) derives to working.
    expect(byAttention('working')(session('s', { status: 'RUNNING' }))).toBe(true);
  });
});

describe('byText', () => {
  it('an empty or whitespace query passes everything', () => {
    expect(byText('')(session('s'))).toBe(true);
    expect(byText('   ')(session('s'))).toBe(true);
  });

  it('matches repoUrl, branch, and harness case-insensitively', () => {
    const s = session('s', { branch: 'Fix-Bug', harness: 'claude' });
    expect(byText('NIC/APP')(s)).toBe(true);
    expect(byText('fix-bug')(s)).toBe(true);
    expect(byText('CLAUDE')(s)).toBe(true);
    expect(byText('nomatch')(s)).toBe(false);
  });

  it('tolerates a missing harness', () => {
    expect(byText('claude')(session('s'))).toBe(false);
  });
});

describe('pruneEmptyGroups', () => {
  it('drops groups with no sessions anywhere in their subtree', () => {
    const tree = buildSessionTree(
      [group('a', 'A'), group('b', 'B'), group('c', 'C', 'b')],
      [session('s1', { groupId: 'c' })],
    );
    const pruned = pruneEmptyGroups(tree);
    // A is empty → gone; B kept because its child C holds a session.
    expect(pruned.roots.map(r => r.group.id)).toEqual(['b']);
    expect(pruned.roots[0]?.children.map(c => c.group.id)).toEqual(['c']);
  });

  it('keeps ungrouped sessions untouched', () => {
    const tree = buildSessionTree([group('a', 'A')], [session('s1')]);
    const pruned = pruneEmptyGroups(tree);
    expect(pruned.roots).toEqual([]);
    expect(pruned.ungrouped.map(s => s.sessionId)).toEqual(['s1']);
  });
});

describe('flattenGroups', () => {
  it('flattens in display order with depths', () => {
    const flat = flattenGroups([
      group('b', 'Beta'),
      group('a', 'Alpha'),
      group('c', 'Child', 'a'),
      group('d', 'Deep', 'c'),
    ]);
    expect(flat.map(f => [f.group.name, f.depth])).toEqual([
      ['Alpha', 0],
      ['Child', 1],
      ['Deep', 2],
      ['Beta', 0],
    ]);
  });
});
