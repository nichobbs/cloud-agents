import { useCallback, useEffect, useState } from 'react';
import { api } from '../lib/api';
import {
  KIND_META,
  refLabel,
  refUrl,
  type EntryDetail,
  type LedgerEntry,
  type LedgerFeedback,
} from '../lib/ledger';
import { formatFullTimestamp, formatTimestamp } from '../lib/time';
import {
  bodyTextStyle,
  cardStyle,
  chipStyle,
  dangerBtnStyle,
  errorStyle,
  linkStyle,
  mutedStyle,
  primaryBtnStyle,
  sectionHeaderStyle,
  smallBtnStyle,
  textareaStyle,
} from './ledgerStyles';

interface LedgerEntryCardProps {
  sessionId: string;
  entry: LedgerEntry;
  /** Feedback already given on this entry (newest first), for delivery status. */
  feedback: LedgerFeedback[];
  /** Offer Approve / Reject / Comment. */
  reviewable: boolean;
  /** Called after a review lands, so the owner can refresh. */
  onReviewed: () => void;
}

const REVIEW_LABEL: Record<string, string> = {
  pending: 'awaiting review',
  approved: 'approved',
  rejected: 'rejected',
  commented: 'commented',
  not_required: '',
  resolved: 'resolved',
};

/** One ledger entry: what the agent recorded, its recommendation, the
 *  human's review actions, and (on demand) the full detail including the
 *  transcript around the moment it was recorded. */
export function LedgerEntryCard({ sessionId, entry, feedback, reviewable, onReviewed }: LedgerEntryCardProps) {
  const [mode, setMode] = useState<'' | 'reject' | 'comment'>('');
  const [body, setBody] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [detail, setDetail] = useState<EntryDetail | null>(null);
  const [detailOpen, setDetailOpen] = useState(false);
  const [detailError, setDetailError] = useState('');
  // The entry version the cached detail was loaded for: new feedback or a
  // review bumps entry.updatedSeq, and an open detail then reloads.
  const [detailSeq, setDetailSeq] = useState('');

  const kind = KIND_META[entry.kind] ?? { label: entry.kind, color: '#8b949e' };
  const severityColor = entry.severity === 'blocking' ? '#f85149' : entry.severity === 'review' ? '#d29922' : '#6e7681';
  const itemUrl = refUrl(entry.itemId);
  const latest = feedback[0];

  const submit = async (kindOfReview: 'approve' | 'reject' | 'comment') => {
    if (kindOfReview !== 'approve' && !body.trim()) {
      setError(kindOfReview === 'reject' ? 'Say what the agent should do instead.' : 'Write a comment first.');
      return;
    }
    setBusy(true);
    setError('');
    try {
      await api.reviewLedgerEntry(sessionId, entry.id, kindOfReview, body.trim());
      setMode('');
      setBody('');
      onReviewed();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const loadDetail = useCallback(async () => {
    setDetailError('');
    const seq = entry.updatedSeq;
    try {
      setDetail(await api.getLedgerEntry(sessionId, entry.id));
      setDetailSeq(seq);
    } catch (e) {
      setDetailError(e instanceof Error ? e.message : String(e));
    }
  }, [sessionId, entry.id, entry.updatedSeq]);

  useEffect(() => {
    if (detailOpen && detail && detailSeq !== entry.updatedSeq) void loadDetail();
  }, [detailOpen, detail, detailSeq, entry.updatedSeq, loadDetail]);

  const toggleDetail = () => {
    const opening = !detailOpen;
    setDetailOpen(opening);
    if (opening && (!detail || detailSeq !== entry.updatedSeq)) void loadDetail();
  };

  return (
    <div style={{ ...cardStyle, borderLeft: `3px solid ${severityColor}` }} data-testid={`ledger-entry-${entry.id}`}>
      <div style={topRowStyle}>
        <span style={{ ...chipStyle, color: kind.color, borderColor: kind.color }}>{kind.label}</span>
        {entry.severity !== 'info' && (
          <span style={{ ...chipStyle, color: severityColor, borderColor: severityColor }}>{entry.severity}</span>
        )}
        {entry.source === 'observed' && (
          <span style={{ ...chipStyle, color: '#a371f7', borderColor: '#a371f7' }}>observed</span>
        )}
        {entry.source === 'observed' && entry.provisional === 'true' && (
          <span style={{ ...chipStyle, color: '#d29922', borderColor: '#d29922' }}>provisional</span>
        )}
        {entry.undeclared === 'true' && <span style={{ ...chipStyle, color: '#f85149', borderColor: '#f85149' }}>undeclared</span>}
        {entry.itemId &&
          (itemUrl ? (
            <a href={itemUrl} target="_blank" rel="noreferrer" style={{ ...linkStyle, fontSize: '12px' }}>
              {refLabel(entry.itemId)}
            </a>
          ) : (
            <span style={mutedStyle}>{refLabel(entry.itemId)}</span>
          ))}
        <span style={{ ...mutedStyle, marginLeft: 'auto' }} title={formatFullTimestamp(entry.createdAt)}>
          {formatTimestamp(entry.createdAt)}
        </span>
      </div>

      <div style={summaryStyle}>{entry.summary}</div>

      {entry.chosen && (
        <div style={mutedLineStyle}>
          Chose <strong style={{ color: '#c9d1d9' }}>{entry.chosen}</strong>
          {entry.rationale ? ` — ${entry.rationale}` : ''}
        </div>
      )}
      {entry.proceedingWith && (
        <div style={mutedLineStyle}>
          Proceeding with <strong style={{ color: '#c9d1d9' }}>{entry.proceedingWith}</strong>
        </div>
      )}
      {entry.recommendation && (
        <div style={recommendationStyle}>
          <span style={{ color: '#8b949e' }}>Agent recommends: </span>
          {entry.recommendation}
        </div>
      )}

      <div style={statusRowStyle}>
        {REVIEW_LABEL[entry.reviewState] && <span style={mutedStyle}>{REVIEW_LABEL[entry.reviewState]}</span>}
        {latest && (
          <span style={mutedStyle}>
            {' · '}
            {latest.deliveredAt ? 'agent has seen your feedback' : 'feedback waiting for the agent'}
          </span>
        )}
      </div>

      <div style={actionsStyle}>
        {reviewable && mode === '' && (
          <>
            <button type="button" style={primaryBtnStyle} disabled={busy} onClick={() => void submit('approve')}>
              Approve
            </button>
            <button type="button" style={dangerBtnStyle} disabled={busy} onClick={() => setMode('reject')}>
              Reject
            </button>
            <button type="button" style={smallBtnStyle} disabled={busy} onClick={() => setMode('comment')}>
              Comment
            </button>
          </>
        )}
        {/* Available while composing too: the transcript is often what a
            rejection needs to point at. */}
        <button type="button" style={detailBtnStyle} onClick={toggleDetail}>
          {detailOpen ? 'Hide details' : 'Details'}
        </button>
      </div>

      {mode !== '' && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: '6px' }}>
          <textarea
            style={textareaStyle}
            rows={3}
            autoFocus
            aria-label={mode === 'reject' ? 'What should the agent do instead?' : 'Comment for the agent'}
            placeholder={mode === 'reject' ? 'What should the agent do instead?' : 'Comment for the agent'}
            value={body}
            onChange={e => setBody(e.target.value)}
          />
          <div style={actionsStyle}>
            <button
              type="button"
              style={mode === 'reject' ? dangerBtnStyle : primaryBtnStyle}
              disabled={busy}
              onClick={() => void submit(mode)}
            >
              {mode === 'reject' ? 'Send rejection' : 'Send comment'}
            </button>
            <button type="button" style={smallBtnStyle} disabled={busy} onClick={() => { setMode(''); setError(''); }}>
              Cancel
            </button>
          </div>
        </div>
      )}
      {error && <div style={errorStyle}>{error}</div>}

      {detailOpen && (
        <div style={detailStyle}>
          {detailError && <div style={errorStyle}>{detailError}</div>}
          {!detail && !detailError && <div style={mutedStyle}>Loading…</div>}
          {detail && <EntryDetailBody detail={detail} />}
        </div>
      )}
    </div>
  );
}

function EntryDetailBody({ detail }: { detail: EntryDetail }) {
  const e = detail.ledgerEntry;
  const confidence = Number(e.confidence);
  return (
    <>
      {e.source === 'observed' && e.confidence !== '' && Number.isFinite(confidence) && (
        <div style={mutedStyle}>Confidence: {Math.round(confidence * 100)}%</div>
      )}
      {e.source === 'observed' && e.evidence && <blockquote style={quoteStyle}>{e.evidence}</blockquote>}
      {e.matchedEntryId && <div style={mutedStyle}>Matches an entry the agent recorded.</div>}
      {e.detail && <div style={bodyTextStyle}>{e.detail}</div>}
      {e.optionsConsidered.length > 0 && (
        <>
          <div style={sectionHeaderStyle}>Options considered</div>
          <ul style={listStyle}>
            {e.optionsConsidered.map((o, i) => (
              <li key={`${i}-${o}`}>{o}</li>
            ))}
          </ul>
        </>
      )}
      {(e.files.length > 0 || e.tags.length > 0) && (
        <div style={mutedStyle}>
          {e.tags.length > 0 && <>Tags: {e.tags.join(', ')}. </>}
          {e.files.length > 0 && <>Files: {e.files.join(', ')}</>}
        </div>
      )}
      {e.reversible === 'false' && <div style={mutedStyle}>The agent marked this as not easily reversible.</div>}
      {detail.supersededBy.length > 0 && <div style={mutedStyle}>Revised by a later entry.</div>}
      {detail.feedback.length > 0 && (
        <>
          <div style={sectionHeaderStyle}>Your feedback</div>
          {detail.feedback.map(f => (
            <div key={f.id} style={mutedLineStyle}>
              <strong style={{ color: '#c9d1d9' }}>{f.kind}</strong>
              {f.body ? `: ${f.body}` : ''} ·{' '}
              {f.deliveredAt ? `seen by the agent ${formatTimestamp(f.deliveredAt)}` : 'not yet seen by the agent'}
            </div>
          ))}
        </>
      )}
      {detail.transitions.length > 0 && (
        <>
          <div style={sectionHeaderStyle}>Item history</div>
          {detail.transitions.map((t, i) => (
            <div key={`${t.at}-${i}`} style={mutedLineStyle}>
              {t.fromState} → {t.toState} ({t.actor}){t.reason ? `: ${t.reason}` : ''}
            </div>
          ))}
        </>
      )}
      <div style={sectionHeaderStyle}>Transcript at the time</div>
      {detail.transcriptExcerpt ? (
        <div style={excerptStyle}>{detail.transcriptExcerpt}</div>
      ) : (
        <div style={mutedStyle}>No captured transcript for this moment.</div>
      )}
    </>
  );
}

const topRowStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: '6px',
  flexWrap: 'wrap',
};

const summaryStyle: React.CSSProperties = {
  fontSize: '14px',
  color: '#e6edf3',
  wordBreak: 'break-word',
};

const mutedLineStyle: React.CSSProperties = {
  fontSize: '12px',
  color: '#8b949e',
  wordBreak: 'break-word',
};

const recommendationStyle: React.CSSProperties = {
  fontSize: '13px',
  color: '#c9d1d9',
  wordBreak: 'break-word',
};

const statusRowStyle: React.CSSProperties = {
  display: 'flex',
  flexWrap: 'wrap',
};

const actionsStyle: React.CSSProperties = {
  display: 'flex',
  gap: '6px',
  flexWrap: 'wrap',
};

const detailBtnStyle: React.CSSProperties = {
  ...smallBtnStyle,
  background: 'transparent',
  color: '#8b949e',
};

const detailStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '6px',
  borderTop: '1px solid #21262d',
  paddingTop: '6px',
};

const listStyle: React.CSSProperties = {
  margin: 0,
  paddingLeft: '18px',
  fontSize: '12px',
  color: '#c9d1d9',
};

const excerptStyle: React.CSSProperties = {
  ...bodyTextStyle,
  fontSize: '12px',
  maxHeight: '240px',
  overflowY: 'auto',
  background: '#0d1117',
  border: '1px solid #21262d',
  borderRadius: '6px',
  padding: '6px 8px',
};

const quoteStyle: React.CSSProperties = {
  ...bodyTextStyle,
  fontSize: '12px',
  margin: 0,
  color: '#8b949e',
  borderLeft: '3px solid #30363d',
  paddingLeft: '8px',
};
