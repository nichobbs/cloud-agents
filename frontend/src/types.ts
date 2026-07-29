export interface Session {
  sessionId: string;
  repoUrl: string;
  branch: string;
  /** Epoch-millis string (server) or ISO string (locally created). */
  createdAt: string;
  harness?: string;
  model?: string;
  /** Server-side lifecycle status: IDLE | RUNNING | WARM. */
  status?: string;
  /** Epoch-millis string of the last run activity. */
  lastMessageAt?: string;
}

/// One addressable entry in a session's transcript.
export interface Message {
  id: string;
  sessionId: string;
  role: 'user' | 'agent';
  content: string;
  seq: string;
  createdAt: string;
}

/// A comment anchored to a specific message.
export interface Comment {
  id: string;
  messageId: string;
  sessionId: string;
  body: string;
  createdAt: string;
}

/// A saved, reusable prompt from the user's library.
export interface Prompt {
  id: string;
  userId: string;
  name: string;
  body: string;
  useCount: string;
  createdAt: string;
  updatedAt: string;
  tags: string[];
}

/// A per-container policy: which harness runs, what network access the
/// container gets, and which credentials are injected (least privilege).
export interface Profile {
  id: string;
  userId: string;
  name: string;
  harness: string; // '' = session chooses
  networkPolicy: 'full' | 'none' | 'restricted';
  credentialMode: 'all' | 'selected';
  credentials: string[]; // granted credential names (selected mode)
  skillIds: string[]; // granted Skill ids (library.ts)
  subagentIds: string[]; // granted Subagent ids
  mcpServerIds: string[]; // granted McpServer ids
  createdAt: string;
  updatedAt: string;
}

/// A reusable SKILL.md-format instruction set — the format has converged
/// across Claude Code, Codex CLI, Gemini CLI, and OpenCode as of 2026, so one
/// stored body renders unchanged into every harness's own skills directory.
/// Grant to a profile on the Profiles page.
export interface Skill {
  id: string;
  userId: string;
  name: string;
  description: string;
  body: string;
  createdAt: string;
  updatedAt: string;
}

/// A reusable subagent definition: rendered into each harness's own native
/// subagent format (name/description/system-prompt everywhere; model is
/// optional and only honored by harnesses that support an override).
export interface Subagent {
  id: string;
  userId: string;
  name: string;
  description: string;
  systemPrompt: string;
  model: string; // '' = harness default
  createdAt: string;
  updatedAt: string;
}

/// A reusable MCP server definition: a stdio command or a remote URL,
/// rendered into each harness's own native MCP config. `env` entries are
/// literal, non-secret config ("DEBUG=1") — grant a matching credential name
/// on the profile for anything secret.
export interface McpServer {
  id: string;
  userId: string;
  name: string;
  transport: 'stdio' | 'url';
  command: string; // stdio only
  args: string[]; // stdio only, ordered
  url: string; // url only
  env: string[]; // "KEY=VALUE" entries, stdio only
  createdAt: string;
  updatedAt: string;
}

/// One agent run in a session's history.
export interface Run {
  id: string;
  sessionId: string;
  userId: string;
  promptPreview: string;
  harness: string;
  model: string;
  status: 'running' | 'succeeded' | 'failed' | 'cancelled';
  startedAt: string;
  endedAt: string;
}

/// A registered run-completion webhook target.
export interface Webhook {
  id: string;
  userId: string;
  url: string;
  createdAt: string;
}

/// A stored credential's public metadata. Values are write-only — the server
/// never returns a secret — so this carries only the name and last-updated time.
export interface Credential {
  name: string;
  updatedAt: string;
}

/// A todo / bookmark, optionally linked back to a source message.
export interface Todo {
  id: string;
  sessionId: string;
  messageId: string;
  note: string;
  done: string; // '0' | '1'
  createdAt: string;
}
