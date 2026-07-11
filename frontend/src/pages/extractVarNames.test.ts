import { describe, it, expect } from 'vitest';
import { extractVarNames } from './SessionDetail';

describe('extractVarNames', () => {
  it('returns [] when there are no placeholders', () => {
    expect(extractVarNames('just a plain prompt')).toEqual([]);
  });

  it('extracts a single placeholder', () => {
    expect(extractVarNames('Hello {{name}}!')).toEqual(['name']);
  });

  it('trims whitespace inside the braces (matches the server-side key trim)', () => {
    expect(extractVarNames('Hi {{ name }}!')).toEqual(['name']);
  });

  it('preserves first-seen order and de-duplicates repeats', () => {
    expect(extractVarNames('{{a}} {{b}} then {{a}} again')).toEqual(['a', 'b']);
  });

  it('ignores an unterminated placeholder', () => {
    expect(extractVarNames('start {{oops no close')).toEqual([]);
  });

  it('skips an empty / whitespace-only placeholder', () => {
    expect(extractVarNames('x {{}} y {{   }} z')).toEqual([]);
  });
});
