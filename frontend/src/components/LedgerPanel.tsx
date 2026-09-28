import { useEffect, useMemo, useState } from 'react';
import { useLedger } from '../hooks/useLedger';
import { api } from '../lib/api';
import {
  attentionQueue,
  blockedEdges,
  feedbackFor,
  humanActions,
  ITEM_STATE_META,
  KIND_META,
  progress,
  refLabel,
  refUrl,
  safeHref,
  type EntryKind,
  type ItemState,
  type LedgerFeedback,
  type WorkItem,
} from '../lib/ledger';
import { LedgerEntryCard } from './LedgerEntryCard';
import {
  bodyTextStyle,
  cardStyle,
  chipStyle,
  errorStyle,
  headerStyle,
  inputStyle,
  linkStyle,
  mutedStyle,
  panelStyle,
  primaryBtnStyle,
  sectionHeaderStyle,
  smallBtnStyle,
  textareaStyle,
} from './ledgerStyles';

interface LedgerPanelProps {
  sessionId: string;
  /** True while a run streams: poll faster, the agent is writing. */
  isStreaming: boolean;
}

/** The session ledger (docs/session-ledger.md): progress through the batch,
 *  what needs the human's review (with the agent's recommendation and
 *  inline Approve / Reject / Comment), the work items and what blocks them,
 *  a channel to tell the agent something, and the full timeline. Updates
 *  live by cursor polling. Hidden entirely on a backend without the ledger. */
export function LedgerPanel({ sessionId, isStreaming }: LedgerPanelProps) {
  const { state, loaded, unavailable, error, refresh } = useLedger(sessionId, isStreaming);
  const queue = useMemo(() => attentionQueue(state.entries), [state.entries]);
  const edges = useMemo(() => blockedEdges(state.items), [state.items]);
  const { resolved, total } = progress(state.summary);

  if (unavailable) return null;

  const waitingFeedback = state.feedback.filter(f => !f.deliveredAt).length;
  // The summary counts every row; the queue only the entries shipped.
  const olderPending = Math.max(0, parseInt(state.summary?.pendingReview ?? '0', 10) - queue.length);
  const empty = loaded && state.items.length === 0 && state.entries.length === 0;

  return (
    <div style={panelStyle} data-testid="ledger-panel">
      <div style={headerRowStyle}>
        <span style={headerStyle}>Session ledger</span>
        {total > 0 && (
          <span style={mutedStyle}>
            {resolved}/{total} done
          </span>
        )}
      </div>
      {state.items.some(i => i.id.startsWith('gh:')) && (
        <GitHubSync sessionId={sessionId} onSynced={() => void refresh()} />
      )}

      {error && <div style={errorStyle}>Could not refresh the ledger: {error}</div>}
      {!loaded && !error && <div style={mutedStyle}>Loading…</div>}
      {empty && (
        <div style={mutedStyle}>
          The agent hasn't recorded anything yet. Its work items, decisions, shortcuts and blockers appear here as
          it goes.
        </div>
      )}

      {total > 0 && <ProgressBar resolved={resolved} total={total} />}
      {state.summary && total > 0 && <StateCounts summary={state.summary} />}
      {state.truncated && (
        <div style={mutedStyle}>
          This session's ledger is long: only the newest entries are shown.
          {olderPending > 0 && ` ${olderPending} older ${olderPending === 1 ? 'entry awaits' : 'entries await'} review in the Inbox.`}
        </div>
      )}
      {state.policyStatus === 'invalid' && (
        <div style={errorStyle}>This repo's .agent-ledger.json is invalid ({state.policyError}); default review rules apply.</div>
      )}

      {queue.length > 0 && (
        <section aria-label="Needs your review" style={sectionStyle}>
          <div style={{ ...sectionHeaderStyle, color: '#d29922' }}>Needs your review ({queue.length})</div>
          {queue.map(e => (
            <LedgerEntryCard
              key={e.id}
              sessionId={sessionId}
              entry={e}
              feedback={feedbackFor(state.feedback, e.id)}
              reviewable
              onReviewed={() => void refresh()}
            />
          ))}
        </section>
      )}

      {state.items.length > 0 && (
        <section aria-label="Work items" style={sectionStyle}>
          <div style={sectionHeaderStyle}>Work items</div>
          {state.items.map(item => (
            <WorkItemRow key={item.id} sessionId={sessionId} item={item} onChanged={() => void refresh()} />
          ))}
        </section>
      )}

      {edges.length > 0 && (
        <section aria-label="Blocked" style={sectionStyle}>
          <div style={sectionHeaderStyle}>Blocked</div>
          {edges.map(({ item, waitsOn }) => (
            <div key={item.id} style={edgeStyle}>
              <RefLink refId={item.id} /> <span style={mutedStyle}>waits on</span>{' '}
              {waitsOn.length > 0 ? (
                waitsOn.map((w, i) => (
                  <span key={`${i}-${w}`}>
                    {i > 0 ? ', ' : ''}
                    <RefLink refId={w} />
                    <StateOf refId={w} items={state.items} />
                  </span>
                ))
              ) : (
                <span style={mutedStyle}>prerequisite work: {item.prerequisiteProposal}</span>
              )}
            </div>
          ))}
        </section>
      )}

      {loaded && (
        <TellAgent
          sessionId={sessionId}
          waiting={waitingFeedback}
          onSent={() => void refresh()}
        />
      )}

      {state.entries.length > 0 && (
        <Timeline sessionId={sessionId} entries={state.entries} feedback={state.feedback} onReviewed={() => void refresh()} />
      )}

      {loaded && <AddItem sessionId={sessionId} onAdded={() => void refresh()} />}
    </div>
  );
}

function ProgressBar({ resolved, total }: { resolved: number; total: number }) {
  const pct = total > 0 ? Math.round((resolved / total) * 100) : 0;
  return (
    <div
      role="progressbar"
      aria-valuenow={resolved}
      aria-valuemin={0}
      aria-valuemax={total}
      aria-label={`${resolved} of ${total} work items done`}
      style={barTrackStyle}
    >
      <div style={{ ...barFillStyle, width: `${pct}%` }} />
    </div>
  );
}

function StateCounts({ summary }: { summary: NonNullable<ReturnType<typeof useLedger>['state']['summary']> }) {
  const counts: Array<[ItemState, string]> = [
    ['in_progress', summary.inProgress],
    ['queued', summary.queued],
    ['pr_open', summary.prOpen],
    ['blocked', summary.blocked],
    ['needs_human', summary.needsHuman],
    ['done', summary.done],
    ['skipped', summary.skipped],
  ];
  return (
    <div style={countsStyle}>
      {counts
        .filter(([, n]) => n !== '0' && n !== '')
        .map(([state, n]) => {
          const meta = ITEM_STATE_META[state];
          return (
            <span key={state} style={{ ...chipStyle, color: meta.color, borderColor: meta.color }}>
              {n} {meta.label}
            </span>
          );
        })}
    </div>
  );
}

function RefLink({ refId }: { refId: string }) {
  const url = refUrl(refId);
  return url ? (
    <a href={url} target="_blank" rel="noreferrer" style={linkStyle}>
      {refLabel(refId)}
    </a>
  ) : (
    <span style={{ color: '#c9d1d9' }}>{refLabel(refId)}</span>
  );
}

function StateOf({ refId, items }: { refId: string; items: WorkItem[] }) {
  const found = items.find(i => i.id === refId);
  if (!found) return <span style={mutedStyle}> (outside this batch)</span>;
  return <span style={mutedStyle}> ({ITEM_STATE_META[found.state]?.label ?? found.state})</span>;
}

function WorkItemRow({ sessionId, item, onChanged }: { sessionId: string; item: WorkItem; onChanged: () => void }) {
  const [pending, setPending] = useState<ItemState | null>(null);
  const [reason, setReason] = useState('');
  const [directiveOpen, setDirectiveOpen] = useState(false);
  const [directive, setDirective] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const meta = ITEM_STATE_META[item.state] ?? { label: item.state, color: '#8b949e' };
  const actions = humanActions(item.state);
  const reasonRequired = pending === 'needs_human';

  // A poll can move the item under a half-entered action; the action may no
  // longer be allowed from the new state, so start over.
  useEffect(() => {
    setPending(null);
    setReason('');
  }, [item.state]);

  const apply = async (to: ItemState) => {
    if (to === 'needs_human' && !reason.trim()) {
      setError('Say what you need to decide or do.');
      return;
    }
    setBusy(true);
    setError('');
    try {
      await api.setLedgerItemState(sessionId, item.id, to, reason.trim());
      setPending(null);
      setReason('');
      onChanged();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const sendDirective = async () => {
    if (!directive.trim()) return;
    setBusy(true);
    setError('');
    try {
      await api.giveLedgerFeedback(sessionId, item.id, 'directive', directive.trim());
      setDirective('');
      setDirectiveOpen(false);
      onChanged();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div style={cardStyle} data-testid={`ledger-item-${item.id}`}>
      <div style={itemTopStyle}>
        <span style={{ ...chipStyle, color: meta.color, borderColor: meta.color }}>{meta.label}</span>
        <RefLink refId={item.id} />
        {item.title && <span style={itemTitleStyle}>{item.title}</span>}
        {safeHref(item.prUrl) && (
          <a href={safeHref(item.prUrl)} target="_blank" rel="noreferrer" style={{ ...linkStyle, fontSize: '12px', marginLeft: 'auto' }}>
            PR
          </a>
        )}
      </div>
      {item.blockedReason && (item.state === 'blocked' || item.state === 'needs_human') && (
        <div style={bodyTextStyle}>{item.blockedReason}</div>
      )}
      {item.state === 'blocked' && item.prerequisiteProposal && (
        <div style={smallTextStyle}>
          <span style={{ color: '#8b949e' }}>Prerequisite work: </span>
          {item.prerequisiteProposal}
        </div>
      )}
      {item.recommendation && (
        <div style={smallTextStyle}>
          <span style={{ color: '#8b949e' }}>Agent recommends: </span>
          {item.recommendation}
        </div>
      )}

      {pending === null && (
        <div style={rowActionsStyle}>
          {actions.map(a => (
            <button
              key={a.to}
              type="button"
              style={smallBtnStyle}
              disabled={busy}
              onClick={() => {
                setError('');
                setPending(a.to);
              }}
            >
              {a.label}
            </button>
          ))}
          <button type="button" style={smallBtnStyle} disabled={busy} onClick={() => setDirectiveOpen(o => !o)}>
            Tell the agent
          </button>
        </div>
      )}
      {pending !== null && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: '6px' }}>
          <input
            style={inputStyle}
            aria-label="Reason"
            placeholder={reasonRequired ? 'What do you need to decide or do? (required)' : 'Reason (optional)'}
            value={reason}
            onChange={e => setReason(e.target.value)}
          />
          <div style={rowActionsStyle}>
            <button type="button" style={primaryBtnStyle} disabled={busy} onClick={() => void apply(pending)}>
              {humanActions(item.state).find(a => a.to === pending)?.label ?? 'Apply'}
            </button>
            <button
              type="button"
              style={smallBtnStyle}
              disabled={busy}
              onClick={() => {
                setPending(null);
                setReason('');
                setError('');
              }}
            >
              Cancel
            </button>
          </div>
        </div>
      )}
      {directiveOpen && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: '6px' }}>
          <textarea
            style={textareaStyle}
            rows={2}
            aria-label={`Instruction about ${refLabel(item.id)}`}
            placeholder={`Instruction about ${refLabel(item.id)}`}
            value={directive}
            onChange={e => setDirective(e.target.value)}
          />
          <div style={rowActionsStyle}>
            <button type="button" style={primaryBtnStyle} disabled={busy || !directive.trim()} onClick={() => void sendDirective()}>
              Send
            </button>
          </div>
        </div>
      )}
      {error && <div style={errorStyle}>{error}</div>}
    </div>
  );
}

function TellAgent({ sessionId, waiting, onSent }: { sessionId: string; waiting: number; onSent: () => void }) {
  const [open, setOpen] = useState(false);
  const [body, setBody] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  const send = async () => {
    if (!body.trim()) return;
    setBusy(true);
    setError('');
    try {
      await api.giveLedgerFeedback(sessionId, '', 'directive', body.trim());
      setBody('');
      setOpen(false);
      onSent();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div style={sectionStyle}>
      <div style={rowActionsStyle}>
        <button type="button" style={smallBtnStyle} onClick={() => setOpen(o => !o)}>
          Message the agent
        </button>
        {waiting > 0 && (
          <span style={mutedStyle}>
            {waiting} item{waiting === 1 ? '' : 's'} of feedback waiting for the agent
          </span>
        )}
      </div>
      {open && (
        <>
          <div style={mutedStyle}>
            Delivered when the agent next checks for feedback (before its next item or PR), or at the start of its next
            run. It won't interrupt what it is doing.
          </div>
          <textarea
            style={textareaStyle}
            rows={3}
            aria-label="Message for the agent"
            value={body}
            onChange={e => setBody(e.target.value)}
          />
          <div style={rowActionsStyle}>
            <button type="button" style={primaryBtnStyle} disabled={busy || !body.trim()} onClick={() => void send()}>
              Send
            </button>
          </div>
        </>
      )}
      {error && <div style={errorStyle}>{error}</div>}
    </div>
  );
}

const TIMELINE_KINDS: Array<EntryKind | 'all'> = ['all', 'decision', 'deviation', 'shortcut', 'blocker', 'question', 'note'];

function Timeline({
  sessionId,
  entries,
  feedback,
  onReviewed,
}: {
  sessionId: string;
  entries: ReturnType<typeof useLedger>['state']['entries'];
  feedback: LedgerFeedback[];
  onReviewed: () => void;
}) {
  const [open, setOpen] = useState(false);
  const [kind, setKind] = useState<EntryKind | 'all'>('all');
  const [showInfo, setShowInfo] = useState(false);
  const shown = entries
    .filter(e => kind === 'all' || e.kind === kind)
    .filter(e => showInfo || e.severity !== 'info')
    .slice()
    .reverse();
  const hiddenInfo = entries.filter(e => (kind === 'all' || e.kind === kind) && e.severity === 'info').length;

  return (
    <section aria-label="Timeline" style={sectionStyle}>
      <button type="button" style={timelineToggleStyle} onClick={() => setOpen(o => !o)} aria-expanded={open}>
        {open ? '▾' : '▸'} Timeline ({entries.length})
      </button>
      {open && (
        <>
          <div style={rowActionsStyle}>
            <select
              aria-label="Filter by kind"
              style={selectStyle}
              value={kind}
              onChange={e => setKind(e.target.value as EntryKind | 'all')}
            >
              {TIMELINE_KINDS.map(k => (
                <option key={k} value={k}>
                  {k === 'all' ? 'All kinds' : KIND_META[k].label}
                </option>
              ))}
            </select>
            <label style={{ ...mutedStyle, display: 'flex', alignItems: 'center', gap: '4px' }}>
              <input type="checkbox" checked={showInfo} onChange={e => setShowInfo(e.target.checked)} />
              Show info ({hiddenInfo})
            </label>
          </div>
          {shown.length === 0 && <div style={mutedStyle}>Nothing matches.</div>}
          {shown.map(e => (
            <LedgerEntryCard
              key={e.id}
              sessionId={sessionId}
              entry={e}
              feedback={feedbackFor(feedback, e.id)}
              reviewable={e.reviewState === 'pending'}
              onReviewed={onReviewed}
            />
          ))}
        </>
      )}
    </section>
  );
}

function AddItem({ sessionId, onAdded }: { sessionId: string; onAdded: () => void }) {
  const [open, setOpen] = useState(false);
  const [ref, setRef] = useState('');
  const [title, setTitle] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  const add = async () => {
    if (!ref.trim()) return;
    setBusy(true);
    setError('');
    try {
      await api.addLedgerItems(sessionId, [{ id: ref.trim(), title: title.trim(), url: '' }]);
      setRef('');
      setTitle('');
      setOpen(false);
      onAdded();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  if (!open) {
    return (
      <button type="button" style={{ ...smallBtnStyle, alignSelf: 'flex-start' }} onClick={() => setOpen(true)}>
        Add work item
      </button>
    );
  }
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '6px' }}>
      <input
        style={inputStyle}
        aria-label="Issue"
        placeholder="#12, owner/repo#12, an issue URL, or local:name"
        value={ref}
        onChange={e => setRef(e.target.value)}
      />
      <input style={inputStyle} aria-label="Title" placeholder="Title (optional)" value={title} onChange={e => setTitle(e.target.value)} />
      <div style={rowActionsStyle}>
        <button type="button" style={primaryBtnStyle} disabled={busy || !ref.trim()} onClick={() => void add()}>
          Add
        </button>
        <button type="button" style={smallBtnStyle} disabled={busy} onClick={() => setOpen(false)}>
          Cancel
        </button>
      </div>
      {error && <div style={errorStyle}>{error}</div>}
    </div>
  );
}

/** Reconcile the session's GitHub issues now: labels, the blocker comment,
 *  blockers closed and PRs merged on GitHub. A maintenance job does the same
 *  in the background; this is for when the owner just changed something. */
function GitHubSync({ sessionId, onSynced }: { sessionId: string; onSynced: () => void }) {
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState('');
  const [error, setError] = useState('');

  const sync = async () => {
    setBusy(true);
    setError('');
    setMessage('');
    try {
      const r = await api.syncLedger(sessionId);
      const moved = parseInt(r.transitions, 10) || 0;
      setMessage(
        r.errors.length > 0
          ? `Synced with ${r.errors.length} GitHub ${r.errors.length === 1 ? 'error' : 'errors'}: ${r.errors[0]}`
          : moved > 0
            ? `Synced: ${moved} ${moved === 1 ? 'item' : 'items'} moved by changes on GitHub.`
            : 'Synced: GitHub is up to date.',
      );
      onSynced();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div style={syncRowStyle}>
      <button type="button" style={smallBtnStyle} disabled={busy} onClick={() => void sync()}>
        {busy ? 'Syncing…' : 'Sync with GitHub'}
      </button>
      {message && <span style={mutedStyle}>{message}</span>}
      {error && <span style={errorStyle}>{error}</span>}
    </div>
  );
}

const syncRowStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: '8px',
  flexWrap: 'wrap',
};

const headerRowStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'space-between',
};

const sectionStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '6px',
};

const barTrackStyle: React.CSSProperties = {
  height: '6px',
  background: '#21262d',
  borderRadius: '3px',
  overflow: 'hidden',
};

const barFillStyle: React.CSSProperties = {
  height: '100%',
  background: '#3fb950',
};

const countsStyle: React.CSSProperties = {
  display: 'flex',
  flexWrap: 'wrap',
  gap: '4px',
};

const edgeStyle: React.CSSProperties = {
  fontSize: '12px',
  color: '#c9d1d9',
  wordBreak: 'break-word',
};

const itemTopStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: '6px',
  flexWrap: 'wrap',
  fontSize: '13px',
};

const itemTitleStyle: React.CSSProperties = {
  color: '#c9d1d9',
  wordBreak: 'break-word',
};

const smallTextStyle: React.CSSProperties = {
  fontSize: '12px',
  color: '#c9d1d9',
  wordBreak: 'break-word',
};

const rowActionsStyle: React.CSSProperties = {
  display: 'flex',
  gap: '6px',
  flexWrap: 'wrap',
  alignItems: 'center',
};

const timelineToggleStyle: React.CSSProperties = {
  background: 'transparent',
  border: 'none',
  color: '#8b949e',
  fontSize: '12px',
  textTransform: 'uppercase',
  letterSpacing: '0.04em',
  cursor: 'pointer',
  padding: 0,
  textAlign: 'left',
};

const selectStyle: React.CSSProperties = {
  background: '#0d1117',
  border: '1px solid #30363d',
  borderRadius: '6px',
  color: '#c9d1d9',
  fontSize: '12px',
  padding: '4px 6px',
};
