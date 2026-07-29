import { describe, it, expect, vi, afterEach } from 'vitest';
import { api } from './api';

// Build a Response-like object whose body streams the given SSE text, so
// api.sendMessage's real frame parser is exercised (not a mock of it).
function sseResponse(frames: string): { ok: true; body: ReadableStream<Uint8Array> } {
  const enc = new TextEncoder();
  return {
    ok: true,
    body: new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(enc.encode(frames));
        controller.close();
      },
    }),
  };
}

afterEach(() => vi.unstubAllGlobals());

describe('api.sendMessage SSE parsing', () => {
  it('delivers chunks then resolves and calls onDone on a done frame', async () => {
    const body = 'data: {"chunk":"out"}\n\nevent: done\ndata: {"messageId":"m1"}\n\n';
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(sseResponse(body)));
    const chunks: string[] = [];
    let doneId = '';
    await api.sendMessage('s1', 'hi', c => chunks.push(c), id => { doneId = id; });
    expect(chunks).toEqual(['out']);
    expect(doneId).toBe('m1');
  });

  it('throws with the error message on an event: error frame (#485)', async () => {
    // A chunk arrives, THEN the run fails mid-stream after 200 was committed.
    const body = 'data: {"chunk":"working"}\n\nevent: error\ndata: {"error":"boom"}\n\n';
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(sseResponse(body)));
    const chunks: string[] = [];
    await expect(api.sendMessage('s1', 'hi', c => chunks.push(c))).rejects.toThrow('boom');
    // Output produced before the failure was still delivered.
    expect(chunks).toEqual(['working']);
  });

  it('falls back to a generic message when the error frame has no JSON error', async () => {
    const body = 'event: error\ndata: not-json\n\n';
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(sseResponse(body)));
    await expect(api.sendMessage('s1', 'hi', () => {})).rejects.toThrow('run failed');
  });

  it('ignores keepalive comment frames interleaved with chunks (#499)', async () => {
    // The backend emits `: keepalive\n\n` comment frames during quiet stretches
    // to detect a vanished client. They carry no data line, so the parser must
    // skip them without emitting a chunk or ending the stream.
    const body =
      ': keepalive\n\ndata: {"chunk":"out"}\n\n: keepalive\n\nevent: done\ndata: {}\n\n';
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(sseResponse(body)));
    const chunks: string[] = [];
    await api.sendMessage('s1', 'hi', c => chunks.push(c));
    expect(chunks).toEqual(['out']);
  });
});
