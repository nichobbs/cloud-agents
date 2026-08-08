import { describe, it, expect } from 'vitest';
import { buildFileTree } from './fileTree';

describe('buildFileTree', () => {
  it('nests paths into directories with full paths on every node', () => {
    const tree = buildFileTree(['src/lib/api.ts', 'src/App.tsx', 'README.md']);
    expect(tree).toEqual([
      {
        name: 'src',
        path: 'src',
        children: [
          {
            name: 'lib',
            path: 'src/lib',
            children: [{ name: 'api.ts', path: 'src/lib/api.ts' }],
          },
          { name: 'App.tsx', path: 'src/App.tsx' },
        ],
      },
      { name: 'README.md', path: 'README.md' },
    ]);
  });

  it('sorts directories before files, each alphabetically', () => {
    const tree = buildFileTree(['zzz.txt', 'beta/x.txt', 'alpha/y.txt', 'aaa.txt']);
    expect(tree.map(n => n.name)).toEqual(['alpha', 'beta', 'aaa.txt', 'zzz.txt']);
    // Directories carry children; files don't.
    expect(tree[0]!.children).toBeDefined();
    expect(tree[2]!.children).toBeUndefined();
  });

  it('merges siblings under a shared directory once', () => {
    const tree = buildFileTree(['docs/a.md', 'docs/b.md']);
    expect(tree).toHaveLength(1);
    expect(tree[0]!.children!.map(n => n.name)).toEqual(['a.md', 'b.md']);
  });

  it('ignores empty paths and empty segments', () => {
    expect(buildFileTree(['', 'a//b.txt'])).toEqual([
      { name: 'a', path: 'a', children: [{ name: 'b.txt', path: 'a/b.txt' }] },
    ]);
  });

  it('returns an empty tree for an empty listing', () => {
    expect(buildFileTree([])).toEqual([]);
  });
});
