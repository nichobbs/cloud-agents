import { describe, it, expect, beforeEach, vi } from 'vitest';
import { renderHook, waitFor, act } from '@testing-library/react';

vi.mock('../lib/api', () => ({
  api: { getLedger: vi.fn() },
}));

import { api } from '../lib/api';
import type { LedgerSnapshot } from '../lib/ledger';
import { useLedger } from './useLedger';

function snap(cursor: string): LedgerSnapshot {
  return {
    cursor,
    unchanged: 'false',
    full: 'true',
    summary: null as never,
    items: [],
    entries: [],
    feedback: [],
    policyStatus: '',
    policyError: '',
  };
}

describe('useLedger', () => {
  beforeEach(() => {
    vi.mocked(api.getLedger).mockReset();
  });

  it('re-polls when refresh() is called while a poll is in flight', async () => {
    let release: (s: LedgerSnapshot) => void = () => {};
    vi.mocked(api.getLedger)
      .mockImplementationOnce(() => new Promise(r => (release = r)))
      .mockResolvedValue(snap('5'));
    const { result } = renderHook(() => useLedger('s1', false));
    await waitFor(() => expect(api.getLedger).toHaveBeenCalledTimes(1));
    // The user acts while the first poll is still out: that refresh must not be dropped.
    act(() => void result.current.refresh());
    expect(api.getLedger).toHaveBeenCalledTimes(1);
    await act(async () => release(snap('4')));
    await waitFor(() => expect(api.getLedger).toHaveBeenCalledTimes(2));
    expect(api.getLedger).toHaveBeenLastCalledWith('s1', '4');
    await waitFor(() => expect(result.current.state.cursor).toBe('5'));
  });

  it('a new session polls at once even while the old one is in flight', async () => {
    vi.mocked(api.getLedger)
      .mockImplementationOnce(() => new Promise(() => {}))
      .mockResolvedValue(snap('2'));
    const { rerender, result } = renderHook(({ id }) => useLedger(id, false), { initialProps: { id: 's1' } });
    await waitFor(() => expect(api.getLedger).toHaveBeenCalledWith('s1', '0'));
    rerender({ id: 's2' });
    await waitFor(() => expect(api.getLedger).toHaveBeenCalledWith('s2', '0'));
    await waitFor(() => expect(result.current.state.cursor).toBe('2'));
  });
});
