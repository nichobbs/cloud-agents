# Spec: Runtime graph handoff — POST the runner's emitted checkpoint objects to the platform

Status: **Proposed.** Closes the one deferred edge of the capture→checkpoint
runtime wiring (`docs/capture-checkpoint.md` §8; AGENTS.md "Provenance capture"):
today `src/docker_manager.l`'s `emitRunnerCheckpoint` builds Testamur
checkpoint-format `ProvenanceObject`s at end-of-run and only **logs** them, with
`treeHash = None` (so no terminal checkpoint). This work package (1) POSTs the
emitted objects to the platform's live ingest endpoint, and (2) captures
`git rev-parse HEAD^{tree}` so real terminal checkpoints land. Both stay gated
behind the existing `CLOUDAGENTS_CAPTURE_CHECKPOINTS` opt-in and best-effort
(a failure is logged, never fails the run).

> **Spec location convention.** cloud-agents keeps specs **flat under `docs/`**
> (e.g. `docs/capture-checkpoint.md`, `docs/session-events-endpoint.md`), NOT in
> a `docs/specs/` subdir the way testamur does. This spec lands as
> **`docs/capture-runtime-handoff.md`** to sit next to the rest of the capture
> arc (`docs/capture-*.md`). (`docs/specs/runtime-graph-handoff.md` from the task
> brief would be the testamur convention; do not use it here.)

## 1. Purpose and scope

The capture→checkpoint pipeline is complete and live-verified as a **pure
producer**: a captured `claude -p --output-format stream-json` run plus its
workspace `git diff HEAD` becomes a `List[ProvenanceObject]` (session + steps +
`file_change` step), content-addressed exactly as the platform computes it
(`CheckpointBridge.emitFromRunnerCapture`). The runtime call site
(`emitRunnerCheckpoint`) already runs at end-of-run behind
`CLOUDAGENTS_CAPTURE_CHECKPOINTS`. Two things remain before those objects are
useful:

1. **Nowhere to send them.** The objects are logged, never handed to the graph.
   The platform is standing up `POST /api/ingest` (a separate, parallel testamur
   spec) that accepts a captured session's provenance objects, tenant-scoped and
   bearer-authed. This WP makes the runner POST to it.
2. **No terminal checkpoint.** `runnerContext(..., None)` passes `treeHash =
   None`, so the vendored mapper stops at steps and emits no terminal
   `Checkpoint` (`mapStreamJsonWithFileChanges` only emits the checkpoint "iff
   `context.tree` is present"). Without a checkpoint id there is nothing for the
   attestation spine or `line_attribution.checkpoint_id` to bind. This WP
   captures the workspace tree hash and threads it in.

**In scope:** the POST seam (config, body encoding, HTTP call, error handling);
the `git rev-parse HEAD^{tree}` capture (entrypoint + inspect parsing + context
threading); the pure object→JSON serializer + its unit tests.

**Out of scope / deferred:** the platform-side `/api/ingest` handler (testamur);
credential issuance/rotation for the per-tenant bearer (operator-provided env
today); retry/queue/backpressure on POST failure (best-effort fire-and-forget,
matching the current emit posture); persisting the emitted objects locally
(they are still not stored in cloud-agents — the endpoint IS the destination).

## 2. Design decision: what body to POST

The task brief allows either a **`session_events` envelope** (raw
`CaptureEvent`s, the `{"events":[…]}` shape of `GET /api/sessions/{id}/events`,
which testamur's `CaptureFetch.ingestEnvelope` re-verifies + re-maps) or a
**`List[ProvenanceObject]`** (what `GraphIngest.ingestObjects` consumes
directly).

**Decision: POST the emitted `List[ProvenanceObject]` as a canonical JSON
array.** Rationale:

- The runner has **already** mapped the session WITH the workspace diff and
  (after §4) the tree hash, so its objects carry the `file_change` step and the
  terminal `Checkpoint` — the exact things that make **Q4 answer** and give the
  attestation spine a subject. The `session_events` envelope carries neither the
  diff nor the tree; testamur re-maps it via `Adapt.mapStreamJson` (the
  no-file-changes path), which reproduces the transcript steps but **drops the
  `file_change` step and the checkpoint** — reintroducing the very
  capture-completeness gap ADR-0008 §capture-completeness names. Sending
  pre-mapped objects is the only body that preserves Q4 end-to-end.
- `ingestObjects` is defined over exactly this shape (testamur ADR-0008), so no
  new platform decode path is needed beyond `/api/ingest` accepting the array.

**Trade-off, called out honestly:** testamur cannot re-verify the capture
hash-chain over already-mapped objects (the envelope path can, because it holds
the raw `CaptureEvent`s). Mitigations, none of which need new code here:
  - The runner **already verified the chain** before mapping —
    `emitFromRunnerCapture` → `emitFromCaptureWithDiff` →
    `emitFromCaptureWithFileChanges` calls `verifyChain` and refuses to map a
    tampered stream (`ChainInvalid`). Only a chain-valid capture ever produces
    objects to POST.
  - The object ids are **content addresses** (`ckpt-…`, step/session ids), so
    the platform recomputes and can reject any id that does not match its bytes —
    a self-verifying integrity check independent of the transport.
  - Idempotent by construction (§5): re-POSTing the same session is a no-op
    upsert keyed on those content ids.

See §7 Open questions for the case where testamur instead wants the envelope
(chain re-verify + single-mapper) — that path would additionally require the
runner to ship the diff/tree out-of-band, since the envelope shape does not
carry them.

## 3. Config

Reuse the existing gate; add two env vars, read with
`Std.Environment.getVarOrDefault` (the same helper `captureCheckpointsEnabled`
already uses). All reads happen inside the sync `emitRunnerCheckpoint` — no new
config plumbing, no manifest change.

| Env var | Meaning | Default / absent behavior |
|---|---|---|
| `CLOUDAGENTS_CAPTURE_CHECKPOINTS` | master opt-in (unchanged) | unset ⇒ `emitRunnerCheckpoint` returns immediately, zero cost |
| `CLOUDAGENTS_GRAPH_INGEST_URL` | platform ingest endpoint, e.g. `https://platform.example/api/ingest` | **empty ⇒ emit + log only, no POST** (preserves today's behavior exactly; capture can run without a destination) |
| `CLOUDAGENTS_GRAPH_INGEST_TOKEN` | per-tenant bearer token | empty ⇒ POST is skipped and logged (`WARNING: graph ingest URL set but token empty`); never POST unauthenticated |

Tenant scoping rides the bearer token (the platform resolves tenant from the
token, per the `/api/ingest` contract). If the platform instead wants an
explicit tenant header, add `CLOUDAGENTS_GRAPH_INGEST_TENANT` and set it as an
`X-Testamur-Tenant` header — flagged as an open question (§7), since the
platform spec is authored in parallel.

**URL validation (fail-closed, before any POST):** require the configured URL to
start with `http://` or `https://`; anything else is logged and skipped. This is
a light check — the URL is **operator-supplied config**, not attacker input, so
it does not need the full path-safety battery testamur's `Transport` applies to
an untrusted *responder*. (We are the client here; the destination is trusted
config.)

## 4. treeHash capture

The tree hash is captured through the **existing inspect-container `diff`
mode**, extended with one more section — no new mode, no new container round
trip (the diff capture `emitRunnerCheckpoint` already does now also yields the
tree, so cost is unchanged).

### 4.1 Entrypoint (`docker/entrypoint.sh`, `diff` case, lines 74–82)

Append a 4th section after the existing three (status / numstat / `git diff
HEAD`). Guarded like every other inspect command so `set -e`/pipefail can't kill
the script before markers print:

```sh
diff)
    echo "CLOUD_AGENTS_INSPECT_OK"
    git status --porcelain || true
    echo "===CLOUD_AGENTS_SECTION==="
    { git diff HEAD --numstat 2>/dev/null || git diff --numstat; } || true
    echo "===CLOUD_AGENTS_SECTION==="
    { git diff HEAD 2>/dev/null || git diff; } || true
    echo "===CLOUD_AGENTS_SECTION==="
    # section 3, tree hash: committed tree, else a throwaway working-tree fallback
    # when there is no HEAD yet (dogfood F3). --verify so a no-HEAD repo yields
    # EMPTY, not the literal "HEAD^{tree}". The fallback uses a throwaway index AND
    # object dir, so it never writes to the real .git/objects (inspect stays
    # read-only, #1028); mktemp -d, not -u (#1029).
    {
        git rev-parse --verify HEAD^{tree} 2>/dev/null || {
            t="$(mktemp -d)"; mkdir -p "$t/objects"
            GIT_INDEX_FILE="$t/index" GIT_OBJECT_DIRECTORY="$t/objects" git add -A 2>/dev/null \
                && GIT_INDEX_FILE="$t/index" GIT_OBJECT_DIRECTORY="$t/objects" git write-tree 2>/dev/null
            rm -rf "$t"
        }
    } || true
    ;;
```

- **Backward compatible.** Existing consumers of `diff` mode read sections 0–2
  (`getWorkspaceDiffHandler` in `src/handlers/workspace.l` checks `>= 3`;
  `emitRunnerCheckpoint` reads `sections[2]`). `splitSections` already returns a
  variable-length slice, so adding section 3 breaks nothing.
- **No-HEAD fallback + committed-diff caveat (dogfood F3).** The committed tree
  (`git rev-parse --verify HEAD^{tree}`) is the preferred anchor. `--verify` is
  load-bearing: a *bare* `git rev-parse HEAD^{tree}` on a no-HEAD repo prints the
  **literal** string `HEAD^{tree}` to stdout (exit non-zero), so without it
  section 3 would be that bogus value, not empty — the runner would thread
  `treeHash = "HEAD^{tree}"`. With `--verify`, a no-HEAD repo yields empty and the
  `||` fires a working-tree `git write-tree` fallback in a **throwaway index AND
  object dir** (a fresh repo before its first commit still anchors a terminal
  checkpoint rather than degrading to steps-only; the real index, checkout, and
  `.git/objects` are all untouched, so inspect mode stays read-only — #1028).
  Section 3
  is empty ⇒ `None` ⇒ steps-only only if even that fallback fails. When a HEAD
  exists the tree is `HEAD`'s **committed** tree; if the agent's edits are
  uncommitted (the common runner case — the diff IS `git diff HEAD`), that is the
  correct anchor for the checkpoint's *base*, with the agent's changes in the
  `file_change` step's hunks, not the tree (do NOT replace the committed-tree case
  with a working-tree write-tree). Document
  this in the doc comment so no one "fixes" it to a working-tree write-tree.

### 4.2 Inspect parsing + context threading (`src/docker_manager.l`, `emitRunnerCheckpoint`, lines 611–624)

```lyric
var diffText = ""
var treeHash = ""
match runInspectContainer(sessionId, harness, userId, "diff", "") {
  case Ok(logs) -> {
    val outcome = CloudAgents.Workspace.parseInspectLog(logs)
    if outcome.ok and outcome.sections.length.toInt() >= 3 {
      diffText = outcome.sections[2]
    }
    if outcome.ok and outcome.sections.length.toInt() >= 4 {
      treeHash = outcome.sections[3].trim()   // section 3 (NEW); trim the trailing newline
    }
  }
  case Err(_) -> ()
}
var tree: Option[String] = None
if treeHash != "" {
  tree = Some(value = treeHash)
}
val ctx = runnerContext("agent:" + harness, harness, "/workspace", CloudAgents.Repository.nowRfc3339Utc(), prompt, model, "auto", tree)
```

`runnerContext`'s `treeHash` param already exists and already flows to
`InvocationContext.tree`; the only change is passing `Some(tree)` instead of the
hard-coded `None`. `emitFromRunnerCapture` → the vendored mapper then emits the
terminal `Checkpoint` and `mapping.checkpointId` becomes `Some(…)`, which the
existing log line already prints.

## 5. The POST

A new pure serializer + one call into the existing HTTP primitive, both invoked
synchronously from `emitRunnerCheckpoint` after a successful emit (no new
`await`, so `emitRunnerCheckpoint` stays a plain sync func and out of the
lyric-lang#6249 await-value-loss trap — the discipline AGENTS.md and
`docs/lyric/gotchas.md` "Async" require).

### 5.1 Serialize `List[ProvenanceObject]` → canonical JSON array

Add a pure helper (proposed home: `src/capture/checkpoint_bridge.l`, next to the
emitters, so it's unit-testable offline without `CloudAgents.Docker`):

```lyric
import Testamur.CheckpointFormat.Canon   // JsonValue, JArray, encodeCanonical
import Testamur.CheckpointFormat.Model    // encodeObject, ProvenanceObject, modelErrorMessage

/// Serialize emitted provenance objects as a canonical JSON array — the body the
/// platform's POST /api/ingest ingests via GraphIngest.ingestObjects. Each object
/// is encoded with the reviewed Model.encodeObject (the SAME encoder the platform
/// hashes with, so bytes/ids agree), then wrapped in a JArray and encodeCanonical'd.
/// A ModelError on any object (e.g. an unsignable checkpoint envelope) fails the
/// whole batch as a typed Err — never a partial body.
pub func objectsToIngestJson(objects: in List[ProvenanceObject]): Result[String, BridgeError] {
  val items: List[Canon.JsonValue] = newList()
  var i = 0
  while i < objects.count {
    match Model.encodeObject(objects[i]) {
      case Ok(jv) -> items.add(jv)
      case Err(e) -> return Err(error = MapFailed(detail = "encode object " + toString(i) + ": " + Model.modelErrorMessage(e)))
    }
    i = i + 1
  }
  return Ok(value = Canon.encodeCanonical(Canon.JArray(items = items)))
}
```

(Reuses `BridgeError`/`MapFailed` so the caller has one error taxonomy. Note the
lyric-lang#6448 `?`-in-arg trap: the code above deliberately `match`es rather
than using `?` inside a call argument.)

### 5.2 Send it — reuse `CloudAgents.GitHubApi`

The repo **already has** the bounded, bearer-authed outbound-POST primitive; do
NOT add a new HTTP stack. `src/github_api.l` exposes
`httpPostJsonWithBearerTimeout(url, jsonBody, bearerToken, userAgent,
timeoutMillis)` (System.Net.HttpWebRequest): sets `Content-Type: application/json`,
`Accept: application/json`, an `Authorization: Bearer …` header, bounded connect
+ read/write timeout, and `GetResponse` throws on any transport failure OR
non-2xx status → surfaces as `Err` (so **2xx-only** is already the contract).
Call it with a short, self-chosen timeout (e.g. 15s — `requestTimeoutMillis`
class, not the LLM 120s) and a `CloudAgents-runner/checkpoint-ingest` UA:

```lyric
match objectsToIngestJson(mapping.objects) {
  case Err(e) -> println("WARNING: checkpoint serialize failed for session " + sessionId + ": " + bridgeErrorMessage(e))
  case Ok(body) -> {
    match CloudAgents.GitHubApi.httpPostJsonWithBearerTimeout(ingestUrl, body, token, "CloudAgents-runner/checkpoint-ingest", 15000) {
      case Ok(_)   -> println("checkpoint: POST ok session=" + sessionId + " objects=" + toString(mapping.objects.count) + " url=" + ingestUrl)
      case Err(m)  -> println("WARNING: checkpoint POST failed for session " + sessionId + ": " + m)   // best-effort: logged, run unaffected
    }
  }
}
```

**No-redirect discipline.** `HttpWebRequest.AllowAutoRedirect` defaults to
`true`, and the primitive does not currently disable it. Since the runner is
POSTing a **bearer token** to the configured endpoint, mirror testamur
`Transport`'s no-redirect posture so a misconfigured/hijacked 3xx can't replay
the token to another host. Add, in `src/github_api.l`, a
`setAllowAutoRedirect(req, false)` extern (`System.Net.HttpWebRequest.set_AllowAutoRedirect`)
and either (a) call it inside `httpPostJsonWithBearerTimeout` (safe — the two
existing callers, Highlights + OpenPr, POST to fixed trusted hosts and don't rely
on redirects), or (b) add a dedicated `httpPostJsonNoRedirect` variant if you'd
rather not touch the shared function's behavior. Recommend (a) with a one-line
doc note; it's strictly safer for every caller. With auto-redirect off, a 3xx
surfaces as a non-2xx `Err` (fail-closed), matching testamur's "2xx-only + no
redirect-follow" bearer-leak defense.

### 5.3 Ordering in `emitRunnerCheckpoint`

1. gate check (unchanged) → 2. inspect `diff` (now also section 3 tree) →
3. build ctx with `Some(tree)` → 4. `emitFromRunnerCapture` (unchanged) →
5. on `Ok(mapping)`: log the summary (unchanged) **then** if
`CLOUDAGENTS_GRAPH_INGEST_URL` non-empty and token non-empty and URL scheme ok,
serialize + POST (new). All synchronous, all best-effort.

## 6. Idempotency / ordering

- Object ids are **content addresses** (session id, step ids, `ckpt-…`), so a
  re-POST of the same session carries identical ids; the platform's
  `ingestObjects` upserts idempotently (ADR-0008), so a duplicate delivery
  (operator re-runs, at-least-once transport) is a safe no-op, not a double
  count.
- The array preserves the mapper's **dependency order**
  (`StreamJsonMapping.objects` is "session/step/checkpoint objects in dependency
  order") — session before its steps before the terminal checkpoint — which is
  the order `ingestObjects` expects. Do not sort or dedupe on the runner side;
  ship the mapping's order verbatim.
- Best-effort means **at-most-once from the runner** (one fire-and-forget POST,
  no retry/queue). A dropped POST loses that session's graph handoff until the
  deferred pull-based path (`CaptureFetch` over `GET /api/sessions/{id}/events`)
  or a manual re-emit fills it. Acceptable for the opt-in phase; a durable
  outbox is an explicit deferred item (§8).

## 7. Test strategy

Honest split — the pure pieces are unit-tested on real fixtures; the Docker glue
and the live POST are manual/live (a `@test_module` cannot reach
`CloudAgents.Docker`, and `emitRunnerCheckpoint` is unreachable from a test, same
as today).

**Offline unit tests (`tests/checkpoint_bridge_tests.l`, extend the existing suite):**
- `objectsToIngestJson` over the emitted objects of the **real** live-edit
  fixture (`tests/fixtures/stream-json/live-edit-turn.ndjson` +
  `live-edit.diff`, already used by `tests/live_capture_e2e_tests.l`): assert the
  body is a JSON array, parses back via `Canon.parse`, has one element per
  `mapping.objects` entry, and round-trips each element byte-identically to
  `Canon.encodeCanonical(Model.encodeObject(o))` (so the POST body carries the
  exact bytes/ids the platform will hash — the cross-repo drift-guard property).
- With a `treeHash` present in the context: assert `mapping.checkpointId` is
  `Some(…)` and the body contains a checkpoint object whose id equals it
  (the terminal-checkpoint path §4 actually produces one).
- Empty-tree path: `runnerContext(..., None)` ⇒ `checkpointId = None` ⇒ body has
  session + steps + `file_change` but no checkpoint object (fail-safe).
- Error path: an object that fails `encodeObject` ⇒ `objectsToIngestJson`
  returns `Err(MapFailed …)`, no partial body.

**Live / manual (needs a Docker host + the `claude` harness; recorded in
`docs/BUILD.md` like the other capture-arc live checks):**
- Set the three env vars against a local `/api/ingest` stub; run a real session;
  confirm the entrypoint's section 3 carries the tree hash, `emitRunnerCheckpoint`
  logs `POST ok`, and the stub received a JSON array whose checkpoint id matches
  the runner's log line.
- Failure isolation: point the URL at an unreachable host / return 500; confirm
  the run still succeeds and the client transcript is unaffected (best-effort).
- No-redirect: stub returns 302; confirm the POST surfaces `Err` (not a followed
  redirect) and the run is unaffected.

## 8. Acceptance criteria

1. With `CLOUDAGENTS_CAPTURE_CHECKPOINTS` unset, `emitRunnerCheckpoint` still
   returns immediately (zero added cost) — unchanged.
2. With the flag set but `CLOUDAGENTS_GRAPH_INGEST_URL` empty, behavior is
   byte-identical to today (emit + log, no POST).
3. With the flag + a valid URL + token set, a successful run POSTs a canonical
   JSON array of the emitted `ProvenanceObject`s (bearer-authed, 2xx-only,
   no-redirect, bounded timeout) and logs `POST ok`.
4. The `diff` inspect now emits a 4th section carrying `git rev-parse HEAD^{tree}`;
   `emitRunnerCheckpoint` threads it as `Some(tree)`, so a run with commits
   produces a **terminal checkpoint** (`mapping.checkpointId = Some(…)`), and a
   commit-less workspace falls back to steps-only (`None`) without error.
5. Every failure hop (inspect, serialize, POST, non-2xx, timeout) is logged and
   swallowed — the run and the streamed transcript are never affected.
6. `objectsToIngestJson` is unit-tested offline on the real fixtures; the POST
   body's bytes/ids match `Model.encodeObject` + `Canon.encodeCanonical` exactly.
7. No new HTTP stack — the POST reuses `CloudAgents.GitHubApi`. No manifest /
   `lyric.toml` change. `emitRunnerCheckpoint` stays a sync func (no new `await`).

## 9. Deferred (sequenced)

- **Durable outbox / retry.** Today's POST is at-most-once fire-and-forget.
  A persisted outbox (reuse the `session_events` store) with retry closes the
  drop window; out of scope for the opt-in phase.
- **Envelope path as an alternative body** (§7 open question) if the platform
  prefers chain-re-verify + single-mapper ingest — needs the runner to ship the
  diff/tree alongside the raw events.
- **Credential issuance/rotation** for the per-tenant bearer (operator-provided
  env today; real issuance is the same deferral as testamur ADR-0018's delivery
  token).
- **NuGet migration** of the vendored `Testamur.CheckpointFormat` (the serializer
  imports `Model`/`Canon` from the vendored copy; a manifest-only swap later).
- **`treeHash` fidelity for uncommitted work** — if the platform later wants the
  post-edit working tree as the checkpoint anchor, the inspect step would
  `git add -A && git write-tree` in a throwaway index; deferred until a consumer
  needs it (the base-commit tree + `file_change` hunks are sufficient for Q4).

## Open questions

1. **Body shape.** This spec POSTs `List[ProvenanceObject]` (preserves Q4 +
   terminal checkpoint). Confirm the parallel `/api/ingest` spec accepts that
   array (via `ingestObjects`) and not *only* a `session_events` envelope. If it
   is envelope-only, the runner must additionally transmit the diff+tree, and Q4
   requires the platform to re-map WITH file changes — a bigger change on both
   sides.
2. **Tenant addressing.** Is tenant resolved from the bearer token alone, or does
   `/api/ingest` want an explicit tenant header/path segment? Determines whether
   `CLOUDAGENTS_GRAPH_INGEST_TENANT` is needed.
3. **Redirect setter placement.** Add `setAllowAutoRedirect(false)` inside the
   shared `httpPostJsonWithBearerTimeout` (affects Highlights/OpenPr too, both
   fixed-host and redirect-free, so safe) vs a dedicated no-redirect variant.
   Recommend the shared change.
4. **Content-Length / body cap.** The emitted array for a long session can be
   large; confirm the platform's max body size and whether the runner should cap
   (fail-closed) before POSTing, mirroring testamur `Transport`'s byte cap.

## Exact call sites / functions / files to touch

| File | Symbol / location | Change |
|---|---|---|
| `docker/entrypoint.sh` | `diff)` case, lines **74–82** | append a 4th section: `git rev-parse HEAD^{tree}` (guarded), after the existing `git diff HEAD` section |
| `src/docker_manager.l` | `emitRunnerCheckpoint`, lines **599–636** (inspect parse **611–621**, ctx build **624**) | read `outcome.sections[3]` (trimmed) into a `treeHash`; pass `Some(tree)`/`None` to `runnerContext` instead of hard-coded `None`; after a successful `emitFromRunnerCapture`, read the two new env vars, serialize `mapping.objects`, and POST (best-effort) |
| `src/capture/checkpoint_bridge.l` | new `pub func objectsToIngestJson(objects) : Result[String, BridgeError]` (near the emitters, ~after line 221) | pure `Model.encodeObject` → `Canon.JArray` → `Canon.encodeCanonical`; import `Testamur.CheckpointFormat.Canon` |
| `src/github_api.l` | `httpPostJsonWithBearerTimeout` (**348–385**); add `setAllowAutoRedirect` extern near the other `HttpWebRequest` setters (**44–65**) | add the no-redirect setter and call it in the POST helper (open question 3) |
| `tests/checkpoint_bridge_tests.l` | new cases | `objectsToIngestJson` round-trip + terminal-checkpoint + empty-tree + encode-error, on the real live-edit fixtures |
| `docs/capture-runtime-handoff.md` | new spec | this document |
| `AGENTS.md` | "Provenance capture" → the `treeHash`/graph-handoff deferred bullets | update once landed (remove the "treeHash is None" / "objects are logged" deferrals) |

_No `lyric.toml` change (all imports are already-declared packages: the vendored
`Testamur.CheckpointFormat.*`, `CloudAgents.GitHubApi`, `Std.Environment`)._
