/// Smart credential import: turn pasted keys or harness credential files into
/// vault entries under their canonical env-var names.
///
/// Recognises:
///  - raw API keys by prefix (sk-ant-…, sk-…, AIza…, ghp_/github_pat_…)
///  - Claude Code OAuth tokens (sk-ant-oat…) and ~/.claude/.credentials.json
///  - Codex CLI ~/.codex/auth.json
///  - OpenCode ~/.local/share/opencode/auth.json (per-provider api keys)
/// Everything is best-effort and pure — callers decide what to upload.

export interface ImportedCredential {
  /** Canonical env-var name, e.g. ANTHROPIC_API_KEY. */
  name: string;
  value: string;
  /** Human-readable description of how it was recognised. */
  source: string;
}

function fromRawKey(key: string): ImportedCredential | null {
  const k = key.trim();
  if (!k || /\s/.test(k)) return null;
  if (k.startsWith('sk-ant-oat')) {
    return { name: 'CLAUDE_CODE_OAUTH_TOKEN', value: k, source: 'Claude Code OAuth token' };
  }
  if (k.startsWith('sk-ant-')) {
    return { name: 'ANTHROPIC_API_KEY', value: k, source: 'Anthropic API key' };
  }
  if (k.startsWith('sk-')) {
    return { name: 'OPENAI_API_KEY', value: k, source: 'OpenAI API key' };
  }
  if (k.startsWith('AIza')) {
    return { name: 'GEMINI_API_KEY', value: k, source: 'Google API key' };
  }
  if (/^(ghp_|github_pat_|gho_|ghs_)/.test(k)) {
    return { name: 'GITHUB_TOKEN', value: k, source: 'GitHub token' };
  }
  return null;
}

interface ClaudeCredentialsFile {
  claudeAiOauth?: { accessToken?: string };
}

interface CodexAuthFile {
  OPENAI_API_KEY?: string;
  openai_api_key?: string;
}

/** OpenCode auth.json: { "<provider>": { "type": "api", "key": "…" }, … } */
type OpenCodeAuthFile = Record<string, { type?: string; key?: string } | undefined>;

const OPENCODE_PROVIDER_ENV: Record<string, string> = {
  anthropic: 'ANTHROPIC_API_KEY',
  openai: 'OPENAI_API_KEY',
  google: 'GEMINI_API_KEY',
  gemini: 'GEMINI_API_KEY',
  github: 'GITHUB_TOKEN',
};

function fromJson(text: string): ImportedCredential[] {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return [];
  }
  if (typeof parsed !== 'object' || parsed === null) return [];
  const out: ImportedCredential[] = [];

  const claude = parsed as ClaudeCredentialsFile;
  const oauthToken = claude.claudeAiOauth?.accessToken;
  if (typeof oauthToken === 'string' && oauthToken) {
    out.push({
      name: 'CLAUDE_CODE_OAUTH_TOKEN',
      value: oauthToken,
      source: '~/.claude/.credentials.json',
    });
  }

  const codex = parsed as CodexAuthFile;
  const openAiKey = codex.OPENAI_API_KEY ?? codex.openai_api_key;
  if (typeof openAiKey === 'string' && openAiKey) {
    out.push({ name: 'OPENAI_API_KEY', value: openAiKey, source: '~/.codex/auth.json' });
  }

  const opencode = parsed as OpenCodeAuthFile;
  for (const [provider, entry] of Object.entries(opencode)) {
    const envName = OPENCODE_PROVIDER_ENV[provider];
    if (!envName || !entry || typeof entry !== 'object') continue;
    if (entry.type === 'api' && typeof entry.key === 'string' && entry.key) {
      if (!out.some(c => c.name === envName)) {
        out.push({ name: envName, value: entry.key, source: `OpenCode auth.json (${provider})` });
      }
    }
  }

  return out;
}

/** Parse pasted text into recognised credentials (possibly several from one
 *  credentials file). Empty array = nothing recognised. */
export function parseCredentialInput(text: string): ImportedCredential[] {
  const trimmed = text.trim();
  if (!trimmed) return [];
  if (trimmed.startsWith('{')) return fromJson(trimmed);
  const single = fromRawKey(trimmed);
  return single ? [single] : [];
}
