import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';

vi.mock('../lib/api', () => ({
  api: {
    putCredential: vi.fn(),
  },
}));

vi.mock('../lib/models', async importOriginal => ({
  ...(await importOriginal<typeof import('../lib/models')>()),
  validateModelProviderKey: vi.fn(),
  clearModelCache: vi.fn(),
}));

vi.mock('../lib/github', async importOriginal => ({
  ...(await importOriginal<typeof import('../lib/github')>()),
  validateGitHubToken: vi.fn(),
  clearRepoCache: vi.fn(),
}));

import { api } from '../lib/api';
import { getConnection } from '../lib/connections';
import { validateGitHubToken } from '../lib/github';
import { validateModelProviderKey } from '../lib/models';
import { Integrations } from './Integrations';

beforeEach(() => {
  localStorage.clear();
  vi.mocked(api.putCredential).mockReset().mockResolvedValue(undefined);
  vi.mocked(validateModelProviderKey).mockReset().mockResolvedValue(12);
  vi.mocked(validateGitHubToken).mockReset().mockResolvedValue('octocat');
});

describe('Integrations', () => {
  it('renders a card per provider plus the smart importer', () => {
    render(<Integrations />);
    for (const label of ['Anthropic', 'OpenAI', 'Google (Gemini)', 'GitHub']) {
      expect(screen.getByText(label)).toBeInTheDocument();
    }
    expect(screen.getByText('Import harness credentials')).toBeInTheDocument();
  });

  it('connect validates the key, stores it locally, and uploads it to the vault', async () => {
    render(<Integrations />);
    await userEvent.type(screen.getByLabelText('Anthropic key'), 'sk-ant-test');
    await userEvent.click(screen.getAllByRole('button', { name: 'Connect' })[0]!);

    await waitFor(() =>
      expect(screen.getByText(/uploaded to vault as ANTHROPIC_API_KEY/)).toBeInTheDocument(),
    );
    expect(validateModelProviderKey).toHaveBeenCalledWith('anthropic', 'sk-ant-test');
    expect(api.putCredential).toHaveBeenCalledWith('ANTHROPIC_API_KEY', 'sk-ant-test');
    expect(getConnection('anthropic')).toBe('sk-ant-test');
  });

  it('a failed validation stores nothing anywhere', async () => {
    vi.mocked(validateModelProviderKey).mockRejectedValue(new Error('Anthropic models API: 401'));
    render(<Integrations />);
    await userEvent.type(screen.getByLabelText('Anthropic key'), 'sk-ant-bad');
    await userEvent.click(screen.getAllByRole('button', { name: 'Connect' })[0]!);

    await waitFor(() =>
      expect(screen.getByText(/Anthropic models API: 401/)).toBeInTheDocument(),
    );
    expect(api.putCredential).not.toHaveBeenCalled();
    expect(getConnection('anthropic')).toBe('');
  });

  it('keeps the local connection when the vault upload fails, and says so', async () => {
    vi.mocked(api.putCredential).mockRejectedValue(new Error('503 vault down'));
    render(<Integrations />);
    await userEvent.type(screen.getByLabelText('GitHub key'), 'ghp_test');
    await userEvent.click(screen.getAllByRole('button', { name: 'Connect' })[3]!);

    await waitFor(() => expect(screen.getByText(/Vault upload failed/)).toBeInTheDocument());
    expect(screen.getByText(/authenticated as octocat/)).toBeInTheDocument();
    expect(getConnection('github')).toBe('ghp_test');
  });

  it('smart import recognises a pasted credentials file and uploads each secret', async () => {
    render(<Integrations />);
    const file = JSON.stringify({
      claudeAiOauth: { accessToken: 'sk-ant-oat01-tok' },
    });
    await userEvent.click(screen.getByLabelText('Credential text to import'));
    await userEvent.paste(file);

    expect(await screen.findByText('CLAUDE_CODE_OAUTH_TOKEN')).toBeInTheDocument();
    await userEvent.click(screen.getByRole('button', { name: 'Upload 1 to vault' }));
    await waitFor(() =>
      expect(screen.getByText(/Uploaded to vault: CLAUDE_CODE_OAUTH_TOKEN/)).toBeInTheDocument(),
    );
    expect(api.putCredential).toHaveBeenCalledWith('CLAUDE_CODE_OAUTH_TOKEN', 'sk-ant-oat01-tok');
  });

  it('smart import reports unrecognised input instead of uploading blindly', async () => {
    render(<Integrations />);
    await userEvent.click(screen.getByLabelText('Credential text to import'));
    await userEvent.paste('hello world');
    expect(await screen.findByText(/Nothing recognised yet/)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /Upload/ })).not.toBeInTheDocument();
  });
});
