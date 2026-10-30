import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, waitFor, fireEvent } from '@testing-library/react';

vi.mock('../lib/imports', () => ({
  importsApi: {
    tokens: vi.fn(),
    createToken: vi.fn(),
    revokeToken: vi.fn(),
    clearTombstone: vi.fn(),
  },
}));

import { importsApi } from '../lib/imports';
import { Imports } from './Imports';

const token = { id: 't1', label: 'claude importer', createdAt: '1700000000000', lastUsedAt: '', revoked: false };

describe('Imports', () => {
  beforeEach(() => {
    vi.mocked(importsApi.tokens).mockReset().mockResolvedValue([token]);
    vi.mocked(importsApi.createToken).mockReset();
    vi.mocked(importsApi.revokeToken).mockReset().mockResolvedValue();
    vi.mocked(importsApi.clearTombstone).mockReset().mockResolvedValue();
  });

  it('lists tokens and shows a new token once', async () => {
    vi.mocked(importsApi.createToken).mockResolvedValue({ token, secret: 'cai_secret123' });
    render(<Imports />);
    expect(await screen.findByText('claude importer')).toBeInTheDocument();
    expect(screen.getByText(/last used never/)).toBeInTheDocument();
    fireEvent.click(screen.getByText('Create token'));
    expect(await screen.findByTestId('import-secret')).toHaveTextContent('cai_secret123');
    expect(importsApi.createToken).toHaveBeenCalledWith('claude importer');
    fireEvent.click(screen.getByText('Done'));
    expect(screen.queryByTestId('import-secret')).not.toBeInTheDocument();
  });

  it('revokes a token after confirmation', async () => {
    vi.spyOn(window, 'confirm').mockReturnValue(true);
    render(<Imports />);
    fireEvent.click(await screen.findByLabelText('Revoke claude importer'));
    await waitFor(() => expect(importsApi.revokeToken).toHaveBeenCalledWith('t1'));
  });

  it('re-allows a deleted session', async () => {
    render(<Imports />);
    await screen.findByText('claude importer');
    fireEvent.change(screen.getByLabelText('Claude Code session id'), { target: { value: 'session_abc' } });
    fireEvent.click(screen.getByText('Allow import'));
    await waitFor(() => expect(importsApi.clearTombstone).toHaveBeenCalledWith('session_abc'));
    expect(await screen.findByText('session_abc can be imported again.')).toBeInTheDocument();
  });
});
