import { apiFetch, authHeaders } from './api';

const BASE = (import.meta.env['VITE_API_URL'] as string | undefined) ?? '';

/** An import token as listed (docs/claude-session-import.md §5). Times are epoch-millis strings. */
export interface ImportToken {
  id: string;
  label: string;
  createdAt: string;
  lastUsedAt: string;
  revoked: boolean;
}

/** The server's `{"message": ...}` / `{"error": ...}` text, falling back to status + raw body. */
async function failure(res: Response): Promise<Error> {
  const text = await res.text();
  try {
    const parsed = JSON.parse(text) as { error?: unknown; message?: unknown };
    if (typeof parsed.error === 'string' && parsed.error) return new Error(parsed.error);
    if (typeof parsed.message === 'string' && parsed.message) return new Error(parsed.message);
  } catch {
    /* not JSON */
  }
  return new Error(`${res.status} ${text}`);
}

async function call(method: string, path: string, body?: unknown): Promise<Response> {
  const res = await apiFetch(`${BASE}${path}`, {
    method,
    headers: body !== undefined ? { 'Content-Type': 'application/json', ...authHeaders() } : authHeaders(),
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  });
  if (!res.ok) throw await failure(res);
  return res;
}

const enc = encodeURIComponent;

export const importsApi = {
  tokens: async (): Promise<ImportToken[]> =>
    ((await (await call('GET', '/api/imports/tokens')).json()) as { tokens: ImportToken[] }).tokens,
  /** Creates a token; `secret` is shown once and never again. */
  createToken: async (label: string): Promise<{ token: ImportToken; secret: string }> =>
    (await (await call('POST', '/api/imports/tokens', { label })).json()) as { token: ImportToken; secret: string },
  revokeToken: async (id: string): Promise<void> => {
    await call('DELETE', `/api/imports/tokens/${enc(id)}`);
  },
  /** Lets a deleted imported session be imported again. */
  clearTombstone: async (ccrSessionId: string): Promise<void> => {
    await call('DELETE', `/api/imports/tombstones/${enc(ccrSessionId)}`);
  },
};

/** The claude.ai page for an imported session. Ids are validated server-side. */
export function claudeSessionUrl(ccrSessionId: string): string {
  return `https://claude.ai/code/${enc(ccrSessionId)}`;
}

export function isImported(s: { importedFrom?: string }): boolean {
  return !!s.importedFrom;
}
