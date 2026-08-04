import { useState } from 'react';
import { Link } from 'react-router-dom';
import { api } from '../lib/api';
import { formatFullTimestamp, formatTimestamp } from '../lib/time';
import type { Message } from '../types';

/// Full-text search across every message in the caller's own session
/// transcripts (GET /api/search/messages?q=...).
export function Search() {
  const [query, setQuery] = useState('');
  const [messages, setMessages] = useState<Message[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [searched, setSearched] = useState(false);

  const runSearch = async () => {
    const term = query.trim();
    if (!term || loading) return;
    setLoading(true);
    setError('');
    try {
      const results = await api.searchMessages(term);
      setMessages(results);
      setSearched(true);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to search messages');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div style={pageStyle}>
      <h2 style={titleStyle}>Search messages</h2>

      <form
        style={formStyle}
        onSubmit={e => {
          e.preventDefault();
          void runSearch();
        }}
      >
        <input
          style={inputStyle}
          placeholder="Search your message transcripts…"
          value={query}
          onChange={e => setQuery(e.target.value)}
          maxLength={200}
          autoFocus
        />
        <button
          type="submit"
          style={{ ...searchBtnStyle, opacity: query.trim() && !loading ? 1 : 0.5 }}
          disabled={!query.trim() || loading}
        >
          {loading ? 'Searching…' : 'Search'}
        </button>
      </form>

      {error && <div style={errStyle}>{error}</div>}
      {loading && <div style={mutedStyle}>Searching…</div>}
      {!loading && searched && messages.length === 0 && (
        <div style={mutedStyle}>No messages matched "{query.trim()}".</div>
      )}

      {!loading && messages.map(m => (
        <Link key={m.id} to={`/sessions/${m.sessionId}`} style={resultLinkStyle}>
          <div style={resultCardStyle}>
            <div style={resultMetaStyle}>
              <span style={roleStyle}>{m.role}</span>
              <span title={formatFullTimestamp(m.createdAt)}>{formatTimestamp(m.createdAt)}</span>
            </div>
            <div style={resultContentStyle}>{m.content}</div>
          </div>
        </Link>
      ))}
    </div>
  );
}

const pageStyle: React.CSSProperties = {
  maxWidth: '900px',
  margin: '0 auto',
  padding: '24px',
  display: 'flex',
  flexDirection: 'column',
  gap: '14px',
};

const titleStyle: React.CSSProperties = {
  fontSize: '18px',
  color: '#c9d1d9',
  margin: 0,
};

const formStyle: React.CSSProperties = {
  display: 'flex',
  gap: '8px',
};

const inputStyle: React.CSSProperties = {
  flex: 1,
  padding: '8px 10px',
  background: '#0d1117',
  border: '1px solid #30363d',
  borderRadius: '6px',
  color: '#c9d1d9',
  fontSize: '14px',
  outline: 'none',
};

const searchBtnStyle: React.CSSProperties = {
  padding: '7px 16px',
  background: '#1f6feb',
  color: '#fff',
  border: 'none',
  borderRadius: '6px',
  fontSize: '13px',
  cursor: 'pointer',
};

const errStyle: React.CSSProperties = {
  fontSize: '13px',
  color: '#f85149',
};

const mutedStyle: React.CSSProperties = {
  fontSize: '13px',
  color: '#6e7681',
  textAlign: 'center',
  padding: '16px',
};

const resultLinkStyle: React.CSSProperties = {
  textDecoration: 'none',
};

const resultCardStyle: React.CSSProperties = {
  background: '#0d1117',
  border: '1px solid #21262d',
  borderRadius: '8px',
  padding: '12px 14px',
  display: 'flex',
  flexDirection: 'column',
  gap: '6px',
};

const resultMetaStyle: React.CSSProperties = {
  display: 'flex',
  justifyContent: 'space-between',
  fontSize: '11px',
  color: '#6e7681',
};

const roleStyle: React.CSSProperties = {
  color: '#58a6ff',
  fontWeight: 600,
  textTransform: 'uppercase',
};

const resultContentStyle: React.CSSProperties = {
  fontSize: '13px',
  color: '#c9d1d9',
  whiteSpace: 'pre-wrap',
  wordBreak: 'break-word',
  maxHeight: '160px',
  overflowY: 'auto',
};
