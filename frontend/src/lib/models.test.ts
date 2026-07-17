import { describe, it, expect, beforeEach, vi } from 'vitest';

// Mock the backend proxy wrapper so discoverModels' proxy-first/fallback
// ordering can be exercised without a server.
vi.mock('./api', () => ({
  proxyModels: vi.fn(),
}));

import { proxyModels } from './api';
import {
  discoverModels,
  filterGoogleModels,
  filterOpenAiModelIds,
  mapAnthropicModels,
  mapGoogleModels,
  mapOpenAiModels,
} from './models';

describe('filterOpenAiModelIds', () => {
  it('keeps chat/agent model families', () => {
    expect(filterOpenAiModelIds(['gpt-4o', 'o3', 'o4-mini'])).toEqual(['gpt-4o', 'o3', 'o4-mini']);
  });

  it('drops non-chat models', () => {
    const noisy = [
      'gpt-4o',
      'text-embedding-3-small',
      'whisper-1',
      'gpt-4o-audio-preview',
      'tts-1',
      'dall-e-3',
      'gpt-4o-realtime-preview',
      'omni-moderation-latest',
      'gpt-4o-transcribe',
      'gpt-4o-search-preview',
      'gpt-3.5-turbo-instruct',
      'davinci-002',
    ];
    expect(filterOpenAiModelIds(noisy)).toEqual(['gpt-4o']);
  });
});

describe('filterGoogleModels', () => {
  it('keeps generateContent-capable gemini models and strips the prefix', () => {
    const out = filterGoogleModels([
      {
        name: 'models/gemini-2.5-pro',
        displayName: 'Gemini 2.5 Pro',
        supportedGenerationMethods: ['generateContent', 'countTokens'],
      },
      {
        name: 'models/embedding-001',
        displayName: 'Embedding',
        supportedGenerationMethods: ['embedContent'],
      },
      {
        name: 'models/gemini-embedding-exp',
        displayName: 'Gemini Embedding',
        supportedGenerationMethods: ['embedContent'],
      },
    ]);
    expect(out).toEqual([{ id: 'gemini-2.5-pro', label: 'Gemini 2.5 Pro' }]);
  });

  it('falls back to the id when displayName is missing', () => {
    const out = filterGoogleModels([
      { name: 'models/gemini-2.5-flash', supportedGenerationMethods: ['generateContent'] },
    ]);
    expect(out).toEqual([{ id: 'gemini-2.5-flash', label: 'gemini-2.5-flash' }]);
  });
});

// ── Shared response→ModelOption mappings (used by proxy AND direct paths) ────

describe('mapAnthropicModels', () => {
  it('maps ids with display names, defaulting the label to the id', () => {
    expect(
      mapAnthropicModels({
        data: [{ id: 'claude-a', display_name: 'Claude A' }, { id: 'claude-b' }],
      }),
    ).toEqual([
      { id: 'claude-a', label: 'Claude A' },
      { id: 'claude-b', label: 'claude-b' },
    ]);
  });

  it('is empty for a payload without data', () => {
    expect(mapAnthropicModels({})).toEqual([]);
  });
});

describe('mapOpenAiModels', () => {
  it('applies the chat/agent-family filter', () => {
    expect(
      mapOpenAiModels({ data: [{ id: 'gpt-4o' }, { id: 'whisper-1' }, { id: 'o3' }] }),
    ).toEqual([
      { id: 'gpt-4o', label: 'gpt-4o' },
      { id: 'o3', label: 'o3' },
    ]);
  });
});

describe('mapGoogleModels', () => {
  it('applies the generateContent/gemini filter', () => {
    expect(
      mapGoogleModels({
        models: [
          {
            name: 'models/gemini-2.5-pro',
            displayName: 'Gemini 2.5 Pro',
            supportedGenerationMethods: ['generateContent'],
          },
          { name: 'models/embedding-001', supportedGenerationMethods: ['embedContent'] },
        ],
      }),
    ).toEqual([{ id: 'gemini-2.5-pro', label: 'Gemini 2.5 Pro' }]);
  });
});

// ── discoverModels: proxy first, direct/static fallback ──────────────────────

describe('discoverModels', () => {
  beforeEach(() => {
    localStorage.clear();
    vi.mocked(proxyModels).mockReset();
  });

  it('uses proxied provider listings when the backend has vault keys', async () => {
    vi.mocked(proxyModels).mockResolvedValue({
      providers: [
        {
          provider: 'anthropic',
          body: JSON.stringify({ data: [{ id: 'claude-test-1', display_name: 'Test 1' }] }),
        },
      ],
    });
    const out = await discoverModels('claude', true);
    expect(out.source).toBe('live');
    expect(out.models.some(m => m.id === 'claude-test-1')).toBe(true);
    expect(proxyModels).toHaveBeenCalledWith('claude');
  });

  it('skips an unparseable provider body without sinking the rest', async () => {
    vi.mocked(proxyModels).mockResolvedValue({
      providers: [
        { provider: 'openai', body: 'not json' },
        {
          provider: 'anthropic',
          body: JSON.stringify({ data: [{ id: 'claude-test-2', display_name: 'Test 2' }] }),
        },
      ],
    });
    const out = await discoverModels('opencode', true);
    expect(out.source).toBe('live');
    expect(out.models.some(m => m.id === 'claude-test-2')).toBe(true);
  });

  it('caches the proxied listing per harness for subsequent calls', async () => {
    vi.mocked(proxyModels).mockResolvedValue({
      providers: [
        {
          provider: 'anthropic',
          body: JSON.stringify({ data: [{ id: 'claude-cached', display_name: 'Cached' }] }),
        },
      ],
    });
    await discoverModels('claude', true);
    vi.mocked(proxyModels).mockClear();
    const out = await discoverModels('claude', false);
    expect(out.models.some(m => m.id === 'claude-cached')).toBe(true);
    expect(proxyModels).not.toHaveBeenCalled();
  });

  it('falls back to the static catalog when the proxy fails and no local keys exist', async () => {
    vi.mocked(proxyModels).mockRejectedValue(new Error('404 no provider API keys in the credential vault'));
    const out = await discoverModels('claude', true);
    expect(out.source).toBe('static');
    expect(out.models.length).toBeGreaterThan(0);
  });
});

describe('#444: proxy and direct listings merge for multi-provider harnesses', () => {
  it('adds locally-keyed providers the vault does not cover', async () => {
    localStorage.setItem(
      'cloud_agents_connections',
      JSON.stringify({ openai: 'sk-local-openai' }),
    );
    // Vault covers only Anthropic (via the proxy)…
    vi.mocked(proxyModels).mockResolvedValue({
      providers: [
        {
          provider: 'anthropic',
          body: JSON.stringify({ data: [{ id: 'claude-vaulted', display_name: 'Vaulted' }] }),
        },
      ],
    });
    // …while the browser holds an OpenAI key served by the direct path.
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: true,
        json: () => Promise.resolve({ data: [{ id: 'gpt-local' }] }),
      }),
    );
    const out = await discoverModels('opencode', true);
    vi.unstubAllGlobals();
    expect(out.source).toBe('live');
    expect(out.models.some(m => m.id === 'claude-vaulted')).toBe(true);
    expect(out.models.some(m => m.id === 'gpt-local')).toBe(true);
  });
});
