import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import userEvent from '@testing-library/user-event';

/// #768: the MCP server form needs a `headers` textarea for a url-transport
/// server (a hosted remote MCP endpoint, e.g. GitHub's, that needs an
/// Authorization header) — shown only for transport 'url', wired into the
/// add/update payload and into loading an existing server back into the
/// form for editing.

vi.mock('../lib/api', () => ({
  api: {
    getSkills: vi.fn(),
    addSkill: vi.fn(),
    updateSkill: vi.fn(),
    deleteSkill: vi.fn(),
    getSubagents: vi.fn(),
    addSubagent: vi.fn(),
    updateSubagent: vi.fn(),
    deleteSubagent: vi.fn(),
    getMcpServers: vi.fn(),
    addMcpServer: vi.fn(),
    updateMcpServer: vi.fn(),
    deleteMcpServer: vi.fn(),
  },
}));

import { api } from '../lib/api';
import { Library } from './Library';

const githubServer = {
  id: 'm1',
  userId: 'u1',
  name: 'github',
  transport: 'url' as const,
  command: '',
  args: [],
  url: 'https://api.githubcopilot.com/mcp/',
  env: [],
  headers: ['Authorization=Bearer ${GITHUB_TOKEN}'],
  createdAt: '0',
  updatedAt: '0',
  enabled: '0',
};

beforeEach(() => {
  vi.mocked(api.getSkills).mockReset().mockResolvedValue([]);
  vi.mocked(api.getSubagents).mockReset().mockResolvedValue([]);
  vi.mocked(api.getMcpServers).mockReset().mockResolvedValue([]);
  vi.mocked(api.addMcpServer).mockReset().mockResolvedValue(githubServer);
  vi.mocked(api.updateMcpServer).mockReset().mockResolvedValue(githubServer);
  vi.mocked(api.deleteMcpServer).mockReset();
});

const openMcpTab = async () => {
  render(<Library />);
  await userEvent.click(screen.getByRole('button', { name: 'MCP servers' }));
  // The form itself renders synchronously; this just waits for the async
  // getMcpServers() load (list content, not the form) to settle.
  await screen.findByLabelText('MCP server name');
};

describe('Library MCP server headers (#768)', () => {
  it('shows the headers textarea only for transport "url", not "stdio"', async () => {
    await openMcpTab();

    expect(screen.queryByLabelText('MCP server headers')).not.toBeInTheDocument();

    await userEvent.selectOptions(screen.getByLabelText('Transport'), 'url');
    expect(screen.getByLabelText('MCP server headers')).toBeInTheDocument();

    await userEvent.selectOptions(screen.getByLabelText('Transport'), 'stdio');
    expect(screen.queryByLabelText('MCP server headers')).not.toBeInTheDocument();
  });

  it('sends headers (split on newlines) in the add payload for a url-transport server', async () => {
    await openMcpTab();

    await userEvent.type(screen.getByLabelText('MCP server name'), 'github');
    await userEvent.selectOptions(screen.getByLabelText('Transport'), 'url');
    await userEvent.type(screen.getByLabelText('MCP server url'), 'https://api.githubcopilot.com/mcp/');
    // fireEvent.change (not userEvent.type) so the literal "${GITHUB_TOKEN}"
    // isn't run through userEvent's own {}-as-special-key-syntax parsing.
    fireEvent.change(screen.getByLabelText('MCP server headers'), {
      target: { value: 'Authorization=Bearer ${GITHUB_TOKEN}' },
    });
    await userEvent.click(screen.getByRole('button', { name: 'Create MCP server' }));

    expect(api.addMcpServer).toHaveBeenCalledWith(
      expect.objectContaining({
        name: 'github',
        transport: 'url',
        url: 'https://api.githubcopilot.com/mcp/',
        headers: ['Authorization=Bearer ${GITHUB_TOKEN}'],
      }),
    );
  });

  it('loads an existing url-transport server\'s headers back into the form for editing', async () => {
    vi.mocked(api.getMcpServers).mockResolvedValue([githubServer]);
    await openMcpTab();
    await screen.findByText('github');

    await userEvent.click(screen.getByRole('button', { name: 'Edit github' }));

    expect(screen.getByLabelText('MCP server headers')).toHaveValue('Authorization=Bearer ${GITHUB_TOKEN}');
  });
});
