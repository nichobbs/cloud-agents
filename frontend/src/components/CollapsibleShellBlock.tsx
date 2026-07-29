import { useState } from 'react';
import { AnsiContent } from './AnsiContent';

interface CollapsibleShellBlockProps {
  command: string;
  output: string;
}

export function CollapsibleShellBlock({ command, output }: CollapsibleShellBlockProps) {
  const [collapsed, setCollapsed] = useState(true);
  const [copied, setCopied] = useState(false);

  const cleanCommand = command.replace(/\x1b\[[0-9;]*m/g, '').trim();
  const outputLineCount = output.split('\n').filter(line => line.trim() !== '').length;

  const handleCopy = async () => {
    try {
      await navigator.clipboard.writeText(`$ ${cleanCommand}\n${output.replace(/\x1b\[[0-9;]*m/g, '')}`);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      alert('Failed to copy command block');
    }
  };

  return (
    <div style={containerStyle}>
      <div style={headerStyle}>
        <div style={titleAreaStyle}>
          <span style={iconStyle}>🐚</span>
          <span style={commandStyle}>$ {cleanCommand}</span>
          <span style={metaStyle}>({outputLineCount} lines output)</span>
        </div>
        <div style={actionsStyle}>
          <button 
            onClick={handleCopy} 
            style={copied ? copyActiveButtonStyle : copyButtonStyle}
          >
            {copied ? '✓ Copied' : '📋 Copy'}
          </button>
          <button 
            onClick={() => setCollapsed(!collapsed)} 
            style={toggleButtonStyle}
          >
            {collapsed ? '➕ Expand' : '➖ Collapse'}
          </button>
        </div>
      </div>
      
      {!collapsed && (
        <div style={outputAreaStyle}>
          <AnsiContent text={output} />
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
  justifyContent: 'space-between',
  alignItems: 'center',
  backgroundColor: '#161b22',
  padding: '6px 12px',
  userSelect: 'none',
};

const titleAreaStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: '8px',
  flex: 1,
  minWidth: 0,
};

const iconStyle: React.CSSProperties = {
  fontSize: '13px',
  flexShrink: 0,
};

const commandStyle: React.CSSProperties = {
  fontSize: '12px',
  fontWeight: '600',
  color: '#e6edf3',
  fontFamily: '"Fira Code", "Cascadia Code", Consolas, monospace',
  overflow: 'hidden',
  textOverflow: 'ellipsis',
  whiteSpace: 'nowrap',
};

const metaStyle: React.CSSProperties = {
  fontSize: '11px',
  color: '#8b949e',
  fontFamily: 'monospace',
  flexShrink: 0,
};

const actionsStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: '8px',
  marginLeft: '12px',
};

const buttonBaseStyle: React.CSSProperties = {
  border: '1px solid #30363d',
  borderRadius: '4px',
  padding: '3px 8px',
  fontSize: '11px',
  fontWeight: '500',
  cursor: 'pointer',
  transition: 'all 0.1s ease',
  outline: 'none',
  fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif',
};

const copyButtonStyle: React.CSSProperties = {
  ...buttonBaseStyle,
  backgroundColor: '#21262d',
  color: '#c9d1d9',
};

const copyActiveButtonStyle: React.CSSProperties = {
  ...buttonBaseStyle,
  backgroundColor: 'rgba(56, 139, 253, 0.15)',
  color: '#58a6ff',
  borderColor: 'rgba(56, 139, 253, 0.4)',
};

const toggleButtonStyle: React.CSSProperties = {
  ...buttonBaseStyle,
  backgroundColor: '#30363d',
  color: '#f0f6fc',
  borderColor: '#8b949e',
};

const outputAreaStyle: React.CSSProperties = {
  padding: '12px',
  borderTop: '1px solid #21262d',
  backgroundColor: '#0a0e14',
  maxHeight: '400px',
  overflowY: 'auto',
};
