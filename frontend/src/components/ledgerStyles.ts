import type React from 'react';

/** Styles shared by the session-ledger views (LedgerPanel, LedgerEntryCard,
 *  the Inbox page), in the same dark palette as the other session panels. */

export const panelStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '10px',
  background: '#0d1117',
  border: '1px solid #21262d',
  borderRadius: '8px',
  padding: '12px 14px',
};

export const headerStyle: React.CSSProperties = {
  fontSize: '12px',
  color: '#8b949e',
  textTransform: 'uppercase',
  letterSpacing: '0.04em',
};

export const sectionHeaderStyle: React.CSSProperties = {
  fontSize: '11px',
  color: '#8b949e',
  textTransform: 'uppercase',
  letterSpacing: '0.04em',
  marginTop: '4px',
};

export const mutedStyle: React.CSSProperties = {
  fontSize: '12px',
  color: '#6e7681',
};

export const errorStyle: React.CSSProperties = {
  fontSize: '12px',
  color: '#f85149',
};

export const chipStyle: React.CSSProperties = {
  display: 'inline-block',
  fontSize: '10px',
  lineHeight: '16px',
  padding: '0 6px',
  border: '1px solid',
  borderRadius: '10px',
  whiteSpace: 'nowrap',
};

export const cardStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '6px',
  padding: '8px 10px',
  background: '#161b22',
  border: '1px solid #21262d',
  borderRadius: '6px',
};

export const smallBtnStyle: React.CSSProperties = {
  background: '#21262d',
  border: '1px solid #30363d',
  borderRadius: '6px',
  color: '#c9d1d9',
  fontSize: '12px',
  padding: '4px 10px',
  cursor: 'pointer',
  minHeight: '28px',
};

export const primaryBtnStyle: React.CSSProperties = {
  ...smallBtnStyle,
  background: '#238636',
  borderColor: '#2ea043',
  color: '#ffffff',
};

export const dangerBtnStyle: React.CSSProperties = {
  ...smallBtnStyle,
  color: '#f85149',
};

export const textareaStyle: React.CSSProperties = {
  width: '100%',
  boxSizing: 'border-box',
  background: '#0d1117',
  border: '1px solid #30363d',
  borderRadius: '6px',
  color: '#c9d1d9',
  fontSize: '13px',
  padding: '6px 8px',
  resize: 'vertical',
  fontFamily: 'inherit',
};

export const inputStyle: React.CSSProperties = {
  ...textareaStyle,
  resize: undefined,
};

export const bodyTextStyle: React.CSSProperties = {
  fontSize: '13px',
  color: '#c9d1d9',
  whiteSpace: 'pre-wrap',
  wordBreak: 'break-word',
};

export const linkStyle: React.CSSProperties = {
  color: '#58a6ff',
  textDecoration: 'none',
};
