/// Live model discovery.
///
/// Rather than hardcoding model lists, ask each provider's models API for
/// what the available key can actually use. The backend's models proxy
/// (ADR-006) is tried first: it calls each provider with the credential
/// vault's key and passes the raw responses through, so no browser-held key
/// is needed. Any proxy failure (no vault keys, older backend, network) falls
/// back to direct browser calls with the locally held connection keys (see
/// lib/connections.ts). Results are cached for an hour (per harness for the
/// proxy, per provider for the direct path); every failure falls back to the
/// static catalog in lib/harnesses.ts so the picker always works offline.

import { proxyModels } from './api';
import { getConnection, type ProviderId } from './connections';
import { getHarness, type ModelOption } from './harnesses';

const CACHE_KEY = 'cloud_agents_model_cache';
const PROXY_CACHE_KEY = 'cloud_agents_proxy_model_cache';
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
  localStorage.removeItem(PROXY_CACHE_KEY);
}

// ─── Per-provider response mappings (pure — shared by proxy and direct paths) ─

export interface AnthropicModelsResponse {
  data?: { id: string; display_name?: string }[];
}

/** Anthropic's /v1/models payload → picker options. */
export function mapAnthropicModels(body: AnthropicModelsResponse): ModelOption[] {
  return (body.data ?? []).map(m => ({ id: m.id, label: m.display_name ?? m.id }));
}

export interface OpenAiModelsResponse {
  data?: { id: string }[];
}

/** OpenAI's /v1/models payload → picker options (chat/agent families only). */
export function mapOpenAiModels(body: OpenAiModelsResponse): ModelOption[] {
  return filterOpenAiModelIds((body.data ?? []).map(m => m.id)).map(id => ({ id, label: id }));
}

export interface GoogleModelsResponse {
  models?: GoogleModel[];
}

/** Google's /v1beta/models payload → picker options. */
export function mapGoogleModels(body: GoogleModelsResponse): ModelOption[] {
  return filterGoogleModels(body.models ?? []);
}

// ─── Per-provider fetchers (direct browser path) ──────────────────────────────

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
  return mapAnthropicModels((await res.json()) as AnthropicModelsResponse);
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
  return mapOpenAiModels((await res.json()) as OpenAiModelsResponse);
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
  return mapGoogleModels((await res.json()) as GoogleModelsResponse);
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

// ─── Backend models proxy (vault keys, server-side calls) ─────────────────────

const PROXY_MAPPERS: Record<Exclude<ProviderId, 'github'>, (body: unknown) => ModelOption[]> = {
  anthropic: body => mapAnthropicModels(body as AnthropicModelsResponse),
  openai: body => mapOpenAiModels(body as OpenAiModelsResponse),
  google: body => mapGoogleModels(body as GoogleModelsResponse),
};

type ProxyModelCache = Partial<Record<string, CacheEntry>>; // keyed by harness id

function loadProxyCache(): ProxyModelCache {
  try {
    return JSON.parse(localStorage.getItem(PROXY_CACHE_KEY) ?? '{}') as ProxyModelCache;
  } catch {
    return {};
  }
}

/** Merged, deduped listings for a harness via the backend models proxy, or
 *  null when the proxy can't help (no vault keys, older backend, unusable
 *  bodies) — cached per harness for an hour, stale cache beating nothing. */
async function proxyDiscover(harnessId: string, force: boolean): Promise<ModelOption[] | null> {
  const cache = loadProxyCache();
  const hit = cache[harnessId];
  if (!force && hit && Date.now() - hit.fetchedAt < CACHE_TTL_MS && hit.models.length > 0) {
    return hit.models;
  }
  try {
    const res = await proxyModels(harnessId);
    const models: ModelOption[] = [];
    const seen = new Set<string>();
    for (const entry of res.providers ?? []) {
      const mapper = PROXY_MAPPERS[entry.provider as Exclude<ProviderId, 'github'>];
      if (!mapper) continue;
      let listing: ModelOption[];
      try {
        listing = mapper(JSON.parse(entry.body));
      } catch {
        continue; // one unusable provider body must not sink the rest
      }
      for (const m of listing) {
        if (!seen.has(m.id)) {
          seen.add(m.id);
          models.push(m);
        }
      }
    }
    if (models.length === 0) {
      return hit && hit.models.length > 0 ? hit.models : null;
    }
    cache[harnessId] = { fetchedAt: Date.now(), models };
    try {
      localStorage.setItem(PROXY_CACHE_KEY, JSON.stringify(cache));
    } catch {
      /* quota — discovery still works, just uncached */
    }
    return models;
  } catch {
    return hit && hit.models.length > 0 ? hit.models : null;
  }
}

export interface DiscoveredModels {
  models: ModelOption[];
  /** 'live' when at least one provider listing was used, else 'static'. */
  source: 'live' | 'static';
}

/** Models for a harness: the backend models proxy (vault keys — no
 *  browser-held key needed) MERGED with direct provider listings from any
 *  locally connected keys, else the static fallback catalog. Merging (rather
 *  than proxy-wins, #444) matters for multi-provider harnesses: the vault
 *  may hold only Anthropic's key while the browser holds OpenAI's — the
 *  picker should show both providers' models. Direct listings are attempted
 *  only for providers with a local key, so this adds no cost when none are
 *  connected. Never rejects. */
export async function discoverModels(harnessId: string, force = false): Promise<DiscoveredModels> {
  const harness = getHarness(harnessId);
  const live: ModelOption[] = [];
  const seen = new Set<string>();
  const merge = (listing: ModelOption[] | null) => {
    for (const m of listing ?? []) {
      if (!seen.has(m.id)) {
        seen.add(m.id);
        live.push(m);
      }
    }
  };
  const [proxied, ...direct] = await Promise.all([
    proxyDiscover(harnessId, force),
    ...harness.providers.map(p => providerModels(p, force)),
  ]);
  merge(proxied);
  for (const listing of direct) merge(listing);
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
