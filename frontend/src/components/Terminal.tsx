import { useEffect, useRef } from 'react';
import { AnsiUp } from 'ansi_up';

const au = new AnsiUp();
au.use_classes = false;

interface TerminalProps {
  output: string;
  isStreaming?: boolean;
}

export function Terminal({ output, isStreaming = false }: TerminalProps) {
  const endRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    endRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [output]);

  const html = au.ansi_to_html(output);

  return (
    <div style={containerStyle}>
      <style>{cursorStyle}</style>
      <div
        style={{ whiteSpace: 'pre-wrap', wordBreak: 'break-word' }}
        dangerouslySetInnerHTML={{ __html: html }}
      />
      {isStreaming && <span className="ca-cursor">▊</span>}
      {!isStreaming && !output && (
        <span style={{ color: '#484f58' }}>No output yet — send a message below.</span>
      )}
      <div ref={endRef} />
    </div>
  );
}

const containerStyle: React.CSSProperties = {
  background: '#0d1117',
  color: '#c9d1d9',
  fontFamily: '"Fira Code", "Cascadia Code", Consolas, "Courier New", monospace',
  fontSize: '13px',
  lineHeight: '1.6',
  padding: '16px',
  borderRadius: '6px',
  border: '1px solid #30363d',
  overflowY: 'auto',
  flex: 1,
  minHeight: '360px',
};

const cursorStyle = `
  @keyframes ca-blink { 0%, 100% { opacity: 1; } 50% { opacity: 0; } }
  .ca-cursor { animation: ca-blink 1s step-end infinite; color: #58a6ff; }
`;
