/// Locally-held provider connections.
///
/// The server-side credential vault is write-only by design — the browser can
/// never read a stored secret back — so features that need to *call* a
/// provider API from the browser (live model discovery, the GitHub repo/PR/CI
/// panels) keep their own copy of the key in localStorage on this device.
/// The Integrations page writes both stores at once: the vault copy is what
/// runner containers receive; the local copy is what the UI itself uses.

export type ProviderId = 'anthropic' | 'openai' | 'google' | 'github';

export interface ProviderMeta {
  label: string;
  /** Canonical env-var name the key is uploaded to the vault under. */
  credentialName: string;
  placeholder: string;
  /** What the key unlocks in the UI (shown on the Integrations page). */
  unlocks: string;
}

export const PROVIDERS: Record<ProviderId, ProviderMeta> = {
  anthropic: {
    label: 'Anthropic',
    credentialName: 'ANTHROPIC_API_KEY',
    placeholder: 'sk-ant-…',
    unlocks: 'Live Claude model discovery; Claude/OpenCode runs.',
  },
  openai: {
    label: 'OpenAI',
    credentialName: 'OPENAI_API_KEY',
    placeholder: 'sk-…',
    unlocks: 'Live GPT/o-series model discovery; Codex/OpenCode runs.',
  },
  google: {
    label: 'Google (Gemini)',
    credentialName: 'GEMINI_API_KEY',
    placeholder: 'AIza…',
    unlocks: 'Live Gemini model discovery; Gemini/OpenCode runs.',
  },
  github: {
    label: 'GitHub',
    credentialName: 'GITHUB_TOKEN',
    placeholder: 'ghp_… or github_pat_…',
    unlocks: 'Repo browser, PR & CI status panels; agent GitHub MCP access.',
  },
};

const STORAGE_KEY = 'cloud_agents_connections';

type ConnectionMap = Partial<Record<ProviderId, string>>;

function load(): ConnectionMap {
  try {
    return JSON.parse(localStorage.getItem(STORAGE_KEY) ?? '{}') as ConnectionMap;
  } catch {
    return {};
  }
}

function save(map: ConnectionMap): void {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(map));
}

export function getConnection(provider: ProviderId): string {
  return load()[provider] ?? '';
}

export function setConnection(provider: ProviderId, key: string): void {
  const map = load();
  if (key) map[provider] = key;
  else delete map[provider];
  save(map);
}

export function clearConnection(provider: ProviderId): void {
  setConnection(provider, '');
}

export function hasConnection(provider: ProviderId): boolean {
  return getConnection(provider).length > 0;
}
