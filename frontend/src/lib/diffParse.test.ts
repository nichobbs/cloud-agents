import { describe, it, expect } from 'vitest';
import { classifyDiffLine, diffHeaderPath, splitPatchByFile } from './diffParse';

const TWO_FILE_PATCH = [
  'diff --git a/src/a.ts b/src/a.ts',
  'index 1111111..2222222 100644',
  '--- a/src/a.ts',
  '+++ b/src/a.ts',
  '@@ -1,3 +1,4 @@',
  ' const a = 1;',
  '-const b = 2;',
  '+const b = 3;',
  '+const c = 4;',
  'diff --git a/README.md b/README.md',
  'index 3333333..4444444 100644',
  '--- a/README.md',
  '+++ b/README.md',
  '@@ -1 +1 @@',
  '-old title',
  '+new title',
  '',
].join('\n');

describe('splitPatchByFile', () => {
  it('splits a multi-file patch into sections keyed by path', () => {
    const sections = splitPatchByFile(TWO_FILE_PATCH);
    expect(Object.keys(sections)).toEqual(['src/a.ts', 'README.md']);
    const a = sections['src/a.ts']!;
    expect(a[0]!.text).toBe('diff --git a/src/a.ts b/src/a.ts');
    expect(a).toHaveLength(9);
    const readme = sections['README.md']!;
    expect(readme).toHaveLength(7);
    expect(readme[readme.length - 1]!.text).toBe('+new title');
  });

  it('keys a rename section by the new path', () => {
    const patch = [
      'diff --git a/old/name.ts b/new/name.ts',
      'similarity index 90%',
      'rename from old/name.ts',
      'rename to new/name.ts',
      '',
    ].join('\n');
    const sections = splitPatchByFile(patch);
    expect(Object.keys(sections)).toEqual(['new/name.ts']);
  });

  it('tolerates an empty patch', () => {
    expect(splitPatchByFile('')).toEqual({});
  });

  it('classifies every line kind for rendering', () => {
    const sections = splitPatchByFile(TWO_FILE_PATCH);
    const kinds = sections['src/a.ts']!.map(l => l.kind);
    expect(kinds).toEqual([
      'meta', // diff --git
      'meta', // index
      'meta', // ---
      'meta', // +++
      'hunk', // @@
      'ctx', //  const a = 1;
      'del', // -const b = 2;
      'add', // +const b = 3;
      'add', // +const c = 4;
    ]);
  });
});

describe('classifyDiffLine', () => {
  it('does not mistake +++/--- file headers for add/del lines', () => {
    expect(classifyDiffLine('+++ b/x')).toBe('meta');
    expect(classifyDiffLine('--- a/x')).toBe('meta');
    expect(classifyDiffLine('+added')).toBe('add');
    expect(classifyDiffLine('-removed')).toBe('del');
  });

  it('classifies hunk headers and context', () => {
    expect(classifyDiffLine('@@ -1,2 +1,2 @@ func x()')).toBe('hunk');
    expect(classifyDiffLine(' unchanged')).toBe('ctx');
    expect(classifyDiffLine('index abc..def 100644')).toBe('meta');
    expect(classifyDiffLine('diff --git a/x b/x')).toBe('meta');
  });
});

describe('diffHeaderPath', () => {
  it('takes the b/ side of a plain header', () => {
    expect(diffHeaderPath('diff --git a/src/x.ts b/src/x.ts')).toBe('src/x.ts');
  });
  it('takes the new path of a rename header', () => {
    expect(diffHeaderPath('diff --git a/old.ts b/new.ts')).toBe('new.ts');
  });
  it('returns "" for a non-header line', () => {
    expect(diffHeaderPath('+not a header')).toBe('');
  });
});
