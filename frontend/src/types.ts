export interface Session {
  sessionId: string;
  repoUrl: string;
  branch: string;
  createdAt: string;
  harness?: string;
  model?: string;
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
