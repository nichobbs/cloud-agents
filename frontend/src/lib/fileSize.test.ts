import { describe, it, expect } from 'vitest';
import { formatFileSize } from './fileSize';

describe('formatFileSize', () => {
  it('formats bytes below 1 KB as whole bytes', () => {
    expect(formatFileSize(0)).toBe('0 B');
    expect(formatFileSize(512)).toBe('512 B');
    expect(formatFileSize(1023)).toBe('1023 B');
  });

  it('formats KB with one decimal place', () => {
    expect(formatFileSize(1024)).toBe('1.0 KB');
    expect(formatFileSize(2048)).toBe('2.0 KB');
    expect(formatFileSize(1536)).toBe('1.5 KB');
  });

  it('formats MB with one decimal place', () => {
    expect(formatFileSize(1024 * 1024)).toBe('1.0 MB');
    expect(formatFileSize(20 * 1024 * 1024)).toBe('20.0 MB');
  });

  it('returns empty string for non-finite or negative input', () => {
    expect(formatFileSize(NaN)).toBe('');
    expect(formatFileSize(-1)).toBe('');
    expect(formatFileSize(Infinity)).toBe('');
  });
});
