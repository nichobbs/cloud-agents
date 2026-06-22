export interface ModelOption {
  id: string;
  label: string;
}

export interface HarnessConfig {
  label: string;
  models: ModelOption[];
  defaultModel: string;
}

export const HARNESSES: Record<string, HarnessConfig> = {
  claude: {
    label: 'Claude Code',
    models: [
      { id: 'claude-opus-4-8', label: 'Opus 4.8' },
      { id: 'claude-sonnet-4-6', label: 'Sonnet 4.6' },
      { id: 'claude-haiku-4-5-20251001', label: 'Haiku 4.5' },
    ],
    defaultModel: 'claude-opus-4-8',
  },
  codex: {
    label: 'Codex CLI',
    models: [
      { id: 'o4-mini', label: 'o4-mini' },
      { id: 'o3', label: 'o3' },
      { id: 'gpt-4o', label: 'GPT-4o' },
    ],
    defaultModel: 'o4-mini',
  },
  opencode: {
    label: 'OpenCode',
    models: [
      { id: 'claude-sonnet-4-6', label: 'Sonnet 4.6' },
      { id: 'gpt-4o', label: 'GPT-4o' },
      { id: 'o4-mini', label: 'o4-mini' },
      { id: 'gemini-2.5-pro', label: 'Gemini 2.5 Pro' },
    ],
    defaultModel: 'claude-sonnet-4-6',
  },
};

export const DEFAULT_HARNESS = 'claude';

export function getHarness(id: string): HarnessConfig {
  return HARNESSES[id] ?? (HARNESSES[DEFAULT_HARNESS] as HarnessConfig);
}
