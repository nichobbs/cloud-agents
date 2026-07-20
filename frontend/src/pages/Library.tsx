import { useEffect, useState } from 'react';
import { api } from '../lib/api';
import type { McpServer, Skill, Subagent } from '../types';

type Tab = 'skills' | 'subagents' | 'mcp';

/// A starter template a user can clone into their own library — not shipped
/// as a distinct backend concept, just pre-fills the create form below.
interface SkillTemplate {
  name: string;
  description: string;
  body: string;
}

interface SubagentTemplate {
  name: string;
  description: string;
  systemPrompt: string;
}

interface McpServerTemplate {
  name: string;
  transport: 'stdio' | 'url';
  command: string;
  args: string[];
}

const skillTemplates: SkillTemplate[] = [
  {
    name: 'commit-message',
    description: 'Write a Conventional Commits-style message from the staged diff.',
    body: '## Steps\n1. Run `git diff --staged`.\n2. Summarize the change in one imperative sentence (max 72 chars).\n3. Prefix with `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, or `chore:`.\n4. Add a body only if the summary line cannot capture the "why".',
  },
  {
    name: 'pr-description',
    description: 'Draft a pull request description from the branch\'s commits and diff.',
    body: '## Steps\n1. Run `git log main..HEAD --oneline` and `git diff main...HEAD`.\n2. Write a Summary section (2-3 bullets) and a Test plan checklist.\n3. Keep it focused on what changed and why, not how.',
  },
];

const subagentTemplates: SubagentTemplate[] = [
  {
    name: 'code-reviewer',
    description: 'Use this agent to review a diff for bugs, style, and simplification before committing.',
    systemPrompt: 'You are a meticulous code reviewer. Read the diff, flag correctness bugs first, then style and simplification opportunities. Cite file:line for every finding. Be concise — no praise, no restating the diff.',
  },
  {
    name: 'test-writer',
    description: 'Use this agent to write focused unit tests for recently changed code.',
    systemPrompt: 'You write focused, deterministic unit tests for the code you are shown. Cover the happy path and the edge cases a reviewer would ask about. Match the existing test file\'s style and assertion helpers exactly — do not introduce a new testing convention.',
  },
];

const mcpServerTemplates: McpServerTemplate[] = [
  { name: 'fetch', transport: 'stdio', command: 'npx', args: ['-y', '@modelcontextprotocol/server-fetch'] },
  { name: 'sequential-thinking', transport: 'stdio', command: 'npx', args: ['-y', '@modelcontextprotocol/server-sequential-thinking'] },
];

/// Skills, subagents, and MCP servers a profile can grant to a session
/// (Profiles page). Skills and subagents render into every harness's own
/// native config unchanged (SKILL.md is a shared format as of 2026; each
/// harness's subagent format differs but the fields here cover all of them).
export function Library() {
  const [tab, setTab] = useState<Tab>('skills');
  return (
    <div style={pageStyle}>
      <h2 style={titleStyle}>Library</h2>
      <p style={subtitleStyle}>
        Reusable skills, subagents, and MCP servers. Grant them to a profile on the{' '}
        <a href="/profiles" style={linkStyle}>Profiles</a> page to make them available to a session — each is
        rendered into every harness's own native config at container start.
      </p>
      <div style={tabsStyle}>
        <button style={tabBtnStyle(tab === 'skills')} onClick={() => setTab('skills')}>Skills</button>
        <button style={tabBtnStyle(tab === 'subagents')} onClick={() => setTab('subagents')}>Subagents</button>
        <button style={tabBtnStyle(tab === 'mcp')} onClick={() => setTab('mcp')}>MCP servers</button>
      </div>
      {tab === 'skills' && <SkillsTab />}
      {tab === 'subagents' && <SubagentsTab />}
      {tab === 'mcp' && <McpServersTab />}
    </div>
  );
}

function SkillsTab() {
  const [items, setItems] = useState<Skill[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [body, setBody] = useState('');

  const reload = async () => {
    try {
      setItems(await api.getSkills());
      setError('');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load skills');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    void reload();
  }, []);

  const clearForm = () => {
    setEditingId(null);
    setName('');
    setDescription('');
    setBody('');
  };

  const useTemplate = (t: SkillTemplate) => {
    setEditingId(null);
    setName(t.name);
    setDescription(t.description);
    setBody(t.body);
  };

  const save = async () => {
    if (!name.trim() || !description.trim() || !body.trim() || saving) return;
    setSaving(true);
    setError('');
    const payload = { name: name.trim(), description: description.trim(), body };
    try {
      if (editingId) {
        await api.updateSkill(editingId, payload);
      } else {
        await api.addSkill(payload);
      }
      clearForm();
      await reload();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to save skill');
    } finally {
      setSaving(false);
    }
  };

  const remove = async (s: Skill) => {
    if (!confirm(`Delete skill "${s.name}"? Profiles granting it will lose access.`)) return;
    setError('');
    try {
      await api.deleteSkill(s.id);
      if (editingId === s.id) clearForm();
      await reload();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to delete skill');
    }
  };

  const valid = name.trim() && description.trim() && body.trim();

  return (
    <>
      <div style={templatesStyle}>
        <span style={templatesLabelStyle}>Start from:</span>
        {skillTemplates.map(t => (
          <button key={t.name} style={templateChipStyle} onClick={() => useTemplate(t)}>{t.name}</button>
        ))}
      </div>
      <div style={formStyle}>
        <input
          style={inputStyle}
          placeholder="Name (e.g. commit-message)"
          value={name}
          onChange={e => setName(e.target.value)}
          maxLength={128}
          aria-label="Skill name"
        />
        <input
          style={inputStyle}
          placeholder="Description (when should this skill be used?)"
          value={description}
          onChange={e => setDescription(e.target.value)}
          maxLength={2000}
          aria-label="Skill description"
        />
        <textarea
          style={textareaStyle}
          placeholder="SKILL.md body (markdown instructions)"
          value={body}
          onChange={e => setBody(e.target.value)}
          rows={8}
          aria-label="Skill body"
        />
        <FormActions saving={saving} valid={!!valid} editing={!!editingId} onSave={() => { void save(); }} onCancel={clearForm} label="skill" />
      </div>
      {error && <div style={errStyle}>{error}</div>}
      {loading && <div style={mutedStyle}>Loading…</div>}
      {!loading && items.length === 0 && <div style={mutedStyle}>No skills yet — create one above.</div>}
      {items.map(s => (
        <div key={s.id} style={cardStyle}>
          <CardHeader
            name={s.name}
            onEdit={() => { setEditingId(s.id); setName(s.name); setDescription(s.description); setBody(s.body); }}
            onDelete={() => { void remove(s); }}
          />
          <div style={descStyle}>{s.description}</div>
        </div>
      ))}
    </>
  );
}

function SubagentsTab() {
  const [items, setItems] = useState<Subagent[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [systemPrompt, setSystemPrompt] = useState('');
  const [model, setModel] = useState('');

  const reload = async () => {
    try {
      setItems(await api.getSubagents());
      setError('');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load subagents');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    void reload();
  }, []);

  const clearForm = () => {
    setEditingId(null);
    setName('');
    setDescription('');
    setSystemPrompt('');
    setModel('');
  };

  const useTemplate = (t: SubagentTemplate) => {
    setEditingId(null);
    setName(t.name);
    setDescription(t.description);
    setSystemPrompt(t.systemPrompt);
    setModel('');
  };

  const save = async () => {
    if (!name.trim() || !description.trim() || !systemPrompt.trim() || saving) return;
    setSaving(true);
    setError('');
    const payload = { name: name.trim(), description: description.trim(), systemPrompt, model: model.trim() };
    try {
      if (editingId) {
        await api.updateSubagent(editingId, payload);
      } else {
        await api.addSubagent(payload);
      }
      clearForm();
      await reload();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to save subagent');
    } finally {
      setSaving(false);
    }
  };

  const remove = async (s: Subagent) => {
    if (!confirm(`Delete subagent "${s.name}"? Profiles granting it will lose access.`)) return;
    setError('');
    try {
      await api.deleteSubagent(s.id);
      if (editingId === s.id) clearForm();
      await reload();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to delete subagent');
    }
  };

  const valid = name.trim() && description.trim() && systemPrompt.trim();

  return (
    <>
      <div style={templatesStyle}>
        <span style={templatesLabelStyle}>Start from:</span>
        {subagentTemplates.map(t => (
          <button key={t.name} style={templateChipStyle} onClick={() => useTemplate(t)}>{t.name}</button>
        ))}
      </div>
      <div style={formStyle}>
        <input
          style={inputStyle}
          placeholder="Name (e.g. code-reviewer)"
          value={name}
          onChange={e => setName(e.target.value)}
          maxLength={128}
          aria-label="Subagent name"
        />
        <input
          style={inputStyle}
          placeholder="Description (when should this subagent be used?)"
          value={description}
          onChange={e => setDescription(e.target.value)}
          maxLength={2000}
          aria-label="Subagent description"
        />
        <textarea
          style={textareaStyle}
          placeholder="System prompt"
          value={systemPrompt}
          onChange={e => setSystemPrompt(e.target.value)}
          rows={8}
          aria-label="Subagent system prompt"
        />
        <input
          style={inputStyle}
          placeholder="Model override (optional — blank uses the harness default)"
          value={model}
          onChange={e => setModel(e.target.value)}
          maxLength={200}
          aria-label="Subagent model override"
        />
        <FormActions saving={saving} valid={!!valid} editing={!!editingId} onSave={() => { void save(); }} onCancel={clearForm} label="subagent" />
      </div>
      {error && <div style={errStyle}>{error}</div>}
      {loading && <div style={mutedStyle}>Loading…</div>}
      {!loading && items.length === 0 && <div style={mutedStyle}>No subagents yet — create one above.</div>}
      {items.map(s => (
        <div key={s.id} style={cardStyle}>
          <CardHeader
            name={s.name}
            onEdit={() => { setEditingId(s.id); setName(s.name); setDescription(s.description); setSystemPrompt(s.systemPrompt); setModel(s.model); }}
            onDelete={() => { void remove(s); }}
          />
          <div style={descStyle}>{s.description}</div>
          {s.model && <span style={badgeStyle}>model: {s.model}</span>}
        </div>
      ))}
    </>
  );
}

function McpServersTab() {
  const [items, setItems] = useState<McpServer[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [name, setName] = useState('');
  const [transport, setTransport] = useState<'stdio' | 'url'>('stdio');
  const [command, setCommand] = useState('');
  const [argsText, setArgsText] = useState('');
  const [url, setUrl] = useState('');
  const [envText, setEnvText] = useState('');

  const reload = async () => {
    try {
      setItems(await api.getMcpServers());
      setError('');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load MCP servers');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    void reload();
  }, []);

  const clearForm = () => {
    setEditingId(null);
    setName('');
    setTransport('stdio');
    setCommand('');
    setArgsText('');
    setUrl('');
    setEnvText('');
  };

  const useTemplate = (t: McpServerTemplate) => {
    setEditingId(null);
    setName(t.name);
    setTransport(t.transport);
    setCommand(t.command);
    setArgsText(t.args.join('\n'));
    setUrl('');
    setEnvText('');
  };

  const linesOf = (text: string): string[] => text.split('\n').map(l => l.trim()).filter(l => l.length > 0);

  const save = async () => {
    if (!name.trim() || saving) return;
    if (transport === 'stdio' && !command.trim()) return;
    if (transport === 'url' && !url.trim()) return;
    setSaving(true);
    setError('');
    const payload = {
      name: name.trim(),
      transport,
      command: command.trim(),
      args: linesOf(argsText),
      url: url.trim(),
      env: linesOf(envText),
    };
    try {
      if (editingId) {
        await api.updateMcpServer(editingId, payload);
      } else {
        await api.addMcpServer(payload);
      }
      clearForm();
      await reload();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to save MCP server');
    } finally {
      setSaving(false);
    }
  };

  const remove = async (s: McpServer) => {
    if (!confirm(`Delete MCP server "${s.name}"? Profiles granting it will lose access.`)) return;
    setError('');
    try {
      await api.deleteMcpServer(s.id);
      if (editingId === s.id) clearForm();
      await reload();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to delete MCP server');
    }
  };

  const valid = name.trim() && (transport === 'stdio' ? command.trim() : url.trim());

  return (
    <>
      <div style={templatesStyle}>
        <span style={templatesLabelStyle}>Start from:</span>
        {mcpServerTemplates.map(t => (
          <button key={t.name} style={templateChipStyle} onClick={() => useTemplate(t)}>{t.name}</button>
        ))}
      </div>
      <div style={formStyle}>
        <input
          style={inputStyle}
          placeholder="Name (e.g. fetch)"
          value={name}
          onChange={e => setName(e.target.value)}
          maxLength={128}
          aria-label="MCP server name"
        />
        <label style={fieldStyle}>
          <span style={labelStyle}>Transport</span>
          <select style={selectStyle} value={transport} onChange={e => setTransport(e.target.value as 'stdio' | 'url')}>
            <option value="stdio">stdio (command)</option>
            <option value="url">url (remote)</option>
          </select>
        </label>
        {transport === 'stdio' ? (
          <>
            <input
              style={inputStyle}
              placeholder="Command (e.g. npx)"
              value={command}
              onChange={e => setCommand(e.target.value)}
              maxLength={4096}
              aria-label="MCP server command"
            />
            <textarea
              style={textareaStyle}
              placeholder={'Args, one per line (e.g.\n-y\n@modelcontextprotocol/server-fetch)'}
              value={argsText}
              onChange={e => setArgsText(e.target.value)}
              rows={3}
              aria-label="MCP server args"
            />
            <textarea
              style={textareaStyle}
              placeholder={'Literal env vars, one KEY=VALUE per line (non-secret only — grant a matching credential name for secrets)'}
              value={envText}
              onChange={e => setEnvText(e.target.value)}
              rows={2}
              aria-label="MCP server env"
            />
          </>
        ) : (
          <input
            style={inputStyle}
            placeholder="URL (e.g. https://example.com/mcp)"
            value={url}
            onChange={e => setUrl(e.target.value)}
            maxLength={4096}
            aria-label="MCP server url"
          />
        )}
        <FormActions saving={saving} valid={!!valid} editing={!!editingId} onSave={() => { void save(); }} onCancel={clearForm} label="MCP server" />
      </div>
      {error && <div style={errStyle}>{error}</div>}
      {loading && <div style={mutedStyle}>Loading…</div>}
      {!loading && items.length === 0 && <div style={mutedStyle}>No MCP servers yet — create one above.</div>}
      {items.map(s => (
        <div key={s.id} style={cardStyle}>
          <CardHeader
            name={s.name}
            onEdit={() => {
              setEditingId(s.id);
              setName(s.name);
              setTransport(s.transport);
              setCommand(s.command);
              setArgsText(s.args.join('\n'));
              setUrl(s.url);
              setEnvText(s.env.join('\n'));
            }}
            onDelete={() => { void remove(s); }}
          />
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: '6px' }}>
            <span style={badgeStyle}>{s.transport}</span>
            {s.transport === 'stdio' ? (
              <code style={grantTagStyle}>{s.command} {s.args.join(' ')}</code>
            ) : (
              <code style={grantTagStyle}>{s.url}</code>
            )}
          </div>
        </div>
      ))}
    </>
  );
}

function CardHeader({ name, onEdit, onDelete }: { name: string; onEdit: () => void; onDelete: () => void }) {
  return (
    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
      <div style={nameStyle}>{name}</div>
      <div style={{ display: 'flex', gap: '8px', flexShrink: 0 }}>
        <button style={smallBtnStyle} onClick={onEdit} aria-label={`Edit ${name}`}>Edit</button>
        <button style={{ ...smallBtnStyle, color: '#f85149', borderColor: '#f85149' }} onClick={onDelete} aria-label={`Delete ${name}`}>
          Delete
        </button>
      </div>
    </div>
  );
}

function FormActions(
  { saving, valid, editing, onSave, onCancel, label }:
  { saving: boolean; valid: boolean; editing: boolean; onSave: () => void; onCancel: () => void; label: string },
) {
  return (
    <div style={{ display: 'flex', gap: '8px' }}>
      <button style={{ ...saveBtnStyle, opacity: valid && !saving ? 1 : 0.5 }} onClick={onSave} disabled={!valid || saving}>
        {saving ? 'Saving…' : editing ? `Update ${label}` : `Create ${label}`}
      </button>
      {editing && <button style={cancelBtnStyle} onClick={onCancel}>Cancel edit</button>}
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

const titleStyle: React.CSSProperties = { fontSize: '18px', color: '#c9d1d9', margin: 0 };
const subtitleStyle: React.CSSProperties = { fontSize: '13px', color: '#8b949e', margin: 0, lineHeight: 1.5 };
const linkStyle: React.CSSProperties = { color: '#58a6ff' };

const tabsStyle: React.CSSProperties = { display: 'flex', gap: '6px', borderBottom: '1px solid #21262d' };

const tabBtnStyle = (active: boolean): React.CSSProperties => ({
  padding: '8px 14px',
  background: 'transparent',
  border: 'none',
  borderBottom: `2px solid ${active ? '#1f6feb' : 'transparent'}`,
  color: active ? '#c9d1d9' : '#8b949e',
  fontSize: '13px',
  cursor: 'pointer',
});

const templatesStyle: React.CSSProperties = { display: 'flex', flexWrap: 'wrap', gap: '6px', alignItems: 'center' };
const templatesLabelStyle: React.CSSProperties = { fontSize: '11px', color: '#8b949e', textTransform: 'uppercase', letterSpacing: '0.04em' };

const templateChipStyle: React.CSSProperties = {
  fontSize: '12px',
  color: '#8b949e',
  background: 'transparent',
  border: '1px dashed #30363d',
  borderRadius: '6px',
  padding: '4px 8px',
  cursor: 'pointer',
};

const formStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: '10px',
  background: '#161b22',
  border: '1px solid #21262d',
  borderRadius: '8px',
  padding: '14px',
};

const inputStyle: React.CSSProperties = {
  padding: '8px 10px',
  background: '#0d1117',
  border: '1px solid #30363d',
  borderRadius: '6px',
  color: '#c9d1d9',
  fontSize: '14px',
  outline: 'none',
};

const textareaStyle: React.CSSProperties = {
  ...inputStyle,
  fontFamily: 'ui-monospace, SFMono-Regular, monospace',
  resize: 'vertical',
};

const fieldStyle: React.CSSProperties = { display: 'flex', flexDirection: 'column', gap: '4px' };
const labelStyle: React.CSSProperties = { fontSize: '11px', color: '#8b949e', textTransform: 'uppercase', letterSpacing: '0.04em' };

const selectStyle: React.CSSProperties = {
  padding: '8px 10px',
  background: '#0d1117',
  border: '1px solid #30363d',
  borderRadius: '6px',
  color: '#c9d1d9',
  fontSize: '13px',
  outline: 'none',
};

const saveBtnStyle: React.CSSProperties = {
  padding: '7px 16px',
  background: '#1f6feb',
  color: '#fff',
  border: 'none',
  borderRadius: '6px',
  fontSize: '13px',
  cursor: 'pointer',
};

const cancelBtnStyle: React.CSSProperties = {
  padding: '7px 16px',
  background: 'transparent',
  color: '#8b949e',
  border: '1px solid #30363d',
  borderRadius: '6px',
  fontSize: '13px',
  cursor: 'pointer',
};

const cardStyle: React.CSSProperties = {
  background: '#0d1117',
  border: '1px solid #21262d',
  borderRadius: '8px',
  padding: '12px 14px',
  display: 'flex',
  flexDirection: 'column',
  gap: '8px',
};

const nameStyle: React.CSSProperties = { fontWeight: 600, fontSize: '14px', color: '#58a6ff' };
const descStyle: React.CSSProperties = { fontSize: '13px', color: '#8b949e' };

const badgeStyle: React.CSSProperties = {
  fontSize: '11px',
  color: '#8b949e',
  background: '#161b22',
  border: '1px solid #21262d',
  borderRadius: '10px',
  padding: '2px 8px',
};

const grantTagStyle: React.CSSProperties = { fontSize: '11px', color: '#79c0ff' };

const smallBtnStyle: React.CSSProperties = {
  padding: '3px 10px',
  background: 'transparent',
  color: '#c9d1d9',
  border: '1px solid #30363d',
  borderRadius: '6px',
  fontSize: '12px',
  cursor: 'pointer',
};

const errStyle: React.CSSProperties = { fontSize: '13px', color: '#f85149' };
const mutedStyle: React.CSSProperties = { fontSize: '13px', color: '#6e7681', textAlign: 'center', padding: '16px' };
