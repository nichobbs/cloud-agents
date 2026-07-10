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
