/// <reference types="vite/client" />

import type { Comment, Credential, Highlight, McpServer, Message, PendingCallbacksResponse, Profile, Prompt, RefreshHighlightsResult, Run, Skill, Subagent, Todo, Webhook } from '../types';
import { completeLogin, isSignedIn, setReturnPath, signOut } from './auth';

const BASE = (import.meta.env['VITE_API_URL'] as string | undefined) ?? '';

/** One repository linked to a session (multi-repo sessions). `branch` is '' for
 *  the repo's default branch. */
export interface SessionRepo {
  id: string;
  repoUrl: string;
  branch: string;
}

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
  isArchived?: string;
}

function authHeaders(): HeadersInit {
  const token = localStorage.getItem('cloud_agents_token');
  return token ? { Authorization: `Bearer ${token}` } : {};
}

let refreshPromise: Promise<string | null> | null = null;

/** Central fetch wrapper for API endpoints: intercepts HTTP 401 status when
 *  signed in, attempts transparent token refresh (queuing concurrent 401s behind
 *  one in-flight refresh), and redirects to /login on failure. */
export async function apiFetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
  const res = await fetch(input, init);

  if (res.status === 401 && isSignedIn()) {
    const urlStr = typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url;
    if (
      urlStr.includes('/api/auth/github/config') ||
      urlStr.includes('/api/auth/github/exchange') ||
      urlStr.includes('/api/auth/github/logout') ||
      urlStr.includes('/api/auth/github/refresh')
    ) {
      return res;
    }

    if (!refreshPromise) {
      refreshPromise = (async () => {
        try {
          const grant = await api.refreshToken();
          if (grant && grant.token) {
            completeLogin(grant.token, grant.login || localStorage.getItem('cloud_agents_login') || '');
            return grant.token;
          }
        } catch {
          /* refresh failed */
        }
        return null;
      })();
    }

    const freshToken = await refreshPromise;
    refreshPromise = null;

    if (freshToken) {
      const newInit: RequestInit = { ...init };
      const headers = new Headers(init?.headers);
      headers.set('Authorization', `Bearer ${freshToken}`);
      newInit.headers = headers;

      return await fetch(input, newInit);
    }

    if (typeof window !== 'undefined' && window.location) {
      setReturnPath(window.location.pathname + window.location.search);
    }
    signOut();
  }

  return res;
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

  /** Proactively or reactively refresh the user's GitHub OAuth token. */
  refreshToken: async (): Promise<{ token: string; login: string; userId: string }> => {
    const res = await fetch(`${BASE}/api/auth/github/refresh`, {
      method: 'POST',
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    return res.json() as Promise<{ token: string; login: string; userId: string }>;
  },

  /** Server-side sign-out: invalidate the presented bearer's validation-cache
   *  row so its next presentation must revalidate live. Throws on failure —
   *  the caller (lib/auth signOut) treats it as best-effort. */
  logout: async (): Promise<void> => {
    const res = await fetch(`${BASE}/api/auth/github/logout`, {
      method: 'POST',
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },

  /** Server-side session list (`GET /api/sessions`). Newer backends include
   *  status/createdAt/lastMessageAt (epoch-millis strings); older ones omit
   *  them, so all are optional here. */
  listSessions: async (): Promise<ServerSession[]> => {
    const res = await apiFetch(`${BASE}/api/sessions`, { headers: authHeaders() });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as { sessions?: ServerSession[] };
    return body.sessions ?? [];
  },

  createSession: async (body: { repoUrl: string; branch: string; harness: string; model: string }): Promise<{ sessionId: string }> => {
    const res = await apiFetch(`${BASE}/api/sessions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify(body),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    return res.json() as Promise<{ sessionId: string }>;
  },

  updateSessionModel: async (sessionId: string, model: string): Promise<void> => {
    const res = await apiFetch(`${BASE}/api/sessions/${sessionId}/model`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify({ model }),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },

  deleteSession: async (sessionId: string): Promise<void> => {
    const res = await apiFetch(`${BASE}/api/sessions/${sessionId}`, {
      method: 'DELETE',
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },

  archiveSession: async (sessionId: string): Promise<void> => {
    const res = await apiFetch(`${BASE}/api/sessions/${sessionId}/archive`, {
      method: 'POST',
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },

  unarchiveSession: async (sessionId: string): Promise<void> => {
    const res = await apiFetch(`${BASE}/api/sessions/${sessionId}/unarchive`, {
      method: 'POST',
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },

  // ─── Linked repositories (multi-repo sessions) ───────────────────────────────

  /** Repositories linked to a session beyond its primary repo. Newer backends
   *  only — an older one 404s these routes; callers treat a failure as "feature
   *  unavailable" and hide the panel. */
  listSessionRepos: async (sessionId: string): Promise<SessionRepo[]> => {
    const res = await apiFetch(`${BASE}/api/sessions/${sessionId}/repos`, { headers: authHeaders() });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as { repos?: SessionRepo[] };
    return body.repos ?? [];
  },

  /** Link another repository to a session. `branch` may be '' (the repo's
   *  default branch). Throws with the backend's message on invalid input,
   *  duplicate, or over the per-session cap. */
  addSessionRepo: async (sessionId: string, repoUrl: string, branch: string): Promise<SessionRepo> => {
    const res = await apiFetch(`${BASE}/api/sessions/${sessionId}/repos`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify({ repoUrl, branch }),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    return res.json() as Promise<SessionRepo>;
  },

  /** Unlink a repository from a session. */
  removeSessionRepo: async (sessionId: string, repoId: string): Promise<void> => {
    const res = await apiFetch(`${BASE}/api/sessions/${sessionId}/repos/${repoId}`, {
      method: 'DELETE',
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },

  /** The profile currently attached to a session ('' when none). */
  getSessionProfile: async (sessionId: string): Promise<string> => {
    const res = await apiFetch(`${BASE}/api/sessions/${sessionId}/profile`, { headers: authHeaders() });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as { profileId?: string };
    return body.profileId ?? '';
  },

  /** Attach a profile to a session (empty string clears it). */
  setSessionProfile: async (sessionId: string, profileId: string): Promise<void> => {
    const res = await apiFetch(`${BASE}/api/sessions/${sessionId}/profile`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify({ profileId }),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },

  /** Cancel an in-flight run (terminates its container). 409 if nothing is running. */
  cancelRun: async (sessionId: string): Promise<void> => {
    const res = await apiFetch(`${BASE}/api/sessions/${sessionId}/cancel`, {
      method: 'POST',
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },

  /** Restart the session's container (terminates any running container and resets status to IDLE). */
  restartContainer: async (sessionId: string): Promise<void> => {
    const res = await apiFetch(`${BASE}/api/sessions/${sessionId}/restart`, {
      method: 'POST',
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },

  /** A session's run history, newest first. */
  getRuns: async (sessionId: string): Promise<Run[]> => {
    const res = await apiFetch(`${BASE}/api/sessions/${sessionId}/runs`, { headers: authHeaders() });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as { runs?: Run[] };
    return body.runs ?? [];
  },

  sendMessage: async (
    sessionId: string,
    text: string,
    onChunk: (chunk: string) => void,
    onDone?: (messageId: string) => void,
    /** Called for every named event frame other than done/error (e.g.
     *  `todo_update`, `progress_update`), so panels can refresh push-style
     *  instead of waiting for their next poll. */
    onEvent?: (eventType: string) => void,
  ): Promise<void> => {
    const res = await apiFetch(`${BASE}/api/sessions/${sessionId}/messages`, {
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
        if (eventType === 'error') {
          // The backend committed 200 then the run failed mid-stream, so the
          // failure arrives in-band as an `event: error` frame (#485). Throw so
          // the caller (useStreamMessage) marks the send failed — surfacing the
          // error banner and NOT folding the run into the transcript as done.
          let msg = 'run failed';
          try {
            const parsed = JSON.parse(dataStr) as { error?: string };
            if (parsed.error) msg = parsed.error;
          } catch {
            // non-JSON error payload — keep the generic message
          }
          throw new Error(msg);
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
        if (eventType !== 'message') {
          // A supplementary named event (todo_update, permission_request,
          // progress_update, …) — its data is not a chunk; just signal it.
          onEvent?.(eventType);
          continue;
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
    const res = await apiFetch(`${BASE}/api/sessions/${sessionId}/output`, { headers: authHeaders() });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as { running?: string; output?: string };
    return { running: body.running === 'true', output: body.output ?? '' };
  },

  /** Incremental live output: only the log bytes past `offset` travel, so a
   *  long run's polling cost is proportional to new output rather than the
   *  whole accumulated log each tick. `length` is the server's current total
   *  log length — feed it back as the next offset. A `length` below the
   *  offset you sent means the log was truncated/replaced (new run) and
   *  `chunk` is the full new log: replace your accumulated output (resync).
   *  Newer backends only — callers fall back to getRunOutput when this
   *  throws (e.g. a 404 route miss on an older backend). Values arrive as
   *  strings (TEXT-only hand-built JSON, like getRunOutput's `running`) and
   *  are normalised here. */
  getRunOutputDelta: async (
    sessionId: string,
    offset: number,
  ): Promise<{ running: boolean; length: number; chunk: string }> => {
    const res = await apiFetch(`${BASE}/api/sessions/${sessionId}/output/${offset}`, {
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as { running?: string; length?: string; chunk?: string };
    const total = Number(body.length ?? '0');
    return {
      running: body.running === 'true',
      length: Number.isFinite(total) ? total : 0,
      chunk: body.chunk ?? '',
    };
  },

  // ─── Transcript ──────────────────────────────────────────────────────────────

  getMessages: async (sessionId: string): Promise<Message[]> => {
    const res = await apiFetch(`${BASE}/api/sessions/${sessionId}/messages`, {
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as { messages?: Message[] };
    return body.messages ?? [];
  },

  /** Full-text search across every message in the caller's own sessions
   *  (`GET /api/search/messages?q=...`), newest first. */
  searchMessages: async (term: string): Promise<Message[]> => {
    const res = await apiFetch(`${BASE}/api/search/messages?q=${encodeURIComponent(term)}`, {
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as { messages?: Message[] };
    return body.messages ?? [];
  },

  // ─── Comments ────────────────────────────────────────────────────────────────

  getComments: async (messageId: string): Promise<Comment[]> => {
    const res = await apiFetch(`${BASE}/api/messages/${messageId}/comments`, {
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as { comments?: Comment[] };
    return body.comments ?? [];
  },

  addComment: async (messageId: string, body: string): Promise<Comment> => {
    // No sessionId in the payload: the backend's AddCommentRequest doesn't
    // declare one — it derives the owning session from the stored message.
    const res = await apiFetch(`${BASE}/api/messages/${messageId}/comments`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify({ body }),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    return res.json() as Promise<Comment>;
  },

  // ─── Prompt library ──────────────────────────────────────────────────────────

  getPrompts: async (): Promise<Prompt[]> => {
    const res = await apiFetch(`${BASE}/api/prompts`, { headers: authHeaders() });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as { prompts?: Prompt[] };
    return (body.prompts ?? []).map(normalisePrompt);
  },

  /** Prompts ordered most-used first (`GET /api/prompts/popular`). */
  getPopularPrompts: async (): Promise<Prompt[]> => {
    const res = await apiFetch(`${BASE}/api/prompts/popular`, { headers: authHeaders() });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as { prompts?: Prompt[] };
    return (body.prompts ?? []).map(normalisePrompt);
  },

  /** Prompts carrying a given tag (`GET /api/prompts/tag/{tag}`). */
  getPromptsByTag: async (tag: string): Promise<Prompt[]> => {
    const res = await apiFetch(`${BASE}/api/prompts/tag/${encodeURIComponent(tag)}`, { headers: authHeaders() });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as { prompts?: Prompt[] };
    return (body.prompts ?? []).map(normalisePrompt);
  },

  addPrompt: async (name: string, body: string, tags: string[] = []): Promise<Prompt> => {
    const res = await apiFetch(`${BASE}/api/prompts`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify({ name, body, tags }),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    return normalisePrompt((await res.json()) as Prompt);
  },

  updatePrompt: async (promptId: string, name: string, body: string, tags: string[] = []): Promise<Prompt> => {
    const res = await apiFetch(`${BASE}/api/prompts/${promptId}`, {
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
    const res = await apiFetch(`${BASE}/api/prompts/${promptId}/render`, {
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
    const res = await apiFetch(`${BASE}/api/prompts/${promptId}/use`, {
      method: 'POST',
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },

  deletePrompt: async (promptId: string): Promise<void> => {
    const res = await apiFetch(`${BASE}/api/prompts/${promptId}`, {
      method: 'DELETE',
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },

  // ─── Credentials (write-only: values are never read back) ─────────────────────

  getCredentialNames: async (): Promise<Credential[]> => {
    const res = await apiFetch(`${BASE}/api/credentials`, { headers: authHeaders() });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as { credentials?: Credential[] };
    return body.credentials ?? [];
  },

  putCredential: async (name: string, value: string): Promise<void> => {
    const res = await apiFetch(`${BASE}/api/credentials`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify({ name, value }),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },

  deleteCredential: async (name: string): Promise<void> => {
    const res = await apiFetch(`${BASE}/api/credentials/${encodeURIComponent(name)}`, {
      method: 'DELETE',
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },

  // ─── Todos / bookmarks ───────────────────────────────────────────────────────

  getTodos: async (sessionId: string): Promise<Todo[]> => {
    const res = await apiFetch(`${BASE}/api/sessions/${sessionId}/todos`, {
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as { todos?: Todo[] };
    return body.todos ?? [];
  },

  addTodo: async (sessionId: string, messageId: string, note: string): Promise<Todo> => {
    const res = await apiFetch(`${BASE}/api/sessions/${sessionId}/todos`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify({ messageId, note }),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    return res.json() as Promise<Todo>;
  },

  toggleTodo: async (todoId: string): Promise<void> => {
    const res = await apiFetch(`${BASE}/api/todos/${todoId}/toggle`, {
      method: 'POST',
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },

  deleteTodo: async (todoId: string): Promise<void> => {
    const res = await apiFetch(`${BASE}/api/todos/${todoId}`, {
      method: 'DELETE',
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },

  setTodoStatus: async (todoId: string, status: 'pending' | 'in_progress' | 'done'): Promise<void> => {
    const res = await apiFetch(`${BASE}/api/todos/${todoId}/status`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify({ status }),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },

  // ─── Session highlights (summarizer-extracted notable items) ────────────────

  getHighlights: async (sessionId: string): Promise<Highlight[]> => {
    const res = await apiFetch(`${BASE}/api/sessions/${sessionId}/highlights`, {
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as { highlights?: Highlight[] };
    return body.highlights ?? [];
  },

  refreshHighlights: async (sessionId: string): Promise<RefreshHighlightsResult> => {
    const res = await apiFetch(`${BASE}/api/sessions/${sessionId}/highlights/refresh`, {
      method: 'POST',
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    return res.json() as Promise<RefreshHighlightsResult>;
  },

  // ─── Profiles (per-container policy: creds, harness, network) ──────────────────

  getProfiles: async (): Promise<Profile[]> => {
    const res = await apiFetch(`${BASE}/api/profiles`, { headers: authHeaders() });
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
    skillIds: string[];
    subagentIds: string[];
    mcpServerIds: string[];
    toolMode: string;
    tools: string[];
  }): Promise<Profile> => {
    const res = await apiFetch(`${BASE}/api/profiles`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify(p),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    return normaliseProfile((await res.json()) as Profile);
  },

  updateProfile: async (
    profileId: string,
    p: {
      name: string;
      harness: string;
      networkPolicy: string;
      credentialMode: string;
      credentials: string[];
      skillIds: string[];
      subagentIds: string[];
      mcpServerIds: string[];
      toolMode: string;
      tools: string[];
    },
  ): Promise<Profile> => {
    const res = await apiFetch(`${BASE}/api/profiles/${profileId}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify(p),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    return normaliseProfile((await res.json()) as Profile);
  },

  deleteProfile: async (profileId: string): Promise<void> => {
    const res = await apiFetch(`${BASE}/api/profiles/${profileId}`, {
      method: 'DELETE',
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },

  // ─── Library (skills, subagents, MCP servers a profile can grant) ─────────────

  getSkills: async (): Promise<Skill[]> => {
    const res = await apiFetch(`${BASE}/api/library/skills`, { headers: authHeaders() });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as { skills?: Skill[] };
    return body.skills ?? [];
  },

  addSkill: async (s: { name: string; description: string; body: string }): Promise<Skill> => {
    const res = await apiFetch(`${BASE}/api/library/skills`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify(s),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    return res.json() as Promise<Skill>;
  },

  updateSkill: async (id: string, s: { name: string; description: string; body: string }): Promise<Skill> => {
    const res = await apiFetch(`${BASE}/api/library/skills/${id}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify(s),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    return res.json() as Promise<Skill>;
  },

  deleteSkill: async (id: string): Promise<void> => {
    const res = await apiFetch(`${BASE}/api/library/skills/${id}`, { method: 'DELETE', headers: authHeaders() });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },

  getSubagents: async (): Promise<Subagent[]> => {
    const res = await apiFetch(`${BASE}/api/library/subagents`, { headers: authHeaders() });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as { subagents?: Subagent[] };
    return body.subagents ?? [];
  },

  addSubagent: async (s: { name: string; description: string; systemPrompt: string; model: string }): Promise<Subagent> => {
    const res = await apiFetch(`${BASE}/api/library/subagents`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify(s),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    return res.json() as Promise<Subagent>;
  },

  updateSubagent: async (
    id: string,
    s: { name: string; description: string; systemPrompt: string; model: string },
  ): Promise<Subagent> => {
    const res = await apiFetch(`${BASE}/api/library/subagents/${id}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify(s),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    return res.json() as Promise<Subagent>;
  },

  deleteSubagent: async (id: string): Promise<void> => {
    const res = await apiFetch(`${BASE}/api/library/subagents/${id}`, { method: 'DELETE', headers: authHeaders() });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },

  getMcpServers: async (): Promise<McpServer[]> => {
    const res = await apiFetch(`${BASE}/api/library/mcp-servers`, { headers: authHeaders() });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as { mcpServers?: McpServer[] };
    return body.mcpServers ?? [];
  },

  addMcpServer: async (
    s: { name: string; transport: string; command: string; args: string[]; url: string; env: string[]; enabled?: string },
  ): Promise<McpServer> => {
    const res = await apiFetch(`${BASE}/api/library/mcp-servers`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify(s),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    return res.json() as Promise<McpServer>;
  },

  updateMcpServer: async (
    id: string,
    s: { name: string; transport: string; command: string; args: string[]; url: string; env: string[]; enabled?: string },
  ): Promise<McpServer> => {
    const res = await apiFetch(`${BASE}/api/library/mcp-servers/${id}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify(s),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    return res.json() as Promise<McpServer>;
  },

  deleteMcpServer: async (id: string): Promise<void> => {
    const res = await apiFetch(`${BASE}/api/library/mcp-servers/${id}`, { method: 'DELETE', headers: authHeaders() });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },

  // ─── Webhooks (run-completion notifications) ──────────────────────────────────

  getWebhooks: async (): Promise<Webhook[]> => {
    const res = await apiFetch(`${BASE}/api/webhooks`, { headers: authHeaders() });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as { webhooks?: Webhook[] };
    return body.webhooks ?? [];
  },

  registerWebhook: async (url: string): Promise<Webhook> => {
    const res = await apiFetch(`${BASE}/api/webhooks`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify({ url }),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    return res.json() as Promise<Webhook>;
  },

  deleteWebhook: async (webhookId: string): Promise<void> => {
    const res = await apiFetch(`${BASE}/api/webhooks/${webhookId}`, {
      method: 'DELETE',
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },

  // ─── Human-in-the-loop pending callbacks (Phase 6) ───────────────────────────

  /** List of all pending callback requests (permissions, questions, secrets) */
  getPendingCallbacks: async (sessionId: string): Promise<PendingCallbacksResponse> => {
    const res = await apiFetch(`${BASE}/api/sessions/${sessionId}/callbacks/pending`, {
      headers: authHeaders(),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const body = (await res.json()) as PendingCallbacksResponse;
    return {
      permissionRequests: body.permissionRequests ?? [],
      userQuestions: body.userQuestions ?? [],
      secretRequests: body.secretRequests ?? [],
    };
  },

  /** Approve, deny, or allow-always a tool permission request */
  answerPermissionRequest: async (
    sessionId: string,
    requestId: string,
    body: { decision: 'allow' | 'deny' | 'allow_always'; note: string; updatedInputJson: string },
  ): Promise<void> => {
    const res = await apiFetch(`${BASE}/api/sessions/${sessionId}/callbacks/permission/${requestId}/answer`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify(body),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },

  /** Submit an answer to an agent's question */
  answerUserQuestion: async (
    sessionId: string,
    requestId: string,
    answer: string,
  ): Promise<void> => {
    const res = await apiFetch(`${BASE}/api/sessions/${sessionId}/callbacks/question/${requestId}/answer`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify({ answer }),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },

  /** Approve or deny a secret request */
  answerSecretRequest: async (
    sessionId: string,
    requestId: string,
    decision: 'allow' | 'deny',
  ): Promise<void> => {
    const res = await apiFetch(`${BASE}/api/sessions/${sessionId}/callbacks/secret/${requestId}/answer`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders() },
      body: JSON.stringify({ decision }),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  },

  // ─── Harness availability (#523) ───────────────────────────────────────────

  /** Which harnesses have a runner image on this deployment, or null when
   *  the backend doesn't report it (older backend, network failure) — the
   *  caller should treat null as "unknown" and fail open (show everything). */
  getEnabledHarnesses: async (): Promise<string[] | null> => {
    try {
      const res = await apiFetch(`${BASE}/api/harnesses`, { headers: authHeaders() });
      if (!res.ok) return null;
      const body = (await res.json()) as { enabled?: string[] };
      return body.enabled ?? null;
    } catch {
      return null;
    }
  },

  /** Send a key to the backend models validator proxy to verify it and retrieve
   *  the live models listing without CORS issues. */
  validateModelKey: async (provider: string, key: string): Promise<{ provider: string; body: string }> => {
    return proxyPost<{ provider: string; body: string }>('/api/models/validate', { provider, key });
  },
};

/** Ensure a profile's optional array fields are always arrays.
 *  Defaults for toolMode/tools cover a pre-#614 backend whose Profile
 *  response predates per-profile tool enablement. */
function normaliseProfile(p: Profile): Profile {
  return {
    ...p,
    credentials: p.credentials ?? [],
    skillIds: p.skillIds ?? [],
    subagentIds: p.subagentIds ?? [],
    mcpServerIds: p.mcpServerIds ?? [],
    toolMode: p.toolMode ?? 'all',
    tools: p.tools ?? [],
  };
}

// ─── Server-side provider proxies (ADR-006) ───────────────────────────────────
//
// The backend calls GitHub / model-provider APIs with credential-vault keys
// and passes each provider's raw JSON through untouched, so the browser needs
// no locally-held key. 404 means "no key in the vault" (or an older backend
// without these routes) — callers fall back to the direct browser-side path.

async function proxyGet<T>(path: string): Promise<T> {
  const res = await apiFetch(`${BASE}${path}`, { headers: authHeaders() });
  if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  return res.json() as Promise<T>;
}

async function proxyPost<T>(path: string, body: unknown): Promise<T> {
  const res = await apiFetch(`${BASE}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...authHeaders() },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  return res.json() as Promise<T>;
}

/** One page (100 repos) of the vault token's accessible repositories — GitHub's raw JSON. */
export function proxyGithubRepos<T = unknown>(page: number): Promise<T> {
  return proxyGet<T>(`/api/github/repos/${page}`);
}

/** A single repository — GitHub's raw JSON. */
export function proxyGithubRepo<T = unknown>(owner: string, repo: string): Promise<T> {
  return proxyGet<T>(`/api/github/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}`);
}

/** Open PRs whose head is owner:branch — GitHub's raw JSON. Branches with '/'
 *  don't fit the single path segment; callers fall back to the direct path. */
export function proxyGithubPulls<T = unknown>(owner: string, repo: string, branch: string): Promise<T> {
  return proxyGet<T>(
    `/api/github/pulls/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/${encodeURIComponent(branch)}`,
  );
}

/** Check runs for the tip of a branch — GitHub's raw check-runs payload. */
export function proxyGithubChecks<T = unknown>(owner: string, repo: string, branch: string): Promise<T> {
  return proxyGet<T>(
    `/api/github/checks/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/${encodeURIComponent(branch)}`,
  );
}

/** Raw model listings from every provider the vault has a key for, one
 *  JSON-string body per provider — the caller parses each with its existing
 *  per-provider filter functions. */
export function proxyModels(harness: string): Promise<{ providers?: { provider: string; body: string }[] }> {
  return proxyGet(`/api/models/${encodeURIComponent(harness)}`);
}
