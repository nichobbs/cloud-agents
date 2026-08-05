# Phase 10 — Open PR (opt-in)

Status: shipped (backend endpoint + tests, frontend button). Not yet run
through the real `lyric` toolchain in this authoring environment — see
"Verification status" at the end.

## 1. Problem

A session clones a repo and runs a coding agent against it on its own
branch, but nothing on the platform offers to open a GitHub PR from that
branch afterward — a human has to do it manually outside the app (or trust
the agent remembered to do it itself via the GitHub MCP server). This phase
adds a "Open PR" action to close that gap.

## 2. Scope decision: opt-in button, not automatic-on-run-finish

The original framing for this feature was "auto-open a PR when a run
finishes." Two things pushed the first version toward an explicit,
user-triggered button instead:

- **No way to verify a run actually produced pushable changes.** This
  codebase has no `docker exec`-style capability (`CloudAgents.Docker`
  only creates, log-polls, and terminates containers — see its module
  header) to inspect a session's checkout after a run. Whether the agent
  committed and pushed anything is entirely up to the agent itself, per
  `docker/branch-policy-rules.md`'s instructions to it — the platform has
  never verified this actually happened.
- **Firing automatically on every run risks noisy, unwanted PRs.** Even
  with the compare-API check below (§3) correctly detecting "nothing
  pushed," a run that *did* push a half-finished experiment would
  automatically become a PR the user never asked for.

An explicit "Open PR" button sidesteps both: it runs the exact same
compare-then-create logic (§3) on demand, so a human decides *when* a
session's state is ready to become a PR, and a genuinely empty/unpushed
branch just gets a clear "nothing to open a PR for" message instead of an
automatic no-op the user never sees. This is a strict subset of the
originally-described automatic behavior — promoting it to fire on every
successful run later is a one-line change (call the same handler from
`streamSendMessage`'s success branch) if that's ever wanted, with none of
this phase's logic needing to change.

## 3. Design: ask GitHub, don't inspect the checkout

Since the platform can't peek inside the (possibly already-terminated)
container, `CloudAgents.OpenPr` asks GitHub itself whether there's anything
to open a PR for — the same "ask the remote, don't inspect the local
checkout" idiom `CloudAgents.Proxy` already uses for CI status and existing-PR
checks. `POST /api/sessions/{id}/open-pr`:

1. Loads the session (owner-scoped via `CloudAgents.SessionStore.getSession`,
   same 404-not-leak pattern every other session-scoped handler uses) and
   parses its `repoUrl` into a GitHub owner/repo pair
   (`githubOwnerRepoFromUrl`, built on the already-proven
   `CloudAgents.RepoKey.repoKeyOf` rather than a fresh URL parser — see its
   own doc comment). A non-github.com repo is a 400.
2. Resolves the caller's vaulted `GITHUB_TOKEN` via
   `CloudAgents.OAuth.ensureFreshGitHubToken` — the same helper
   `CloudAgents.Proxy`'s read-only endpoints use, so an empty vault 404s
   *before any network call*, exactly like those endpoints already do.
3. Fetches the repository's actual default branch (never assumed to be
   `main`/`master`).
4. Calls GitHub's own **compare API**
   (`GET /repos/{owner}/{repo}/compare/{base}...{head}`) to check whether
   the session's branch has any commits ahead of that default branch. A 404
   here (branch or repo ref doesn't exist on the remote — most commonly,
   nothing was ever pushed) is treated as "nothing to compare," not an
   error.
5. Checks for an already-open PR on that branch (the same
   `GET .../pulls?state=open&head=owner:branch` shape
   `CloudAgents.Proxy.githubPullsHandler` already uses) to avoid opening a
   duplicate.
6. **`decidePrAction`** — a pure function taking the three pieces of state
   gathered above (default branch, compare status, existing PR URL) —
   decides `Reject` (branch IS the default branch, or has no commits ahead),
   `Reuse` (an open PR already exists — return its URL instead of creating
   another), or `Create`. Kept pure and separate from the network calls
   specifically so the decision logic — the part most worth getting
   right — has direct unit test coverage (`tests/open_pr_tests.l`) with no
   real GitHub round trip required.
7. On `Create`, opens the PR via `POST /repos/{owner}/{repo}/pulls` with the
   vaulted token, using `httpPostJsonWithBearer` — the same primitive
   `CloudAgents.Highlights` already uses for its summarizer call, just aimed
   at a different API. The token never reaches the browser at any point
   (ADR-006's precedent: the credential vault stays write-only from the
   browser's perspective).

Response: `{"url": "...", "created": true|false}` — `created: false` means
an already-open PR was found and reused, not that anything failed.

## 4. Frontend

A new "Open PR" button in `GitHubPanel.tsx` (the existing per-session repo/
PR/CI status panel), calling `api.openPr(sessionId)`. Unlike every other
call that panel makes, this one has **no direct-browser fallback** — the
panel's read-only GitHub calls fall back to a locally-held token when the
backend proxy has none (`lib/github.ts`), but opening a PR is server-side
only, consistent with never wanting a write-scoped token any more exposed
to the browser than read operations already are. A successful call shows
the resulting PR link (labeled "PR opened" vs. "Already open" depending on
`created`) and triggers the panel's normal pull-list refresh so the PR also
shows up in the regular list. A failure just surfaces the backend's error
message inline — no separate friendly-message mapping was added for this
first version (unlike, say, `Credentials.tsx`'s `AuthNotConfigured`
handling), since the underlying error messages (`"...400 no commits found
on..."`, `"...404..."`, GitHub reconnect prompts) are already reasonably
self-explanatory for an opt-in action a human just clicked.

## 5. Deferred / not built

- **Automatic PR-on-run-finish.** Deliberately out of scope for this first
  version — see §2.
- **Editable PR title/body before creation.** The PR is opened with a fixed
  title (`"Cloud Agents: <branch>"`) and a one-line body. A confirmation
  step letting the user edit these before the PR is actually created would
  be a natural follow-up but adds a second round-trip/dialog this phase
  didn't build.
- **A friendly, mapped error message for every failure mode.** See §4 — the
  raw backend message is shown as-is.

## 6. Verification status

This authoring environment has no `lyric` toolchain installed by default (an
attempt to install it this session hit a known session-level MCP connection
issue with the `add_repo` tool per `AGENTS.md`, not a real permission
denial), so this change relies on CI's `Build & verify` job for its actual
compile+test gate — and unlike some earlier phases, that gate has already
run against this code and mattered: CI's first pass on this PR failed with a
real compile error, `argument type () -> String does not match parameter
type String`, at all four of `open_pr.l`'s GitHub API calls. The cause: a
top-level `val userAgent = "cloud-agents"` collided with an unrelated,
already-imported `pub func userAgent(): String` in `CloudAgents.OAuth`
(`src/handlers/oauth.l`) — Lyric resolved the unqualified name to the
imported function instead of the local `val`. Fixed by renaming to
`openPrUserAgent`, mirroring the naming convention `CloudAgents.Proxy`
already uses for exactly this reason (`proxyUserAgent`, not `userAgent`).
The same CI pass's automated review also caught a real security gap (the
session's branch name — which can legally contain characters like `#` that
are unsafe in a raw URL — was embedded unvalidated into the compare/pulls
GitHub API URLs) and a real efficiency gap (the compare and existing-PR
calls ran even when the session was still on the repo's default branch,
where the answer is always "nothing to do"); both are fixed in the same
follow-up commit, re-validating the branch through
`CloudAgents.Proxy.isValidProxyBranch` (the same charset its own
GitHub-URL-embedding endpoints require) and short-circuiting before the
now-unnecessary calls.

A second review round on the follow-up commit caught four more real
issues, all fixed: the compare API's `/compare/{base}...{head}` path
segment wasn't percent-encoding `/` in branch names (a valid, common
character that's ambiguous with that endpoint's own path routing), the
existing-PR lookup filtered only by `head` and could reuse a PR targeting
the wrong `base`, a stale in-flight `openPr()` response could still land
after the frontend switched to a different session (a gap in the
session-switch reset fix itself), and — in a third round —
`defaultBranch`, fetched from GitHub's own repo metadata, was embedded in
the same URLs `session.branch` is without the same re-validation, even
though it's just as embeddable-unsafe regardless of where a branch name
originated. See the closed `pr-922`-labeled issues (#930-#933) for the
full detail on each.

`tests/open_pr_tests.l` covers what's testable without a live GitHub API
call, matching the precedent `tests/proxy_tests.l` already established for
this codebase's other GitHub-calling handlers (its own module comment:
"no network path is ever exercised here"):

- `githubOwnerRepoFromUrl`: plain URLs, `.git`-suffixed/mixed-case URLs,
  non-github.com hosts, owner-only URLs, empty/garbage input.
- `decidePrAction`: every branch of the pure reject/reuse/create decision,
  directly, with no network involved at all.
- `openPrHandler`'s pre-network-call validation: empty session id, unknown/
  foreign session id (404, not a leak), a non-github.com repo, an unsafe
  branch name, and the no-vaulted-GITHUB_TOKEN 404 path — this last one is
  directly analogous to `tests/proxy_tests.l`'s "GitHub proxy answers 404
  when the vault has no GITHUB_TOKEN" test, and for the same reason:
  `ensureFreshGitHubToken` short-circuits on an empty vault before any
  outbound request.

Not covered by an automated test, for the same structural reason
`tests/proxy_tests.l` doesn't cover its own live GitHub calls either: the
actual compare/existing-PR/create HTTP round trips against a real GitHub
API and a real vaulted token. Manually reviewed against the real GitHub REST
API's documented shapes (`default_branch`, compare's `status` field values,
`pulls` list `html_url`, `POST .../pulls`'s request/response shape) rather
than executed.
