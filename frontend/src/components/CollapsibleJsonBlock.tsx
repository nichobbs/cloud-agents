import { useState } from 'react';

interface CollapsibleJsonBlockProps {
  rawContent: string;
}

export function CollapsibleJsonBlock({ rawContent }: CollapsibleJsonBlockProps) {
  const [collapsed, setCollapsed] = useState(true);
  const [copied, setCopied] = useState(false);

  // Strip ANSI color codes from JSON to parse and format it cleanly
  const cleanJson = rawContent.replace(/\x1b\[[0-9;]*m/g, '').trim();

  let formattedJson = cleanJson;
  let linesCount = 0;
  let sizeBytes = cleanJson.length;

  try {
    const parsed = JSON.parse(cleanJson);
    formattedJson = JSON.stringify(parsed, null, 2);
    linesCount = formattedJson.split('\n').length;
  } catch {
    linesCount = cleanJson.split('\n').length;
  }

  const handleCopy = async () => {
    try {
      await navigator.clipboard.writeText(cleanJson);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      alert('Failed to copy JSON block');
    }
  };

  const formattedSize = sizeBytes > 1024 
    ? `${(sizeBytes / 1024).toFixed(1)} KB` 
    : `${sizeBytes} B`;

  return (
    <div style={containerStyle}>
      <div style={headerStyle}>
        <div style={titleAreaStyle}>
          <span style={iconStyle}>📦</span>
          <span style={titleStyle}>JSON Payload</span>
          <span style={metaStyle}>({linesCount} lines • {formattedSize})</span>
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
        <pre style={preStyle}>
          <code style={codeStyle}>{formattedJson}</code>
        </pre>
      )}
    </div>
  );
}

const containerStyle: React.CSSProperties = {
  margin: '12px 0',
  backgroundColor: '#0d1117',
  border: '1px solid #30363d',
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
  gap: '6px',
};

const iconStyle: React.CSSProperties = {
  fontSize: '14px',
};

const titleStyle: React.CSSProperties = {
  fontSize: '12px',
  fontWeight: '600',
  color: '#c9d1d9',
  fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif',
};

const metaStyle: React.CSSProperties = {
  fontSize: '11px',
  color: '#8b949e',
  fontFamily: 'monospace',
};

const actionsStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: '8px',
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

const preStyle: React.CSSProperties = {
  margin: 0,
  padding: '12px',
  borderTop: '1px solid #30363d',
  backgroundColor: '#0d1117',
  overflowX: 'auto',
  maxHeight: '400px',
};

const codeStyle: React.CSSProperties = {
  fontFamily: '"Fira Code", "Cascadia Code", Consolas, "Courier New", monospace',
  fontSize: '12px',
  color: '#79c0ff',
  lineHeight: '1.5',
};
