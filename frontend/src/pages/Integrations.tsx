import { useEffect, useState } from 'react';
import { api } from '../lib/api';
import {
  PROVIDERS,
  clearConnection,
  getConnection,
  setConnection,
  type ProviderId,
} from '../lib/connections';
import { parseCredentialInput, type ImportedCredential } from '../lib/credentialImport';
import { clearRepoCache, validateGitHubToken } from '../lib/github';
import { clearModelCache, validateModelProviderKey } from '../lib/models';

/** A changed key invalidates only that provider's cached listings: the repo
 *  cache is GitHub's, the model cache belongs to the model providers (#418). */
function clearCachesFor(provider: ProviderId): void {
  if (provider === 'github') clearRepoCache();
  else clearModelCache();
}

/// One-stop provider setup. Connecting a provider does two things at once:
///  1. uploads the key to the server-side vault under its canonical env-var
///     name, so runner containers receive it automatically, and
///  2. keeps a local copy on this device so the UI itself can call the
///     provider (live model discovery, GitHub repo/PR/CI panels).
/// The vault is write-only, so the local copy is the only way the browser can
/// use a key — deleting it here never touches the vault entry.
export function Integrations() {
  return (
    <div style={pageStyle}>
      <h2 style={titleStyle}>Integrations</h2>
      <p style={subtitleStyle}>
        Connect a provider once: the key is validated live, uploaded to the credential vault under
        its canonical name (so agent containers receive it), and kept on this device so the app can
        discover models and show GitHub status. Local copies never leave this browser except to
        call the provider itself.
      </p>
      {(Object.keys(PROVIDERS) as ProviderId[]).map(p => (
        <ProviderCard key={p} provider={p} />
      ))}
      <SmartImport />
    </div>
  );
}

function ProviderCard({ provider }: { provider: ProviderId }) {
  const meta = PROVIDERS[provider];
  const [key, setKey] = useState('');
  const [connected, setConnected] = useState(false);
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState('');
  const [error, setError] = useState('');

  useEffect(() => {
    setConnected(getConnection(provider).length > 0);
  }, [provider]);

  const connect = async () => {
    const value = key.trim();
    if (!value || busy) return;
    setBusy(true);
    setError('');
    setStatus('Validating…');
    try {
      let detail: string;
      if (provider === 'github') {
        const login = await validateGitHubToken(value);
        detail = `authenticated as ${login}`;
      } else {
        const count = await validateModelProviderKey(provider, value);
        detail = `${count} models visible`;
      }
      // Local copy first — model discovery and GitHub panels work even if the
      // vault is unavailable (e.g. ENCRYPTION_KEY not configured server-side).
      setConnection(provider, value);
      clearCachesFor(provider);
      setConnected(true);
      setKey('');
      try {
        await api.putCredential(meta.credentialName, value);
        setStatus(`Connected (${detail}) — uploaded to vault as ${meta.credentialName}.`);
      } catch (err) {
        setStatus(`Connected (${detail}).`);
        setError(
          `Vault upload failed: ${err instanceof Error ? err.message : 'unknown error'} — agent containers won't receive ${meta.credentialName} until it's stored in Credentials.`,
        );
      }
    } catch (err) {
      setStatus('');
      setError(err instanceof Error ? err.message : 'Validation failed');
    } finally {
      setBusy(false);
    }
  };

  const disconnect = () => {
    clearConnection(provider);
    clearCachesFor(provider);
    setConnected(false);
    setStatus('Disconnected on this device. The vault copy (if any) is unchanged — manage it on the Credentials page.');
  };

  return (
    <div style={cardStyle}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
        <div>
          <span style={providerNameStyle}>{meta.label}</span>
          <span style={connected ? connectedBadgeStyle : disconnectedBadgeStyle}>
            {connected ? 'connected' : 'not connected'}
          </span>
        </div>
        {connected && (
          <button style={disconnectBtnStyle} onClick={disconnect}>
            Disconnect
          </button>
        )}
      </div>
      <div style={unlocksStyle}>{meta.unlocks}</div>
      <div style={{ display: 'flex', gap: '8px', flexWrap: 'wrap' }}>
        <input
          style={inputStyle}
          type="password"
          placeholder={connected ? 'Replace key…' : meta.placeholder}
          value={key}
          onChange={e => setKey(e.target.value)}
          onKeyDown={e => {
            if (e.key === 'Enter') void connect();
          }}
          autoComplete="new-password"
          autoCapitalize="off"
          autoCorrect="off"
          spellCheck={false}
          aria-label={`${meta.label} key`}
        />
        <button
          style={{ ...connectBtnStyle, opacity: key.trim() && !busy ? 1 : 0.5 }}
          onClick={() => { void connect(); }}
          disabled={!key.trim() || busy}
        >
          {busy ? 'Connecting…' : connected ? 'Reconnect' : 'Connect'}
        </button>
      </div>
      {status && <div style={statusStyle}>{status}</div>}
      {error && <div style={errStyle}>{error}</div>}
    </div>
  );
}

/// Paste a raw key or a whole harness credentials file (Claude Code
/// `.credentials.json`, Codex `auth.json`, OpenCode `auth.json`) — recognised
/// entries are uploaded to the vault under their canonical names in one click.
function SmartImport() {
  const [text, setText] = useState('');
  const [found, setFound] = useState<ImportedCredential[]>([]);
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState('');
  const [error, setError] = useState('');

  const analyse = (value: string) => {
    setText(value);
    setResult('');
    setError('');
    setFound(parseCredentialInput(value));
  };

  const upload = async () => {
    if (found.length === 0 || busy) return;
    setBusy(true);
    setError('');
    const done: string[] = [];
    const failed: string[] = [];
    const connectedProviders: ProviderId[] = [];
    const connectionFor: Record<string, ProviderId> = {
      ANTHROPIC_API_KEY: 'anthropic',
      OPENAI_API_KEY: 'openai',
      GEMINI_API_KEY: 'google',
      GITHUB_TOKEN: 'github',
    };
    for (const cred of found) {
      try {
        await api.putCredential(cred.name, cred.value);
        done.push(cred.name);
        // Keys the UI itself can use also become local connections.
        const provider = connectionFor[cred.name];
        if (provider) {
          setConnection(provider, cred.value);
          connectedProviders.push(provider);
        }
      } catch (err) {
        failed.push(`${cred.name} (${err instanceof Error ? err.message : 'error'})`);
      }
    }
    // Invalidate only the caches whose provider key actually changed (#418).
    for (const provider of connectedProviders) clearCachesFor(provider);
    if (done.length > 0) {
      setResult(`Uploaded to vault: ${done.join(', ')}.`);
      setText('');
      setFound([]);
    }
    if (failed.length > 0) setError(`Failed: ${failed.join('; ')}`);
    setBusy(false);
  };

  return (
    <div style={cardStyle}>
      <div style={providerNameStyle}>Import harness credentials</div>
      <div style={unlocksStyle}>
        Paste an API key or the contents of a local credentials file —{' '}
        <code>~/.claude/.credentials.json</code>, <code>~/.codex/auth.json</code>, or OpenCode's{' '}
        <code>auth.json</code>. Recognised secrets upload straight to the vault under their
        canonical names. (Or run <code>scripts/upload-credentials.sh</code> to do this from your
        machine automatically.)
      </div>
      <textarea
        style={textareaStyle}
        rows={3}
        placeholder='sk-ant-…  or  {"claudeAiOauth":{"accessToken":"…"}}'
        value={text}
        onChange={e => analyse(e.target.value)}
        autoCapitalize="off"
        autoCorrect="off"
        spellCheck={false}
        aria-label="Credential text to import"
      />
      {text.trim() && found.length === 0 && (
        <div style={mutedStyle}>Nothing recognised yet — expecting a known key format or credentials file.</div>
      )}
      {found.length > 0 && (
        <div style={foundListStyle}>
          {found.map(c => (
            <div key={c.name} style={foundRowStyle}>
              <code style={{ color: '#79c0ff' }}>{c.name}</code>
              <span style={mutedStyle}>{c.source}</span>
            </div>
          ))}
          <button
            style={{ ...connectBtnStyle, opacity: busy ? 0.5 : 1, alignSelf: 'flex-start' }}
            onClick={() => { void upload(); }}
            disabled={busy}
          >
            {busy ? 'Uploading…' : `Upload ${found.length} to vault`}
          </button>
        </div>
      )}
      {result && <div style={statusStyle}>{result}</div>}
      {error && <div style={errStyle}>{error}</div>}
    </div>
  );
}

const pageStyle: React.CSSProperties = {
  maxWidth: '760px',
  margin: '0 auto',
  padding: '24px',
  display: 'flex',
  flexDirection: 'column',
  gap: '14px',
};

const titleStyle: React.CSSProperties = { fontSize: '18px', color: '#c9d1d9', margin: 0 };

const subtitleStyle: React.CSSProperties = {
  fontSize: '13px',
  color: '#8b949e',
  margin: 0,
  lineHeight: 1.5,
};

const cardStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '10px',
  background: '#161b22',
  border: '1px solid #21262d',
  borderRadius: '8px',
  padding: '14px 16px',
};

const providerNameStyle: React.CSSProperties = {
  fontSize: '14px',
  fontWeight: 600,
  color: '#c9d1d9',
};

const connectedBadgeStyle: React.CSSProperties = {
  marginLeft: '10px',
  fontSize: '11px',
  fontWeight: 600,
  color: '#56d364',
  background: 'rgba(63, 185, 80, 0.15)',
  borderRadius: '999px',
  padding: '2px 8px',
};

const disconnectedBadgeStyle: React.CSSProperties = {
  ...connectedBadgeStyle,
  color: '#8b949e',
  background: '#21262d',
};

const unlocksStyle: React.CSSProperties = { fontSize: '12px', color: '#8b949e', lineHeight: 1.5 };

const inputStyle: React.CSSProperties = {
  flex: 1,
  minWidth: '220px',
  padding: '8px 10px',
  background: '#0d1117',
  border: '1px solid #30363d',
  borderRadius: '6px',
  color: '#c9d1d9',
  fontSize: '13px',
  outline: 'none',
};

const textareaStyle: React.CSSProperties = {
  ...inputStyle,
  fontFamily: 'monospace',
  resize: 'vertical',
};

const connectBtnStyle: React.CSSProperties = {
  padding: '8px 16px',
  background: '#1f6feb',
  color: '#fff',
  border: 'none',
  borderRadius: '6px',
  fontSize: '13px',
  cursor: 'pointer',
};

const disconnectBtnStyle: React.CSSProperties = {
  padding: '3px 10px',
  background: 'transparent',
  color: '#f85149',
  border: '1px solid #f85149',
  borderRadius: '6px',
  fontSize: '12px',
  cursor: 'pointer',
};

const statusStyle: React.CSSProperties = { fontSize: '12px', color: '#56d364' };

const errStyle: React.CSSProperties = { fontSize: '12px', color: '#f85149' };

const mutedStyle: React.CSSProperties = { fontSize: '12px', color: '#6e7681' };

const foundListStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '6px',
};

const foundRowStyle: React.CSSProperties = {
  display: 'flex',
  gap: '10px',
  alignItems: 'center',
  fontSize: '12px',
};
