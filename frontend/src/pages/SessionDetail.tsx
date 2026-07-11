import { useCallback, useEffect, useRef, useState } from 'react';
import { Link, useLocation, useNavigate, useParams } from 'react-router-dom';
import { MessageBlock } from '../components/MessageBlock';
import { Terminal } from '../components/Terminal';
import { useSessions } from '../context/SessionsContext';
import { useStreamMessage } from '../hooks/useStreamMessage';
import { getHarness } from '../lib/harnesses';
import { api } from '../lib/api';
import type { Message, Profile, Prompt, Run } from '../types';

/** Unique `{{name}}` placeholder names in a prompt body, in first-seen order. */
function extractVarNames(body: string): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  const re = /\{\{([^}]+)\}\}/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(body)) !== null) {
    const name = (m[1] ?? '').trim();
    if (name && !seen.has(name)) {
      seen.add(name);
      out.push(name);
    }
  }
  return out;
}

export function SessionDetail() {
  const { id } = useParams<{ id: string }>();
  const sessionId = id ?? '';
  const { getSession, removeSession, updateSession } = useSessions();
  const navigate = useNavigate();
  const location = useLocation();
  const session = getSession(sessionId);
  const { output, isStreaming, error: sendError, send, reset } = useStreamMessage(sessionId);

  const [messages, setMessages] = useState<Message[]>([]);
  const [messagesError, setMessagesError] = useState(false);
  const [input, setInput] = useState('');
  const [deleting, setDeleting] = useState(false);
  const [modelSwitching, setModelSwitching] = useState(false);
  const [modelError, setModelError] = useState('');
  const [prompts, setPrompts] = useState<Prompt[]>([]);
  const [savingPrompt, setSavingPrompt] = useState(false);
  const [profiles, setProfiles] = useState<Profile[]>([]);
  const [profileId, setProfileId] = useState('');
  const [profileSaving, setProfileSaving] = useState(false);
  const [runs, setRuns] = useState<Run[]>([]);
  const [showRuns, setShowRuns] = useState(false);
  const [cancelling, setCancelling] = useState(false);
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  // Prompt library for the composer picker. Best-effort: an older backend
  // without the endpoint just leaves the picker hidden.
  useEffect(() => {
    let active = true;
    api
      .getPrompts()
      .then(ps => {
        if (active) setPrompts(ps);
      })
      .catch(() => {
        /* library unavailable — hide the picker */
      });
    return () => {
      active = false;
    };
  }, []);

  // Profiles for the run-profile selector.
  useEffect(() => {
    let active = true;
    api
      .getProfiles()
      .then(ps => {
        if (active) setProfiles(ps);
      })
      .catch(() => {
        /* profiles unavailable — hide the selector */
      });
    return () => {
      active = false;
    };
  }, []);

  // Reflect the session's actually-attached profile in the selector (#270).
  // Best-effort and session-scoped: a slow fetch for a previous session must
  // not overwrite the current one's selection. Reset to '' first so the
  // previous session's profile doesn't flash while the new fetch is in flight
  // (#273).
  useEffect(() => {
    let active = true;
    setProfileId('');
    api
      .getSessionProfile(sessionId)
      .then(pid => {
        if (active) setProfileId(pid);
      })
      .catch(() => {
        /* profile lookup unavailable — leave the selector at its default */
      });
    return () => {
      active = false;
    };
  }, [sessionId]);

  // Tracks which session this component instance is currently showing, so a
  // handleSend() call that outlives a navigation to a different session (a
  // send can take up to 30 minutes) can tell it's stale and bail out instead
  // of folding its result into the wrong session's view. SessionDetail isn't
  // remounted on navigation between sessions, only re-rendered with a new
  // `sessionId`, so a plain closure over `sessionId` inside handleSend isn't
  // enough on its own — this ref is what lets that closure check itself
  // against the *current* session after an awaited call returns.
  const currentSessionRef = useRef(sessionId);
  useEffect(() => {
    currentSessionRef.current = sessionId;
  }, [sessionId]);

  const highlightedId = location.hash.startsWith('#message-')
    ? location.hash.slice('#message-'.length)
    : null;

  // Single place that actually calls the transcript API and absorbs its
  // errors (transcript may be empty or unavailable; leave state as-is on
  // failure) — both call sites below just decide when to apply the result.
  const fetchMessages = useCallback(async (forSessionId: string): Promise<Message[] | null> => {
    try {
      return await api.getMessages(forSessionId);
    } catch {
      return null;
    }
  }, []);

  // Used for explicit, one-off refreshes (e.g. right after a successful
  // send). No concurrent fetch to race against, but the user can still
  // navigate to a different session while this fetch is in flight — guard
  // against applying a stale session's result via the same currentSessionRef
  // handleSend already uses for this purpose.
  const reload = useCallback(async () => {
    const forSessionId = sessionId;
    const fetched = await fetchMessages(forSessionId);
    if (fetched && currentSessionRef.current === forSessionId) {
      setMessages(fetched);
      setMessagesError(false);
    }
  }, [sessionId, fetchMessages]);

  useEffect(() => {
    // Guard against a slow fetch for a previous session resolving after
    // navigating to a new one and overwriting its transcript with stale data
    // — session switches change `sessionId` without remounting this
    // component, so a request in flight can outlive the session it was for.
    // Same pattern as CommentThread.tsx's `active` flag.
    let active = true;
    setMessagesError(false);
    fetchMessages(sessionId).then(fetched => {
      if (!active) return;
      if (fetched) {
        setMessages(fetched);
      } else {
        // A failed fetch right after switching sessions must not leave the
        // previous session's transcript on screen under this session's
        // header — clear it and surface the failure instead of silently
        // showing someone else's conversation.
        setMessages([]);
        setMessagesError(true);
      }
    });
    return () => {
      active = false;
    };
  }, [sessionId, fetchMessages]);

  // Deep-link: scroll to the message referenced by the URL hash once loaded.
  useEffect(() => {
    if (!highlightedId || messages.length === 0) return;
    const el = document.getElementById(`message-${highlightedId}`);
    el?.scrollIntoView({ behavior: 'smooth', block: 'center' });
  }, [highlightedId, messages]);

  if (!session) {
    return (
      <div style={{ padding: '32px 24px', color: '#8b949e', textAlign: 'center' }}>
        Session not found.{' '}
        <button style={linkBtnStyle} onClick={() => navigate('/sessions')}>
          Back to sessions
        </button>
      </div>
    );
  }

  const repoName = (() => {
    try {
      return new URL(session.repoUrl).pathname.replace(/^\//, '').replace(/\.git$/, '');
    } catch {
      return session.repoUrl;
    }
  })();

  const handleSend = async () => {
    const text = input.trim();
    if (!text || isStreaming) return;
    setInput('');
    const { succeeded, stale } = await send(text);

    if (stale) {
      // Either the user navigated to a different session while this send
      // was in flight, or they left this same session and came back before
      // it resolved (a fresh generation) — useStreamMessage's own
      // stillCurrent() check already caught this and left its
      // output/isStreaming/error state alone. Bail out of the continuation
      // below too: reload()/reset() would otherwise act on a
      // completed-but-superseded send, corrupting a genuinely in-flight
      // newer send on the same session (or the wrong session's transcript),
      // and focus() would steal it from a textarea the user isn't looking
      // at anymore.
      return;
    }

    if (succeeded) {
      // Fold the completed run into the persisted transcript and clear the
      // live panel. `stale` above only reflects the state as of `send()`
      // resolving — the user can still navigate away during `reload()`'s
      // own fetch, so re-check before the unconditional `reset()`: reload()
      // already guards its own setMessages call against this, but reset()
      // (which touches useStreamMessage's output/error, now bound to
      // whatever session is current) has no guard of its own.
      const forSession = sessionId;
      await reload();
      if (currentSessionRef.current === forSession) {
        reset();
      }
    } else {
      // Restore the prompt so a failed send (network error, container
      // crash, backend 500) doesn't silently discard what the user typed —
      // and leave `output`/`error` populated so the failure is visible
      // instead of being wiped immediately.
      setInput(text);
    }
    textareaRef.current?.focus();
  };

  const handleKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      void handleSend();
    }
  };

  const handleModelChange = async (newModel: string) => {
    if (!session || modelSwitching || isStreaming) return;
    setModelSwitching(true);
    setModelError('');
    try {
      await api.updateSessionModel(session.sessionId, newModel);
      updateSession(session.sessionId, { model: newModel });
    } catch (err) {
      setModelError(err instanceof Error ? err.message : 'Failed to switch model');
    } finally {
      setModelSwitching(false);
    }
  };

  const handleProfileChange = async (pid: string) => {
    if (profileSaving) return;
    setProfileSaving(true);
    try {
      await api.setSessionProfile(sessionId, pid);
      setProfileId(pid);
    } catch (err) {
      alert(err instanceof Error ? `Failed to set profile: ${err.message}` : 'Failed to set profile');
    } finally {
      setProfileSaving(false);
    }
  };

  const handleCancel = async () => {
    if (cancelling) return;
    setCancelling(true);
    try {
      await api.cancelRun(sessionId);
    } catch (err) {
      alert(err instanceof Error ? `Cancel failed: ${err.message}` : 'Cancel failed');
    } finally {
      setCancelling(false);
    }
  };

  const toggleRuns = async () => {
    const next = !showRuns;
    setShowRuns(next);
    if (next) {
      try {
        setRuns(await api.getRuns(sessionId));
      } catch {
        /* run history unavailable — leave the list empty */
      }
    }
  };

  const handleInsertPrompt = async (promptId: string) => {
    const p = prompts.find(x => x.id === promptId);
    if (!p) return;
    // If the body has {{var}} placeholders, collect values and render server-side
    // (which also counts the use); otherwise insert the body verbatim.
    const vars = extractVarNames(p.body);
    let text = p.body;
    if (vars.length > 0) {
      const bindings: Record<string, string> = {};
      for (const name of vars) {
        const value = window.prompt(`Value for {{${name}}}:`, '');
        if (value === null) return; // cancelled — insert nothing
        bindings[name] = value;
      }
      try {
        text = await api.renderPrompt(p.id, bindings);
      } catch (err) {
        alert(err instanceof Error ? `Failed to render prompt: ${err.message}` : 'Failed to render prompt');
        return;
      }
    } else {
      // Usage bookkeeping is best-effort; the count just informs the library UI.
      api.usePrompt(p.id).catch(() => { /* non-fatal */ });
    }
    // Insert (append to any draft) rather than replace, so a prompt can be
    // combined with typed context.
    setInput(prev => (prev.trim() ? `${prev.trimEnd()}\n\n${text}` : text));
    textareaRef.current?.focus();
  };

  const handleSavePrompt = async () => {
    const text = input.trim();
    if (!text || savingPrompt) return;
    const promptName = prompt('Name for this prompt:', text.split('\n')[0]?.slice(0, 60) ?? '');
    if (!promptName?.trim()) return;
    setSavingPrompt(true);
    try {
      const created = await api.addPrompt(promptName.trim(), text);
      setPrompts(prev => [...prev, created].sort((a, b) => a.name.localeCompare(b.name)));
    } catch (err) {
      alert(err instanceof Error ? `Failed to save prompt: ${err.message}` : 'Failed to save prompt');
    } finally {
      setSavingPrompt(false);
    }
  };

  const handleDelete = async () => {
    if (!confirm(`Delete session ${session.sessionId.slice(0, 8)}…?`)) return;
    setDeleting(true);
    try {
      await api.deleteSession(session.sessionId);
    } catch {
      // server-side errors are best-effort; remove from local list regardless
    }
    removeSession(session.sessionId);
    navigate('/sessions');
  };

  return (
    <div style={pageStyle}>
      <div style={headerStyle}>
        <div>
          <div style={{ display: 'flex', alignItems: 'center', gap: '8px', marginBottom: '4px' }}>
            <div style={repoNameStyle}>{repoName}</div>
            <span style={harnessBadgeStyle}>
              {getHarness(session.harness ?? 'claude').label}
            </span>
          </div>
          <div style={metaStyle}>
            branch: <code style={{ color: '#79c0ff' }}>{session.branch}</code>
            <span style={{ margin: '0 8px', color: '#30363d' }}>·</span>
            model:{' '}
            <select
              style={modelSelectStyle}
              value={session.model ?? ''}
              onChange={e => { void handleModelChange(e.target.value); }}
              disabled={modelSwitching || isStreaming}
              title="Switch model (takes effect on next message)"
            >
              {getHarness(session.harness ?? 'claude').models.map(m => (
                <option key={m.id} value={m.id}>{m.label}</option>
              ))}
            </select>
            {profiles.length > 0 && (
              <>
                <span style={{ margin: '0 8px', color: '#30363d' }}>·</span>
                profile:{' '}
                <select
                  style={modelSelectStyle}
                  value={profileId}
                  onChange={e => { void handleProfileChange(e.target.value); }}
                  disabled={profileSaving || isStreaming}
                  title="Attach a profile (credentials, network, harness) for this session's runs"
                >
                  <option value="">none</option>
                  {profiles.map(p => (
                    <option key={p.id} value={p.id}>{p.name}</option>
                  ))}
                </select>
              </>
            )}
            <span style={{ margin: '0 8px', color: '#30363d' }}>·</span>
            <span style={{ fontFamily: 'monospace', fontSize: '11px' }}>
              {session.sessionId}
            </span>
          </div>
          {modelError && <div style={modelErrorStyle}>Model switch failed: {modelError}</div>}
        </div>
        <div style={{ display: 'flex', gap: '8px', flexShrink: 0 }}>
          <button style={todosBtnStyle} onClick={() => { void toggleRuns(); }}>
            {showRuns ? 'Hide runs' : 'Runs'}
          </button>
          <Link to={`/sessions/${sessionId}/todos`} style={todosBtnStyle}>
            Todos
          </Link>
          <button
            style={deleteBtnStyle}
            onClick={() => { void handleDelete(); }}
            disabled={deleting}
          >
            {deleting ? 'Deleting…' : 'Delete'}
          </button>
        </div>
      </div>

      {showRuns && (
        <div style={runsPanelStyle}>
          <div style={runsHeaderStyle}>Run history</div>
          {runs.length === 0 && <div style={runsEmptyStyle}>No runs recorded yet.</div>}
          {runs.map(r => (
            <div key={r.id} style={runRowStyle}>
              <span style={runStatusStyle(r.status)}>{r.status}</span>
              <span style={runPreviewStyle} title={r.promptPreview}>{r.promptPreview || '(no prompt)'}</span>
              <span style={runMetaStyle}>{formatRunTime(r.startedAt)}</span>
            </div>
          ))}
        </div>
      )}

      <div style={transcriptStyle}>
        {messagesError && (
          <div style={messagesErrorStyle}>
            Failed to load transcript for this session.
          </div>
        )}
        {messages.length === 0 && !isStreaming && !sendError && !messagesError && (
          <div style={emptyStyle}>
            No messages yet — send a prompt below to start the session.
          </div>
        )}
        {messages.map(m => (
          <MessageBlock
            key={m.id}
            message={m}
            highlighted={m.id === highlightedId}
            onTodoAdded={() => { /* todos live on their own page */ }}
          />
        ))}
        {(isStreaming || sendError) && (
          <div style={liveWrapStyle}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
              <div style={sendError ? liveErrorLabelStyle : liveLabelStyle}>
                {isStreaming ? 'running…' : 'failed'}
              </div>
              {isStreaming && (
                <button
                  style={cancelRunBtnStyle}
                  onClick={() => { void handleCancel(); }}
                  disabled={cancelling}
                  title="Terminate the running container"
                >
                  {cancelling ? 'Cancelling…' : 'Cancel run'}
                </button>
              )}
            </div>
            <Terminal output={output} isStreaming={isStreaming} />
          </div>
        )}
      </div>

      <div style={composerToolsStyle}>
        {prompts.length > 0 && (
          <select
            style={promptPickerStyle}
            value=""
            onChange={e => {
              if (e.target.value) void handleInsertPrompt(e.target.value);
            }}
            disabled={isStreaming}
            aria-label="Insert a saved prompt"
          >
            <option value="">Insert prompt…</option>
            {prompts.map(p => (
              <option key={p.id} value={p.id}>
                {p.name}
              </option>
            ))}
          </select>
        )}
        <button
          style={{ ...savePromptBtnStyle, opacity: input.trim() && !savingPrompt ? 1 : 0.5 }}
          onClick={() => { void handleSavePrompt(); }}
          disabled={!input.trim() || savingPrompt}
          title="Save the current draft to the prompt library"
        >
          {savingPrompt ? 'Saving…' : 'Save as prompt'}
        </button>
      </div>

      <div style={inputRowStyle}>
        <textarea
          ref={textareaRef}
          style={textareaStyle}
          rows={3}
          placeholder="Send a message… (Enter to send, Shift+Enter for newline)"
          value={input}
          onChange={e => setInput(e.target.value)}
          onKeyDown={handleKeyDown}
          disabled={isStreaming}
        />
        <button
          style={{
            ...sendBtnStyle,
            opacity: isStreaming || !input.trim() ? 0.5 : 1,
            cursor: isStreaming || !input.trim() ? 'not-allowed' : 'pointer',
          }}
          onClick={() => { void handleSend(); }}
          disabled={isStreaming || !input.trim()}
        >
          {isStreaming ? 'Running…' : 'Send'}
        </button>
      </div>
    </div>
  );
}

function formatRunTime(epochMillis: string): string {
  const n = Number(epochMillis);
  if (!Number.isFinite(n) || n <= 0) return '';
  return new Date(n).toLocaleString();
}

const runStatusColor: Record<string, string> = {
  running: '#d29922',
  succeeded: '#3fb950',
  failed: '#f85149',
  cancelled: '#8b949e',
};

const pageStyle: React.CSSProperties = {
  maxWidth: '900px',
  margin: '0 auto',
  padding: '24px',
  display: 'flex',
  flexDirection: 'column',
  gap: '16px',
  minHeight: 'calc(100vh - 57px)',
};

const cancelRunBtnStyle: React.CSSProperties = {
  padding: '3px 10px',
  background: 'transparent',
  color: '#f85149',
  border: '1px solid #f85149',
  borderRadius: '6px',
  fontSize: '12px',
  cursor: 'pointer',
};

const runsPanelStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '6px',
  background: '#0d1117',
  border: '1px solid #21262d',
  borderRadius: '8px',
  padding: '12px 14px',
};

const runsHeaderStyle: React.CSSProperties = {
  fontSize: '12px',
  color: '#8b949e',
  textTransform: 'uppercase',
  letterSpacing: '0.04em',
};

const runsEmptyStyle: React.CSSProperties = { fontSize: '12px', color: '#6e7681' };

const runRowStyle: React.CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: '10px',
  fontSize: '12px',
  padding: '4px 0',
  borderTop: '1px solid #161b22',
};

const runStatusStyle = (status: string): React.CSSProperties => ({
  color: runStatusColor[status] ?? '#8b949e',
  fontWeight: 600,
  minWidth: '72px',
  flexShrink: 0,
});

const runPreviewStyle: React.CSSProperties = {
  flex: 1,
  color: '#8b949e',
  whiteSpace: 'nowrap',
  overflow: 'hidden',
  textOverflow: 'ellipsis',
};

const runMetaStyle: React.CSSProperties = { color: '#6e7681', whiteSpace: 'nowrap', flexShrink: 0 };

const headerStyle: React.CSSProperties = {
  display: 'flex',
  justifyContent: 'space-between',
  alignItems: 'flex-start',
};

const repoNameStyle: React.CSSProperties = {
  fontSize: '16px',
  fontWeight: 600,
  color: '#c9d1d9',
};

const harnessBadgeStyle: React.CSSProperties = {
  fontSize: '11px',
  fontWeight: 500,
  color: '#8b949e',
  background: '#21262d',
  border: '1px solid #30363d',
  borderRadius: '4px',
  padding: '1px 6px',
  whiteSpace: 'nowrap',
};

const modelSelectStyle: React.CSSProperties = {
  background: 'transparent',
  border: 'none',
  color: '#79c0ff',
  fontSize: '12px',
  fontFamily: 'monospace',
  cursor: 'pointer',
  padding: 0,
  outline: 'none',
};

const modelErrorStyle: React.CSSProperties = {
  fontSize: '11px',
  color: '#f85149',
  marginTop: '4px',
};

const metaStyle: React.CSSProperties = {
  fontSize: '12px',
  color: '#8b949e',
};

const transcriptStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '12px',
  flex: 1,
};

const messagesErrorStyle: React.CSSProperties = {
  color: '#f85149',
  fontSize: '13px',
  textAlign: 'center',
  padding: '16px',
};

const emptyStyle: React.CSSProperties = {
  color: '#6e7681',
  fontSize: '14px',
  textAlign: 'center',
  padding: '32px',
};

const liveWrapStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '6px',
};

const liveLabelStyle: React.CSSProperties = {
  fontSize: '11px',
  color: '#56d364',
  textTransform: 'uppercase',
  letterSpacing: '0.04em',
};

const liveErrorLabelStyle: React.CSSProperties = {
  ...liveLabelStyle,
  color: '#f85149',
};

const todosBtnStyle: React.CSSProperties = {
  padding: '5px 12px',
  background: '#21262d',
  color: '#c9d1d9',
  border: '1px solid #30363d',
  borderRadius: '6px',
  fontSize: '13px',
  textDecoration: 'none',
};

const deleteBtnStyle: React.CSSProperties = {
  padding: '5px 12px',
  background: 'transparent',
  color: '#f85149',
  border: '1px solid #f85149',
  borderRadius: '6px',
  fontSize: '13px',
  cursor: 'pointer',
};

const composerToolsStyle: React.CSSProperties = {
  display: 'flex',
  gap: '8px',
  justifyContent: 'flex-end',
  marginBottom: '-8px',
};

const promptPickerStyle: React.CSSProperties = {
  background: '#0d1117',
  border: '1px solid #30363d',
  borderRadius: '6px',
  color: '#8b949e',
  fontSize: '12px',
  padding: '3px 8px',
  outline: 'none',
  cursor: 'pointer',
};

const savePromptBtnStyle: React.CSSProperties = {
  padding: '3px 10px',
  background: 'transparent',
  color: '#8b949e',
  border: '1px solid #30363d',
  borderRadius: '6px',
  fontSize: '12px',
  cursor: 'pointer',
};

const inputRowStyle: React.CSSProperties = {
  display: 'flex',
  gap: '10px',
  alignItems: 'flex-end',
};

const textareaStyle: React.CSSProperties = {
  flex: 1,
  padding: '10px 12px',
  background: '#0d1117',
  border: '1px solid #30363d',
  borderRadius: '6px',
  color: '#c9d1d9',
  fontSize: '14px',
  fontFamily: 'inherit',
  resize: 'vertical',
  outline: 'none',
  boxSizing: 'border-box',
};

const sendBtnStyle: React.CSSProperties = {
  padding: '10px 20px',
  background: '#1f6feb',
  color: '#fff',
  border: 'none',
  borderRadius: '6px',
  fontSize: '14px',
  fontWeight: 500,
  flexShrink: 0,
  alignSelf: 'flex-end',
};

const linkBtnStyle: React.CSSProperties = {
  background: 'none',
  border: 'none',
  color: '#58a6ff',
  cursor: 'pointer',
  fontSize: 'inherit',
  padding: 0,
  textDecoration: 'underline',
};
