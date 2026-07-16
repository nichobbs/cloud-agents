import { describe, it, expect } from 'vitest';
import { filterGoogleModels, filterOpenAiModelIds } from './models';

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
