---
name: dependency-vetting
description: A checklist to run before adding a new external dependency to a project
---

Use this skill before running an install command (`npm install`, `pip install`, `cargo
add`, `go get`, adding a NuGet/gem/etc.) to add a NEW third-party dependency — not for
routine version bumps of existing ones.

## Before adding

1. **Is it necessary?** Could the need be met with a small amount of hand-written code,
   or a package already in the manifest? A dependency is a maintenance liability, not a
   free win — weigh a few lines of code you understand against a package you don't.
2. **License compatibility.** Check the package's license against the project's own
   (e.g. a GPL dependency in a project meant to stay permissively licensed is a real
   problem, not a formality).
3. **Maintenance signal.** Last release date, open issue/PR backlog, whether it has more
   than one maintainer. An abandoned package is a future migration you're signing up for.
4. **Size and transitive weight.** What does it pull in transitively? A single-function
   need shouldn't drag in a large dependency tree.
5. **Known vulnerabilities.** Check for existing advisories against the package (and its
   pinned version specifically, not just the package name in the abstract).
6. **Alternatives considered.** If two packages solve the same problem, note why you
   picked one over the other — smaller footprint, better maintenance, existing use
   elsewhere in the project.

## After adding

- Pin to a specific version (or the project's normal range convention) rather than an
  unbounded wildcard.
- Note in the commit/PR description what was added and why, so a reviewer doesn't have
  to reverse-engineer the motivation from a manifest diff.

## Failure modes to avoid

- Adding a heavyweight package for one small utility function.
- Skipping the license check because the package "looked fine."
- Picking the first search result without checking maintenance status.
- Silently adding a dependency mid-diff without calling it out in the PR description —
  a manifest change deserves an explicit mention (see the pr-description skill).
