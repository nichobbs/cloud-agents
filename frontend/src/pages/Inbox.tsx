import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { LedgerEntryCard } from '../components/LedgerEntryCard';
import { errorStyle, headerStyle, linkStyle, mutedStyle, panelStyle } from '../components/ledgerStyles';
import { api } from '../lib/api';
import type { InboxEntry } from '../lib/ledger';

/** How often the inbox re-checks while open (reviews arrive from agents
 *  running in any session). */
export const INBOX_POLL_MS = 15000;

function repoName(repoUrl: string): string {
  const m = /github\.com\/([^/]+\/[^/.]+)/.exec(repoUrl);
  return m?.[1] ?? repoUrl;
}

/** Everything awaiting the user's review across all their sessions — the
 *  ledger's attention queue, blocking first — grouped by session, with the
 *  agent's recommendation and inline Approve / Reject / Comment on each. */
export function Inbox() {
  const [entries, setEntries] = useState<InboxEntry[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [error, setError] = useState('');

  const reload = useCallback(async () => {
    try {
      setEntries(await api.getLedgerInbox());
      setError('');
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoaded(true);
    }
  }, []);

  useEffect(() => {
    void reload();
    const id = window.setInterval(() => {
      if (document.visibilityState !== 'hidden') void reload();
    }, INBOX_POLL_MS);
    return () => window.clearInterval(id);
  }, [reload]);

  // Group by session, keeping the server's order (blocking first, oldest
  // first) both across and within groups.
  const groups = useMemo(() => {
    const out: Array<{ sessionId: string; repoUrl: string; branch: string; items: InboxEntry[] }> = [];
    for (const e of entries) {
      const sid = e.ledgerEntry.sessionId;
      let g = out.find(x => x.sessionId === sid);
      if (!g) {
        g = { sessionId: sid, repoUrl: e.repoUrl, branch: e.branch, items: [] };
        out.push(g);
      }
      g.items.push(e);
    }
    return out;
  }, [entries]);

  const blocking = entries.filter(e => e.ledgerEntry.severity === 'blocking').length;

  return (
    <main style={pageStyle}>
      <h1 style={titleStyle}>Inbox</h1>
      <p style={mutedStyle}>
        Decisions, shortcuts, questions and blockers your agents recorded for review.
        {entries.length > 0 && ` ${entries.length} waiting${blocking > 0 ? `, ${blocking} blocking` : ''}.`}
      </p>
      {error && <div style={errorStyle}>Could not load the inbox: {error}</div>}
      {loaded && !error && entries.length === 0 && <div style={mutedStyle}>Nothing needs your review.</div>}
      {groups.map(g => (
        <section key={g.sessionId} style={panelStyle} aria-label={`Session ${repoName(g.repoUrl)}`}>
          <div style={groupHeaderStyle}>
            <span style={headerStyle}>
              {repoName(g.repoUrl)}
              {g.branch ? ` · ${g.branch}` : ''}
            </span>
            <Link to={`/sessions/${g.sessionId}`} style={{ ...linkStyle, fontSize: '12px' }}>
              Open session
            </Link>
          </div>
          {g.items.map(e => (
            <LedgerEntryCard
              key={e.ledgerEntry.id}
              sessionId={g.sessionId}
              entry={e.ledgerEntry}
              feedback={[]}
              reviewable
              onReviewed={() => void reload()}
            />
          ))}
        </section>
      ))}
    </main>
  );
}

const pageStyle: React.CSSProperties = {
  maxWidth: '760px',
  margin: '0 auto',
  padding: '16px',
  display: 'flex',
  flexDirection: 'column',
  gap: '12px',
};

const titleStyle: React.CSSProperties = {
  fontSize: '20px',
  color: '#e6edf3',
  margin: 0,
};

const groupHeaderStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'space-between',
  gap: '8px',
};
