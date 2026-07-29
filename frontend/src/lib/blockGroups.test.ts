import { describe, expect, it } from 'vitest';
import { groupConsecutiveBlocks, groupLabel, type ParsedBlock } from './blockGroups';

function shell(start: number, end: number, command = 'ls'): ParsedBlock {
  return { type: 'shell', start, end, command, content: 'out' };
}

function json(start: number, end: number): ParsedBlock {
  return { type: 'json', start, end, content: '{}' };
}

describe('groupConsecutiveBlocks', () => {
  it('groups blocks separated only by whitespace', () => {
    //           0....5....10...15...20
    const text = 'AAAAA\n\nBBBBB\n\nCCCCC';
    const blocks = [shell(0, 5), shell(7, 12), shell(14, 19)];
    const segments = groupConsecutiveBlocks(blocks, text);
    expect(segments).toHaveLength(1);
    expect(segments[0]!.kind).toBe('group');
    if (segments[0]!.kind === 'group') expect(segments[0]!.blocks).toHaveLength(3);
  });

  it('keeps blocks apart when prose sits between them', () => {
    const text = 'AAAAA\nNow I will check the tests\nBBBBB';
    const blocks = [shell(0, 5), shell(33, 38)];
    const segments = groupConsecutiveBlocks(blocks, text);
    expect(segments).toHaveLength(2);
    expect(segments.every(s => s.kind === 'single')).toBe(true);
  });

  it('leaves a lone block as a single', () => {
    const segments = groupConsecutiveBlocks([shell(0, 5)], 'AAAAA');
    expect(segments).toEqual([{ kind: 'single', block: shell(0, 5) }]);
  });

  it('treats ANSI-only gaps as whitespace', () => {
    const text = 'AAAAA\x1b[32m\n\x1b[0mBBBB';
    const blocks = [shell(0, 5), shell(15, 19)];
    const segments = groupConsecutiveBlocks(blocks, text);
    expect(segments).toHaveLength(1);
    expect(segments[0]!.kind).toBe('group');
  });

  it('mixes groups and singles across one message', () => {
    const text = 'AAAAA\n\nBBBBB\nsome prose here\nCCCCC';
    const blocks = [shell(0, 5), shell(7, 12), shell(29, 34)];
    const segments = groupConsecutiveBlocks(blocks, text);
    expect(segments).toHaveLength(2);
    expect(segments[0]!.kind).toBe('group');
    expect(segments[1]!.kind).toBe('single');
  });
});

describe('groupLabel', () => {
  it('describes commands and tools together', () => {
    expect(groupLabel([shell(0, 1), shell(2, 3), json(4, 5)])).toBe('Ran 2 commands · used 1 tool call');
  });

  it('handles commands only, with singular/plural', () => {
    expect(groupLabel([shell(0, 1)])).toBe('Ran 1 command');
    expect(groupLabel([shell(0, 1), shell(2, 3)])).toBe('Ran 2 commands');
  });

  it('handles tools only', () => {
    expect(groupLabel([json(0, 1), json(2, 3)])).toBe('Used 2 tool calls');
  });
});
