/// <reference types="vite/client" />

import type { Comment, Credential, Message, Profile, Prompt, Run, Todo, Webhook } from '../types';

const BASE = (import.meta.env['VITE_API_URL'] as string | undefined) ?? '';

/** One entry of GET /api/sessions. */
export interface ServerSession {
  sessionId: string;
  repoUrl: string;
  branch: string;
  harness?: string;
  model?: string;
  status?: string;
  createdAt?: string;
  lastMessageAt?: string;
}

function authHeaders(): HeadersInit {
  const token = localStorage.getItem('cloud_agents_token');
  return token ? { Authorization: `Bearer ${token}` } : {};
}

/** Ensure `tags` is always an array (older responses may omit it). */
function normalisePrompt(p: Prompt): Prompt {
  return { ...p, tags: p.tags ?? [] };
}

export const api = {
  // ─── GitHub OAuth ───────────────────────────────────────────────────────────

  /** Whether the server has a GitHub OAuth app configured, and its client id. */
  getAuthConfig: async (): Promise<{ configured: boolean; clientId: string }> => {
    const res = await fetch(`${BASE}/api/auth/github/config`);
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as { configured?: string; clientId?: string };
    return { configured: body.configured === 'true', clientId: body.clientId ?? '' };
  },

  /** Swap the OAuth callback code for the user's token (+ identity). */
  exchangeCode: async (code: string): Promise<{ token: string; login: string; userId: string }> => {
    const res = await fetch(`${BASE}/api/auth/github/exchange`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ code }),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    return res.json() as Promise<{ token: string; login: string; userId: string }>;
  },

  /** Server-side session list (`GET /api/sessions`). Newer backends include
   *  status/createdAt/lastMessageAt (epoch-millis strings); older ones omit
   *  them, so all are optional here. */
  listSessions: async (): Promise<ServerSession[]> => {
    const res = await fetch(`${BASE}/api/sessions`, { headers: authHeaders() });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as { sessions?: ServerSession[] };
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

  /** The profile currently attached to a session ('' when none). */
  getSessionProfile: async (sessionId: string): Promise<string> => {
    const res = await fetch(`${BASE}/api/sessions/${sessionId}/profile`, { headers: authHeaders() });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as { profileId?: string };
    return body.profileId ?? '';
  },

  /** Attach a profile to a session (empty string clears it). */
  setSessionProfile: async (sessionId: string, profileId: string): Promise<void> => {
    const res = await fetch(`${BASE}/api/sessions/${sessionId}/profile`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify({ profileId }),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },

  /** Cancel an in-flight run (terminates its container). 409 if nothing is running. */
  cancelRun: async (sessionId: string): Promise<void> => {
    const res = await fetch(`${BASE}/api/sessions/${sessionId}/cancel`, {
      method: 'POST',
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },

  /** A session's run history, newest first. */
  getRuns: async (sessionId: string): Promise<Run[]> => {
    const res = await fetch(`${BASE}/api/sessions/${sessionId}/runs`, { headers: authHeaders() });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as { runs?: Run[] };
    return body.runs ?? [];
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
    return (body.prompts ?? []).map(normalisePrompt);
  },

  /** Prompts ordered most-used first (`GET /api/prompts/popular`). */
  getPopularPrompts: async (): Promise<Prompt[]> => {
    const res = await fetch(`${BASE}/api/prompts/popular`, { headers: authHeaders() });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as { prompts?: Prompt[] };
    return (body.prompts ?? []).map(normalisePrompt);
  },

  /** Prompts carrying a given tag (`GET /api/prompts/tag/{tag}`). */
  getPromptsByTag: async (tag: string): Promise<Prompt[]> => {
    const res = await fetch(`${BASE}/api/prompts/tag/${encodeURIComponent(tag)}`, { headers: authHeaders() });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as { prompts?: Prompt[] };
    return (body.prompts ?? []).map(normalisePrompt);
  },

  addPrompt: async (name: string, body: string, tags: string[] = []): Promise<Prompt> => {
    const res = await fetch(`${BASE}/api/prompts`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify({ name, body, tags }),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    return normalisePrompt((await res.json()) as Prompt);
  },

  updatePrompt: async (promptId: string, name: string, body: string, tags: string[] = []): Promise<Prompt> => {
    const res = await fetch(`${BASE}/api/prompts/${promptId}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify({ name, body, tags }),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    return normalisePrompt((await res.json()) as Prompt);
  },

  /** Render a prompt's `{{var}}` placeholders and return the result. Counts as
   *  a use. `vars` is a flat key→value map. */
  renderPrompt: async (promptId: string, vars: Record<string, string>): Promise<string> => {
    const keys = Object.keys(vars);
    const values = keys.map(k => vars[k] ?? '');
    const res = await fetch(`${BASE}/api/prompts/${promptId}/render`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify({ keys, values }),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const out = (await res.json()) as { rendered?: string };
    return out.rendered ?? '';
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

  getCredentialNames: async (): Promise<Credential[]> => {
    const res = await fetch(`${BASE}/api/credentials`, { headers: authHeaders() });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as { credentials?: Credential[] };
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

  // ─── Profiles (per-container policy: creds, harness, network) ──────────────────

  getProfiles: async (): Promise<Profile[]> => {
    const res = await fetch(`${BASE}/api/profiles`, { headers: authHeaders() });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as { profiles?: Profile[] };
    return (body.profiles ?? []).map(normaliseProfile);
  },

  addProfile: async (p: {
    name: string;
    harness: string;
    networkPolicy: string;
    credentialMode: string;
    credentials: string[];
  }): Promise<Profile> => {
    const res = await fetch(`${BASE}/api/profiles`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify(p),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    return normaliseProfile((await res.json()) as Profile);
  },

  updateProfile: async (
    profileId: string,
    p: { name: string; harness: string; networkPolicy: string; credentialMode: string; credentials: string[] },
  ): Promise<Profile> => {
    const res = await fetch(`${BASE}/api/profiles/${profileId}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify(p),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    return normaliseProfile((await res.json()) as Profile);
  },

  deleteProfile: async (profileId: string): Promise<void> => {
    const res = await fetch(`${BASE}/api/profiles/${profileId}`, {
      method: 'DELETE',
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },

  // ─── Webhooks (run-completion notifications) ──────────────────────────────────

  getWebhooks: async (): Promise<Webhook[]> => {
    const res = await fetch(`${BASE}/api/webhooks`, { headers: authHeaders() });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as { webhooks?: Webhook[] };
    return body.webhooks ?? [];
  },

  registerWebhook: async (url: string): Promise<Webhook> => {
    const res = await fetch(`${BASE}/api/webhooks`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify({ url }),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    return res.json() as Promise<Webhook>;
  },

  deleteWebhook: async (webhookId: string): Promise<void> => {
    const res = await fetch(`${BASE}/api/webhooks/${webhookId}`, {
      method: 'DELETE',
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },
};

/** Ensure a profile's optional array fields are always arrays. */
function normaliseProfile(p: Profile): Profile {
  return { ...p, credentials: p.credentials ?? [] };
}
