import { AnsiUp } from 'ansi_up';

const au = new AnsiUp();
au.use_classes = false;

interface AnsiContentProps {
  text: string;
}

/// Renders a string containing ANSI escape codes as coloured HTML. Shared by
/// the live Terminal and the persisted per-message transcript blocks.
export function AnsiContent({ text }: AnsiContentProps) {
  let html = au.ansi_to_html(text);

  // Apply rich color-coding highlighting to tool names, actions, and PR terms
  const highlights = [
    {
      regex: /\b(run_command)\b/g,
      replace: '<span style="background: rgba(210, 153, 34, 0.15); color: #d29922; padding: 1px 5px; border-radius: 4px; font-weight: 600; border: 1px solid rgba(210, 153, 34, 0.3); font-family: monospace;">$1</span>'
    },
    {
      regex: /\b(call_mcp_tool)\b/g,
      replace: '<span style="background: rgba(187, 128, 255, 0.15); color: #bc8cff; padding: 1px 5px; border-radius: 4px; font-weight: 600; border: 1px solid rgba(187, 128, 255, 0.3); font-family: monospace;">$1</span>'
    },
    {
      regex: /\b(write_to_file|replace_file_content|multi_replace_file_content)\b/g,
      replace: '<span style="background: rgba(63, 185, 80, 0.15); color: #56d364; padding: 1px 5px; border-radius: 4px; font-weight: 600; border: 1px solid rgba(63, 185, 80, 0.3); font-family: monospace;">$1</span>'
    },
    {
      regex: /\b(ask_question|ask_permission)\b/g,
      replace: '<span style="background: rgba(248, 81, 73, 0.15); color: #f85149; padding: 1px 5px; border-radius: 4px; font-weight: 600; border: 1px solid rgba(248, 81, 73, 0.3); font-family: monospace;">$1</span>'
    },
    {
      regex: /\b(search_web|view_file|list_dir)\b/g,
      replace: '<span style="background: rgba(56, 139, 253, 0.15); color: #58a6ff; padding: 1px 5px; border-radius: 4px; font-weight: 600; border: 1px solid rgba(56, 139, 253, 0.3); font-family: monospace;">$1</span>'
    },
    {
      regex: /\b(create_pull_request|pull request|PR)\b/gi,
      replace: '<span style="background: rgba(46, 160, 67, 0.15); color: #3fb950; padding: 1px 5px; border-radius: 4px; font-weight: 600; border: 1px solid rgba(46, 160, 67, 0.3);">$&</span>'
    }
  ];

  for (const hl of highlights) {
    html = html.replace(hl.regex, hl.replace);
  }

  return (
    <div
      style={contentStyle}
      dangerouslySetInnerHTML={{ __html: html }}
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
