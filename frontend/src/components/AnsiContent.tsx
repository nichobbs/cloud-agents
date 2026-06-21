import { AnsiUp } from 'ansi_up';

const au = new AnsiUp();
au.use_classes = false;

interface AnsiContentProps {
  text: string;
}

/// Renders a string containing ANSI escape codes as coloured HTML. Shared by
/// the live Terminal and the persisted per-message transcript blocks.
export function AnsiContent({ text }: AnsiContentProps) {
  return (
    <div
      style={contentStyle}
      dangerouslySetInnerHTML={{ __html: au.ansi_to_html(text) }}
    />
  );
}

const contentStyle: React.CSSProperties = {
  whiteSpace: 'pre-wrap',
  wordBreak: 'break-word',
  fontFamily: '"Fira Code", "Cascadia Code", Consolas, "Courier New", monospace',
  fontSize: '13px',
  lineHeight: '1.6',
  color: '#c9d1d9',
};
