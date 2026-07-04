@AGENTS.md

(This is a plain pointer file, not a symlink — a symlink here breaks on
GitHub's raw-file/API content endpoints and on checkouts without symlink
support, which silently return the literal text "AGENTS.md" instead of the
real content. The `@AGENTS.md` line above uses Claude Code's CLAUDE.md
import syntax so AGENTS.md's content is actually auto-loaded into context —
a backtick-quoted mention like `` `AGENTS.md` `` reads as a literal filename
to Claude Code, not an import, and silently defeats the whole point of this
file. Keep this file to a single import line so there's nothing here to
drift out of sync with `AGENTS.md`.)
