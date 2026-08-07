/** One node of a workspace file tree. Directories carry `children`
 *  (possibly empty); files never do. `path` is the full repo-relative path. */
export interface FileTreeNode {
  name: string;
  path: string;
  children?: FileTreeNode[];
}

interface MutableNode {
  name: string;
  path: string;
  /** Present iff the node is a directory. */
  childMap?: Map<string, MutableNode>;
}

/** Build a nested directory tree from a flat list of `/`-separated paths.
 *  Sibling ordering: directories first, then files, each alphabetical
 *  (stable — equal names keep insertion order via the stable Array sort). */
export function buildFileTree(paths: string[]): FileTreeNode[] {
  const root = new Map<string, MutableNode>();
  for (const path of paths) {
    if (!path) continue;
    const parts = path.split('/').filter(p => p !== '');
    let level = root;
    let prefix = '';
    for (let i = 0; i < parts.length; i++) {
      const name = parts[i] ?? '';
      const isLeaf = i === parts.length - 1;
      const nodePath = prefix ? `${prefix}/${name}` : name;
      let node = level.get(name);
      if (!node) {
        node = { name, path: nodePath };
        level.set(name, node);
      }
      if (!isLeaf) {
        // Intermediate segment — the node is a directory even if some other
        // entry claimed the same name as a file.
        if (!node.childMap) node.childMap = new Map();
        level = node.childMap;
        prefix = nodePath;
      }
    }
  }
  return toSortedArray(root);
}

function toSortedArray(level: Map<string, MutableNode>): FileTreeNode[] {
  const nodes = [...level.values()];
  nodes.sort((a, b) => {
    const aDir = a.childMap ? 0 : 1;
    const bDir = b.childMap ? 0 : 1;
    if (aDir !== bDir) return aDir - bDir;
    return a.name < b.name ? -1 : a.name > b.name ? 1 : 0;
  });
  return nodes.map(n =>
    n.childMap
      ? { name: n.name, path: n.path, children: toSortedArray(n.childMap) }
      : { name: n.name, path: n.path },
  );
}
