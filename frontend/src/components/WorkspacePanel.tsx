import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import DOMPurify from 'dompurify';
import hljs from 'highlight.js';
import { marked } from 'marked';
import 'highlight.js/styles/github-dark.css';
import { api } from '../lib/api';
import { splitPatchByFile, type DiffLine, type DiffLineKind } from '../lib/diffParse';
import { buildFileTree, type FileTreeNode } from '../lib/fileTree';
import type { WorkspaceDiff, WorkspaceFileContent, WorkspaceFileEntry } from '../types';

interface WorkspacePanelProps {
  sessionId: string;
  /** True while a run is streaming; a falling edge triggers a refresh. */
  isStreaming: boolean;
}

type Tab = 'changes' | 'files';

/** git-status letter → badge color (X = anything else). */
const STATUS_COLORS: Record<string, string> = {
  M: '#d29922',
  A: '#3fb950',
  D: '#f85149',
  U: '#58a6ff',
  R: '#bc8cff',
  X: '#8b949e',
};

/// Inspector for the session's workspace volume: a "Changes" tab showing the
/// uncommitted diff (status + diffstat + expandable per-file patches) and a
/// "Files" tab with a browsable tree and an in-panel file viewer (markdown
/// rendered, code highlighted, images inline). Every fetch spawns a
/// short-lived inspect container server-side, so data loads only on demand:
/// first expand, explicit Refresh, and the falling edge of a run — never on
/// an interval.
export function WorkspacePanel({ sessionId, isStreaming }: WorkspacePanelProps) {
  const [expanded, setExpanded] = useState(false);
  const [tab, setTab] = useState<Tab>('changes');
  // 404 from the workspace routes = older backend — hide the whole panel.
  const [hidden, setHidden] = useState(false);
  // 409 = the session has no workspace volume yet (no runs).
  const [noWorkspace, setNoWorkspace] = useState(false);

  const [diff, setDiff] = useState<WorkspaceDiff | null>(null);
  const [diffLoading, setDiffLoading] = useState(false);
  const [diffError, setDiffError] = useState('');
  const [openPatches, setOpenPatches] = useState<Record<string, boolean>>({});

  const [files, setFiles] = useState<WorkspaceFileEntry[] | null>(null);
  const [filesTruncated, setFilesTruncated] = useState(false);
  const [filesLoading, setFilesLoading] = useState(false);
  const [filesError, setFilesError] = useState('');
  const [openDirs, setOpenDirs] = useState<Record<string, boolean>>({});

  const [viewer, setViewer] = useState<WorkspaceFileContent | null>(null);
  const [viewerLoading, setViewerLoading] = useState('');
  const [viewerError, setViewerError] = useState('');

  const sessionRef = useRef(sessionId);
  useEffect(() => {
    sessionRef.current = sessionId;
  }, [sessionId]);

  // A navigation to another session invalidates everything loaded here.
  useEffect(() => {
    setHidden(false);
    setNoWorkspace(false);
    setDiff(null);
    setDiffLoading(false);
    setDiffError('');
    setOpenPatches({});
    setFiles(null);
    setFilesTruncated(false);
    setFilesLoading(false);
    setFilesError('');
    setOpenDirs({});
    setViewer(null);
    setViewerLoading('');
    setViewerError('');
  }, [sessionId]);

  /** Shared error branch for the workspace endpoints' status-prefixed
   *  messages. Returns true when the error was absorbed into panel state. */
  const absorbWorkspaceError = useCallback((e: unknown): { message: string; absorbed: boolean } => {
    const message = e instanceof Error ? e.message : String(e);
    if (message.startsWith('404 ')) {
      setHidden(true);
      return { message, absorbed: true };
    }
    if (message.startsWith('409 ')) {
      setNoWorkspace(true);
      return { message, absorbed: true };
    }
    return { message, absorbed: false };
  }, []);

  const loadDiff = useCallback(async () => {
    const forSession = sessionId;
    setDiffLoading(true);
    setDiffError('');
    setNoWorkspace(false);
    try {
      const d = await api.getWorkspaceDiff(forSession);
      if (sessionRef.current === forSession) setDiff(d);
    } catch (e) {
      if (sessionRef.current !== forSession) return;
      const { message, absorbed } = absorbWorkspaceError(e);
      if (!absorbed) setDiffError(message || 'failed to load diff');
    } finally {
      if (sessionRef.current === forSession) setDiffLoading(false);
    }
  }, [sessionId, absorbWorkspaceError]);

  const loadFiles = useCallback(async () => {
    const forSession = sessionId;
    setFilesLoading(true);
    setFilesError('');
    setNoWorkspace(false);
    try {
      const listing = await api.listWorkspaceFiles(forSession);
      if (sessionRef.current !== forSession) return;
      setFiles(listing.files);
      setFilesTruncated(listing.truncated === 'true');
    } catch (e) {
      if (sessionRef.current !== forSession) return;
      const { message, absorbed } = absorbWorkspaceError(e);
      if (!absorbed) setFilesError(message || 'failed to list files');
    } finally {
      if (sessionRef.current === forSession) setFilesLoading(false);
    }
  }, [sessionId, absorbWorkspaceError]);

  // First-open fetch per tab. Errors / the 409 state stop the auto-fetch so a
  // failure never loops; Refresh retries explicitly.
  useEffect(() => {
    if (!expanded || hidden || noWorkspace) return;
    if (tab === 'changes' && diff === null && !diffLoading && !diffError) void loadDiff();
    if (tab === 'files' && files === null && !filesLoading && !filesError) void loadFiles();
  }, [expanded, tab, hidden, noWorkspace, diff, diffLoading, diffError, files, filesLoading, filesError, loadDiff, loadFiles]);

  // Falling edge of isStreaming = a run just finished — its writes are what
  // this panel exists to show, so re-fetch whatever has been loaded (or hit
  // the 409 "no workspace yet", which the finished run may have cured). Never
  // fetch for a panel the user hasn't opened: each call costs a container.
  const prevStreamingRef = useRef(isStreaming);
  useEffect(() => {
    if (prevStreamingRef.current && !isStreaming && expanded && !hidden) {
      if (diff !== null || diffError !== '' || noWorkspace) void loadDiff();
      if (files !== null || filesError !== '') void loadFiles();
    }
    prevStreamingRef.current = isStreaming;
  }, [isStreaming, expanded, hidden, diff, diffError, files, filesError, noWorkspace, loadDiff, loadFiles]);

  const openFile = useCallback(async (path: string) => {
    const forSession = sessionId;
    setViewerLoading(path);
    setViewerError('');
    try {
      const f = await api.getWorkspaceFile(forSession, path);
      if (sessionRef.current === forSession) setViewer(f);
    } catch (e) {
      if (sessionRef.current !== forSession) return;
      const message = e instanceof Error ? e.message : String(e);
      setViewerError(message || 'failed to load file');
    } finally {
      if (sessionRef.current === forSession) setViewerLoading('');
    }
  }, [sessionId]);

  const sections = useMemo(() => splitPatchByFile(diff?.patch ?? ''), [diff]);
  const tree = useMemo(() => buildFileTree((files ?? []).map(f => f.path)), [files]);

  if (hidden) return null; // older backend without workspace routes

  const refreshing = tab === 'changes' ? diffLoading : filesLoading;
  const refresh = () => {
    if (tab === 'changes') void loadDiff();
    else void loadFiles();
  };

  return (
    <div style={panelStyle}>
      <button
        style={headerBtnStyle}
        onClick={() => setExpanded(e => !e)}
        aria-expanded={expanded}
      >
        <span style={chevronStyle}>{expanded ? '▾' : '▸'}</span>
        <span style={headerStyle}>Workspace</span>
      </button>

      {expanded && (
        <>
          <div style={tabRowStyle}>
            <button style={tab === 'changes' ? activeTabStyle : tabStyle} onClick={() => setTab('changes')}>
              Changes
            </button>
            <button style={tab === 'files' ? activeTabStyle : tabStyle} onClick={() => setTab('files')}>
              Files
            </button>
            <span style={{ flex: 1 }} />
            <button
              style={refreshBtnStyle}
              onClick={refresh}
              disabled={refreshing}
              title="Re-inspect the workspace (runs a short-lived container)"
            >
              {refreshing ? 'Inspecting…' : '↻ Refresh'}
            </button>
          </div>

          {noWorkspace && <div style={emptyStyle}>No workspace yet — send a message first.</div>}

          {tab === 'changes' && !noWorkspace && (
            <ChangesTab
              diff={diff}
              loading={diffLoading}
              error={diffError}
              sections={sections}
              openPatches={openPatches}
              onTogglePatch={path => setOpenPatches(prev => ({ ...prev, [path]: !prev[path] }))}
              onRetry={() => void loadDiff()}
            />
          )}

          {tab === 'files' && !noWorkspace && (
            <FilesTab
              files={files}
              truncated={filesTruncated}
              loading={filesLoading}
              error={filesError}
              tree={tree}
              onToggleDir={(path, open) => setOpenDirs(prev => ({ ...prev, [path]: !open }))}
              isDirOpen={(path, depth) => openDirs[path] ?? depth < 2}
              viewer={viewer}
              viewerLoading={viewerLoading}
              viewerError={viewerError}
              onOpenFile={path => void openFile(path)}
              onCloseViewer={() => setViewer(null)}
              onRetry={() => void loadFiles()}
            />
          )}
        </>
      )}
    </div>
  );
}

// ─── Changes tab ──────────────────────────────────────────────────────────────

function ChangesTab({ diff, loading, error, sections, openPatches, onTogglePatch, onRetry }: {
  diff: WorkspaceDiff | null;
  loading: boolean;
  error: string;
  sections: Record<string, DiffLine[]>;
  openPatches: Record<string, boolean>;
  onTogglePatch: (path: string) => void;
  onRetry: () => void;
}) {
  if (error) {
    return (
      <div role="alert" style={errorStyle}>
        {error}{' '}
        <button style={retryBtnStyle} onClick={onRetry}>Retry</button>
      </div>
    );
  }
  if (diff === null) return loading ? <div style={emptyStyle}>Inspecting workspace…</div> : null;
  if (diff.clean === 'true') return <div style={emptyStyle}>Working tree clean.</div>;

  const additions = diff.files.reduce((n, f) => n + (parseInt(f.additions, 10) || 0), 0);
  const deletions = diff.files.reduce((n, f) => n + (parseInt(f.deletions, 10) || 0), 0);

  return (
    <div style={changesBodyStyle}>
      <div style={diffstatHeaderStyle}>
        {diff.files.length} file{diff.files.length === 1 ? '' : 's'} changed
        {' · '}
        <span style={{ color: '#3fb950' }}>+{additions}</span>{' '}
        <span style={{ color: '#f85149' }}>−{deletions}</span>
      </div>
      {diff.files.map(f => (
        <div key={f.path}>
          <button style={fileRowStyle} onClick={() => onTogglePatch(f.path)} title={f.path}>
            <span
              style={{
                ...statusBadgeStyle,
                color: STATUS_COLORS[f.status] ?? '#8b949e',
                borderColor: STATUS_COLORS[f.status] ?? '#8b949e',
              }}
            >
              {f.status}
            </span>
            <span style={filePathStyle}>{f.path}</span>
            {f.additions !== '' && <span style={addCountStyle}>+{f.additions}</span>}
            {f.deletions !== '' && <span style={delCountStyle}>−{f.deletions}</span>}
          </button>
          {openPatches[f.path] && <PatchView lines={sections[f.path]} />}
        </div>
      ))}
    </div>
  );
}

function PatchView({ lines }: { lines: DiffLine[] | undefined }) {
  if (!lines || lines.length === 0) {
    return <div style={noPatchStyle}>No patch for this file (binary or untracked).</div>;
  }
  return (
    <div style={patchScrollStyle}>
      {lines.map((l, i) => (
        <div key={i} style={{ ...patchLineStyle, ...PATCH_LINE_KIND_STYLES[l.kind] }}>
          {l.text === '' ? ' ' : l.text}
        </div>
      ))}
    </div>
  );
}

// ─── Files tab ────────────────────────────────────────────────────────────────

function FilesTab({
  files, truncated, loading, error, tree, onToggleDir, isDirOpen,
  viewer, viewerLoading, viewerError, onOpenFile, onCloseViewer, onRetry,
}: {
  files: WorkspaceFileEntry[] | null;
  truncated: boolean;
  loading: boolean;
  error: string;
  tree: FileTreeNode[];
  onToggleDir: (path: string, open: boolean) => void;
  isDirOpen: (path: string, depth: number) => boolean;
  viewer: WorkspaceFileContent | null;
  viewerLoading: string;
  viewerError: string;
  onOpenFile: (path: string) => void;
  onCloseViewer: () => void;
  onRetry: () => void;
}) {
  if (error) {
    return (
      <div role="alert" style={errorStyle}>
        {error}{' '}
        <button style={retryBtnStyle} onClick={onRetry}>Retry</button>
      </div>
    );
  }
  if (files === null) return loading ? <div style={emptyStyle}>Inspecting workspace…</div> : null;

  if (viewer) {
    return <FileViewer file={viewer} onClose={onCloseViewer} />;
  }

  return (
    <div style={filesBodyStyle}>
      {truncated && <div style={noteStyle}>listing truncated at 5000 files</div>}
      {viewerError && <div role="alert" style={errorStyle}>{viewerError}</div>}
      {viewerLoading !== '' && <div style={emptyStyle}>Loading {viewerLoading}…</div>}
      {files.length === 0 && <div style={emptyStyle}>No files in the workspace.</div>}
      <TreeLevel nodes={tree} depth={0} isDirOpen={isDirOpen} onToggleDir={onToggleDir} onOpenFile={onOpenFile} />
    </div>
  );
}

function TreeLevel({ nodes, depth, isDirOpen, onToggleDir, onOpenFile }: {
  nodes: FileTreeNode[];
  depth: number;
  isDirOpen: (path: string, depth: number) => boolean;
  onToggleDir: (path: string, open: boolean) => void;
  onOpenFile: (path: string) => void;
}) {
  return (
    <>
      {nodes.map(n => {
        const indent = { paddingLeft: `${6 + depth * 14}px` };
        if (n.children) {
          const open = isDirOpen(n.path, depth);
          return (
            <div key={n.path}>
              <button
                style={{ ...treeRowStyle, ...indent, color: '#8b949e' }}
                onClick={() => onToggleDir(n.path, open)}
                aria-expanded={open}
              >
                {open ? '▾' : '▸'} {n.name}/
              </button>
              {open && (
                <TreeLevel
                  nodes={n.children}
                  depth={depth + 1}
                  isDirOpen={isDirOpen}
                  onToggleDir={onToggleDir}
                  onOpenFile={onOpenFile}
                />
              )}
            </div>
          );
        }
        return (
          <button
            key={n.path}
            style={{ ...treeRowStyle, ...indent }}
            onClick={() => onOpenFile(n.path)}
            title={n.path}
          >
            {n.name}
          </button>
        );
      })}
    </>
  );
}

// ─── File viewer ──────────────────────────────────────────────────────────────

const IMAGE_MIME: Record<string, string> = {
  png: 'image/png',
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  gif: 'image/gif',
  webp: 'image/webp',
  ico: 'image/x-icon',
  svg: 'image/svg+xml',
};

/** Highlight files up to this many bytes; larger ones render as plain text. */
const HIGHLIGHT_CAP = 200 * 1024;

function extOf(path: string): string {
  const base = path.slice(path.lastIndexOf('/') + 1);
  const i = base.lastIndexOf('.');
  return i === -1 ? '' : base.slice(i + 1).toLowerCase();
}

function base64ToBytes(b64: string): Uint8Array<ArrayBuffer> {
  try {
    const bin = atob(b64);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return bytes;
  } catch {
    return new Uint8Array(0);
  }
}

/** '1234' bytes → '1.2 KB'-style label. Falls back to the raw string. */
export function humanSize(size: string): string {
  const n = parseInt(size, 10);
  if (!Number.isFinite(n) || n < 0) return size;
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MB`;
}

function FileViewer({ file, onClose }: { file: WorkspaceFileContent; onClose: () => void }) {
  const bytes = useMemo(() => base64ToBytes(file.contentBase64), [file.contentBase64]);
  const ext = extOf(file.path);
  const imageMime = IMAGE_MIME[ext];
  const isMd = ext === 'md' || ext === 'markdown';
  const [showSource, setShowSource] = useState(false);

  // Images render from a blob URL, revoked when the viewer closes/swaps files.
  const [blobUrl, setBlobUrl] = useState('');
  useEffect(() => {
    if (!imageMime) return;
    const url = URL.createObjectURL(new Blob([bytes], { type: imageMime }));
    setBlobUrl(url);
    return () => {
      URL.revokeObjectURL(url);
      setBlobUrl('');
    };
  }, [bytes, imageMime]);

  const text = useMemo(
    () => (imageMime ? '' : new TextDecoder('utf-8').decode(bytes)),
    [bytes, imageMime],
  );

  const markdownHtml = useMemo(() => {
    if (!isMd) return '';
    return DOMPurify.sanitize(marked.parse(text, { async: false }));
  }, [isMd, text]);

  const highlighted = useMemo(() => {
    if (imageMime || isMd || bytes.length > HIGHLIGHT_CAP) return null;
    try {
      if (ext && hljs.getLanguage(ext)) return hljs.highlight(text, { language: ext }).value;
      return hljs.highlightAuto(text).value;
    } catch {
      return null;
    }
  }, [imageMime, isMd, bytes.length, ext, text]);

  return (
    <div style={viewerCardStyle}>
      <div style={viewerHeaderStyle}>
        <span style={viewerNameStyle} title={file.path}>{file.path}</span>
        <span style={viewerSizeStyle}>{humanSize(file.size)}</span>
        {isMd && (
          <button style={sourceToggleStyle} onClick={() => setShowSource(s => !s)}>
            {showSource ? 'Rendered' : 'Source'}
          </button>
        )}
        <button style={closeBtnStyle} onClick={onClose} aria-label="Close file">
          ×
        </button>
      </div>
      {file.truncated === 'true' && (
        <div style={noteStyle}>Showing the first 1 MiB of {humanSize(file.size)}.</div>
      )}
      <div style={viewerBodyStyle}>
        {imageMime ? (
          blobUrl !== '' && <img src={blobUrl} alt={file.path} style={imageStyle} />
        ) : isMd && !showSource ? (
          <div style={markdownStyle} dangerouslySetInnerHTML={{ __html: markdownHtml }} />
        ) : highlighted !== null && !isMd ? (
          <pre style={codePreStyle}>
            <code className="hljs" dangerouslySetInnerHTML={{ __html: highlighted }} />
          </pre>
        ) : (
          <pre style={codePreStyle}>{text}</pre>
        )}
      </div>
    </div>
  );
}

// ─── Styles ───────────────────────────────────────────────────────────────────

const panelStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '8px',
  background: '#0d1117',
  border: '1px solid #21262d',
  borderRadius: '8px',
  padding: '12px 14px',
};

const headerBtnStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: '6px',
  background: 'transparent',
  border: 'none',
  padding: 0,
  cursor: 'pointer',
  textAlign: 'left',
};

const chevronStyle: React.CSSProperties = {
  color: '#8b949e',
  fontSize: '10px',
  width: '10px',
};

const headerStyle: React.CSSProperties = {
  fontSize: '12px',
  color: '#8b949e',
  textTransform: 'uppercase',
  letterSpacing: '0.04em',
};

const tabRowStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: '6px',
};

const tabStyle: React.CSSProperties = {
  background: 'transparent',
  border: '1px solid #30363d',
  borderRadius: '6px',
  color: '#8b949e',
  fontSize: '11px',
  padding: '2px 10px',
  cursor: 'pointer',
};

const activeTabStyle: React.CSSProperties = {
  ...tabStyle,
  color: '#c9d1d9',
  background: '#21262d',
};

const refreshBtnStyle: React.CSSProperties = {
  background: 'transparent',
  border: '1px solid #30363d',
  borderRadius: '6px',
  color: '#8b949e',
  fontSize: '11px',
  padding: '2px 8px',
  cursor: 'pointer',
};

const emptyStyle: React.CSSProperties = {
  fontSize: '12px',
  color: '#6e7681',
};

const noteStyle: React.CSSProperties = {
  fontSize: '11px',
  color: '#d29922',
};

const errorStyle: React.CSSProperties = {
  fontSize: '12px',
  color: '#f85149',
};

const retryBtnStyle: React.CSSProperties = {
  background: 'transparent',
  border: '1px solid #30363d',
  borderRadius: '6px',
  color: '#8b949e',
  fontSize: '11px',
  padding: '1px 8px',
  cursor: 'pointer',
};

const changesBodyStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '2px',
};

const diffstatHeaderStyle: React.CSSProperties = {
  fontSize: '12px',
  color: '#c9d1d9',
  paddingBottom: '4px',
};

const fileRowStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: '8px',
  width: '100%',
  background: 'transparent',
  border: 'none',
  borderTop: '1px solid #161b22',
  padding: '4px 0',
  cursor: 'pointer',
  textAlign: 'left',
};

const statusBadgeStyle: React.CSSProperties = {
  fontSize: '10px',
  fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
  border: '1px solid',
  borderRadius: '4px',
  padding: '0 4px',
  flexShrink: 0,
};

const filePathStyle: React.CSSProperties = {
  flex: 1,
  minWidth: 0,
  fontSize: '12px',
  fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
  color: '#c9d1d9',
  overflow: 'hidden',
  textOverflow: 'ellipsis',
  whiteSpace: 'nowrap',
};

const addCountStyle: React.CSSProperties = {
  fontSize: '11px',
  color: '#3fb950',
  flexShrink: 0,
};

const delCountStyle: React.CSSProperties = {
  fontSize: '11px',
  color: '#f85149',
  flexShrink: 0,
};

const patchScrollStyle: React.CSSProperties = {
  overflowX: 'auto',
  border: '1px solid #21262d',
  borderRadius: '6px',
  margin: '2px 0 6px',
  background: '#0d1117',
};

const patchLineStyle: React.CSSProperties = {
  fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
  fontSize: '11px',
  lineHeight: '1.5',
  whiteSpace: 'pre',
  padding: '0 8px',
};

const PATCH_LINE_KIND_STYLES: Record<DiffLineKind, React.CSSProperties> = {
  add: { color: '#3fb950', background: 'rgba(63,185,80,.12)' },
  del: { color: '#f85149', background: 'rgba(248,81,73,.12)' },
  hunk: { color: '#79c0ff' },
  meta: { color: '#8b949e' },
  ctx: { color: '#c9d1d9' },
};

const noPatchStyle: React.CSSProperties = {
  fontSize: '11px',
  color: '#6e7681',
  padding: '2px 0 6px 20px',
};

const filesBodyStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '2px',
};

const treeRowStyle: React.CSSProperties = {
  display: 'block',
  width: '100%',
  background: 'transparent',
  border: 'none',
  padding: '2px 0',
  cursor: 'pointer',
  textAlign: 'left',
  fontSize: '12px',
  fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
  color: '#c9d1d9',
  overflow: 'hidden',
  textOverflow: 'ellipsis',
  whiteSpace: 'nowrap',
};

const viewerCardStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '6px',
  background: '#161b22',
  border: '1px solid #30363d',
  borderRadius: '8px',
  padding: '10px 12px',
};

const viewerHeaderStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: '8px',
};

const viewerNameStyle: React.CSSProperties = {
  flex: 1,
  minWidth: 0,
  fontSize: '12px',
  fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
  color: '#c9d1d9',
  overflow: 'hidden',
  textOverflow: 'ellipsis',
  whiteSpace: 'nowrap',
};

const viewerSizeStyle: React.CSSProperties = {
  fontSize: '11px',
  color: '#8b949e',
  flexShrink: 0,
};

const sourceToggleStyle: React.CSSProperties = {
  background: 'transparent',
  border: '1px solid #30363d',
  borderRadius: '6px',
  color: '#8b949e',
  fontSize: '11px',
  padding: '1px 8px',
  cursor: 'pointer',
  flexShrink: 0,
};

const closeBtnStyle: React.CSSProperties = {
  background: 'transparent',
  border: 'none',
  color: '#8b949e',
  fontSize: '16px',
  lineHeight: 1,
  padding: '0 2px',
  cursor: 'pointer',
  flexShrink: 0,
};

const viewerBodyStyle: React.CSSProperties = {
  overflow: 'auto',
  maxHeight: '480px',
};

const imageStyle: React.CSSProperties = {
  maxWidth: '100%',
  display: 'block',
};

const markdownStyle: React.CSSProperties = {
  fontSize: '13px',
  color: '#c9d1d9',
  wordBreak: 'break-word',
};

const codePreStyle: React.CSSProperties = {
  margin: 0,
  fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
  fontSize: '11px',
  lineHeight: '1.5',
  color: '#c9d1d9',
  whiteSpace: 'pre',
  overflowX: 'auto',
};
