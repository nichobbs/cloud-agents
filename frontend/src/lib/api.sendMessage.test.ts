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

  it('signals named event frames via onEvent without emitting chunks (#817)', async () => {
    const body =
      'event: todo_update\ndata: {"id":"t1","status":"done","note":"x"}\n\n' +
      'data: {"chunk":"out"}\n\n' +
      'event: progress_update\ndata: {"summary":"s","percentComplete":""}\n\n' +
      'event: done\ndata: {}\n\n';
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(sseResponse(body)));
    const chunks: string[] = [];
    const events: string[] = [];
    await api.sendMessage('s1', 'hi', c => chunks.push(c), undefined, e => events.push(e));
    expect(chunks).toEqual(['out']);
    expect(events).toEqual(['todo_update', 'progress_update']);
  });

  it('named event frames are harmless when no onEvent is provided', async () => {
    const body = 'event: todo_update\ndata: {"id":"t1"}\n\ndata: {"chunk":"out"}\n\nevent: done\ndata: {}\n\n';
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(sseResponse(body)));
    const chunks: string[] = [];
    await api.sendMessage('s1', 'hi', c => chunks.push(c));
    expect(chunks).toEqual(['out']);
  });

  it('includes staged attachments in the request body when provided', async () => {
    const fetchMock = vi.fn().mockResolvedValue(sseResponse('event: done\ndata: {}\n\n'));
    vi.stubGlobal('fetch', fetchMock);
    await api.sendMessage('s1', 'hi', () => {}, undefined, undefined, [
      { fileName: 'a.png', mimeType: 'image/png', contentBase64: 'AAAA' },
    ]);
    const init = fetchMock.mock.calls[0]?.[1] as RequestInit;
    const body = JSON.parse(init.body as string) as { text: string; attachments: unknown[] };
    expect(body.text).toBe('hi');
    expect(body.attachments).toEqual([{ fileName: 'a.png', mimeType: 'image/png', contentBase64: 'AAAA' }]);
  });

  it('sends an empty attachments array when none are provided (backward-compatible body shape)', async () => {
    const fetchMock = vi.fn().mockResolvedValue(sseResponse('event: done\ndata: {}\n\n'));
    vi.stubGlobal('fetch', fetchMock);
    await api.sendMessage('s1', 'hi', () => {});
    const init = fetchMock.mock.calls[0]?.[1] as RequestInit;
    const body = JSON.parse(init.body as string) as { attachments: unknown[] };
    expect(body.attachments).toEqual([]);
  });
});
