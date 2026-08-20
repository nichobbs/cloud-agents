# Spec: chat document/image attachments

Status: **Implemented** (backend + frontend). Adds upload support to a
session's chat composer — images and documents alike — landing alongside the
existing text-only `POST /api/sessions/{id}/messages`.

## 1. Purpose and scope

Before this, a session's only input channel was the prompt text box; a user
who wanted the agent to look at a screenshot, a PDF, or a log file had no way
to get it there short of pasting text. This adds a file picker to the
composer that carries images and documents alongside the prompt.

**In scope:** uploading files with a chat message; persisting them
(metadata in SQLite, bytes on disk); making them visible to the agent inside
the runner container; listing/downloading them from the UI, including after
a page reload.

**Out of scope / deferred:** editing/replacing an already-sent attachment;
attachments on scheduled-job runs (`CloudAgents.Jobs`/`runSessionMessageBlocking`
has no composer UI, so it always sends none); a native multimodal API call to
the harness (see §4 — deliberately not needed).

## 2. Request/response shape

```
POST /api/sessions/{id}/messages
{
  "text": "what's going on in this screenshot?",
  "attachments": [
    {"fileName": "screenshot.png", "mimeType": "image/png", "contentBase64": "..."}
  ]
}
```

- `text` may now be empty when `attachments` is non-empty (a pure file drop);
  empty `text` with empty `attachments` is still the existing 400.
- Standard (non-URL-safe) base64, no `data:...;base64,` prefix — mirrors
  `CloudAgents.Callbacks.UploadArtifactRequest.contentBase64`.
- Limits (`src/handlers/sessions.l`): 20 MiB decoded bytes per file, 50 MiB
  total per message, 10 files per message. Enforced server-side
  (authoritative) and client-side (fail fast, no wasted upload).

```
GET /api/sessions/{id}/attachments
-> {"attachments":[{"id":..., "sessionId":..., "messageId":..., "fileName":...,
                     "mimeType":..., "kind":"image"|"document",
                     "sizeBytes":..., "createdAt":...}]}

GET /api/sessions/{id}/attachments/{aid}
-> 200 with the raw bytes, Content-Type: <mimeType>,
   Content-Disposition: inline; filename="<fileName>"
```

`messageId` is `''` in the brief window between an upload being stored and
the user message it was sent with being persisted — see §3.

## 3. Storage

Metadata lives in `session_attachments` (migration `0031_session_attachments`,
`src/db/db_client.l`/`src/db/repository.l`) — mirrors the existing
`artifacts` table (Phase 6 §7 `report_artifact`) but for user-supplied input
rather than container-reported output. Bytes live on disk at
`CloudAgents.Repository.attachmentsBaseDir()/<sessionId>/<storedName>`
(`CLOUD_AGENTS_ATTACHMENTS_DIR` env var, same override convention as
`CLOUD_AGENTS_ARTIFACTS_DIR`); `storedName` is `<attachmentId>_<fileName>`,
collision-free within a session the same way `report_artifact`'s
`storedName` is.

`CloudAgents.Handlers.storeAttachments` (`src/handlers/sessions.l`) does the
validate-then-persist work: per-file and per-message size/count checks, a
basename-only sanitized `fileName` (path traversal neutralized, same
guarantee as artifact uploads), then a DB row per file with `messageId`
starting `''`. `streamSendMessage` calls it BEFORE claiming the session's run
lock (so a bad upload 400s without ever locking the session), then — once
`CloudAgents.Repository.addMessage` mints the user message's id —
`CloudAgents.Repository.linkAttachmentToMessage` back-fills `messageId` on
each stored row. The message's persisted transcript `content` is the
ORIGINAL text the user typed, not the container-bound prompt built in §4 — so
the UI shows what the user actually typed, not an internal file manifest.

## 4. Reaching the agent: no new multimodal plumbing

`claude -p "${PROMPT}"` (`docker/entrypoint.sh`) takes a single text prompt —
there is no separate image/document channel into the harness CLI. Rather than
teach the invocation a second input format, `CloudAgents.Docker`
bind-mounts the session's attachments directory
(`attachmentsBaseDir()/<sessionId>/`) read-write at `/workspace/.attachments`
whenever a message carries at least one attachment
(`createRunnerContainer`'s `attachmentsHostDir` param, threaded through
`streamSessionMessage`/`runSessionMessageAsync` — `runSessionMessageBlocking`,
used only by scheduled jobs with no composer, always passes `""`), and
`CloudAgents.Handlers.promptWithAttachments` appends a short manifest to the
CONTAINER-bound prompt naming each file's in-container path and mime type,
e.g.:

```
[The user attached 1 file(s) to this message. Read each one with the Read tool before responding:
- /workspace/.attachments/<id>_screenshot.png (image/png)
]
```

This works for both images and documents with no separate vision-payload
code: Claude Code's own `Read` tool is already multimodal (it reads text
files as text and image files as image content blocks), so once a file is on
disk and the agent is told where to look, the harness's existing tool-call
loop does the rest. `docker/entrypoint.sh` needed NO changes — its existing
unconditional `chown -R claude-user:claude-user /workspace || true` already
recurses into a bind mount nested under `/workspace`, the same as every
other workspace path.

## 5. Frontend

`frontend/src/pages/SessionDetail.tsx`: a paperclip button opens a hidden
multi-file `<input>`; each picked file is read to base64 via `FileReader`,
staged (with a thumbnail preview for images), and validated against the same
limits as §2. `frontend/src/components/MessageBlock.tsx` renders a message's
attachments (fetched via `api.listAttachments`, grouped by `messageId`) as
image thumbnails (lazily fetched as a `Blob` and shown via an object URL,
since the download route is bearer-authenticated) or click-to-download
document chips.

## 6. Test strategy

`tests/attachment_tests.l` — live-SQLite + real file I/O, mirroring
`tests/callbacks_v2_tests.l`'s `report_artifact` coverage:

- `basenameOfAttachment`/`attachmentKindOf`/`contentDispositionQuoted`/
  `promptWithAttachments` — pure, offline.
- `storeAttachments` — round trip (validate, write to disk, persist rows,
  path-traversal neutralized), oversize-file rejection before anything is
  stored, over-the-cap file count rejection.
- `listAttachmentsHandler`/`downloadAttachmentHandler` — messageId starts
  empty and round-trips after linking; cross-session and unknown-id fetches
  both 404.

Not covered (needs a Docker host, same gap every runner-container feature
in this repo has): the live end-to-end path — a real container actually
`Read`-ing an uploaded file via the bind mount.

## 7. Acceptance criteria

1. `POST /api/sessions/{id}/messages` accepts `attachments`; empty `text` +
   non-empty `attachments` is accepted; both empty is still a 400.
2. Uploaded bytes are stored on disk and their metadata in
   `session_attachments`, linked to the user message once it exists.
3. A message with attachments reaches the container with a Read-tool
   manifest naming each file's `/workspace/.attachments/...` path; the
   persisted transcript entry keeps the user's original text unmodified.
4. `GET /api/sessions/{id}/attachments` lists a session's uploads;
   `GET /api/sessions/{id}/attachments/{aid}` serves the bytes, scoped so a
   foreign session can never fetch another session's attachment.
5. Oversize files, too many files, and over-budget total bytes are all
   rejected with 400 before anything is written to disk or the database.
6. The composer stages files with size/count validation matching the
   server's limits and renders past uploads (thumbnails/download chips)
   under their message after a reload.
