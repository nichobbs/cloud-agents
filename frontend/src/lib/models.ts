/// Live model discovery.
///
/// Rather than hardcoding model lists, ask each provider's models API for what
/// the connected key can actually use. Runs in the browser using the locally
/// held connection keys (see lib/connections.ts) — the Lyric backend has no
/// reliable outbound HTTPS, so the frontend is the right place for this.
/// Results are cached per provider for an hour; every failure falls back to
/// the static catalog in lib/harnesses.ts so the picker always works offline.

import { getConnection, type ProviderId } from './connections';
import { getHarness, type ModelOption } from './harnesses';

const CACHE_KEY = 'cloud_agents_model_cache';
const CACHE_TTL_MS = 60 * 60 * 1000;

interface CacheEntry {
  fetchedAt: number;
  models: ModelOption[];
}

type ModelCache = Partial<Record<ProviderId, CacheEntry>>;

function loadCache(): ModelCache {
  try {
    return JSON.parse(localStorage.getItem(CACHE_KEY) ?? '{}') as ModelCache;
  } catch {
    return {};
  }
}

function saveCache(cache: ModelCache): void {
  try {
    localStorage.setItem(CACHE_KEY, JSON.stringify(cache));
  } catch {
    /* quota — discovery still works, just uncached */
  }
}

/** Drop cached listings (e.g. after connecting a different key). */
export function clearModelCache(): void {
  localStorage.removeItem(CACHE_KEY);
}

// ─── Per-provider fetchers ────────────────────────────────────────────────────

async function fetchAnthropicModels(key: string): Promise<ModelOption[]> {
  const res = await fetch('https://api.anthropic.com/v1/models?limit=100', {
    headers: {
      'x-api-key': key,
      'anthropic-version': '2023-06-01',
      // Anthropic requires this opt-in header for browser-origin requests.
      'anthropic-dangerous-direct-browser-access': 'true',
    },
  });
  if (!res.ok) throw new Error(`Anthropic models API: ${res.status}`);
  const body = (await res.json()) as { data?: { id: string; display_name?: string }[] };
  return (body.data ?? []).map(m => ({ id: m.id, label: m.display_name ?? m.id }));
}

/** OpenAI's /v1/models lists everything (embeddings, audio, images…); keep the
 *  chat/agent-capable families and drop the rest. */
export function filterOpenAiModelIds(ids: string[]): string[] {
  const exclude = /(embedding|whisper|tts|audio|realtime|image|dall-e|moderation|transcribe|search|davinci|babbage|instruct)/;
  return ids
    .filter(id => /^(gpt-|o[0-9])/.test(id) && !exclude.test(id))
    .sort();
}

async function fetchOpenAiModels(key: string): Promise<ModelOption[]> {
  const res = await fetch('https://api.openai.com/v1/models', {
    headers: { Authorization: `Bearer ${key}` },
  });
  if (!res.ok) throw new Error(`OpenAI models API: ${res.status}`);
  const body = (await res.json()) as { data?: { id: string }[] };
  return filterOpenAiModelIds((body.data ?? []).map(m => m.id)).map(id => ({ id, label: id }));
}

interface GoogleModel {
  name?: string;
  displayName?: string;
  supportedGenerationMethods?: string[];
}

/** Keep generateContent-capable gemini-* models; strip the "models/" prefix. */
export function filterGoogleModels(models: GoogleModel[]): ModelOption[] {
  return models
    .filter(m => (m.supportedGenerationMethods ?? []).includes('generateContent'))
    .map(m => ({ id: (m.name ?? '').replace(/^models\//, ''), label: m.displayName ?? '' }))
    .filter(m => m.id.startsWith('gemini-'))
    .map(m => ({ id: m.id, label: m.label || m.id }))
    .sort((a, b) => a.id.localeCompare(b.id));
}

async function fetchGoogleModels(key: string): Promise<ModelOption[]> {
  // Key goes in the x-goog-api-key header, not a ?key= query param — URLs
  // end up in proxy/browser logs, headers don't.
  const res = await fetch('https://generativelanguage.googleapis.com/v1beta/models?pageSize=200', {
    headers: { 'x-goog-api-key': key },
  });
  if (!res.ok) throw new Error(`Google models API: ${res.status}`);
  const body = (await res.json()) as { models?: GoogleModel[] };
  return filterGoogleModels(body.models ?? []);
}

const FETCHERS: Record<Exclude<ProviderId, 'github'>, (key: string) => Promise<ModelOption[]>> = {
  anthropic: fetchAnthropicModels,
  openai: fetchOpenAiModels,
  google: fetchGoogleModels,
};

/** Validate a model-provider key by listing models with it. Throws on a bad
 *  key / network failure; resolves with the model count otherwise. */
export async function validateModelProviderKey(
  provider: Exclude<ProviderId, 'github'>,
  key: string,
): Promise<number> {
  const models = await FETCHERS[provider](key);
  return models.length;
}

async function providerModels(provider: ProviderId, force: boolean): Promise<ModelOption[] | null> {
  if (provider === 'github') return null;
  const key = getConnection(provider);
  if (!key) return null;
  const cache = loadCache();
  const hit = cache[provider];
  if (!force && hit && Date.now() - hit.fetchedAt < CACHE_TTL_MS && hit.models.length > 0) {
    return hit.models;
  }
  try {
    const models = await FETCHERS[provider](key);
    if (models.length === 0) return null;
    cache[provider] = { fetchedAt: Date.now(), models };
    saveCache(cache);
    return models;
  } catch {
    // Stale cache beats static fallback if we have one.
    return hit && hit.models.length > 0 ? hit.models : null;
  }
}

export interface DiscoveredModels {
  models: ModelOption[];
  /** 'live' when at least one provider listing was used, else 'static'. */
  source: 'live' | 'static';
}

/** Models for a harness: live provider listings (merged, deduped) when keys
 *  are connected, else the static fallback catalog. Never rejects. */
export async function discoverModels(harnessId: string, force = false): Promise<DiscoveredModels> {
  const harness = getHarness(harnessId);
  const listings = await Promise.all(harness.providers.map(p => providerModels(p, force)));
  const live: ModelOption[] = [];
  const seen = new Set<string>();
  for (const listing of listings) {
    for (const m of listing ?? []) {
      if (!seen.has(m.id)) {
        seen.add(m.id);
        live.push(m);
      }
    }
  }
  if (live.length === 0) {
    return { models: harness.models, source: 'static' };
  }
  // The harness's current default should always be selectable even when a
  // provider listing omits it (e.g. an alias id the API doesn't enumerate).
  if (!seen.has(harness.defaultModel)) {
    live.unshift({ id: harness.defaultModel, label: harness.defaultModel });
  }
  return { models: live, source: 'live' };
}
