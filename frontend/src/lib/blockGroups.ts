/// Grouping of consecutive parsed transcript blocks (shell commands, JSON
/// tool payloads) into a single collapsed "Ran N commands · used M tools"
/// row. Pure so MessageBlock's rendering and the tests share one
/// implementation.

export interface ParsedBlock {
  type: 'json' | 'shell';
  start: number;
  end: number;
  command?: string;
  content: string;
}

export type RenderSegment =
  | { kind: 'single'; block: ParsedBlock }
  | { kind: 'group'; blocks: ParsedBlock[] };

/**
 * Collapse runs of ≥2 consecutive blocks separated only by whitespace into
 * one group segment. Blocks with real prose between them stay separate —
 * the prose is context the reader should see in place.
 */
export function groupConsecutiveBlocks(blocks: ParsedBlock[], text: string): RenderSegment[] {
  const segments: RenderSegment[] = [];
  let run: ParsedBlock[] = [];

  const flush = () => {
    if (run.length >= 2) {
      segments.push({ kind: 'group', blocks: run });
    } else if (run.length === 1) {
      segments.push({ kind: 'single', block: run[0]! });
    }
    run = [];
  };

  for (const block of blocks) {
    if (run.length === 0) {
      run.push(block);
      continue;
    }
    const prev = run[run.length - 1]!;
    const gap = text.substring(prev.end, block.start);
    // ANSI codes in the gap are styling, not prose.
    if (gap.replace(/\x1b\[[0-9;]*m/g, '').trim() === '') {
      run.push(block);
    } else {
      flush();
      run.push(block);
    }
  }
  flush();
  return segments;
}

/** "Ran 3 commands · used 2 tools" — omits whichever count is zero. */
export function groupLabel(blocks: ParsedBlock[]): string {
  const commands = blocks.filter(b => b.type === 'shell').length;
  const tools = blocks.filter(b => b.type === 'json').length;
  const parts: string[] = [];
  if (commands > 0) parts.push(`Ran ${commands} command${commands === 1 ? '' : 's'}`);
  if (tools > 0) parts.push(`${commands > 0 ? 'used' : 'Used'} ${tools} tool call${tools === 1 ? '' : 's'}`);
  return parts.join(' · ');
}
