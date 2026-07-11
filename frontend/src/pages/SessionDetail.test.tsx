import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { render, screen, within, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import type { Profile, Prompt } from '../types';

// The API client is the only side-effecting dependency; mock it wholesale so
// each test drives the component purely through UI + resolved values.
vi.mock('../lib/api', () => ({
  api: {
    getPrompts: vi.fn(),
    getProfiles: vi.fn(),
    getSessionProfile: vi.fn(),
    getMessages: vi.fn(),
    renderPrompt: vi.fn(),
    usePrompt: vi.fn(),
    setSessionProfile: vi.fn(),
    getRuns: vi.fn(),
    cancelRun: vi.fn(),
    updateSessionModel: vi.fn(),
    addPrompt: vi.fn(),
    deleteSession: vi.fn(),
  },
}));

// A configurable stream-hook stub. Most tests want a static idle state; the
// #214 test overrides `send`/`output` to drive a completed send. `.current` is
// swapped per test (reset in beforeEach) so the hoisted mock stays stable.
const stream = vi.hoisted(() => ({
  current: {
    output: '' as string,
    isStreaming: false,
    error: null as string | null,
    send: (async () => ({ succeeded: true, stale: false })) as (t: string) => Promise<{ succeeded: boolean; stale: boolean }>,
    reset: (() => {}) as () => void,
    reattachEnded: 0,
  },
}));
vi.mock('../hooks/useStreamMessage', () => ({
  useStreamMessage: () => stream.current,
}));

vi.mock('../context/SessionsContext', () => ({
  useSessions: () => ({
    getSession: (id: string) => ({
      sessionId: id,
      repoUrl: 'https://github.com/owner/repo',
      branch: 'main',
      createdAt: '0',
      harness: 'claude',
      model: 'claude-opus-4-8',
    }),
    removeSession: vi.fn(),
    updateSession: vi.fn(),
  }),
}));

import { api } from '../lib/api';
import { SessionDetail } from './SessionDetail';

function makePrompt(over: Partial<Prompt>): Prompt {
  return {
    id: 'p1',
    userId: 'u1',
    name: 'Greeting',
    body: 'Hello {{name}}!',
    useCount: '0',
    createdAt: '0',
    updatedAt: '0',
    tags: [],
    ...over,
  };
}

function makeProfile(over: Partial<Profile>): Profile {
  return {
    id: 'pa',
    userId: 'u1',
    name: 'Profile A',
    harness: '',
    networkPolicy: 'full',
    credentialMode: 'all',
    credentials: [],
    createdAt: '0',
    updatedAt: '0',
    ...over,
  };
}

/** A promise whose resolution the test controls, for driving race orderings. */
function deferred<T>(): { promise: Promise<T>; resolve: (v: T) => void } {
  let resolve!: (v: T) => void;
  const promise = new Promise<T>(r => {
    resolve = r;
  });
  return { promise, resolve };
}

function renderPage() {
  const root = document.createElement('div');
  root.id = 'root';
  document.body.appendChild(root);
  return render(
    <MemoryRouter initialEntries={['/sessions/s1']}>
      <Routes>
        <Route path="/sessions/:id" element={<SessionDetail />} />
      </Routes>
    </MemoryRouter>,
    { container: root },
  );
}

beforeEach(() => {
  vi.mocked(api.getPrompts).mockResolvedValue([]);
  vi.mocked(api.getProfiles).mockResolvedValue([]);
  vi.mocked(api.getSessionProfile).mockResolvedValue('');
  vi.mocked(api.getMessages).mockResolvedValue([]);
  vi.mocked(api.usePrompt).mockResolvedValue(undefined);
  vi.mocked(api.setSessionProfile).mockResolvedValue(undefined);
  stream.current = {
    output: '',
    isStreaming: false,
    error: null,
    send: async () => ({ succeeded: true, stale: false }),
    reset: () => {},
    reattachEnded: 0,
  };
});

afterEach(() => {
  vi.clearAllMocks();
  document.querySelectorAll('#root').forEach(el => el.remove());
  // Belt-and-suspenders: the modal's cleanup already restores these on
  // unmount, but reset anyway so a failing test can't leak into the next.
  document.body.style.overflow = '';
  document.body.removeAttribute('inert');
});

describe('SessionDetail template modal', () => {
  it('opens a field per placeholder and inserts the server-rendered text', async () => {
    vi.mocked(api.getPrompts).mockResolvedValue([
      makePrompt({ body: 'Hi {{name}} from {{team}}' }),
    ]);
    vi.mocked(api.renderPrompt).mockResolvedValue('Hi Nic from Core');
    renderPage();
    const user = userEvent.setup();

    const picker = await screen.findByLabelText('Insert a saved prompt');
    await user.selectOptions(picker, 'p1');

    const dialog = await screen.findByRole('dialog');
    const fields = within(dialog).getAllByRole('textbox');
    expect(fields).toHaveLength(2);
    await user.type(fields[0]!, 'Nic');
    await user.type(fields[1]!, 'Core');
    await user.click(within(dialog).getByRole('button', { name: 'Insert' }));

    expect(api.renderPrompt).toHaveBeenCalledWith('p1', { name: 'Nic', team: 'Core' });
    // Composer receives the rendered text and the modal closes.
    await screen.findByDisplayValue('Hi Nic from Core');
    expect(screen.queryByRole('dialog')).toBeNull();
  });

  it('cancels without rendering and restores focus to the picker', async () => {
    vi.mocked(api.getPrompts).mockResolvedValue([makePrompt({ body: 'Hi {{name}}' })]);
    renderPage();
    const user = userEvent.setup();

    const picker = await screen.findByLabelText('Insert a saved prompt');
    await user.selectOptions(picker, 'p1');
    const dialog = await screen.findByRole('dialog');
    await user.click(within(dialog).getByRole('button', { name: 'Cancel' }));

    expect(screen.queryByRole('dialog')).toBeNull();
    expect(api.renderPrompt).not.toHaveBeenCalled();
    expect(screen.getByPlaceholderText(/Send a message/)).toHaveValue('');
    // Focus returns to whatever opened the modal (#279).
    expect(document.activeElement).toBe(picker);
  });

  it('locks background scroll and marks #root inert while open, restoring on close', async () => {
    vi.mocked(api.getPrompts).mockResolvedValue([makePrompt({ body: 'Hi {{name}}' })]);
    renderPage();
    const user = userEvent.setup();

    const picker = await screen.findByLabelText('Insert a saved prompt');
    await user.selectOptions(picker, 'p1');
    await screen.findByRole('dialog');

    const root = document.getElementById('root')!;
    expect(root.hasAttribute('inert')).toBe(true);
    expect(document.body.style.overflow).toBe('hidden');

    await user.keyboard('{Escape}');

    expect(screen.queryByRole('dialog')).toBeNull();
    expect(root.hasAttribute('inert')).toBe(false);
    expect(document.body.style.overflow).toBe('');
  });

  it('inserts a placeholder-free prompt verbatim and records a use', async () => {
    vi.mocked(api.getPrompts).mockResolvedValue([
      makePrompt({ id: 'p2', name: 'Plain', body: 'no vars here' }),
    ]);
    renderPage();
    const user = userEvent.setup();

    const picker = await screen.findByLabelText('Insert a saved prompt');
    await user.selectOptions(picker, 'p2');

    await screen.findByDisplayValue('no vars here');
    expect(screen.queryByRole('dialog')).toBeNull();
    expect(api.usePrompt).toHaveBeenCalledWith('p2');
    expect(api.renderPrompt).not.toHaveBeenCalled();
  });
});

describe('SessionDetail profile selector', () => {
  it('does not let the in-flight mount fetch revert a manual change (#276)', async () => {
    vi.mocked(api.getProfiles).mockResolvedValue([
      makeProfile({ id: 'pa', name: 'A' }),
      makeProfile({ id: 'pb', name: 'B' }),
    ]);
    // Hold the mount-time "what profile is attached" fetch open so we can
    // resolve it *after* a manual change, reproducing the race.
    const gate = deferred<string>();
    vi.mocked(api.getSessionProfile).mockReturnValue(gate.promise);
    renderPage();
    const user = userEvent.setup();

    const profileSelect = (await screen.findByTitle(/Attach a profile/)) as HTMLSelectElement;
    await user.selectOptions(profileSelect, 'pb');
    expect(api.setSessionProfile).toHaveBeenCalledWith('s1', 'pb');
    expect(profileSelect.value).toBe('pb');

    // The stale fetch now resolves with the server's pre-change value…
    gate.resolve('pa');
    // …and must not clobber the manual choice.
    await waitFor(() => expect(profileSelect.value).toBe('pb'));
  });
});

describe('SessionDetail live output retention', () => {
  it('keeps the completed run visible when the post-send transcript refresh fails (#214)', async () => {
    const reset = vi.fn();
    stream.current = {
      output: 'AGENT REPLY',
      isStreaming: false,
      error: null,
      send: async () => ({ succeeded: true, stale: false }),
      reset,
      reattachEnded: 0,
    };
    // Clean transcript on mount, then fail the post-send reload.
    vi.mocked(api.getMessages).mockReset();
    vi.mocked(api.getMessages).mockResolvedValueOnce([]).mockRejectedValue(new Error('boom'));
    renderPage();
    const user = userEvent.setup();

    const composer = await screen.findByPlaceholderText(/Send a message/);
    await user.type(composer, 'hello');
    await user.click(screen.getByRole('button', { name: 'Send' }));

    // The panel stays on screen (via keepOutput) with the "couldn't refresh"
    // label, instead of the completed run vanishing…
    await screen.findByText(/could not refresh transcript/);
    // …and it wasn't reset, so the run's output is retained.
    expect(reset).not.toHaveBeenCalled();
  });
});

