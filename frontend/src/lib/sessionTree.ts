import type { Session, SessionGroup } from '../types';
import { sessionAttention } from './attention';
import type { Attention } from './attention';

/// Pure helpers for the session tree on the session list page: build a
/// nested group tree from the flat SessionGroup rows, attach sessions to
/// their groups, roll up per-group attention, and filter sessions by
/// attention state / free text.

export interface GroupNode {
  group: SessionGroup;
  children: GroupNode[];
  sessions: Session[];
}

export interface SessionTree {
  /** Top-level groups (parentId '' — or an orphaned/cyclic parentId). */
  roots: GroupNode[];
  /** Sessions with no group (or a groupId pointing at an unknown group). */
  ungrouped: Session[];
}

/** Build the group tree and attach sessions. Tolerant of bad data:
 *  - a group whose parentId doesn't exist (orphan) becomes a root
 *  - parent cycles are broken by promoting one member to a root
 *  - a session whose groupId is unknown lands in `ungrouped`
 *  Siblings are name-sorted (stable — ties keep input order). */
export function buildSessionTree(groups: SessionGroup[], sessions: Session[]): SessionTree {
  const nodes = new Map<string, GroupNode>();
  for (const g of groups) nodes.set(g.id, { group: g, children: [], sessions: [] });

  const roots: GroupNode[] = [];
  for (const g of groups) {
    const node = nodes.get(g.id);
    if (!node) continue;
    const parent = g.parentId !== '' && g.parentId !== g.id ? nodes.get(g.parentId) : undefined;
    if (parent) parent.children.push(node);
    else roots.push(node);
  }

  // Cycle guard: a↔b parent loops leave both unreachable from any root.
  // Promote the first member found to a root (detaching it from its parent
  // so rendering can't recurse forever); the rest of the cycle stays nested.
  const reachable = new Set<string>();
  const visit = (n: GroupNode): void => {
    if (reachable.has(n.group.id)) return;
    reachable.add(n.group.id);
    for (const c of n.children) visit(c);
  };
  for (const r of roots) visit(r);
  for (const g of groups) {
    if (reachable.has(g.id)) continue;
    const node = nodes.get(g.id);
    if (!node) continue;
    const parent = nodes.get(g.parentId);
    if (parent) parent.children = parent.children.filter(c => c.group.id !== g.id);
    roots.push(node);
    visit(node);
  }

  const sortNodes = (list: GroupNode[]): void => {
    list.sort((x, y) => x.group.name.localeCompare(y.group.name));
    for (const n of list) sortNodes(n.children);
  };
  sortNodes(roots);

  const ungrouped: Session[] = [];
  for (const s of sessions) {
    const node = s.groupId ? nodes.get(s.groupId) : undefined;
    if (node) node.sessions.push(s);
    else ungrouped.push(s);
  }

  return { roots, ungrouped };
}

/** Worst attention state in the subtree: pending > working > viewed > idle. */
const ATTENTION_PRIORITY: readonly Attention[] = ['pending', 'working', 'viewed', 'idle'];

export function rollupAttention(node: GroupNode): Attention {
  const rank = (a: Attention): number => ATTENTION_PRIORITY.indexOf(a);
  let worst: Attention = 'idle';
  for (const s of node.sessions) {
    const a = sessionAttention(s);
    if (rank(a) < rank(worst)) worst = a;
  }
  for (const c of node.children) {
    const a = rollupAttention(c);
    if (rank(a) < rank(worst)) worst = a;
  }
  return worst;
}

/** Total sessions in the subtree (the count shown on a group row). */
export function countSessions(node: GroupNode): number {
  let n = node.sessions.length;
  for (const c of node.children) n += countSessions(c);
  return n;
}

export type AttentionFilter = 'all' | 'working' | 'pending' | 'viewed';

/** Predicate for the attention filter chips. 'all' passes everything. */
export function byAttention(filter: AttentionFilter): (s: Session) => boolean {
  return s => filter === 'all' || sessionAttention(s) === filter;
}

/** Predicate for the free-text filter — case-insensitive match against
 *  repoUrl, branch, or harness. An empty/whitespace query passes everything. */
export function byText(q: string): (s: Session) => boolean {
  const needle = q.trim().toLowerCase();
  return s =>
    needle === '' ||
    s.repoUrl.toLowerCase().includes(needle) ||
    s.branch.toLowerCase().includes(needle) ||
    (s.harness ?? '').toLowerCase().includes(needle);
}

/** Drop group nodes whose subtree has no sessions — used while a filter is
 *  active so filtered-out groups don't clutter the tree. */
export function pruneEmptyGroups(tree: SessionTree): SessionTree {
  const prune = (list: GroupNode[]): GroupNode[] =>
    list
      .map(n => ({ ...n, children: prune(n.children) }))
      .filter(n => n.sessions.length > 0 || n.children.length > 0);
  return { roots: prune(tree.roots), ungrouped: tree.ungrouped };
}

export interface FlatGroup {
  group: SessionGroup;
  depth: number;
}

/** The tree flattened in display order with depths — for the
 *  "move to group" select's indented option labels. */
export function flattenGroups(groups: SessionGroup[]): FlatGroup[] {
  const tree = buildSessionTree(groups, []);
  const out: FlatGroup[] = [];
  const walk = (n: GroupNode, depth: number): void => {
    out.push({ group: n.group, depth });
    for (const c of n.children) walk(c, depth + 1);
  };
  for (const r of tree.roots) walk(r, 0);
  return out;
}
