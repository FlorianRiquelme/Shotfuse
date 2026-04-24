# Router P4.2 Closeout Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Verify the Router actor implementation at `Core/Sources/Core/Router/Router.swift` already satisfies the four P4.2 test-contract subtests, then formally close the work item.

**Architecture:** The Router is a Swift `actor` with three predictors scored via `RouterScoringModel`, an auto-deliver rule (`top_score > 0.85 AND second_score < 0.4`), side-effect execution (clipboard / `~/Projects/<root>/screenshots/` / `obsidian://daily`), and a redacted 6-field telemetry log at `~/.shotfuse/telemetry.jsonl` with 10 MB rotation, keep 2. This plan does **not** add code — it verifies coverage is complete against the P4.2 contract and walks the telemetry schema end-to-end once more.

**Tech Stack:** Swift Testing, Swift actors, `os.Logger`, `JSONEncoder(.sortedKeys)`, `CC_SHA256`.

---

## Context — P4.2 test contract (from `.claude/session-plan.md`)

`RouterTests` must prove:

- **(a)** Xcode + git-root ⇒ `~/Projects/<root>/screenshots/` with `top>0.85`
- **(b)** Obsidian-frontmost ⇒ `obsidian://daily`
- **(c)** Unwritable target ⇒ fallback to clipboard + unified-log entry
- **(d)** Telemetry line is exactly the 6 allowed fields; no OCR / clipboard / path leakage

## Existing coverage (confirmed 2026-04-24)

| Subtest | Existing test | File:line |
|---|---|---|
| (a) | `"Xcode + gitRoot -> projectScreenshots auto-delivery"` | `Core/Tests/CoreTests/RouterTests.swift:154` |
| (b) | `"Obsidian -> obsidianDaily auto-delivery"` | `Core/Tests/CoreTests/RouterTests.swift:199` |
| (c) | `"Unwritable target -> fallback to clipboard"` (+ 459, 490) | `Core/Tests/CoreTests/RouterTests.swift:240` |
| (d) | `"Telemetry line audit: exactly 6 keys, correct shape"` | `Core/Tests/CoreTests/RouterTests.swift:279` |

Supplemental coverage already in place: telemetry rotation at 10 MB (line 331), scoring tie-breaking (393), Obsidian-opener failure fallback (459), unwritable-parent side-effect (490), user-override from chooser (532).

---

## File Structure

No files created or modified. Verification only.

- Read: `Core/Tests/CoreTests/RouterTests.swift`
- Read: `Core/Sources/Core/Router/Router.swift`

---

### Task 1: Run the full RouterTests suite and confirm all 8 tests pass

**Files:**
- Read only

- [ ] **Step 1: Run the Router test suite**

Run:

```bash
xcodebuild test \
  -workspace Shotfuse.xcworkspace \
  -scheme Core \
  -destination 'platform=macOS' \
  -only-testing:CoreTests/RouterTests \
  2>&1 | tail -40
```

Expected output (tail):

```
** TEST SUCCEEDED **
```

With the per-test log containing all 8 `@Test` cases:

- `Xcode + gitRoot -> projectScreenshots auto-delivery`
- `Obsidian -> obsidianDaily auto-delivery`
- `Unwritable target -> fallback to clipboard`
- `Telemetry line audit: exactly 6 keys, correct shape`
- `Telemetry file rotation at 10 MB, keep 2`
- `Router scoring tie-breaking`
- `Obsidian opener failure -> fellBackToClipboard(.obsidianOpenFailed)`
- `projectScreenshots side-effect with unwritable parent`
- `User-chosen destination from chooser overrides prediction`

- [ ] **Step 2: Verify the telemetry-audit test asserts the complete forbidden-key set**

Open `Core/Tests/CoreTests/RouterTests.swift` at line 317 and confirm the forbidden key set matches this value:

```swift
let forbiddenKeys: Set<String> = ["ocr", "text", "clipboard", "bundle_id", "path", "git_root", "window_title"]
```

Expected: exact match. If any of `ocr`, `text`, `clipboard`, `bundle_id`, `path`, `git_root`, `window_title` is missing, the redaction audit (separate plan `2026-04-24-observability-redaction-audit.md`) will supplement — but this test must at minimum contain all seven to satisfy SPEC §13.5 + §17.2.

- [ ] **Step 3: Verify the unified-log emission for path (c)**

Open `Core/Sources/Core/Router/Router.swift` and confirm the unwritable-target fallback in `sideEffect(for:context:)` emits a `logger.error` before returning `.fellBackToClipboard(reason: .notWritable)` — two such sites exist (lines 292 and 300 in current main). Expected: both sites present, both call the redacted `.sha256Prefix` helper on path strings.

- [ ] **Step 4: Commit the verification evidence**

No code changes; this plan is closeout-only. Skip the commit step. Proceed to Task 2.

---

### Task 2: Close the bd item and move Router work to done

**Files:**
- None (external state change)

- [ ] **Step 1: Close hq-8vb in beads with pointer to this plan**

Run:

```bash
bd close hq-8vb --notes "Closed during beads → superpowers-plans migration on 2026-04-24. All four P4.2 subtests verified against RouterTests.swift:154/199/240/279. See docs/superpowers/plans/2026-04-24-router-p42-closeout.md."
```

Expected: `bd list --status=open` no longer shows hq-8vb.

- [ ] **Step 2: Confirm the downstream bd items that depended on Router now show unblocked**

Run:

```bash
bd show hq-ap9 | grep -A1 "DEPENDS ON"
bd show hq-5v4 | grep -A1 "DEPENDS ON"
```

Expected: the `hq-8vb` dependency is marked `✓` (closed) in both outputs. (These bd items will be closed en masse by the other conversion plans — the check here is just to confirm the graph is consistent before they shut down.)

---

## Self-Review

**1. Spec coverage.** P4.2 contract subtests (a)-(d) each have a named test at a concrete line. §13.5 telemetry shape is asserted by test (d). §7.3 side-effect policy (unwritable → clipboard + log) is asserted by test (c) + log-call verification in Step 3.

**2. Placeholder scan.** No TBDs, no "implement later", no unnamed tests.

**3. Type consistency.** No new types introduced — this plan only reads existing names (`RouterTelemetryLine`, `RouterSideEffectResult.fellBackToClipboard(reason:)`, `RouterScoringModel`).
