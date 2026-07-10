/// <reference types="vite/client" />

import type { Comment, Message, Prompt, Todo } from '../types';

const BASE = (import.meta.env['VITE_API_URL'] as string | undefined) ?? '';

function authHeaders(): HeadersInit {
  const token = localStorage.getItem('cloud_agents_token');
  return token ? { Authorization: `Bearer ${token}` } : {};
}

export const api = {
  /** Server-side session list (`GET /api/sessions`). `createdAt` is not part
   *  of the server record, so entries come back without it. */
  listSessions: async (): Promise<
    { sessionId: string; repoUrl: string; branch: string; harness?: string; model?: string }[]
  > => {
    const res = await fetch(`${BASE}/api/sessions`, { headers: authHeaders() });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as {
      sessions?: { sessionId: string; repoUrl: string; branch: string; harness?: string; model?: string }[];
    };
    return body.sessions ?? [];
  },

  createSession: async (body: { repoUrl: string; branch: string; harness: string; model: string }): Promise<{ sessionId: string }> => {
    const res = await fetch(`${BASE}/api/sessions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify(body),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    return res.json() as Promise<{ sessionId: string }>;
  },

  updateSessionModel: async (sessionId: string, model: string): Promise<void> => {
    const res = await fetch(`${BASE}/api/sessions/${sessionId}/model`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify({ model }),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },

  deleteSession: async (sessionId: string): Promise<void> => {
    const res = await fetch(`${BASE}/api/sessions/${sessionId}`, {
      method: 'DELETE',
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },

  sendMessage: async (
    sessionId: string,
    text: string,
    onChunk: (chunk: string) => void,
    onDone?: (messageId: string) => void,
  ): Promise<void> => {
    const res = await fetch(`${BASE}/api/sessions/${sessionId}/messages`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify({ text }),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    if (!res.body) return;

    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buffer = '';

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });

      let idx: number;
      while ((idx = buffer.indexOf('\n\n')) !== -1) {
        const frame = buffer.slice(0, idx);
        buffer = buffer.slice(idx + 2);

        let eventType = 'message';
        let dataStr = '';
        for (const line of frame.split('\n')) {
          if (line.startsWith('event:')) eventType = line.slice(6).trim();
          else if (line.startsWith('data:')) dataStr += line.slice(5).trim();
        }
        if (eventType === 'done') {
          if (onDone && dataStr) {
            try {
              const parsed = JSON.parse(dataStr) as { messageId?: string };
              if (parsed.messageId) onDone(parsed.messageId);
            } catch {
              // no message id in the done frame — fine
            }
          }
          return;
        }
        if (!dataStr) continue;
        try {
          const parsed = JSON.parse(dataStr) as { chunk?: string };
          if (parsed.chunk) onChunk(parsed.chunk);
        } catch {
          // ignore malformed frame
        }
      }
    }
  },

  /** Poll live output for an in-progress run (see useStreamMessage). The
   *  backend sends `running` as the string "true"/"false" (TEXT-only JSON
   *  records); normalise it to a boolean here. */
  getRunOutput: async (sessionId: string): Promise<{ running: boolean; output: string }> => {
    const res = await fetch(`${BASE}/api/sessions/${sessionId}/output`, { headers: authHeaders() });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as { running?: string; output?: string };
    return { running: body.running === 'true', output: body.output ?? '' };
  },

  // ─── Transcript ──────────────────────────────────────────────────────────────

  getMessages: async (sessionId: string): Promise<Message[]> => {
    const res = await fetch(`${BASE}/api/sessions/${sessionId}/messages`, {
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as { messages?: Message[] };
    return body.messages ?? [];
  },

  // ─── Comments ────────────────────────────────────────────────────────────────

  getComments: async (messageId: string): Promise<Comment[]> => {
    const res = await fetch(`${BASE}/api/messages/${messageId}/comments`, {
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as { comments?: Comment[] };
    return body.comments ?? [];
  },

  addComment: async (messageId: string, body: string): Promise<Comment> => {
    // No sessionId in the payload: the backend's AddCommentRequest doesn't
    // declare one — it derives the owning session from the stored message.
    const res = await fetch(`${BASE}/api/messages/${messageId}/comments`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify({ body }),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    return res.json() as Promise<Comment>;
  },

  // ─── Prompt library ──────────────────────────────────────────────────────────

  getPrompts: async (): Promise<Prompt[]> => {
    const res = await fetch(`${BASE}/api/prompts`, { headers: authHeaders() });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as { prompts?: Prompt[] };
    return body.prompts ?? [];
  },

  addPrompt: async (name: string, body: string): Promise<Prompt> => {
    const res = await fetch(`${BASE}/api/prompts`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify({ name, body }),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    return res.json() as Promise<Prompt>;
  },

  updatePrompt: async (promptId: string, name: string, body: string): Promise<Prompt> => {
    const res = await fetch(`${BASE}/api/prompts/${promptId}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify({ name, body }),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    return res.json() as Promise<Prompt>;
  },

  /** Best-effort usage bookkeeping; callers may fire-and-forget. */
  usePrompt: async (promptId: string): Promise<void> => {
    const res = await fetch(`${BASE}/api/prompts/${promptId}/use`, {
      method: 'POST',
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },

  deletePrompt: async (promptId: string): Promise<void> => {
    const res = await fetch(`${BASE}/api/prompts/${promptId}`, {
      method: 'DELETE',
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },

  // ─── Credentials (write-only: values are never read back) ─────────────────────

  getCredentialNames: async (): Promise<{ name: string; updatedAt: string }[]> => {
    const res = await fetch(`${BASE}/api/credentials`, { headers: authHeaders() });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as { credentials?: { name: string; updatedAt: string }[] };
    return body.credentials ?? [];
  },

  putCredential: async (name: string, value: string): Promise<void> => {
    const res = await fetch(`${BASE}/api/credentials`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify({ name, value }),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },

  deleteCredential: async (name: string): Promise<void> => {
    const res = await fetch(`${BASE}/api/credentials/${encodeURIComponent(name)}`, {
      method: 'DELETE',
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },

  // ─── Todos / bookmarks ───────────────────────────────────────────────────────

  getTodos: async (sessionId: string): Promise<Todo[]> => {
    const res = await fetch(`${BASE}/api/sessions/${sessionId}/todos`, {
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as { todos?: Todo[] };
    return body.todos ?? [];
  },

  addTodo: async (sessionId: string, messageId: string, note: string): Promise<Todo> => {
    const res = await fetch(`${BASE}/api/sessions/${sessionId}/todos`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify({ messageId, note }),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    return res.json() as Promise<Todo>;
  },

  toggleTodo: async (todoId: string): Promise<void> => {
    const res = await fetch(`${BASE}/api/todos/${todoId}/toggle`, {
      method: 'POST',
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },

  deleteTodo: async (todoId: string): Promise<void> => {
    const res = await fetch(`${BASE}/api/todos/${todoId}`, {
      method: 'DELETE',
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },
};
