import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, waitFor, fireEvent } from '@testing-library/react';
import type { WorkspaceDiff } from '../types';

vi.mock('../lib/api', () => ({
  api: {
    getWorkspaceDiff: vi.fn(),
    listWorkspaceFiles: vi.fn(),
    getWorkspaceFile: vi.fn(),
  },
}));

import { api } from '../lib/api';
import { WorkspacePanel, humanSize } from './WorkspacePanel';

const diff: WorkspaceDiff = {
  files: [
    { path: 'src/a.ts', status: 'M', additions: '18', deletions: '9' },
    { path: 'src/b.ts', status: 'M', additions: '2', deletions: '1' },
    { path: 'assets/logo.png', status: 'A', additions: '', deletions: '' },
  ],
  patch: [
    'diff --git a/src/a.ts b/src/a.ts',
    '--- a/src/a.ts',
    '+++ b/src/a.ts',
    '@@ -1 +1 @@',
    '-old line',
    '+new line',
    '',
  ].join('\n'),
  clean: 'false',
};

function renderPanel(isStreaming = false) {
  return render(<WorkspacePanel sessionId="s1" isStreaming={isStreaming} />);
}

function expand() {
  fireEvent.click(screen.getByRole('button', { name: /Workspace/ }));
}

describe('humanSize', () => {
  it('formats byte counts', () => {
    expect(humanSize('42')).toBe('42 B');
    expect(humanSize('2048')).toBe('2.0 KB');
    expect(humanSize('1300000')).toBe('1.2 MB');
    expect(humanSize('bogus')).toBe('bogus');
  });
});

describe('WorkspacePanel changes tab', () => {
  beforeEach(() => {
    vi.mocked(api.getWorkspaceDiff).mockReset();
    vi.mocked(api.listWorkspaceFiles).mockReset();
    vi.mocked(api.getWorkspaceFile).mockReset();
  });

  it('is collapsed by default and fetches nothing until expanded', () => {
    renderPanel();
    expect(screen.getByRole('button', { name: /Workspace/ })).toBeInTheDocument();
    expect(api.getWorkspaceDiff).not.toHaveBeenCalled();
    expect(screen.queryByText('Changes')).not.toBeInTheDocument();
  });

  it('renders diffstat totals and per-file rows after expanding', async () => {
    vi.mocked(api.getWorkspaceDiff).mockResolvedValue(diff);
    renderPanel();
    expand();
    await waitFor(() => expect(screen.getByText('src/a.ts')).toBeInTheDocument());
    expect(api.getWorkspaceDiff).toHaveBeenCalledWith('s1');
    // Totals: 3 files, +20 −10 (the binary file contributes nothing).
    expect(screen.getByText(/3 files changed/)).toBeInTheDocument();
    expect(screen.getByText('+20')).toBeInTheDocument();
    expect(screen.getByText('−10')).toBeInTheDocument();
    // Per-file counts and status badges are visible.
    expect(screen.getByText('+18')).toBeInTheDocument();
    expect(screen.getByText('−9')).toBeInTheDocument();
    expect(screen.getAllByText('M')).toHaveLength(2);
    expect(screen.getByText('A')).toBeInTheDocument();
  });

  it('expands a file row into its classified patch lines', async () => {
    vi.mocked(api.getWorkspaceDiff).mockResolvedValue(diff);
    renderPanel();
    expand();
    await waitFor(() => expect(screen.getByText('src/a.ts')).toBeInTheDocument());
    fireEvent.click(screen.getByText('src/a.ts'));
    expect(screen.getByText('+new line')).toBeInTheDocument();
    expect(screen.getByText('-old line')).toBeInTheDocument();
    expect(screen.getByText('@@ -1 +1 @@')).toBeInTheDocument();
  });

  it('shows the no-workspace message on a 409', async () => {
    vi.mocked(api.getWorkspaceDiff).mockRejectedValue(new Error('409 workspace not initialized yet'));
    renderPanel();
    expand();
    await waitFor(() =>
      expect(screen.getByText('No workspace yet — send a message first.')).toBeInTheDocument(),
    );
    // Not an alert — it's an expected state, not an error.
    expect(screen.queryByRole('alert')).not.toBeInTheDocument();
  });

  it('hides the whole panel on a 404 (older backend)', async () => {
    vi.mocked(api.getWorkspaceDiff).mockRejectedValue(new Error('404 not found'));
    const { container } = renderPanel();
    expand();
    await waitFor(() => expect(api.getWorkspaceDiff).toHaveBeenCalled());
    await waitFor(() => expect(container).toBeEmptyDOMElement());
  });

  it('shows "Working tree clean." when the diff is clean', async () => {
    vi.mocked(api.getWorkspaceDiff).mockResolvedValue({ files: [], patch: '', clean: 'true' });
    renderPanel();
    expand();
    await waitFor(() => expect(screen.getByText('Working tree clean.')).toBeInTheDocument());
  });

  it('surfaces other errors inline with a retry', async () => {
    vi.mocked(api.getWorkspaceDiff)
      .mockRejectedValueOnce(new Error('502 docker failed'))
      .mockResolvedValueOnce({ files: [], patch: '', clean: 'true' });
    renderPanel();
    expand();
    await waitFor(() => expect(screen.getByRole('alert')).toHaveTextContent('502 docker failed'));
    fireEvent.click(screen.getByRole('button', { name: 'Retry' }));
    await waitFor(() => expect(screen.getByText('Working tree clean.')).toBeInTheDocument());
  });

  it('refreshes the diff on the falling edge of isStreaming', async () => {
    vi.mocked(api.getWorkspaceDiff).mockResolvedValue(diff);
    const { rerender } = renderPanel(true);
    expand();
    await waitFor(() => expect(api.getWorkspaceDiff).toHaveBeenCalledTimes(1));
    rerender(<WorkspacePanel sessionId="s1" isStreaming={false} />);
    await waitFor(() => expect(api.getWorkspaceDiff).toHaveBeenCalledTimes(2));
  });
});

describe('WorkspacePanel files tab', () => {
  beforeEach(() => {
    vi.mocked(api.getWorkspaceDiff).mockReset();
    vi.mocked(api.listWorkspaceFiles).mockReset();
    vi.mocked(api.getWorkspaceFile).mockReset();
    vi.mocked(api.getWorkspaceDiff).mockResolvedValue({ files: [], patch: '', clean: 'true' });
  });

  it('lists the file tree and opens a text file in the viewer', async () => {
    vi.mocked(api.listWorkspaceFiles).mockResolvedValue({
      files: [{ path: 'docs/notes.txt' }, { path: 'top.txt' }],
      truncated: 'false',
    });
    const content = 'hello workspace';
    vi.mocked(api.getWorkspaceFile).mockResolvedValue({
      path: 'docs/notes.txt',
      contentBase64: btoa(content),
      size: String(content.length),
      truncated: 'false',
    });
    renderPanel();
    expand();
    fireEvent.click(screen.getByText('Files'));
    await waitFor(() => expect(screen.getByText('top.txt')).toBeInTheDocument());
    // Depth-0 directories are open by default, so the nested file shows.
    fireEvent.click(screen.getByText('notes.txt'));
    await waitFor(() => expect(api.getWorkspaceFile).toHaveBeenCalledWith('s1', 'docs/notes.txt'));
    // Decoded content + header + size are on screen.
    await waitFor(() => expect(screen.getByText(/hello workspace/)).toBeInTheDocument());
    expect(screen.getByText('docs/notes.txt')).toBeInTheDocument();
    expect(screen.getByText('15 B')).toBeInTheDocument();
    // Close returns to the tree.
    fireEvent.click(screen.getByRole('button', { name: 'Close file' }));
    await waitFor(() => expect(screen.getByText('top.txt')).toBeInTheDocument());
  });

  it('notes when the listing was truncated at the 5000-file cap', async () => {
    vi.mocked(api.listWorkspaceFiles).mockResolvedValue({
      files: [{ path: 'a.txt' }],
      truncated: 'true',
    });
    renderPanel();
    expand();
    fireEvent.click(screen.getByText('Files'));
    await waitFor(() =>
      expect(screen.getByText('listing truncated at 5000 files')).toBeInTheDocument(),
    );
  });
});
