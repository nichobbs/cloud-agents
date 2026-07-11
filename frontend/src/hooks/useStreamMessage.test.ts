import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { renderHook, waitFor } from '@testing-library/react';

vi.mock('../lib/api', () => ({
  api: {
    getRunOutput: vi.fn(),
    sendMessage: vi.fn(),
  },
}));

import { api } from '../lib/api';
import { useStreamMessage } from './useStreamMessage';

describe('useStreamMessage reattachment (#217)', () => {
  beforeEach(() => {
    vi.mocked(api.getRunOutput).mockReset();
  });
  afterEach(() => {
    vi.clearAllMocks();
  });

  it('reattaches to an in-progress run on mount and shows its output', async () => {
    // A run is already running for this session (started elsewhere / before a
    // reload), so getRunOutput reports running with partial output.
    vi.mocked(api.getRunOutput).mockResolvedValue({ running: true, output: 'in-progress output' });

    const { result } = renderHook(() => useStreamMessage('s1'));

    // Without send() driving anything, the mount effect still surfaces the
    // in-flight run.
    await waitFor(() => {
      expect(result.current.isStreaming).toBe(true);
      expect(result.current.output).toBe('in-progress output');
    });
    expect(api.getRunOutput).toHaveBeenCalledWith('s1');
  });

  it('does not attach when no run is in progress', async () => {
    vi.mocked(api.getRunOutput).mockResolvedValue({ running: false, output: '' });

    const { result } = renderHook(() => useStreamMessage('s1'));

    // Give the mount fetch time to resolve, then confirm it stayed idle.
    await new Promise(r => setTimeout(r, 25));
    expect(result.current.isStreaming).toBe(false);
    expect(result.current.output).toBe('');
  });
});
