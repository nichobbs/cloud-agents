# Frozen snapshot — do not edit to match current `src/`

The snapshot's logic is frozen, but it has been ported to compile against
`Lyric.Docker` 0.7 (`ContainerId`, the `waitContainer` timeout and the
`stopContainer` grace period), to run on lyric 0.7.7 (a direct call to an
`async func` awaits in place, so the run is started through `Task.Run`, as in
`src/docker_manager.l`), and the `CloudAgents.Db` stub returns valid bind specs
(`Lyric.Docker` now validates them). `Lyric.Web`/`Lyric.Docker` are pinned to
0.7.6. On lyric 0.7.5 it crashes with the `AccessViolationException`; on 0.7.7
it survives (lyric-lang#8022).

`docker_manager.l` and `docker_policy.l` in this directory are a **frozen
snapshot** of `src/docker_manager.l` / `src/docker_policy.l` as they existed
at commit
[`9aec3a6484f669afe434f214bdf511b99de99e09`](https://github.com/nichobbs/cloud-agents/commit/9aec3a6484f669afe434f214bdf511b99de99e09),
the last commit before the `hasExceededRunTimeout`
`AccessViolationException` workaround (see
`docs/BUILD.md`/`docs/lyric/gotchas.md` for the full narrative).
`scripts/repro-crosspkg-long-crash.sh` uses this snapshot on purpose — the
live `src/` no longer contains the crashing pattern, so copying the
current source here would silently stop reproducing the bug.

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
