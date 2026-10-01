import { apiFetch, authHeaders } from './api';

const BASE = (import.meta.env['VITE_API_URL'] as string | undefined) ?? '';

export type OrgRole = 'owner' | 'admin' | 'member';

export interface Org {
  id: string;
  name: string;
  kind: 'personal' | 'native' | 'github_org';
  role: OrgRole;
  source: 'native' | 'github';
  suspended: boolean;
}

export interface OrgList {
  personal: string;
  orgs: Org[];
}

export interface OrgMember {
  userId: string;
  githubLogin: string;
  role: OrgRole;
  source: 'native' | 'github';
  suspended: boolean;
}

export interface OrgInvitation {
  id: string;
  githubLogin: string;
  role: OrgRole;
  createdAt: string;
  expiresAt: string;
}

/** Shown for a GitHub membership the hourly sync suspended. */
export const SUSPENDED_REASON = 'GitHub membership suspended until you sign in again';

/** The server's `{"error": ...}` text, falling back to status + raw body. */
async function failure(res: Response): Promise<Error> {
  const text = await res.text();
  try {
    const parsed = JSON.parse(text) as { error?: unknown };
    if (typeof parsed.error === 'string' && parsed.error) return new Error(parsed.error);
  } catch {
    /* not JSON */
  }
  return new Error(`${res.status} ${text}`);
}

async function call<T>(method: string, path: string, body?: unknown): Promise<T> {
  const res = await apiFetch(`${BASE}${path}`, {
    method,
    headers: body !== undefined ? { 'Content-Type': 'application/json', ...authHeaders() } : authHeaders(),
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  });
  if (!res.ok) throw await failure(res);
  return (await res.json()) as T;
}

const enc = encodeURIComponent;

export const orgsApi = {
  list: () => call<OrgList>('GET', '/api/orgs'),
  create: async (name: string): Promise<Org> => (await call<{ org: Org }>('POST', '/api/orgs', { name })).org,
  connectGithub: async (githubOrg: string): Promise<Org> =>
    (await call<{ org: Org }>('POST', '/api/orgs/github', { githubOrg })).org,
  members: async (orgId: string): Promise<OrgMember[]> =>
    (await call<{ members: OrgMember[] }>('GET', `/api/orgs/${enc(orgId)}/members`)).members,
  setRole: (orgId: string, userId: string, role: OrgRole) =>
    call<{ ok: boolean }>('POST', `/api/orgs/${enc(orgId)}/members/${enc(userId)}`, { role }),
  removeMember: (orgId: string, userId: string) =>
    call<{ ok: boolean }>('DELETE', `/api/orgs/${enc(orgId)}/members/${enc(userId)}`),
  invitations: async (orgId: string): Promise<OrgInvitation[]> =>
    (await call<{ invitations: OrgInvitation[] }>('GET', `/api/orgs/${enc(orgId)}/invitations`)).invitations,
  invite: (orgId: string, githubLogin: string, role: OrgRole) =>
    call<{ invitation: OrgInvitation; token: string }>('POST', `/api/orgs/${enc(orgId)}/invitations`, {
      githubLogin,
      role,
    }),
  revokeInvitation: (orgId: string, invitationId: string) =>
    call<{ ok: boolean }>('DELETE', `/api/orgs/${enc(orgId)}/invitations/${enc(invitationId)}`),
  acceptInvitation: async (token: string): Promise<Org> =>
    (await call<{ org: Org }>('POST', '/api/invitations/accept', { token })).org,
};

export function inviteLink(token: string): string {
  return `${window.location.origin}/invite/${token}`;
}
