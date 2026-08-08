/** Rendering class of one unified-diff line. */
export type DiffLineKind = 'add' | 'del' | 'hunk' | 'meta' | 'ctx';

/** One patch line with its rendering class. */
export interface DiffLine {
  kind: DiffLineKind;
  text: string;
}

/** Rendering class for a single patch line. Order matters: `+++`/`---`
 *  file headers must win over plain `+`/`-` change lines. */
export function classifyDiffLine(line: string): DiffLineKind {
  if (line.startsWith('+++') || line.startsWith('---')) return 'meta';
  if (line.startsWith('@@')) return 'hunk';
  if (line.startsWith('diff ') || line.startsWith('index ')) return 'meta';
  if (line.startsWith('+')) return 'add';
  if (line.startsWith('-')) return 'del';
  return 'ctx';
}

/** The post-image path out of a `diff --git a/OLD b/NEW` header line —
 *  renames key by the NEW path. '' when the line isn't parseable. */
export function diffHeaderPath(line: string): string {
  const prefix = 'diff --git ';
  if (!line.startsWith(prefix)) return '';
  const rest = line.slice(prefix.length);
  // The b/ side is the last ` b/` occurrence — path components can't be
  // told apart perfectly when paths contain ' b/', but this handles the
  // overwhelmingly common cases including renames (a/old b/new).
  const idx = rest.lastIndexOf(' b/');
  if (idx === -1) return rest;
  return rest.slice(idx + 3);
}

/** Split a whole unified diff into per-file line sections keyed by (new)
 *  path. Lines before the first `diff --git` header are dropped; an empty
 *  patch yields an empty record. Each section includes its header lines. */
export function splitPatchByFile(patch: string): Record<string, DiffLine[]> {
  const out: Record<string, DiffLine[]> = {};
  if (!patch) return out;
  const lines = patch.split('\n');
  // Drop the trailing empty string a final newline produces (a real blank
  // context line inside a hunk is ' ', not '').
  if (lines.length > 0 && lines[lines.length - 1] === '') lines.pop();
  let current: DiffLine[] | null = null;
  for (const line of lines) {
    if (line.startsWith('diff --git ')) {
      const path = diffHeaderPath(line);
      current = [];
      out[path] = current;
    }
    if (current) current.push({ kind: classifyDiffLine(line), text: line });
  }
  return out;
}
