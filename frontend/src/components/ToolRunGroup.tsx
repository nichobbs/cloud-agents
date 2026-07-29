import { useState } from 'react';
import { groupLabel, type ParsedBlock } from '../lib/blockGroups';
import { CollapsibleJsonBlock } from './CollapsibleJsonBlock';
import { CollapsibleShellBlock } from './CollapsibleShellBlock';

interface ToolRunGroupProps {
  blocks: ParsedBlock[];
}

/// A run of consecutive shell/tool blocks collapsed into one summary row
/// ("Ran 4 commands · used 2 tool calls"). Expanding reveals the individual
/// collapsible blocks, so drill-down is two clicks: group, then block.
export function ToolRunGroup({ blocks }: ToolRunGroupProps) {
  const [expanded, setExpanded] = useState(false);

  const firstShell = blocks.find(b => b.type === 'shell');
  const preview = firstShell?.command ? `$ ${firstShell.command.replace(/\x1b\[[0-9;]*m/g, '')}` : '';

  return (
    <div style={containerStyle}>
      <div
        style={headerStyle}
        onClick={() => setExpanded(v => !v)}
        title={expanded ? 'Collapse this run of tool calls' : 'Expand to see each command/tool call'}
      >
        <span style={iconStyle}>{expanded ? '▾' : '▸'}</span>
        <span style={labelStyle}>{groupLabel(blocks)}</span>
        {!expanded && preview && <span style={previewStyle}>{preview}{blocks.length > 1 ? ' …' : ''}</span>}
      </div>
      {expanded && (
        <div style={bodyStyle}>
          {blocks.map((b, i) =>
            b.type === 'shell' ? (
              <CollapsibleShellBlock key={i} command={b.command ?? ''} output={b.content} />
            ) : (
              <CollapsibleJsonBlock key={i} rawContent={b.content} />
            ),
          )}
        </div>
      )}
    </div>
  );
}

const containerStyle: React.CSSProperties = {
  margin: '10px 0',
  backgroundColor: '#0d1117',
  border: '1px solid #21262d',
  borderRadius: '6px',
  overflow: 'hidden',
};

const headerStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: '8px',
  padding: '6px 12px',
  cursor: 'pointer',
  userSelect: 'none',
  backgroundColor: '#161b22',
};

const iconStyle: React.CSSProperties = {
  color: '#8b949e',
  fontSize: '11px',
  flexShrink: 0,
};

const labelStyle: React.CSSProperties = {
  fontSize: '12px',
  fontWeight: 600,
  color: '#8b949e',
  whiteSpace: 'nowrap',
  flexShrink: 0,
};

const previewStyle: React.CSSProperties = {
  fontSize: '11px',
  color: '#6e7681',
  fontFamily: '"Fira Code", "Cascadia Code", Consolas, monospace',
  overflow: 'hidden',
  textOverflow: 'ellipsis',
  whiteSpace: 'nowrap',
  minWidth: 0,
};

const bodyStyle: React.CSSProperties = {
  padding: '4px 10px',
  borderTop: '1px solid #21262d',
};
