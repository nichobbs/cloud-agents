import { useState, useEffect } from 'react';
import { api } from '../lib/api';
import { formatFullTimestamp, formatTimestamp } from '../lib/time';
import type { Attachment, Message } from '../types';
import { groupConsecutiveBlocks, type ParsedBlock } from '../lib/blockGroups';
import { AnsiContent } from './AnsiContent';
import { CommentThread } from './CommentThread';
import { CollapsibleJsonBlock } from './CollapsibleJsonBlock';
import { CollapsibleShellBlock } from './CollapsibleShellBlock';
import { ToolRunGroup } from './ToolRunGroup';

interface MessageBlockProps {
  message: Message;
  /** Files uploaded alongside this message, if any (grouped by messageId in
   *  SessionDetail — undefined/empty for a message with none). */
  attachments?: Attachment[];
  highlighted?: boolean;
  onTodoAdded?: () => void;
  onRetry?: (content: string) => void;
  isUnread?: boolean;
  isLatestAgentMessage?: boolean;
}

function formatAttachmentSize(sizeBytes: string): string {
  const n = Number(sizeBytes);
  if (!Number.isFinite(n) || n < 0) return '';
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MB`;
}

/** One uploaded file under a message: an image renders as a lazily-fetched
 *  thumbnail (click to open full-size in a new tab); anything else is a
 *  click-to-download chip. The download route is bearer-authenticated, so
 *  both fetch the bytes via api.getAttachmentBlob and build an object URL
 *  rather than a plain `<img src>`/`<a href>`. */
function AttachmentChip({ sessionId, attachment }: { sessionId: string; attachment: Attachment }) {
  const [objectUrl, setObjectUrl] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    if (attachment.kind !== 'image') return;
    let active = true;
    setLoading(true);
    api.getAttachmentBlob(sessionId, attachment.id)
      .then(blob => {
        if (!active) return;
        setObjectUrl(URL.createObjectURL(blob));
      })
      .catch(() => { if (active) setFailed(true); })
      .finally(() => { if (active) setLoading(false); });
    return () => {
      active = false;
    };
  }, [sessionId, attachment.id, attachment.kind]);

  useEffect(() => {
    return () => {
      if (objectUrl) URL.revokeObjectURL(objectUrl);
    };
  }, [objectUrl]);

  const handleDownload = async () => {
    try {
      const blob = await api.getAttachmentBlob(sessionId, attachment.id);
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = attachment.fileName;
      a.click();
      URL.revokeObjectURL(url);
    } catch {
      alert(`Failed to download "${attachment.fileName}"`);
    }
  };

  if (attachment.kind === 'image') {
    return (
      <a
        href={objectUrl ?? undefined}
        // Forces a save instead of a navigation/render — mimeType is
        // entirely client-supplied at upload time, so without this a
        // malicious image/svg+xml attachment could execute script at this
        // app's own origin the moment its blob: URL is opened directly
        // (browsers render SVG documents, not just <img> resources, on
        // direct navigation). Mirrors the document chip's handleDownload,
        // which already forces a save the same way.
        download={attachment.fileName}
        rel="noreferrer"
        style={attachmentImageLinkStyle}
        title={attachment.fileName}
        onClick={e => { if (!objectUrl) e.preventDefault(); }}
      >
        {objectUrl ? (
          <img src={objectUrl} alt={attachment.fileName} style={attachmentImageStyle} />
        ) : (
          <span style={attachmentPlaceholderStyle}>{failed ? '⚠️' : loading ? '…' : '🖼️'}</span>
        )}
      </a>
    );
  }

  return (
    <button style={attachmentDocChipStyle} onClick={() => { void handleDownload(); }} title={`Download ${attachment.fileName}`}>
      📄 {attachment.fileName} <span style={{ color: '#6e7681' }}>({formatAttachmentSize(attachment.sizeBytes)})</span>
    </button>
  );
}

/// One addressable transcript entry. Renders the message content and exposes
/// the two affordances that hang off it: commenting and bookmarking to the todo
/// list. The wrapper carries `id="message-<id>"` so todos can deep-link back.
export function MessageBlock({ message, attachments, highlighted, onTodoAdded, onRetry, isUnread, isLatestAgentMessage }: MessageBlockProps) {
  const [showComments, setShowComments] = useState(false);
  const [commentCount, setCommentCount] = useState<number | null>(null);
  const [bookmarking, setBookmarking] = useState(false);
  const [copied, setCopied] = useState(false);

  // Default collapse state: collapse system startup outputs and very long messages by default
  const isSystemOrStartup = message.content.includes('entrypoint:') ||
    message.content.includes('entrypoint-gemini:') ||
    message.content.includes('entrypoint-opencode:') ||
    message.content.includes('entrypoint-codex:');
  const isVeryLong = message.content.length > 2000;

  const [collapsed, setCollapsed] = useState(() => {
    if (isLatestAgentMessage) return false;
    if (message.role === 'agent') return true;
    return isSystemOrStartup || isVeryLong;
  });

  useEffect(() => {
    if (isLatestAgentMessage) {
      setCollapsed(false);
    } else if (message.role === 'agent') {
      setCollapsed(true);
    } else {
      setCollapsed(isSystemOrStartup || isVeryLong);
    }
  }, [isLatestAgentMessage, isSystemOrStartup, isVeryLong, message.role]);

  const handleCopy = async () => {
    const cleanContent = message.content.replace(/\x1b\[[0-9;]*m/g, '');
    try {
      await navigator.clipboard.writeText(cleanContent);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      alert('Failed to copy message content');
    }
  };

  const isUser = message.role === 'user';

  const bookmark = async () => {
    if (bookmarking) return;
    const note = prompt('Add to todo list — note for this item:', defaultNote(message));
    if (note === null) return; // cancelled
    const trimmed = note.trim();
    if (!trimmed) return;
    setBookmarking(true);
    try {
      await api.addTodo(message.sessionId, message.id, trimmed);
      onTodoAdded?.();
    } catch {
      /* surface nothing — best effort */
    } finally {
      setBookmarking(false);
    }
  };

  return (
    <div
      id={`message-${message.id}`}
      style={{
        ...blockStyle,
        background: isUser ? '#1c212a' : '#161b22',
        borderColor: highlighted ? '#1f6feb' : (isUser ? '#388bfd' : '#30363d'),
        boxShadow: highlighted ? '0 0 0 1px #1f6feb' : (isUser ? 'inset 0 0 4px rgba(56, 139, 253, 0.1)' : 'none'),
      }}
    >
      <div style={headerRow}>
        <span style={{ ...roleBadge, ...(isUser ? userBadge : agentBadge) }}>
          {isUser ? 'you' : 'agent'}
        </span>
        <span style={tsStyle} title={formatFullTimestamp(message.createdAt)}>
          {formatTimestamp(message.createdAt)}
        </span>
        {isUnread && (
          <span
            style={{
              fontSize: '10px',
              fontWeight: 600,
              background: 'rgba(56, 139, 253, 0.15)',
              color: '#58a6ff',
              padding: '1px 6px',
              borderRadius: '999px',
              border: '1px solid rgba(56, 139, 253, 0.3)',
              marginLeft: '4px',
              textTransform: 'uppercase',
              letterSpacing: '0.04em',
            }}
          >
            New
          </span>
        )}
        <div style={{ flex: 1 }} />
        <button
          style={actionBtn}
          onClick={() => setCollapsed(v => !v)}
          title={collapsed ? "Expand message" : "Collapse message"}
        >
          {collapsed ? '▶ Expand' : '▼ Collapse'}
        </button>
        <button
          style={actionBtn}
          onClick={() => setShowComments(v => !v)}
          title="Comment on this response"
        >
          💬 {commentCount !== null ? commentCount : 'Comment'}
        </button>
        <button
          style={actionBtn}
          onClick={() => { void bookmark(); }}
          disabled={bookmarking}
          title="Bookmark to the todo list"
        >
          🔖 {bookmarking ? '…' : 'Bookmark'}
        </button>
        <button
          style={actionBtn}
          onClick={() => { void handleCopy(); }}
          title="Copy message content"
        >
          📋 {copied ? 'Copied' : 'Copy'}
        </button>
        {isUser && onRetry && (
          <button
            style={actionBtn}
            onClick={() => onRetry(message.content)}
            title="Retry this message"
          >
            🔄 Retry
          </button>
        )}
      </div>

      {attachments && attachments.length > 0 && (
        <div style={attachmentsRowStyle}>
          {attachments.map(a => (
            <AttachmentChip key={a.id} sessionId={message.sessionId} attachment={a} />
          ))}
        </div>
      )}

      {collapsed ? (
        <div
          onClick={() => setCollapsed(false)}
          style={{
            ...collapsedPreviewStyle,
            cursor: 'pointer',
          }}
          title="Click to expand"
        >
          <span style={{ color: '#8b949e', fontSize: '13px', fontFamily: 'monospace', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
            {getCollapsedPreview(message.content)}
          </span>
          <span style={{ color: '#58a6ff', fontSize: '11px', marginLeft: '12px', flexShrink: 0 }}>
            ({message.content.length} chars, click to expand)
          </span>
        </div>
      ) : (
        isUser ? (
          <div style={userContent}><AnsiContent text={message.content} /></div>
        ) : (
          renderAgentContent(message.content)
        )
      )}

      {showComments && (
        <CommentThread
          messageId={message.id}
          onCountChange={setCommentCount}
        />
      )}
    </div>
  );
}

function findJsonBlocks(text: string): { start: number; end: number; content: string }[] {
  const blocks: { start: number; end: number; content: string }[] = [];
  const n = text.length;
  let i = 0;
  while (i < n) {
    const char = text[i];
    if (char === '{' || char === '[') {
      let braceCount = 0;
      let bracketCount = 0;
      let inString = false;
      let escape = false;
      let j = i;
      while (j < n) {
        const c = text[j];
        if (escape) {
          escape = false;
        } else if (c === '\\') {
          escape = true;
        } else if (c === '"') {
          inString = !inString;
        } else if (!inString) {
          if (c === '{') braceCount++;
          else if (c === '}') {
            braceCount--;
            if (braceCount === 0 && bracketCount === 0) {
              const candidate = text.substring(i, j + 1);
              const cleanCandidate = candidate.replace(/\x1b\[[0-9;]*m/g, '').trim();
              if (cleanCandidate.length > 100 && (cleanCandidate.match(/\n/g) || []).length >= 4) {
                try {
                  JSON.parse(cleanCandidate);
                  blocks.push({ start: i, end: j + 1, content: candidate });
                  i = j;
                  break;
                } catch {
                  // Keep going
                }
              }
            }
          } else if (c === '[') bracketCount++;
          else if (c === ']') {
            bracketCount--;
            if (braceCount === 0 && bracketCount === 0) {
              const candidate = text.substring(i, j + 1);
              const cleanCandidate = candidate.replace(/\x1b\[[0-9;]*m/g, '').trim();
              if (cleanCandidate.length > 100 && (cleanCandidate.match(/\n/g) || []).length >= 4) {
                try {
                  JSON.parse(cleanCandidate);
                  blocks.push({ start: i, end: j + 1, content: candidate });
                  i = j;
                  break;
                } catch {
                  // Keep going
                }
              }
            }
          }
        }
        j++;
      }
    }
    i++;
  }
  return blocks;
}

function findShellBlocks(text: string): { start: number; end: number; command: string; output: string }[] {
  const lines = text.split('\n');
  const blocks: { startIndex: number; endIndex: number; command: string; output: string }[] = [];
  const n = lines.length;
  
  let i = 0;
  while (i < n) {
    const line = lines[i] ?? '';
    const cleanLine = line.replace(/\x1b\[[0-9;]*m/g, '').trim();
    if (cleanLine.startsWith('$ ')) {
      const command = cleanLine.substring(2).trim();
      const outputLines: string[] = [];
      const startIndex = i;
      
      let j = i + 1;
      while (j < n) {
        const nextLine = lines[j] ?? '';
        const cleanNext = nextLine.replace(/\x1b\[[0-9;]*m/g, '').trim();
        
        if (cleanNext.startsWith('$ ')) {
          break;
        }
        
        if (
          cleanNext.startsWith('#') ||
          cleanNext.startsWith('- ') ||
          cleanNext.startsWith('* ') ||
          cleanNext.startsWith('>') ||
          cleanNext.startsWith('```')
        ) {
          break;
        }
        
        outputLines.push(nextLine);
        j++;
      }
      
      if (outputLines.length > 0) {
        blocks.push({
          startIndex,
          endIndex: j,
          command,
          output: outputLines.join('\n'),
        });
        i = j - 1;
      }
    }
    i++;
  }
  
  const charBlocks: { start: number; end: number; command: string; output: string }[] = [];
  let currentPos = 0;
  const linePositions = lines.map(l => {
    const start = currentPos;
    currentPos += l.length + 1;
    return { start, end: start + l.length };
  });
  
  blocks.forEach(b => {
    const startPos = linePositions[b.startIndex];
    const endPos = linePositions[b.endIndex - 1];
    if (startPos !== undefined && endPos !== undefined) {
      charBlocks.push({
        start: startPos.start,
        end: endPos.end,
        command: b.command,
        output: b.output,
      });
    }
  });
  
  return charBlocks;
}

function renderAgentContent(text: string) {
  const jsonBlocks = findJsonBlocks(text);
  const shellBlocks = findShellBlocks(text);

  const allBlocks: ParsedBlock[] = [
    ...jsonBlocks.map(b => ({ type: 'json' as const, start: b.start, end: b.end, content: b.content })),
    ...shellBlocks.map(b => ({ type: 'shell' as const, start: b.start, end: b.end, command: b.command, content: b.output }))
  ];

  allBlocks.sort((a, b) => a.start - b.start);

  const nonOverlappingBlocks: ParsedBlock[] = [];
  let lastEnd = 0;
  for (const block of allBlocks) {
    if (block.start >= lastEnd) {
      nonOverlappingBlocks.push(block);
      lastEnd = block.end;
    }
  }

  if (nonOverlappingBlocks.length === 0) {
    return <AnsiContent text={text} />;
  }

  // Runs of ≥2 consecutive blocks (whitespace-only gaps) collapse into one
  // "Ran N commands · used M tool calls" row — see lib/blockGroups.ts.
  const segments = groupConsecutiveBlocks(nonOverlappingBlocks, text);

  const elements: React.ReactNode[] = [];
  let lastIndex = 0;

  segments.forEach((seg, index) => {
    const segStart = seg.kind === 'single' ? seg.block.start : seg.blocks[0]!.start;
    const segEnd = seg.kind === 'single' ? seg.block.end : seg.blocks[seg.blocks.length - 1]!.end;
    if (segStart > lastIndex) {
      const textSegment = text.substring(lastIndex, segStart);
      if (textSegment.trim() !== '') {
        elements.push(<AnsiContent key={`text-${index}`} text={textSegment} />);
      }
    }
    if (seg.kind === 'group') {
      elements.push(<ToolRunGroup key={`group-${index}`} blocks={seg.blocks} />);
    } else if (seg.block.type === 'json') {
      elements.push(
        <CollapsibleJsonBlock key={`json-${index}`} rawContent={seg.block.content} />
      );
    } else {
      elements.push(
        <CollapsibleShellBlock key={`shell-${index}`} command={seg.block.command ?? ''} output={seg.block.content} />
      );
    }
    lastIndex = segEnd;
  });

  if (lastIndex < text.length) {
    const segment = text.substring(lastIndex);
    if (segment.trim() !== '') {
      elements.push(<AnsiContent key="text-end" text={segment} />);
    }
  }

  return <>{elements}</>;
}

function defaultNote(m: Message): string {
  const firstLine = m.content.split('\n')[0] ?? '';
  const clean = firstLine.replace(/\x1b\[[0-9;]*m/g, '').trim();
  return clean.slice(0, 80);
}

function getCollapsedPreview(text: string): string {
  const clean = text.replace(/\x1b\[[0-9;]*m/g, '').trim();
  const firstLine = clean.split('\n')[0] ?? '';
  if (firstLine.length > 120) {
    return firstLine.slice(0, 120) + '...';
  }
  return firstLine || '...';
}

const blockStyle: React.CSSProperties = {
  background: '#161b22',
  border: '1px solid #30363d',
  borderRadius: '8px',
  padding: '12px 14px',
  scrollMarginTop: '70px',
  transition: 'border-color 0.2s, box-shadow 0.2s',
};

const headerRow: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: '8px',
  marginBottom: '8px',
};

const roleBadge: React.CSSProperties = {
  fontSize: '11px',
  fontWeight: 600,
  padding: '2px 8px',
  borderRadius: '999px',
  textTransform: 'uppercase',
  letterSpacing: '0.03em',
};

const userBadge: React.CSSProperties = {
  background: 'rgba(56, 139, 253, 0.15)',
  color: '#79c0ff',
};

const agentBadge: React.CSSProperties = {
  background: 'rgba(63, 185, 80, 0.15)',
  color: '#56d364',
};

const tsStyle: React.CSSProperties = {
  fontSize: '11px',
  color: '#6e7681',
};

const actionBtn: React.CSSProperties = {
  background: 'transparent',
  border: '1px solid #30363d',
  borderRadius: '6px',
  color: '#8b949e',
  fontSize: '12px',
  padding: '3px 8px',
  cursor: 'pointer',
  transition: 'background 0.2s, border-color 0.2s, color 0.2s',
};

const userContent: React.CSSProperties = {
  fontSize: '14px',
  color: '#c9d1d9',
  whiteSpace: 'pre-wrap',
  wordBreak: 'break-word',
};

const attachmentsRowStyle: React.CSSProperties = {
  display: 'flex',
  flexWrap: 'wrap',
  gap: '6px',
  marginBottom: '8px',
};

const attachmentImageLinkStyle: React.CSSProperties = {
  display: 'block',
  width: '64px',
  height: '64px',
  borderRadius: '6px',
  overflow: 'hidden',
  border: '1px solid #30363d',
  background: '#0d1117',
};

const attachmentImageStyle: React.CSSProperties = {
  width: '100%',
  height: '100%',
  objectFit: 'cover',
  display: 'block',
};

const attachmentPlaceholderStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'center',
  width: '100%',
  height: '100%',
  fontSize: '18px',
};

const attachmentDocChipStyle: React.CSSProperties = {
  display: 'inline-flex',
  alignItems: 'center',
  gap: '4px',
  background: '#161b22',
  border: '1px solid #30363d',
  borderRadius: '6px',
  padding: '4px 8px',
  color: '#c9d1d9',
  fontSize: '12px',
  cursor: 'pointer',
};

const collapsedPreviewStyle: React.CSSProperties = {
  background: '#0d1117',
  border: '1px solid #21262d',
  borderRadius: '6px',
  padding: '8px 12px',
  marginTop: '8px',
  display: 'flex',
  justifyContent: 'space-between',
  alignItems: 'center',
  transition: 'background 0.2s, border-color 0.2s',
};
