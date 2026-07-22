# Frozen snapshot — do not edit to match current `src/`

`docker_manager.l` and `docker_policy.l` in this directory are a **frozen
snapshot** of `src/docker_manager.l` / `src/docker_policy.l` as they existed
at commit `<PREFIX_COMMIT>`, before the `hasExceededRunTimeout`
`AccessViolationException` workaround was applied in the commit right
after `9aec3a6484f669afe434f214bdf511b99de99e09` (see
`docs/BUILD.md`/`docs/lyric/gotchas.md`). `scripts/repro-crosspkg-long-crash.sh`
uses this snapshot on purpose — the live `src/` no longer contains the
crashing pattern, so copying the current source here would silently stop
reproducing the bug.

The other `stub_*.l` files are hand-written stand-ins for every package
`docker_manager.l` imports (`CloudAgents.Db`, `NetworkPolicy`, `Repository`,
`RunnerEnv`, `SessionStore`, `Sqlite`, `Streaming`, `Crypto`) — matching
signatures, trivial bodies, no SQLite/real credentials/real session data.
`main.l` hosts a real `Lyric.Web` streaming route that calls
`streamSessionMessage` directly with a made-up session id and an
unreachable Docker host, exactly reproducing the crash outside the full
application (no auth, no database, no real container).

Do not "clean up" this snapshot to match current source — that's the whole
point of freezing it. If the upstream Lyric compiler bug is ever fixed,
`scripts/repro-crosspkg-long-crash.sh` will start reporting "did not
reproduce" and can be deleted/retired at that point (mirroring
`scripts/repro-compiler-bug.sh`'s and `scripts/repro-docker-crash.sh`'s own
conventions for a fixed-upstream check).
