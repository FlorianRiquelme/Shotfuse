# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

## Work Tracking — superpowers plans

Open work lives in `docs/superpowers/plans/` as dated markdown files
(`YYYY-MM-DD-<feature>.md`). Each plan contains the full task breakdown
with exact file paths, code, and commands. To find work:

```bash
ls docs/superpowers/plans/
```

Execute a plan via the `superpowers:executing-plans` or
`superpowers:subagent-driven-development` sub-skill. Steps use `- [ ]`
checkbox syntax for tracking.

Do **not** use `bd` / beads — it was retired on 2026-04-24. Historical
bd data under `.beads/` is frozen and archival only.

## Session Completion

When ending a work session, commit finished work and push to the remote
before signing off. Work is not complete until `git push` succeeds.

```bash
git status              # confirm no stray files
git pull --rebase
git push
git status              # must show "up to date with origin"
```


## Build & Test

### Xcode projects (XcodeGen)

`App/App.xcodeproj` and `CLI/CLI.xcodeproj` are generated from `App/project.yml`
and `CLI/project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen). The
generated `*.xcodeproj` directories are gitignored — each clone regenerates them
locally.

**When adding, renaming, or removing Swift files** under `App/Sources/` or
`CLI/Sources/` (including nested dirs like `CLI/Sources/Commands/`), or when
editing `project.yml`, the xcodeproj must be regenerated:

```bash
brew install xcodegen   # one-time, if missing
cd CLI && xcodegen generate   # and/or: cd App && xcodegen generate
```

Skipping this step causes `Shotfuse.xcworkspace` builds to fail with
"cannot find <Type> in scope" because the pbxproj does not list the new
source files (see bd `hq-abq`).

### Pre-commit guard

`.githooks/pre-commit` auto-runs `xcodegen generate` whenever a commit stages
changes to `project.yml` or `Sources/**` in either `CLI/` or `App/`. Activate
it once per clone/worktree:

```bash
git config core.hooksPath .githooks
```

If the hook reports `xcodegen is required ... not found on PATH`, install it
with `brew install xcodegen` and retry the commit. Do not bypass the hook with
`--no-verify` — the drift is silent and breaks CI/UAT builds.

## Architecture Overview

_Add a brief overview of your project architecture_

## Conventions & Patterns

_Add your project-specific conventions here_
