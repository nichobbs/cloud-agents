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
  isArchived?: string;
  /** Group (folder) this session belongs to; '' or absent when ungrouped. */
  groupId?: string;
  /** Epoch-millis string of when the user last opened the session; '0' if never. */
  lastViewedAt?: string;
  /** Count (as string) of pending callbacks awaiting a human. */
  pendingCount?: string;
  /** Server-derived attention state: working | pending | viewed | idle.
   *  Absent on older backends — use lib/attention.ts sessionAttention(). */
  attention?: string;
}

/// A folder in the session tree. Groups nest via parentId ('' = root) and
/// are owned by the requesting user.
export interface SessionGroup {
  id: string;
  name: string;
  parentId: string;
  createdAt: string;
}

/// One changed file in GET /api/sessions/{id}/workspace/diff.
/// status: M modified, A added, D deleted, R renamed, U untracked, X other.
/// additions/deletions are line counts as strings, '' when unknown (binary).
export interface WorkspaceDiffFile {
  path: string;
  status: string;
  additions: string;
  deletions: string;
}

/// GET /api/sessions/{id}/workspace/diff response. `patch` is the full
/// unified diff; `clean` is 'true' when the workspace has no changes.
export interface WorkspaceDiff {
  files: WorkspaceDiffFile[];
  patch: string;
  clean: string;
}

/// One entry of GET /api/sessions/{id}/workspace/files.
export interface WorkspaceFileEntry {
  path: string;
}

/// GET /api/sessions/{id}/workspace/file?path=… response. Content is
/// base64 of the first 1 MiB; `size` is the full byte size; `truncated`
/// is 'true' when the file exceeded the cap.
export interface WorkspaceFileContent {
  path: string;
  contentBase64: string;
  size: string;
  truncated: string;
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

/// GET /api/search/messages?q=... response. `truncated` is true when the
/// true match count exceeded the server's cap (50) — the returned messages
/// are just the newest 50, not the complete result set.
export interface SearchMessagesResult {
  messages: Message[];
  truncated: boolean;
}

/// POST /api/sessions/{id}/open-pr response. `created` is false when an
/// already-open PR for the session's branch was found and reused instead of
/// opening a duplicate.
export interface OpenPrResult {
  url: string;
  created: boolean;
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
/// container gets, which credentials are injected (least privilege), and
/// which of the shim's MCP callback tools are enabled.
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
  toolMode: 'all' | 'selected';
  tools: string[]; // enabled shim tool names (selected mode)
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
/// on the profile for anything secret; an env value can reference that
/// credential by name (e.g. "GITHUB_PERSONAL_ACCESS_TOKEN=${GITHUB_TOKEN}")
/// and docker/inject-library.sh expands it against the container's real
/// environment at injection time.
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
  enabled: string; // '1' | '0' — '0' is saved but withheld from every container injection
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
  /** 'pending' | 'in_progress' | 'done'; '' from a pre-migration backend. */
  status: string;
}

/// A notable item the summarizer extracted from an agent response
/// (discovery, issue, workaround, revert, incomplete work, followup).
export interface Highlight {
  id: string;
  sessionId: string;
  messageId: string;
  kind: string;
  title: string;
  detail: string;
  createdAt: string;
}

export interface RefreshHighlightsResult {
  status: string; // 'disabled' | 'ok' | 'error'
  scanned: string;
  added: string;
  detail: string;
}

export interface PermissionRequest {
  id: string;
  sessionId: string;
  toolName: string;
  inputJson: string;
  status: string; // 'pending' | 'allowed' | 'denied'
  updatedInputJson?: string;
  note?: string;
  createdAt: string;
  decidedAt?: string;
}

export interface UserQuestion {
  id: string;
  sessionId: string;
  question: string;
  optionsJson: string; // JSON string of choices
  status: string; // 'pending' | 'answered' | 'timeout'
  answer?: string;
  createdAt: string;
  decidedAt?: string;
}

export interface SecretRequest {
  id: string;
  sessionId: string;
  name: string;
  reason: string;
  status: string; // 'pending' | 'allowed' | 'denied'
  createdAt: string;
  decidedAt?: string;
}

export interface PendingCallbacksResponse {
  permissionRequests: PermissionRequest[];
  userQuestions: UserQuestion[];
  secretRequests: SecretRequest[];
}
