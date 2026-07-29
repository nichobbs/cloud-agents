import { useState, useEffect } from 'react';
import { api } from '../lib/api';
import { formatFullTimestamp, formatTimestamp } from '../lib/time';
import type { Message } from '../types';
import { AnsiContent } from './AnsiContent';
import { CommentThread } from './CommentThread';
import { CollapsibleJsonBlock } from './CollapsibleJsonBlock';
import { CollapsibleShellBlock } from './CollapsibleShellBlock';

interface MessageBlockProps {
  message: Message;
  highlighted?: boolean;
  onTodoAdded?: () => void;
  onRetry?: (content: string) => void;
  isUnread?: boolean;
  isLatestAgentMessage?: boolean;
}

/// One addressable transcript entry. Renders the message content and exposes
/// the two affordances that hang off it: commenting and bookmarking to the todo
/// list. The wrapper carries `id="message-<id>"` so todos can deep-link back.
export function MessageBlock({ message, highlighted, onTodoAdded, onRetry, isUnread, isLatestAgentMessage }: MessageBlockProps) {
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
    return isSystemOrStartup || isVeryLong;
  });

  useEffect(() => {
    if (isLatestAgentMessage) {
      setCollapsed(false);
    } else {
      setCollapsed(isSystemOrStartup || isVeryLong);
    }
  }, [isLatestAgentMessage, isSystemOrStartup, isVeryLong]);

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
          <div style={userContent}>{message.content}</div>
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

interface ParsedTextBlock {
  type: 'json' | 'shell';
  start: number;
  end: number;
  command?: string;
  content: string;
}

function renderAgentContent(text: string) {
  const jsonBlocks = findJsonBlocks(text);
  const shellBlocks = findShellBlocks(text);

  const allBlocks: ParsedTextBlock[] = [
    ...jsonBlocks.map(b => ({ type: 'json' as const, start: b.start, end: b.end, content: b.content })),
    ...shellBlocks.map(b => ({ type: 'shell' as const, start: b.start, end: b.end, command: b.command, content: b.output }))
  ];

  allBlocks.sort((a, b) => a.start - b.start);

  const nonOverlappingBlocks: ParsedTextBlock[] = [];
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

  const elements: React.ReactNode[] = [];
  let lastIndex = 0;

  nonOverlappingBlocks.forEach((block, index) => {
    if (block.start > lastIndex) {
      const segment = text.substring(lastIndex, block.start);
      if (segment.trim() !== '') {
        elements.push(<AnsiContent key={`text-${index}`} text={segment} />);
      }
    }
    if (block.type === 'json') {
      elements.push(
        <CollapsibleJsonBlock key={`json-${index}`} rawContent={block.content} />
      );
    } else if (block.type === 'shell') {
      elements.push(
        <CollapsibleShellBlock key={`shell-${index}`} command={block.command ?? ''} output={block.content} />
      );
    }
    lastIndex = block.end;
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
