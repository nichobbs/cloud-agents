import { useCallback, useEffect, useState } from 'react';
import { useOrgs } from '../context/OrgContext';
import { getLogin } from '../lib/auth';
import { inviteLink, orgsApi } from '../lib/orgs';
import type { Org, OrgInvitation, OrgMember, OrgRole } from '../lib/orgs';

const SUSPENDED_REASON = 'GitHub membership suspended until you sign in again';

const msg = (err: unknown, fallback: string) => (err instanceof Error ? err.message : fallback);

function formatTime(epochMillis: string): string {
  const n = Number(epochMillis);
  if (!Number.isFinite(n) || n <= 0) return 'unknown';
  return new Date(n).toLocaleString();
}

/// Organisation settings: create/connect organisations and manage the members
/// and pending invitations of the one selected in the list. Selecting an
/// organisation here does not switch the active one (use the button or the
/// nav switcher).
export function Organisations() {
  const { orgs, activeOrgId, reload, setActiveOrg } = useOrgs();
  const [selectedId, setSelectedId] = useState('');
  const [error, setError] = useState('');
  const [name, setName] = useState('');
  const [ghOrg, setGhOrg] = useState('');
  const [busy, setBusy] = useState(false);

  const selected = orgs.find(o => o.id === selectedId) ?? orgs.find(o => o.id === activeOrgId) ?? orgs[0];

  const create = async () => {
    if (!name.trim() || busy) return;
    setBusy(true);
    setError('');
    try {
      const org = await orgsApi.create(name.trim());
      setName('');
      await reload();
      setSelectedId(org.id);
    } catch (err) {
      setError(msg(err, 'Failed to create organisation'));
    } finally {
      setBusy(false);
    }
  };

  const connect = async () => {
    if (!ghOrg.trim() || busy) return;
    setBusy(true);
    setError('');
    try {
      const org = await orgsApi.connectGithub(ghOrg.trim());
      setGhOrg('');
      await reload();
      setSelectedId(org.id);
    } catch (err) {
      setError(msg(err, 'Failed to connect GitHub organisation'));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div style={pageStyle}>
      <h2 style={titleStyle}>Organisations</h2>
      <p style={subtitleStyle}>
        Sessions, profiles and credentials belong to the organisation that is active when you create them.
        Switch organisation from the nav bar. Changes to GitHub organisation membership take effect within an
        hour (the hourly sync), or at the member&apos;s next sign-in.
      </p>
      {error && <div style={errStyle} role="alert">{error}</div>}

      <div style={listStyle}>
        {orgs.length === 0 && <div style={mutedStyle}>No organisations loaded.</div>}
        {orgs.map(o => (
          <button
            key={o.id}
            style={{ ...orgBtnStyle, borderColor: selected?.id === o.id ? '#1f6feb' : '#21262d' }}
            onClick={() => setSelectedId(o.id)}
            aria-pressed={selected?.id === o.id}
          >
            <span style={{ color: '#c9d1d9' }}>{o.name}</span>
            <span style={metaStyle}>
              {o.kind === 'github_org' ? 'GitHub' : o.kind} · {o.role}
              {o.id === activeOrgId ? ' · active' : ''}
              {o.suspended ? ' · suspended' : ''}
            </span>
          </button>
        ))}
      </div>

      <div style={formStyle}>
        <input
          style={inputStyle}
          placeholder="New organisation name"
          aria-label="New organisation name"
          value={name}
          maxLength={100}
          onChange={e => setName(e.target.value)}
          onKeyDown={e => { if (e.key === 'Enter') void create(); }}
        />
        <button style={{ ...primaryBtnStyle, opacity: name.trim() && !busy ? 1 : 0.5 }} disabled={!name.trim() || busy} onClick={() => { void create(); }}>
          Create organisation
        </button>
      </div>

      <div style={formStyle}>
        <input
          style={inputStyle}
          placeholder="GitHub organisation login"
          aria-label="GitHub organisation login"
          value={ghOrg}
          onChange={e => setGhOrg(e.target.value)}
          onKeyDown={e => { if (e.key === 'Enter') void connect(); }}
        />
        <button style={{ ...primaryBtnStyle, opacity: ghOrg.trim() && !busy ? 1 : 0.5 }} disabled={!ghOrg.trim() || busy} onClick={() => { void connect(); }}>
          Connect GitHub organisation
        </button>
        <div style={{ ...metaStyle, flexBasis: '100%' }}>
          Only administrators of the GitHub organisation can connect it; you become its owner.
        </div>
      </div>

      {selected && (
        <OrgDetail
          key={selected.id}
          org={selected}
          isActive={selected.id === activeOrgId}
          onSwitch={() => setActiveOrg(selected.id)}
          onLeft={reload}
          onError={setError}
        />
      )}
    </div>
  );
}

function OrgDetail({
  org,
  isActive,
  onSwitch,
  onLeft,
  onError,
}: {
  org: Org;
  isActive: boolean;
  onSwitch: () => void;
  onLeft: () => Promise<void>;
  onError: (m: string) => void;
}) {
  const { personalId, setActiveOrg } = useOrgs();
  const isPersonal = org.kind === 'personal';
  const canInvite = org.role === 'owner' || org.role === 'admin';
  const isOwner = org.role === 'owner';
  const me = getLogin();

  const [members, setMembers] = useState<OrgMember[]>([]);
  const [invitations, setInvitations] = useState<OrgInvitation[]>([]);
  const [login, setLogin] = useState('');
  const [role, setRole] = useState<OrgRole>('member');
  const [issued, setIssued] = useState<{ login: string; link: string } | null>(null);
  const [copied, setCopied] = useState(false);

  const load = useCallback(async () => {
    if (isPersonal) return;
    try {
      setMembers(await orgsApi.members(org.id));
      setInvitations(canInvite ? await orgsApi.invitations(org.id) : []);
    } catch (err) {
      onError(msg(err, 'Failed to load organisation'));
    }
  }, [org.id, isPersonal, canInvite, onError]);

  useEffect(() => {
    void load();
  }, [load]);

  const run = async (fn: () => Promise<unknown>, fallback: string) => {
    onError('');
    try {
      await fn();
      await load();
    } catch (err) {
      onError(msg(err, fallback));
    }
  };

  const invite = async () => {
    if (!login.trim()) return;
    onError('');
    try {
      const res = await orgsApi.invite(org.id, login.trim(), role);
      setIssued({ login: res.invitation.githubLogin, link: inviteLink(res.token) });
      setCopied(false);
      setLogin('');
      await load();
    } catch (err) {
      onError(msg(err, 'Failed to create invitation'));
    }
  };

  const copy = async () => {
    if (!issued) return;
    try {
      await navigator.clipboard.writeText(issued.link);
      setCopied(true);
    } catch {
      /* clipboard unavailable: the link stays selectable in the field */
    }
  };

  const leave = async (m: OrgMember) => {
    if (!confirm(`Leave "${org.name}"?`)) return;
    onError('');
    try {
      await orgsApi.removeMember(org.id, m.userId);
      if (isActive) setActiveOrg(personalId);
      await onLeft();
    } catch (err) {
      onError(msg(err, 'Failed to leave organisation'));
    }
  };

  return (
    <section style={detailStyle} aria-label={`${org.name} settings`}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: '10px' }}>
        <h3 style={{ ...titleStyle, fontSize: '15px' }}>{org.name}</h3>
        {isActive ? (
          <span style={metaStyle}>Active organisation</span>
        ) : (
          <button style={ghostBtnStyle} disabled={org.suspended} onClick={onSwitch} title={org.suspended ? SUSPENDED_REASON : undefined}>
            Switch to this organisation
          </button>
        )}
      </div>

      {isPersonal ? (
        <div style={mutedStyle}>Your personal organisation has no members to manage.</div>
      ) : (
        <>
          <h4 style={subheadStyle}>Members</h4>
          {members.map(m => {
            const self = m.githubLogin === me;
            return (
              <div key={m.userId} style={rowStyle}>
                <span style={{ color: '#c9d1d9', fontSize: '13px' }}>
                  {m.githubLogin || m.userId}
                  <span style={metaStyle}> · {m.source}{m.suspended ? ' · suspended' : ''}</span>
                </span>
                <div style={{ display: 'flex', gap: '8px', alignItems: 'center' }}>
                  {isOwner ? (
                    <select
                      style={selectStyle}
                      aria-label={`Role of ${m.githubLogin}`}
                      value={m.role}
                      onChange={e => { void run(() => orgsApi.setRole(org.id, m.userId, e.target.value as OrgRole), 'Failed to change role'); }}
                    >
                      <option value="owner">owner</option>
                      <option value="admin">admin</option>
                      <option value="member">member</option>
                    </select>
                  ) : (
                    <span style={metaStyle}>{m.role}</span>
                  )}
                  {self && (
                    <button style={dangerBtnStyle} onClick={() => { void leave(m); }}>Leave</button>
                  )}
                  {isOwner && !self && (
                    <button
                      style={dangerBtnStyle}
                      aria-label={`Remove ${m.githubLogin}`}
                      onClick={() => {
                        if (confirm(`Remove ${m.githubLogin} from "${org.name}"?`)) {
                          void run(() => orgsApi.removeMember(org.id, m.userId), 'Failed to remove member');
                        }
                      }}
                    >
                      Remove
                    </button>
                  )}
                </div>
              </div>
            );
          })}
          {org.source === 'github' && (
            <div style={metaStyle}>
              Members of a GitHub organisation are synced from GitHub; changes there apply within an hour or at
              the member&apos;s next sign-in.
            </div>
          )}

          {canInvite && (
            <>
              <h4 style={subheadStyle}>Invitations</h4>
              <div style={formStyle}>
                <input
                  style={inputStyle}
                  placeholder="GitHub login to invite"
                  aria-label="GitHub login to invite"
                  value={login}
                  onChange={e => setLogin(e.target.value)}
                  onKeyDown={e => { if (e.key === 'Enter') void invite(); }}
                />
                <select style={selectStyle} aria-label="Invitation role" value={role} onChange={e => setRole(e.target.value as OrgRole)}>
                  <option value="member">member</option>
                  <option value="admin">admin</option>
                </select>
                <button style={{ ...primaryBtnStyle, opacity: login.trim() ? 1 : 0.5 }} disabled={!login.trim()} onClick={() => { void invite(); }}>
                  Invite
                </button>
              </div>
              {issued && (
                <div style={noticeStyle}>
                  <div style={{ fontSize: '13px', color: '#c9d1d9' }}>
                    Invitation link for {issued.login}. It is shown only once; copy it now and send it to them.
                    They must sign in as that GitHub login to accept.
                  </div>
                  <div style={{ display: 'flex', gap: '8px' }}>
                    <input style={inputStyle} readOnly aria-label="Invitation link" value={issued.link} onFocus={e => e.currentTarget.select()} />
                    <button style={ghostBtnStyle} onClick={() => { void copy(); }}>{copied ? 'Copied' : 'Copy'}</button>
                  </div>
                </div>
              )}
              {invitations.length === 0 && <div style={mutedStyle}>No pending invitations.</div>}
              {invitations.map(i => (
                <div key={i.id} style={rowStyle}>
                  <span style={{ color: '#c9d1d9', fontSize: '13px' }}>
                    {i.githubLogin}
                    <span style={metaStyle}> · {i.role} · expires {formatTime(i.expiresAt)}</span>
                  </span>
                  <button
                    style={dangerBtnStyle}
                    aria-label={`Revoke invitation for ${i.githubLogin}`}
                    onClick={() => { void run(() => orgsApi.revokeInvitation(org.id, i.id), 'Failed to revoke invitation'); }}
                  >
                    Revoke
                  </button>
                </div>
              ))}
            </>
          )}
        </>
      )}
    </section>
  );
}

const pageStyle: React.CSSProperties = { maxWidth: '900px', margin: '0 auto', padding: '24px', display: 'flex', flexDirection: 'column', gap: '12px' };
const titleStyle: React.CSSProperties = { fontSize: '18px', color: '#c9d1d9', margin: 0 };
const subheadStyle: React.CSSProperties = { fontSize: '13px', color: '#8b949e', margin: '8px 0 0', textTransform: 'uppercase', letterSpacing: '0.04em' };
const subtitleStyle: React.CSSProperties = { fontSize: '13px', color: '#8b949e', margin: 0, lineHeight: 1.5 };
const listStyle: React.CSSProperties = { display: 'flex', flexDirection: 'column', gap: '6px' };
const orgBtnStyle: React.CSSProperties = { display: 'flex', justifyContent: 'space-between', gap: '10px', background: '#0d1117', border: '1px solid', borderRadius: '8px', padding: '10px 14px', fontSize: '13px', cursor: 'pointer', textAlign: 'left' };
const formStyle: React.CSSProperties = { display: 'flex', gap: '8px', flexWrap: 'wrap', background: '#161b22', border: '1px solid #21262d', borderRadius: '8px', padding: '14px' };
const detailStyle: React.CSSProperties = { display: 'flex', flexDirection: 'column', gap: '10px', background: '#161b22', border: '1px solid #21262d', borderRadius: '8px', padding: '14px' };
const noticeStyle: React.CSSProperties = { display: 'flex', flexDirection: 'column', gap: '8px', background: '#0d1117', border: '1px solid #1f6feb', borderRadius: '8px', padding: '12px' };
const inputStyle: React.CSSProperties = { flex: 1, minWidth: '200px', padding: '8px 10px', background: '#0d1117', border: '1px solid #30363d', borderRadius: '6px', color: '#c9d1d9', fontSize: '13px', outline: 'none' };
const selectStyle: React.CSSProperties = { padding: '6px 8px', background: '#0d1117', border: '1px solid #30363d', borderRadius: '6px', color: '#c9d1d9', fontSize: '13px' };
const primaryBtnStyle: React.CSSProperties = { padding: '8px 16px', background: '#1f6feb', color: '#fff', border: 'none', borderRadius: '6px', fontSize: '13px', cursor: 'pointer' };
const ghostBtnStyle: React.CSSProperties = { padding: '5px 12px', background: '#21262d', color: '#c9d1d9', border: '1px solid #30363d', borderRadius: '6px', fontSize: '12px', cursor: 'pointer' };
const dangerBtnStyle: React.CSSProperties = { padding: '3px 10px', background: 'transparent', color: '#f85149', border: '1px solid #f85149', borderRadius: '6px', fontSize: '12px', cursor: 'pointer' };
const rowStyle: React.CSSProperties = { display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: '10px', background: '#0d1117', border: '1px solid #21262d', borderRadius: '8px', padding: '10px 14px' };
const metaStyle: React.CSSProperties = { fontSize: '11px', color: '#6e7681' };
const errStyle: React.CSSProperties = { fontSize: '13px', color: '#f85149' };
const mutedStyle: React.CSSProperties = { fontSize: '13px', color: '#6e7681', textAlign: 'center', padding: '8px' };
