# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->


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
