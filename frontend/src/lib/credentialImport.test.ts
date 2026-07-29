import { describe, it, expect } from 'vitest';
import { parseCredentialInput } from './credentialImport';

describe('parseCredentialInput', () => {
  it('returns [] for empty / whitespace input', () => {
    expect(parseCredentialInput('')).toEqual([]);
    expect(parseCredentialInput('   \n ')).toEqual([]);
  });

  it('recognises raw provider keys by prefix', () => {
    expect(parseCredentialInput('sk-ant-api03-abc')[0]?.name).toBe('ANTHROPIC_API_KEY');
    expect(parseCredentialInput('sk-proj-abc123')[0]?.name).toBe('OPENAI_API_KEY');
    expect(parseCredentialInput('AIzaSyExample')[0]?.name).toBe('GEMINI_API_KEY');
    expect(parseCredentialInput('ghp_abc123')[0]?.name).toBe('GITHUB_TOKEN');
    expect(parseCredentialInput('github_pat_abc')[0]?.name).toBe('GITHUB_TOKEN');
  });

  it('recognises a Claude Code OAuth token ahead of the generic anthropic prefix', () => {
    expect(parseCredentialInput('sk-ant-oat01-xyz')[0]?.name).toBe('CLAUDE_CODE_OAUTH_TOKEN');
  });

  it('rejects unknown raw strings and multi-word text', () => {
    expect(parseCredentialInput('hello world')).toEqual([]);
    expect(parseCredentialInput('not-a-key')).toEqual([]);
  });

  it('parses ~/.claude/.credentials.json', () => {
    const file = JSON.stringify({ claudeAiOauth: { accessToken: 'sk-ant-oat01-tok', refreshToken: 'r' } });
    const out = parseCredentialInput(file);
    expect(out).toEqual([
      { name: 'CLAUDE_CODE_OAUTH_TOKEN', value: 'sk-ant-oat01-tok', source: '~/.claude/.credentials.json' },
    ]);
  });

  it('parses Codex auth.json', () => {
    const out = parseCredentialInput(JSON.stringify({ OPENAI_API_KEY: 'sk-live' }));
    expect(out).toEqual([{ name: 'OPENAI_API_KEY', value: 'sk-live', source: '~/.codex/auth.json' }]);
  });

  it('parses OpenCode auth.json with several providers', () => {
    const file = JSON.stringify({
      anthropic: { type: 'api', key: 'sk-ant-a' },
      openai: { type: 'api', key: 'sk-o' },
      google: { type: 'api', key: 'AIza-g' },
      wellknown: { type: 'wellknown', key: 'ignored' },
    });
    const names = parseCredentialInput(file).map(c => c.name).sort();
    expect(names).toEqual(['ANTHROPIC_API_KEY', 'GEMINI_API_KEY', 'OPENAI_API_KEY']);
  });

  it('ignores non-api OpenCode entries and malformed JSON', () => {
    expect(parseCredentialInput('{"anthropic":{"type":"oauth"}}')).toEqual([]);
    expect(parseCredentialInput('{broken json')).toEqual([]);
  });
});
