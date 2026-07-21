import { useCallback, useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { Link, useLocation, useNavigate, useParams } from 'react-router-dom';
import { GitHubPanel } from '../components/GitHubPanel';
import { LinkedReposPanel } from '../components/LinkedReposPanel';
import { MessageBlock } from '../components/MessageBlock';
import { Terminal } from '../components/Terminal';
import { useSessions } from '../context/SessionsContext';
import { useStreamMessage } from '../hooks/useStreamMessage';
import { clearFailedDraft, saveFailedDraft, takeFailedDraft } from '../lib/drafts';
import { getHarness, type ModelOption } from '../lib/harnesses';
import { api } from '../lib/api';
import { discoverModels } from '../lib/models';
import { formatElapsed, formatFullTimestamp, formatTimestamp, parseTimestamp } from '../lib/time';
import type { Message, Profile, Prompt, Run } from '../types';

/** Unique `{{name}}` placeholder names in a prompt body, in first-seen order. */
export function extractVarNames(body: string): string[] {
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
  const { output, isStreaming, error: sendError, send, reset, reattachEnded } = useStreamMessage(sessionId);

  const [messages, setMessages] = useState<Message[]>([]);
  const [messagesError, setMessagesError] = useState(false);
  // Keep the completed run's live-output panel on screen when a successful
  // send's transcript refresh failed — otherwise the panel (gated on
  // isStreaming, already false by the time reload() runs) is gone and the
  // response is nowhere on screen (#214/#312). Cleared on a fresh send, on a
  // successful reload, and on navigation.
  const [keepOutput, setKeepOutput] = useState(false);
  const [input, setInput] = useState('');
  // Set when this session's composer was just populated from a persisted
  // failed draft (#104) rather than the user's own typing, so a small note
  // can explain why there's text already sitting there. Cleared as soon as
  // the user edits it or sends/discards it.
  const [recoveredDraft, setRecoveredDraft] = useState(false);
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
  // Multi-variable prompt templating: when a picked prompt has {{placeholders}},
  // collect every value in one modal instead of sequential window.prompt()
  // dialogs (#275).
  const [templatePrompt, setTemplatePrompt] = useState<{ prompt: Prompt; vars: string[] } | null>(null);
  const [templateValues, setTemplateValues] = useState<Record<string, string>>({});
  const [rendering, setRendering] = useState(false);
  const [templateError, setTemplateError] = useState('');
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const modalRef = useRef<HTMLDivElement>(null);
  // The element focused when the template modal opened (the prompt picker), so
  // focus can be returned there when the modal is dismissed (#279).
  const modalTriggerRef = useRef<HTMLElement | null>(null);
  // Set once the user manually changes the profile for this session, so the
  // mount-time GET of the attached profile can't overwrite that choice when it
  // resolves after the change (#276). Reset per session in the fetch effect.
  const profileTouchedRef = useRef(false);

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
    profileTouchedRef.current = false;
    setProfileId('');
    api
      .getSessionProfile(sessionId)
      .then(pid => {
        // Don't clobber a manual profile change made while this fetch was
        // still in flight (#276) — the response reflects the server's
        // pre-change value, so applying it would silently revert the user.
        if (active && !profileTouchedRef.current) setProfileId(pid);
      })
      .catch(() => {
        /* profile lookup unavailable — leave the selector at its default */
      });
    return () => {
      active = false;
    };
  }, [sessionId]);

  // Dismiss the modal without inserting and return focus to whatever opened it
  // (#279). The successful-submit path deliberately does NOT use this — there
  // focus should follow the inserted text to the composer textarea.
  const closeTemplate = useCallback(() => {
    setTemplatePrompt(null);
    modalTriggerRef.current?.focus();
  }, []);

  // Dialog semantics for the template modal (#278): Escape closes it and Tab
  // is trapped within it, so keyboard focus can't wander behind the overlay.
  useEffect(() => {
    if (!templatePrompt) return;
    // Lock background scroll while the modal is open (#287).
    const prevOverflow = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    // Mark the app root inert so assistive tech, Tab, and pointer input can't
    // reach background content while the modal is open (#287) — aria-modal
    // alone isn't reliable across screen readers. The modal is portaled to
    // <body>, outside #root, so it stays interactive.
    const appRoot = document.getElementById('root');
    appRoot?.setAttribute('inert', '');
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        if (!rendering) {
          e.preventDefault();
          closeTemplate();
        }
        return;
      }
      if (e.key === 'Tab' && modalRef.current) {
        const nodes = Array.from(
          modalRef.current.querySelectorAll<HTMLElement>(
            'button:not([disabled]), textarea, input, [tabindex]:not([tabindex="-1"])',
          ),
        );
        const first = nodes[0];
        const last = nodes[nodes.length - 1];
        if (!first || !last) return;
        if (e.shiftKey && document.activeElement === first) {
          e.preventDefault();
          last.focus();
        } else if (!e.shiftKey && document.activeElement === last) {
          e.preventDefault();
          first.focus();
        }
      }
    };
    document.addEventListener('keydown', onKey);
    return () => {
      document.body.style.overflow = prevOverflow;
      appRoot?.removeAttribute('inert');
      document.removeEventListener('keydown', onKey);
    };
  }, [templatePrompt, rendering, closeTemplate]);

  // Close the template modal when navigating to a different session — it was
  // opened for the previous session's prompt and composer (#282). Also clear
  // the in-flight render flag so a fresh modal opened in the new session
  // starts clean rather than inheriting a prior session's submit state (#288).
  useEffect(() => {
    setTemplatePrompt(null);
    setRendering(false);
  }, [sessionId]);

  // Recover a failed send's prompt text left behind by a PREVIOUS visit to
  // this session (#104): handleSend() below persists it via saveFailedDraft
  // when the user navigated away before the send settled, since restoring it
  // straight into `input` at that point would land in whatever session the
  // user had since navigated to. One-shot: takeFailedDraft clears it, so
  // returning to this session again later won't keep re-surfacing it.
  useEffect(() => {
    const draft = takeFailedDraft(sessionId);
    if (draft) {
      setInput(draft);
      setRecoveredDraft(true);
    } else {
      // Without this branch, a draft recovered for a PREVIOUS session (or
      // whatever the user was mid-typing there) stayed in `input`/
      // `recoveredDraft` when navigating to a session with no draft of its
      // own (#564) — showing the wrong session's leftover text, and its
      // stale "recovered draft" banner, and misdirecting it if sent.
      setInput('');
      setRecoveredDraft(false);
    }
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
  // Bumped on every sessionId change — including leaving this session and
  // returning to it — so an awaited continuation can tell "same session, but a
  // fresh visit" apart from "still the same visit". A session-id check alone
  // can't (the id is identical across an A→B→A round trip), which is the gap
  // #314 flags for handleSend's post-reload state updates.
  const generationRef = useRef(0);
  useEffect(() => {
    currentSessionRef.current = sessionId;
    generationRef.current += 1;
  }, [sessionId]);

  // Latest isStreaming, readable from an awaited continuation without a stale
  // closure — lets foldRunIntoTranscript tell whether a *new* run has started
  // streaming since the one it's folding finished (#320).
  const isStreamingRef = useRef(isStreaming);
  useEffect(() => {
    isStreamingRef.current = isStreaming;
  }, [isStreaming]);

  // Run timing for the live-output panel: when streaming starts, stamp the
  // start; when it ends, stamp the finish. A 1s ticker drives the elapsed
  // readout while the run is live, so it's always clear when a run began and
  // how long it has been going.
  const [runStartedAt, setRunStartedAt] = useState<number | null>(null);
  const [runEndedAt, setRunEndedAt] = useState<number | null>(null);
  const [nowTick, setNowTick] = useState(() => Date.now());
  const prevStreamingRef = useRef(false);
  useEffect(() => {
    if (isStreaming && !prevStreamingRef.current) {
      setRunStartedAt(Date.now());
      setRunEndedAt(null);
    } else if (!isStreaming && prevStreamingRef.current) {
      setRunEndedAt(Date.now());
    }
    prevStreamingRef.current = isStreaming;
  }, [isStreaming]);
  useEffect(() => {
    if (!isStreaming) return;
    const t = setInterval(() => setNowTick(Date.now()), 1000);
    return () => clearInterval(t);
  }, [isStreaming]);
  // Timing belongs to a single session's run; clear it on navigation.
  useEffect(() => {
    setRunStartedAt(null);
    setRunEndedAt(null);
  }, [sessionId]);

  // Live model discovery for this session's harness (static catalog fallback;
  // see lib/models.ts). The session's *current* model is always selectable
  // even when a provider listing omits it.
  const sessionHarness = session?.harness ?? 'claude';
  const [availableModels, setAvailableModels] = useState<ModelOption[]>(
    () => getHarness(sessionHarness).models,
  );
  useEffect(() => {
    let active = true;
    setAvailableModels(getHarness(sessionHarness).models);
    discoverModels(sessionHarness).then(({ models }) => {
      if (active) setAvailableModels(models);
    });
    return () => {
      active = false;
    };
  }, [sessionHarness]);

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
  const reload = useCallback(async (): Promise<boolean> => {
    const forSessionId = sessionId;
    const fetched = await fetchMessages(forSessionId);
    if (fetched && currentSessionRef.current === forSessionId) {
      setMessages(fetched);
      setMessagesError(false);
      return true;
    }
    return false;
  }, [sessionId, fetchMessages]);

  // Fold a just-finished run into the persisted transcript: reload it, then
  // clear the live panel only if the reload applied fresh messages — otherwise
  // keep the completed output visible instead of losing it (#214/#312). Gated
  // on session id + generation so a navigate-away-and-back mid-reload can't
  // apply a stale result (#314). Shared by handleSend's success path and the
  // reattach-completion effect below, so a reattached run gets the same
  // post-run handling a locally-sent one does (#316).
  const foldRunIntoTranscript = useCallback(async () => {
    const forSession = sessionId;
    const forGeneration = generationRef.current;
    const reloaded = await reload();
    if (currentSessionRef.current !== forSession || generationRef.current !== forGeneration) return;
    // A new run may have started streaming during reload() — a fresh same-
    // session send (the composer re-enables the moment the prior run ends) or a
    // reattach. It now owns the live panel, so don't reset()/keepOutput and
    // clobber its output (#320). Same session + generation, so the guards above
    // can't catch this — the isStreaming ref can.
    if (isStreamingRef.current) return;
    if (reloaded) {
      reset();
      setKeepOutput(false);
    } else {
      setKeepOutput(true);
    }
  }, [sessionId, reload, reset]);

  // A reattached run finished (the hook bumps reattachEnded) — fold it into the
  // transcript exactly as a completed send() does (#316). Tracked against the
  // previous value so this only fires on a real increment, not when
  // foldRunIntoTranscript's identity changes on navigation.
  const prevReattachEnded = useRef(reattachEnded);
  useEffect(() => {
    if (reattachEnded === prevReattachEnded.current) return;
    prevReattachEnded.current = reattachEnded;
    void foldRunIntoTranscript();
  }, [reattachEnded, foldRunIntoTranscript]);

  useEffect(() => {
    // Guard against a slow fetch for a previous session resolving after
    // navigating to a new one and overwriting its transcript with stale data
    // — session switches change `sessionId` without remounting this
    // component, so a request in flight can outlive the session it was for.
    // Same pattern as CommentThread.tsx's `active` flag.
    let active = true;
    setMessagesError(false);
    setKeepOutput(false); // a retained prior-session response must not linger here
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
    // Fixed at call time to whichever session this send was actually for —
    // `sessionId` may point somewhere else by the time this async function
    // resumes below (#104).
    const forSessionAtSend = sessionId;
    setInput('');
    setRecoveredDraft(false);
    setKeepOutput(false); // a fresh run supersedes any retained prior output
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
      if (!succeeded) {
        // The usual restore (setInput(text) below) can't run here — it
        // would land in whatever session's composer is on screen NOW, not
        // necessarily the one this send actually failed for.
        if (currentSessionRef.current === forSessionAtSend) {
          // ...except when it's the SAME session currently on screen — just a
          // later generation (the user left session A and came back to A
          // before this send settled). The mount-time recovery effect already
          // ran for this visit and found nothing, since this draft didn't
          // exist in storage yet; nothing else re-triggers it for the
          // CURRENTLY-viewed session, so without this the draft would sit in
          // storage unsurfaced until a separate, later revisit (#569). Reflect
          // it directly instead of persisting it — persisting AND setting
          // state here would leave a stale copy in storage that reappears on
          // a future revisit even though it was already shown just now.
          setInput(text);
          setRecoveredDraft(true);
        } else {
          // Genuinely a different session on screen now — persist it against
          // forSessionAtSend instead, so it isn't silently lost (#104): the
          // recovery effect above hands it back the next time that session is
          // opened.
          saveFailedDraft(forSessionAtSend, text);
        }
      } else {
        // Mirrors the non-stale success path below: a fresh send for
        // forSessionAtSend just succeeded, so any EARLIER failed draft still
        // persisted for it is now moot — clear it here too, not just in the
        // non-stale branch, otherwise a stale-but-successful send left a
        // now-obsolete draft sitting in storage forever (#581).
        clearFailedDraft(forSessionAtSend);
      }
      return;
    }

    if (succeeded) {
      // This session's outstanding failed draft, if any, is now moot — a
      // fresh send for it just succeeded.
      clearFailedDraft(forSessionAtSend);
      // Fold the completed run into the transcript (reload + keep-or-clear the
      // live panel), shared with the reattach path. See foldRunIntoTranscript.
      await foldRunIntoTranscript();
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
    // Mark before the await so a still-in-flight mount-time fetch won't revert
    // this choice when it resolves (#276).
    profileTouchedRef.current = true;
    const forSession = sessionId;
    setProfileSaving(true);
    try {
      await api.setSessionProfile(forSession, pid);
      // Only reflect the change if still on the session it was made for (#283)
      // — a navigation during the await would otherwise show this profile
      // under a different session's selector.
      if (currentSessionRef.current === forSession) setProfileId(pid);
    } catch (err) {
      // The change didn't take effect, so stop suppressing the mount-time
      // fetch — otherwise a failed change would leave the selector stuck at
      // its reset value for the rest of the session even though the server
      // still has the real profile (#285). Only do this while still on the
      // session the change was for: after navigating away, the ref belongs to
      // the new session (possibly guarding its own manual change), so clearing
      // it here would clobber that (#289).
      if (currentSessionRef.current === forSession) {
        profileTouchedRef.current = false;
      }
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

  // Append to any existing draft rather than replace, so a prompt can be
  // combined with typed context.
  const insertText = useCallback((text: string) => {
    setInput(prev => (prev.trim() ? `${prev.trimEnd()}\n\n${text}` : text));
    textareaRef.current?.focus();
  }, []);

  const handleInsertPrompt = (promptId: string) => {
    const p = prompts.find(x => x.id === promptId);
    if (!p) return;
    const vars = extractVarNames(p.body);
    if (vars.length > 0) {
      // Open the modal to collect all placeholder values at once (#275);
      // rendering + use-count happen server-side on submit. Remember the
      // trigger element so focus can return to it on dismiss (#279).
      modalTriggerRef.current = document.activeElement as HTMLElement | null;
      const initial: Record<string, string> = {};
      for (const name of vars) initial[name] = '';
      setTemplateValues(initial);
      setTemplateError('');
      setTemplatePrompt({ prompt: p, vars });
      return;
    }
    // No placeholders — insert verbatim. Usage bookkeeping is best-effort;
    // the count just informs the library UI.
    api.usePrompt(p.id).catch(() => { /* non-fatal */ });
    insertText(p.body);
  };

  const submitTemplate = async () => {
    if (!templatePrompt || rendering) return;
    // The server render is a round trip; the user can navigate to a different
    // session before it resolves (SessionDetail re-renders without remounting).
    // Capture the session so a late result isn't dropped into the wrong
    // session's composer (#282) — same guard handleSend uses via
    // currentSessionRef.
    const forSession = sessionId;
    setRendering(true);
    setTemplateError('');
    try {
      const text = await api.renderPrompt(templatePrompt.prompt.id, templateValues);
      // If the user navigated to a different session mid-render, the modal
      // this submit belonged to has already been closed (and rendering reset)
      // by the close-on-navigate effect — and the shared modal state may now
      // back a *newly opened* modal for the current session. Mutating
      // templatePrompt/rendering/error here would close or corrupt that newer
      // modal (#288), so bail without touching any of it.
      if (currentSessionRef.current !== forSession) return;
      setRendering(false);
      setTemplatePrompt(null);
      insertText(text);
    } catch (err) {
      // Same guard on the error path: only surface the failure on the modal
      // that issued the request (#288).
      if (currentSessionRef.current === forSession) {
        setTemplateError(err instanceof Error ? err.message : 'Failed to render prompt');
        setRendering(false);
      }
    }
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
    // Otherwise a deleted session's persisted failed-draft entry (#104)
    // lingers in localStorage forever (#572) — nothing else ever visits a
    // deleted session's id again to read/clear it via takeFailedDraft.
    clearFailedDraft(session.sessionId);
    removeSession(session.sessionId);
    navigate('/sessions');
  };

  return (
    <div style={pageStyle}>
      {templatePrompt && createPortal(
        <div
          style={modalOverlayStyle}
          onClick={() => { if (!rendering) closeTemplate(); }}
        >
          <div
            ref={modalRef}
            style={modalStyle}
            role="dialog"
            aria-modal="true"
            aria-labelledby="template-modal-title"
            onClick={e => e.stopPropagation()}
          >
            <div id="template-modal-title" style={modalTitleStyle}>
              Fill in “{templatePrompt.prompt.name}”
            </div>
            <div style={modalSubtitleStyle}>
              {templatePrompt.vars.length === 1
                ? '1 variable'
                : `${templatePrompt.vars.length} variables`}
            </div>
            {templatePrompt.vars.map((name, i) => (
              <label key={name} style={modalFieldStyle}>
                <span style={modalLabelStyle}>{`{{${name}}}`}</span>
                <textarea
                  autoFocus={i === 0}
                  rows={2}
                  style={modalInputStyle}
                  value={templateValues[name] ?? ''}
                  onChange={e =>
                    setTemplateValues(prev => ({ ...prev, [name]: e.target.value }))
                  }
                  onKeyDown={e => {
                    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
                      e.preventDefault();
                      void submitTemplate();
                    }
                  }}
                />
              </label>
            ))}
            {templateError && <div role="alert" style={modalErrorStyle}>{templateError}</div>}
            <div style={modalActionsStyle}>
              <button
                style={modalCancelBtnStyle}
                onClick={closeTemplate}
                disabled={rendering}
              >
                Cancel
              </button>
              <button
                style={modalInsertBtnStyle}
                onClick={() => { void submitTemplate(); }}
                disabled={rendering}
                title="Insert (⌘/Ctrl+Enter)"
              >
                {rendering ? 'Rendering…' : 'Insert'}
              </button>
            </div>
          </div>
        </div>,
        document.body,
      )}
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
              {(session.model && !availableModels.some(m => m.id === session.model)
                ? [{ id: session.model, label: session.model }, ...availableModels]
                : availableModels
              ).map(m => (
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
            {formatTimestamp(session.createdAt) && (
              <>
                <span style={{ margin: '0 8px', color: '#30363d' }}>·</span>
                <span title={formatFullTimestamp(session.createdAt)}>
                  created {formatTimestamp(session.createdAt)}
                </span>
              </>
            )}
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

      <GitHubPanel repoUrl={session.repoUrl} branch={session.branch} />

      <LinkedReposPanel
        sessionId={sessionId}
        primaryRepoUrl={session.repoUrl}
        primaryBranch={session.branch}
      />

      {showRuns && (
        <div style={runsPanelStyle}>
          <div style={runsHeaderStyle}>Run history</div>
          {runs.length === 0 && <div style={runsEmptyStyle}>No runs recorded yet.</div>}
          {runs.map(r => (
            <div key={r.id} style={runRowStyle}>
              <span style={runStatusStyle(r.status)}>{r.status}</span>
              <span style={runPreviewStyle} title={r.promptPreview}>{r.promptPreview || '(no prompt)'}</span>
              <span style={runMetaStyle} title={formatFullTimestamp(r.startedAt)}>
                {formatTimestamp(r.startedAt)}
                {runDuration(r) ? ` · ${runDuration(r)}` : ''}
              </span>
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
        {messages.length === 0 && !isStreaming && !sendError && !messagesError && !keepOutput && (
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
        {(isStreaming || sendError || keepOutput) && (
          <div style={liveWrapStyle}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
              <div style={sendError ? liveErrorLabelStyle : liveLabelStyle}>
                {isStreaming ? 'running…' : sendError ? 'failed' : 'done — could not refresh transcript'}
                {runStartedAt !== null && (
                  <span style={liveTimingStyle} title={new Date(runStartedAt).toLocaleString()}>
                    {' '}· started {formatTimestamp(String(runStartedAt))}
                    {isStreaming && ` · ${formatElapsed(nowTick - runStartedAt)}`}
                    {!isStreaming && runEndedAt !== null &&
                      ` · finished ${formatTimestamp(String(runEndedAt))} (${formatElapsed(runEndedAt - runStartedAt)})`}
                  </span>
                )}
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
              if (e.target.value) handleInsertPrompt(e.target.value);
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

      {recoveredDraft && (
        <div style={recoveredDraftStyle}>
          A message you sent to this session earlier failed to go through, and you'd navigated away
          before it could be restored — we saved it below. Send it again, or clear it and start fresh.
        </div>
      )}
      <div style={inputRowStyle}>
        <textarea
          ref={textareaRef}
          style={textareaStyle}
          rows={3}
          placeholder="Send a message… (Enter to send, Shift+Enter for newline)"
          value={input}
          onChange={e => { setRecoveredDraft(false); setInput(e.target.value); }}
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

/** "2:13" duration for a finished run, '' while running / on bad data. */
function runDuration(r: Run): string {
  const started = parseTimestamp(r.startedAt);
  const ended = parseTimestamp(r.endedAt);
  if (!Number.isFinite(started) || !Number.isFinite(ended) || ended < started) return '';
  return formatElapsed(ended - started);
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

const modalOverlayStyle: React.CSSProperties = {
  position: 'fixed',
  inset: 0,
  background: 'rgba(1, 4, 9, 0.7)',
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'center',
  padding: '24px',
  zIndex: 100,
};

const modalStyle: React.CSSProperties = {
  width: '100%',
  maxWidth: '480px',
  maxHeight: '80vh',
  overflowY: 'auto',
  background: '#161b22',
  border: '1px solid #30363d',
  borderRadius: '10px',
  padding: '20px',
  display: 'flex',
  flexDirection: 'column',
  gap: '12px',
};

const modalTitleStyle: React.CSSProperties = {
  fontSize: '15px',
  fontWeight: 600,
  color: '#c9d1d9',
};

const modalSubtitleStyle: React.CSSProperties = {
  fontSize: '12px',
  color: '#8b949e',
  marginTop: '-8px',
};

const modalFieldStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '4px',
};

const modalLabelStyle: React.CSSProperties = {
  fontSize: '12px',
  fontFamily: 'monospace',
  color: '#79c0ff',
};

const modalInputStyle: React.CSSProperties = {
  padding: '8px 10px',
  background: '#0d1117',
  border: '1px solid #30363d',
  borderRadius: '6px',
  color: '#c9d1d9',
  fontSize: '13px',
  fontFamily: 'inherit',
  resize: 'vertical',
  outline: 'none',
  boxSizing: 'border-box',
};

const modalErrorStyle: React.CSSProperties = {
  fontSize: '12px',
  color: '#f85149',
};

const modalActionsStyle: React.CSSProperties = {
  display: 'flex',
  justifyContent: 'flex-end',
  gap: '8px',
  marginTop: '4px',
};

const modalCancelBtnStyle: React.CSSProperties = {
  padding: '6px 14px',
  background: 'transparent',
  color: '#8b949e',
  border: '1px solid #30363d',
  borderRadius: '6px',
  fontSize: '13px',
  cursor: 'pointer',
};

const modalInsertBtnStyle: React.CSSProperties = {
  padding: '6px 14px',
  background: '#1f6feb',
  color: '#fff',
  border: 'none',
  borderRadius: '6px',
  fontSize: '13px',
  fontWeight: 500,
  cursor: 'pointer',
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

const recoveredDraftStyle: React.CSSProperties = {
  color: '#d29922',
  fontSize: '12px',
  padding: '6px 10px',
  marginBottom: '6px',
  background: '#2d2a12',
  border: '1px solid #4a3f0f',
  borderRadius: '6px',
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

const liveTimingStyle: React.CSSProperties = {
  color: '#8b949e',
  textTransform: 'none',
  letterSpacing: 'normal',
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
