import { afterEach, describe, it, expect, beforeEach, vi } from 'vitest';
import { renderHook, waitFor, act } from '@testing-library/react';

vi.mock('../lib/api', () => ({
  api: { getLedger: vi.fn() },
}));

import { api } from '../lib/api';
import type { LedgerSnapshot } from '../lib/ledger';
import { item as itemRow } from '../test/ledgerFixtures';
import { LEDGER_POLL_ACTIVE_MS, LEDGER_POLL_IDLE_MS, useLedger } from './useLedger';

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

  describe('cadence', () => {
    afterEach(() => {
      vi.useRealTimers();
      Object.defineProperty(document, 'visibilityState', { configurable: true, value: 'visible' });
    });

    it('polls every 3s while a run streams and every 10s otherwise', async () => {
      vi.useFakeTimers();
      vi.mocked(api.getLedger).mockResolvedValue(snap('1'));
      const { rerender } = renderHook(({ active }) => useLedger('s1', active), { initialProps: { active: true } });
      await vi.advanceTimersByTimeAsync(0);
      const afterMount = vi.mocked(api.getLedger).mock.calls.length;
      await vi.advanceTimersByTimeAsync(LEDGER_POLL_ACTIVE_MS * 2);
      expect(vi.mocked(api.getLedger).mock.calls.length).toBe(afterMount + 2);

      rerender({ active: false });
      await vi.advanceTimersByTimeAsync(0);
      const afterRunEnd = vi.mocked(api.getLedger).mock.calls.length;
      expect(afterRunEnd).toBe(afterMount + 3); // the catch-up poll when the run ended
      await vi.advanceTimersByTimeAsync(LEDGER_POLL_IDLE_MS - 1);
      expect(vi.mocked(api.getLedger).mock.calls.length).toBe(afterRunEnd);
      await vi.advanceTimersByTimeAsync(1);
      expect(vi.mocked(api.getLedger).mock.calls.length).toBe(afterRunEnd + 1);
    });

    it('skips polls while hidden and catches up when shown', async () => {
      vi.useFakeTimers();
      vi.mocked(api.getLedger).mockResolvedValue(snap('1'));
      renderHook(() => useLedger('s1', true));
      await vi.advanceTimersByTimeAsync(0);
      const before = vi.mocked(api.getLedger).mock.calls.length;
      Object.defineProperty(document, 'visibilityState', { configurable: true, value: 'hidden' });
      await vi.advanceTimersByTimeAsync(LEDGER_POLL_ACTIVE_MS * 3);
      expect(vi.mocked(api.getLedger).mock.calls.length).toBe(before);
      Object.defineProperty(document, 'visibilityState', { configurable: true, value: 'visible' });
      document.dispatchEvent(new Event('visibilitychange'));
      await vi.advanceTimersByTimeAsync(0);
      expect(vi.mocked(api.getLedger).mock.calls.length).toBe(before + 1);
    });

    it('stops polling on unmount', async () => {
      vi.useFakeTimers();
      vi.mocked(api.getLedger).mockResolvedValue(snap('1'));
      const { unmount } = renderHook(() => useLedger('s1', true));
      await vi.advanceTimersByTimeAsync(0);
      unmount();
      const calls = vi.mocked(api.getLedger).mock.calls.length;
      await vi.advanceTimersByTimeAsync(LEDGER_POLL_IDLE_MS * 3);
      document.dispatchEvent(new Event('visibilitychange'));
      expect(vi.mocked(api.getLedger).mock.calls.length).toBe(calls);
    });
  });

  it('merges deltas after the first full snapshot', async () => {
    vi.mocked(api.getLedger)
      .mockResolvedValueOnce({ ...snap('2'), items: [{ ...itemRow({ id: 'gh:a/b#1' }), state: 'queued' }] })
      .mockResolvedValue({ ...snap('3'), full: 'false', items: [{ ...itemRow({ id: 'gh:a/b#1' }), state: 'done' }] });
    const { result } = renderHook(() => useLedger('s1', false));
    await waitFor(() => expect(result.current.state.cursor).toBe('2'));
    act(() => void result.current.refresh());
    await waitFor(() => expect(result.current.state.cursor).toBe('3'));
    expect(api.getLedger).toHaveBeenLastCalledWith('s1', '2');
    expect(result.current.state.items.map(i => i.state)).toEqual(['done']);
  });
});
