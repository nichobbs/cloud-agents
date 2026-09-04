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
validate-then-persist work in two passes: validate + base64-decode every
input first, without writing anything, so a later file's overage against the
cumulative per-message budget can never leave an earlier file's bytes/row
orphaned; then write each file's bytes and insert its `session_attachments`
row (`messageId` starting `''`). Pass 2 itself is not wrapped in a DB
transaction, so a genuine I/O or DB failure partway through a multi-file
batch (disk full, a transient SQLite error on file N of M) is handled with
best-effort rollback: `cleanupPartialAttachmentBatch` deletes the rows/files
that same call already committed earlier in the batch before returning the
error, so files `1..N-1` aren't left stranded with `messageId` permanently
`''`. That cleanup is itself best-effort (its own failure — e.g. the same
disk-full condition — is swallowed rather than masking the original error),
so a genuinely persistent storage failure can still leave an orphan behind;
this closes the common case (a transient hiccup on one file) without adding
a full transactional rewrite. `streamSendMessage` calls it AFTER
successfully claiming the session's run lock — not before — so a validation
failure (or any other early return) is covered by the same `defer`-based
lock release the rest of the run already relies on, closing the same
orphaned-row risk one level up: claiming the lock first means no concurrent
send can lose a lock race *after* attachments were already written for it.
Once `CloudAgents.Repository.addMessage` mints the user message's id,
`CloudAgents.Repository.linkAttachmentToMessage` back-fills `messageId` on
each stored row. The message's persisted transcript `content` is the
ORIGINAL text the user typed, not the container-bound prompt built in §4 — so
the UI shows what the user actually typed, not an internal file manifest.

## 4. Reaching the agent: no new multimodal plumbing

`claude -p "${PROMPT}"` (`docker/entrypoint.sh`) takes a single text prompt —
there is no separate image/document channel into the harness CLI. Rather than
teach the invocation a second input format, `CloudAgents.Docker`
bind-mounts the session's attachments directory
(`attachmentsBaseDir()/<sessionId>/`) READ-ONLY (`:ro`) at
`/workspace/.attachments` whenever the SESSION already has at least one
attachment — not only when the CURRENT message happens to carry a new one.
`CloudAgents.Handlers.storeAttachments` resolves this: a non-empty
`inputs` validates and writes the new files as described in §3; an EMPTY
`inputs` (a plain text follow-up) still resolves `hostDir` to the session's
existing attachment directory via `CloudAgents.Repository.listAttachments`
whenever that session has any (falling back to `""`, i.e. no mount, only
when the session truly has none, or on a listAttachments read failure —
fail open rather than blocking the send). This is what lets a user attach
`screenshot.png` in one message and, in the NEXT message, ask "what did you
see in that screenshot?" with no new attachment — without this, that
follow-up's container would get no `/workspace/.attachments` mount at all,
even though the file is still on disk and listed by
`GET /api/sessions/{id}/attachments` (`createRunnerContainer`'s
`attachmentsHostDir` param, threaded through
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
loop does the rest. `docker/entrypoint.sh` needed NO changes. The mount is
read-only — the agent only ever needs to read these files, matching the
read-only `NODE_EXTRA_CA_CERTS` bind in the same function; a writable mount
would let a compromised/prompt-injected run delete or overwrite an earlier
upload in the same session's (accumulating) attachments directory, silently
breaking that file's future downloads. Files land with the default
world-readable permissions `Std.File.writeBytes`/`createDir` produce, so
`claude-user` can read them without needing the `chown -R
claude-user:claude-user /workspace || true` the rest of the workspace gets
(a read-only mount couldn't be chowned in the first place).

The download route (`GET /api/sessions/{id}/attachments/{aid}`) serves
`Content-Disposition: attachment` (not `inline`), and upload-time validation
rejects mime types capable of executing as active content when rendered
(`image/svg+xml`, `text/html`, `application/xhtml+xml`,
`CloudAgents.Handlers.isDangerousAttachmentMimeType`) — an attachment's
`mimeType` is entirely client-supplied, and an SVG/HTML file served inline at
this app's own origin is a stored-XSS vector if a viewer ever navigates to it
directly rather than fetching it as an opaque blob. `frontend/src/pages/
SessionDetail.tsx`'s composer pre-checks the same blocklist client-side
(`isDangerousAttachmentMimeType` there, a small duplicate — see §5) so a
dangerous file is rejected at pick-time with the same instant notice the
size/count checks already give, rather than only after a wasted upload
round-trip. `CloudAgents.Callbacks`'s pre-existing `report_artifact` upload
path (`src/handlers/callbacks.l`) carries the identical check under its own
name, `isDangerousArtifactMimeType` — a small intentional duplicate across
packages (this codebase's convention, see e.g. `basenameOf`'s own doc
comment there) rather than a shared import, closing the same risk class in
the artifact route that this feature's design doc originally cited as its
own precedent without actually matching it.

## 5. Frontend

`frontend/src/pages/SessionDetail.tsx`: a paperclip button opens a hidden
multi-file `<input>`; each picked file is checked against the same
size/count limits as §2 AND the same dangerous-mimetype blocklist as §4
(`isDangerousAttachmentMimeType`, a small client-side duplicate of the
server check keyed off the browser's own `File.type`) BEFORE it is read to
base64 via `FileReader` and staged (with a thumbnail preview for images) —
so a rejected file never pays the cost of being encoded, and the user sees
the same kind of instant notice for a bad mime type as for an oversize or
over-the-cap file. `frontend/src/components/MessageBlock.tsx` renders a message's
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
  stored, over-the-cap file count rejection, a text-only follow-up still
  resolving the session's existing attachment directory when one exists
  (#1005).
- `cleanupPartialAttachmentBatch` — the pass-2 best-effort-rollback helper
  (#1003), exercised directly since forcing a genuine mid-batch I/O/DB
  failure isn't something a test can trigger through the public API.
- `listAttachmentsHandler`/`downloadAttachmentHandler` — messageId starts
  empty and round-trips after linking; cross-session and unknown-id fetches
  both 404.
- `tests/callbacks_v2_tests.l` pins `isDangerousArtifactMimeType` on
  `report_artifact`'s upload path (#1007), the same blocklist as this
  feature's own `isDangerousAttachmentMimeType`.
- `frontend/src/pages/SessionDetail.test.tsx` covers the composer's
  client-side mimetype pre-check (#1006): an SVG/HTML pick is rejected with a
  notice before it is ever staged or base64-encoded.

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
