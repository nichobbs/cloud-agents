import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { renderHook, waitFor, act } from '@testing-library/react';

// Unlike useStreamMessage.test.ts — whose api mock deliberately leaves
// getRunOutputDelta undefined so every poll exercises the older-backend
// fallback — this file mocks the delta endpoint too, covering the preferred
// incremental path.
vi.mock('../lib/api', () => ({
  api: {
    getRunOutput: vi.fn(),
    getRunOutputDelta: vi.fn(),
    sendMessage: vi.fn(),
  },
}));

import { api } from '../lib/api';
import { useStreamMessage } from './useStreamMessage';

describe('useStreamMessage incremental (delta) polling', () => {
  beforeEach(() => {
    vi.mocked(api.getRunOutput).mockReset();
    vi.mocked(api.getRunOutputDelta).mockReset();
    vi.mocked(api.sendMessage).mockReset();
  });
  afterEach(() => {
    vi.clearAllMocks();
  });

  it('send() polls the delta endpoint with a server-authoritative offset and accumulates chunks', async () => {
    // The send blocks forever so the parallel poll loop drives the stream.
    vi.mocked(api.sendMessage).mockImplementation(() => new Promise(() => {}));
    // No run at mount, so the reattach probe bails and doesn't interfere.
    vi.mocked(api.getRunOutput).mockResolvedValue({ running: false, output: '' });
    vi.mocked(api.getRunOutputDelta)
      .mockResolvedValueOnce({ running: true, length: 5, chunk: 'hello' })
      .mockResolvedValueOnce({ running: false, length: 11, chunk: ' world' })
      .mockResolvedValue({ running: false, length: 11, chunk: '' });

    const { result } = renderHook(() => useStreamMessage('s1'));

    act(() => {
      void result.current.send('hi');
    });

    // First tick fires immediately; the second follows the 1.5s floor.
    await waitFor(() => expect(result.current.output).toContain('hello'));
    await waitFor(() => expect(result.current.output).toContain('hello world'), {
      timeout: 3000,
    });

    // The offset fed to each poll is the previous response's length: 0, then 5.
    expect(api.getRunOutputDelta).toHaveBeenNthCalledWith(1, 's1', 0);
    expect(api.getRunOutputDelta).toHaveBeenNthCalledWith(2, 's1', 5);
    // The full-log endpoint served only the mount-time reattach probe — the
    // poll loop itself never fell back to it.
    expect(api.getRunOutput).toHaveBeenCalledTimes(1);
  });

  it('treats a server length below the sent offset as a full replacement (resync)', async () => {
    vi.mocked(api.sendMessage).mockImplementation(() => new Promise(() => {}));
    vi.mocked(api.getRunOutput).mockResolvedValue({ running: false, output: '' });
    // Second tick: the log shrank (a new run truncated/replaced it), so the
    // server returns the FULL new log as the chunk with the new, smaller
    // length — the client must replace, not append.
    vi.mocked(api.getRunOutputDelta)
      .mockResolvedValueOnce({ running: true, length: 10, chunk: 'OLD-OUTPUT' })
      .mockResolvedValueOnce({ running: false, length: 3, chunk: 'new' })
      .mockResolvedValue({ running: false, length: 3, chunk: '' });

    const { result } = renderHook(() => useStreamMessage('s1'));
    act(() => {
      void result.current.send('hi');
    });

    await waitFor(() => expect(result.current.output).toContain('OLD-OUTPUT'));
    await waitFor(() => expect(result.current.output).toContain('new'), { timeout: 3000 });
    // Replaced, not appended: the pre-truncation tail is gone.
    expect(result.current.output).not.toContain('OLD-OUTPUT');
    // The second poll carried the offset from the first response's length.
    expect(api.getRunOutputDelta).toHaveBeenNthCalledWith(2, 's1', 10);
  });

  it('reattach polling prefers the delta endpoint, seeded from the probe output', async () => {
    // A run is already in progress: the mount probe (full-log endpoint)
    // returns its output-so-far; subsequent polls only fetch the delta.
    vi.mocked(api.getRunOutput).mockResolvedValue({ running: true, output: 'start' });
    vi.mocked(api.getRunOutputDelta)
      .mockResolvedValueOnce({ running: false, length: 10, chunk: '-more' })
      .mockResolvedValue({ running: false, length: 10, chunk: '' });

    const { result } = renderHook(() => useStreamMessage('s1'));

    await waitFor(() => expect(result.current.output).toBe('start'));
    await waitFor(() => expect(result.current.output).toBe('start-more'), { timeout: 3000 });

    // The first delta poll's offset is the probe output's length.
    expect(api.getRunOutputDelta).toHaveBeenCalledWith('s1', 5);
    // The full-log endpoint served only the initial probe.
    expect(api.getRunOutput).toHaveBeenCalledTimes(1);
    // The reattached run finished, so completion is signalled (#316).
    await waitFor(() => expect(result.current.reattachEnded).toBe(1));
    expect(result.current.isStreaming).toBe(false);
  });

  it('falls back to full-log polling when the delta endpoint throws (older backend)', async () => {
    vi.mocked(api.sendMessage).mockImplementation(() => new Promise(() => {}));
    vi.mocked(api.getRunOutput)
      .mockResolvedValueOnce({ running: false, output: '' }) // mount reattach probe
      .mockResolvedValue({ running: false, output: 'full log' });
    // An older backend 404s the /output/{offset} route.
    vi.mocked(api.getRunOutputDelta).mockRejectedValue(new Error('404 Not Found'));

    const { result } = renderHook(() => useStreamMessage('s1'));
    act(() => {
      void result.current.send('hi');
    });

    await waitFor(() => expect(result.current.output).toContain('full log'));
    // The delta endpoint was tried once, then permanently skipped for this run.
    expect(api.getRunOutputDelta).toHaveBeenCalledTimes(1);
  });
});
