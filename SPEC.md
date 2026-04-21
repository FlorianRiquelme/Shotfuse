# Shotfuse — v0.1 Spec

**Status**: canonical v0.1 contract
**Spec version**: 0.1.1
**Dated**: 2026-04-21
**Source**: tightened from `BRAINSTORM.md` after multi-AI brainstorm + naming round; audited 2026-04-21 (see `SPEC-AUDIT-2026-04-21.md`) and updated 0.1.0 → 0.1.1. BRAINSTORM.md remains the narrative record; SPEC.md is the executable contract.

---

## 1. Product identity

| Field | Value |
|---|---|
| Name | `Shotfuse` |
| Tagline | *The aftermath is the product.* |
| CLI binary | `shot` |
| Package extension | `.shot` (macOS package directory, UTI-registered) |
| Platform floor | macOS 26+ |
| Stack | Swift, SwiftUI (read-only displays + settings), AppKit (capture surfaces, `Limbo` HUD, annotation canvas) |
| Test framework | Swift Testing |
| Distribution | Open source, public GitHub. Developer ID + notarization. No sandbox in v1. |
| Bundle ID | `dev.friquelme.shotfuse` |
| License | MIT |

---

## 2. v0.1 Definition of Done

### Weekend 1 — the Spine

**Single observable test:**

> Press a hotkey → drag a region → release. Within a budget of **p95 ≤ 1.5s warm / ≤ 3.0s cold (first capture post-launch); p50 ≤ 600ms warm** — measured from hotkey-release to *both* clipboard-write complete AND `.shot` package `fsync` returned — a PNG of the selection is on the clipboard AND a `.shot` package exists at `~/.shotfuse/library/<timestamp>_<bundle>.shot/` containing:
> - `master.png` at native resolution
> - `ocr.json` (wrapper per §6.3) with text, bounding boxes, and Vision version
> - `context.json` with `frontmost.bundle_id`, `frontmost.window_title`, optional `frontmost.file_url` / `browser_url` / `git_root`, and `captured_at`
> - `thumb.jpg` at 256px
> - `manifest.json` with valid `id` (UUIDv7), `created_at`, `expires_at` = created + 24h, `pinned: false`
>
> `Cmd+Shift+G` opens a search overlay. Typing OCR text or a frontmost app name returns the matching capture within 100ms. A background launch agent (§15.1) deletes unpinned packages past `expires_at`.

### Weekend 2 — the Personality

**Single observable test:**

> Across 10 consecutive real-work captures, as measured by `~/.shotfuse/telemetry.jsonl`: (a) ≤ 2 events where `predicted ≠ chosen` (user invoked `Cmd+Z` redirect), AND (b) ≤ 2 events where the chooser appeared instead of auto-delivery (i.e. `top_score ≤ 0.85` or `second_score ≥ 0.4`). Predicted destinations are exactly: `clipboard`, `~/Projects/<git-root>/screenshots/`, `obsidian://daily`. Annotations (arrow, text, blur rectangle) round-trip through `annotations.json` and re-render **byte-identically on the same machine at the same macOS minor version; SSIM ≥ 0.995 across supported macOS 26.x patchlevels** from `master.png` on re-export.

*If the Weekend 2 Router test fails, stop adding features and fix the Router. Do not promote more destinations into the taxonomy until this test passes.*

---

## 3. Non-goals for v0.1

| Non-goal | Revisit when |
|---|---|
| Screen recording (`SCRecordingOutput` + `AVAssetWriter`) | Weekend 1 and 2 are both in daily use |
| GIF export | After recording ships (GIF is a post-export derivation) |
| Scrolling capture | Specific surfaces first (Safari, PDF); only after package format has stable consumers |
| `Ghost overlay` / trace mode | Ships as separate `shot ghost <file>` subcommand post-v0.1 |
| LLM-driven annotation | After arrow/text/blur editor feels mechanical (no UI friction) |
| iCloud / git sync of the library | Opt-in; trivially derivable from on-disk package format |
| System audio + microphone recording | v0.4+ (mic/SCK clock drift, TCC permission cost) |
| Window + fullscreen capture | **Weekend 2** (same engine as region, different `SCContentFilter`) — in-scope for Weekend 2 DoD |
| Destinations beyond `clipboard` / project / Obsidian | After Router telemetry exists (`slack://`, `linear://`, `local-share-link`) |
| Wi-Fi SSID in `context.json` | Would require Location Services TCC gate; not worth it in v0.1 |
| Localization beyond English | When non-English contributors appear |
| Per-library encryption passphrase | When library-sync (iCloud / git) is promoted from non-goal |
| RFC 3161 TSA-signed witnesses | Before first external-trust use case |
| Hot-reload of `keymap.toml` | When manual restart becomes painful |

---

## 4. Locked vocabulary

These are code identifiers, doc headings, and commit-message terms. Do not rename without a versioned spec delta (see §12).

| Term | Meaning | Code surface |
|---|---|---|
| `Limbo` | The 2–8s window between capture and decision; also the floating AppKit HUD that hosts promotion gestures | `LimboController`, `LimboHUD` |
| `Fuse` | The 24h default expiry; `fuse reset` extends, `fuse pin` removes | `FusePolicy`, `manifest.expires_at` |
| `Witness Capture` | Cryptographic-hash mode (`Cmd+Shift+W`); bypasses `Limbo`; full `.shot` package stored in `~/.shotfuse/witnesses/` (separate on-disk library); never indexed in `~/.shotfuse/index.db`, never routed | `WitnessService`; `manifest.mode = "witness"` |
| `Decay Gradient` | The value-over-time curve a capture rides; drives fuse, search ranking, and promotion weight | `DecayModel` |
| `.shot` package | Directory-form capture bundle, macOS package convention, UTI-registered | On-disk format, see §6 |
| `Router` | The destination-prediction engine; capital-R refers to the component | `Router` actor in `Core` |
| `Verbal` vs `Reference` capture | Two behavioral modes: *verbal* = speech-act (route-and-forget), *reference* = archival (retained, indexed deeper) | `CaptureMode` enum values `verbal` / `reference` |

### 4.1 Deferred vocabulary (re-introduced in later spec versions)

| Term | Deferred to | Rationale |
|---|---|---|
| `Capture Echo` | `spec_version = 2` | Detection algorithm (pHash vs region overlap vs AX diff) needs real library data to tune; see §11. Field removed from v0.1 manifest to avoid an always-null field in on-disk format. |

---

## 5. Architecture contracts (invariants)

Breaking one of these requires a versioned spec delta (§12), not a code-only change.

1. **`CaptureEngine` is a single actor owning the state machine.** In v0.1.0 (Weekend 1), it owns `{idle, arming, selecting, capturing, finalizing, failed}`. In v0.1.1 (Weekend 2), it extends to include `annotating`. No state is added without a spec delta. No other type mutates these states.
2. **SwiftUI never owns `SCStream` or `SCStreamOutput`.** Capture surfaces (selection overlay, `Limbo` HUD, annotation canvas) are AppKit. SwiftUI is for settings, inspector panels, library browser — display only.
3. **`master.png` / `master.mov` are written once and never modified.** Every export re-renders from `master.*` + `annotations.json`. SensitiveContentAnalysis (§13.4) redaction produces a *new* `.shot`; the original master is untouched.
4. **A `.shot` is a directory, not a flat file.** Registered as a macOS package UTI. `manifest.json` is the canonical metadata; everything else can be re-derived if corrupted.
5. **Shotfuse's own bundle is always excluded from `SCContentFilter`.** The `Limbo` HUD, settings, selection overlay, and menubar popover must never appear in a capture.
6. **Crop rects and window frames are stored in canonical point space + full display metadata.** DPI conversion happens at the last moment (export/render), never at storage.
7. **Global hotkeys use `RegisterEventHotKey` (Carbon).** No global event taps — avoids the Input Monitoring TCC gate. On registration failure (e.g., hotkey already owned by another app), Shotfuse writes a structured log entry to `unified-logging`, surfaces a warning badge on the menubar icon, and offers a settings deep-link to pick an alternate binding.
8. **Screen Recording preflight uses the modern SCK API.** On launch, Shotfuse attempts `SCShareableContent.current` with a 1s timeout. Failure ⇒ deep-link to System Settings → Privacy & Security → Screen Recording. No capture surface is shown until the call succeeds.
9. **Library index is SQLite + FTS5** at `~/.shotfuse/index.db`. Spotlight is not a dependency; if Spike B confirms it works, it becomes a nice-to-have on top, not a replacement.
10. **Image captures never include the cursor.** SCK is configured with `showsCursor = false` for image mode. Video captures (post-v0.1) may opt in.
11. **Shotfuse plays no audio during any active `SCStream` session.** The success chime (if any) is suppressed while a capture is in flight.
12. **`.shot` package writes are atomic.** Packages are written to `<name>.shot.tmp/` and renamed to `<name>.shot/` only after `manifest.json` is `fsync`'d. Library scanners ignore `*.shot.tmp/`.

---

## 6. `.shot` package format

```
2026-04-21T10-43-12_com.apple.dt.Xcode.shot/
├── manifest.json           # canonical metadata; the index target
├── master.png              # immutable source pixels at native resolution
├── thumb.jpg               # 256px preview for pinboard + QuickLook
├── ocr.json                # Vision results (wrapped; see §6.3)
├── context.json            # AX tree snapshot + frontmost + clipboard + time
├── annotations.json        # vector annotation model (arrows, text, blur rects)
└── exports/                # append-only; rendered from master + annotations
    └── 2026-04-21T10-45-00_clipboard.png
```

### 6.1 `manifest.json` (v1)

| Field | Type | Required | Notes |
|---|---|---|---|
| `spec_version` | int | yes | `1` for v0.1 |
| `id` | UUIDv7 | yes | sortable by time; stable across moves/renames |
| `created_at` | ISO-8601 | yes | UTC |
| `expires_at` | ISO-8601 or null | yes | `Fuse` output; null ⇔ pinned |
| `mode` | `"verbal"` \| `"reference"` \| `"witness"` | yes | drives retention and library placement |
| `kind` | `"image"` \| `"video"` | yes | v0.1 is `image` only |
| `master` | `{ path, width, height, dpi }` | yes | |
| `display` | `{ id, native_width, native_height, native_scale, vendor_id?, product_id?, serial?, localized_name }` | yes | `CGDirectDisplayID` alone is unstable across reboot / reconnect; metadata enables robust rematch |
| `tags` | string[] | no | user-applied |
| `pinned` | bool | yes | true ⇒ no fuse |
| `witness` | `{ hash: string, algorithm: "sha256" }` | no | present iff `mode = "witness"`; see §13.6 |
| `sensitivity` | string[] (any of `"nudity"`, `"password_field"`, `"card_number"`, or the singleton `"none"`) | no | SCA results per §13.4 |

### 6.2 `context.json` (v1)

`context.clipboard` is captured ONLY if both hold: (a) `frontmost.bundle_id ∉ SENSITIVE_BUNDLES` (see §13.3), AND (b) the clipboard was last modified ≥ 60s ago OR the last-modifier's bundle ID is not in `SENSITIVE_BUNDLES`. Truncation: first 1024 UTF-8 bytes at a grapheme-cluster boundary, no ellipsis marker. If truncation occurred, set `clipboard_truncated: true`.

| Field | Type | Required | Notes |
|---|---|---|---|
| `frontmost.bundle_id` | string | yes | e.g. `com.apple.dt.Xcode` |
| `frontmost.window_title` | string | no | may be empty |
| `frontmost.file_url` | string | no | from AX when available (IDEs, text editors) |
| `frontmost.git_root` | string | no | resolved from `file_url` |
| `frontmost.browser_url` | string | no | from AX when frontmost is a browser |
| `clipboard` | string | no | text only; truncated per above |
| `clipboard_truncated` | bool | no | true iff truncation occurred |
| `ax_available` | bool | yes | false if Accessibility TCC denied |
| `captured_at` | ISO-8601 | yes | UTC, matches `manifest.created_at` |

### 6.3 `ocr.json` (v1)

Top-level object: `{ vision_version: string, locale_hints: string[], results: [{ text: string, bbox: [x, y, w, h] in master-pixel space, confidence: 0..1, lang: string }] }`.

OCR is best-effort async: the capture is searchable by `context.json` fields (frontmost app, window title, file URL) immediately; OCR enriches the FTS5 index on catch-up. OCR is deferred to AC power or energy-ok mode (low-power mode pauses the queue). Vision output is NOT re-OCR'd on macOS upgrade unless `shot reindex` is invoked explicitly.

### 6.4 `annotations.json` (v1)

Vector model. v0.1 supports only: `arrow { from, to, color, width }`, `text { at, string, font, color }`, `blur_rect { rect, sigma }`. All coordinates in master-pixel space.

Defaults: `arrow.color = #FF3B30`, `arrow.width = 4pt` (converted to master-pixel at render), `text.font = system body` (`.body` via `NSFont.preferredFont(forTextStyle:)`), `text.color = #FF3B30`, `blur_rect.sigma = 12pt`. All user-overridable via inspector; persisted per-capture.

### 6.5 `exports/` directory

Append-only. Files named `<iso8601>_<destination-slug>.<ext>` (e.g., `2026-04-21T10-45-00_clipboard.png`, `2026-04-21T10-47-12_obsidian.png`). Retention is unbounded; user-visible via `shot show <id>`.

---

## 7. Destination `Router` — v0.1 taxonomy

Three predictors. Coverage matters less than accuracy at this stage.

| Destination | Predicate |
|---|---|
| `clipboard` | Default / fallback; always scores non-zero |
| `~/Projects/<git-root>/screenshots/` | `frontmost.bundle_id ∈ {com.apple.dt.Xcode, com.microsoft.VSCode, com.todesktop.230313mzl4w4u92¹, dev.zed.Zed}` AND `frontmost.git_root != null` |
| `obsidian://daily` | `frontmost.bundle_id ∈ {md.obsidian, com.apple.Notes}` |

¹ Cursor's bundle ID as of 2026-04; verify before first notarized build.

Post-v0.1 candidates (do NOT ship in v0.1): `slack://channel`, `linear://issue/<id>`, `local-share-link`.

### 7.1 Decision rule

> Auto-deliver if `top_score > 0.85 AND second_score < 0.4`. Otherwise show a 3-option chooser in the `Limbo` HUD. After auto-delivery, show a 3-second non-blocking toast: *"→ `<destination>` · `Cmd+Z` to redirect"*. `Cmd+Z` inside the toast opens the chooser.

Log every decision to `~/.shotfuse/telemetry.jsonl` as `{ id, ts, predicted, chosen, top_score, second_score }` — feeds the threshold-tuning work in §11. Telemetry schema and retention locked in §13.5.

### 7.2 Keymap

No GUI for key config in v0.1. Config at `~/.shotfuse/keymap.toml`:

```toml
[capture]
region     = "cmd+shift+2"
window     = "cmd+shift+3"   # Weekend 2
fullscreen = "cmd+shift+4"   # Weekend 2
witness    = "cmd+shift+w"

[limbo]
edit     = "e"
pin      = "p"
tag      = "t"
delete   = "esc"
redirect = "cmd+z"
```

Keymap changes are applied on app restart only. Hot-reload deferred (§11).

### 7.3 Side-effect policy

Router creates `screenshots/` if missing. Router NEVER modifies `.gitignore`, runs `git add`, or writes outside the target directory. Unwritable target ⇒ fall back to `clipboard` AND log via `unified-logging` category `router`. Obsidian URL scheme failures (plugin missing, Obsidian not running) fall back to `clipboard` with the same logging.

---

## 8. TCC permission contract

Four gates. Treat each as a distinct state — never bundle prompts.

| TCC gate | Needed for | Denial UX |
|---|---|---|
| Screen Recording | Pixel capture (v0.1 Weekend 1) | Deep-link to System Settings; capture surface never appears (Invariant 8) |
| Accessibility | AX tree snapshot in `context.json` (v0.1 Weekend 1) | Capture proceeds; `context.ax_available = false` |
| Microphone | Mic recording (v0.4+) | Out of v0.1 scope |
| Input Monitoring | Not required — v0.1 uses `RegisterEventHotKey` exclusively | — |

TCC status is re-checked per-capture (cheap), not only on launch. If permission is revoked mid-session, the next capture triggers the denial UX above.

---

## 9. Blocker spikes — MUST complete before Weekend 1 code

Both spikes are architectural load-bearing. If either returns negative, this spec needs revision before implementation starts.

### Spike A — AX tree extraction latency

**Question.** Can the AX tree snapshot for the frontmost app complete in ≤50ms p95 at capture time? If not, `context.json` enrichment must go async (post-capture) and the `Limbo` HUD must render without context on first paint.

**DoD.** A ~30-line Swift benchmark that extracts `{ bundle_id, window_title, focused file_url / browser_url }` 20 times each against Xcode, VS Code, Safari, Slack, Obsidian. Report p50 / p95 / p99. Decision: sync if ≤50ms p95, else async with post-capture enrichment.

**Feeds back into.** `CaptureEngine` state — whether `capturing → finalizing` blocks on AX or schedules it.

### Spike B — Spotlight + QuickLook on `.shot` packages

**Question.** Does registering `.shot` as a UTI package allow Spotlight to index `manifest.json` + `ocr.json` contents? Does QuickLook render `thumb.jpg` + summary without a custom plugin?

**DoD.** Minimal Xcode project registers the UTI, writes a synthetic `.shot` with fake `manifest.json`, `ocr.json`, `thumb.jpg`. Verify: (a) Spotlight returns the package when searching OCR text; (b) QuickLook previews `thumb.jpg`.

**Feeds back into.** Whether the library index can lean on Spotlight (unlikely in v0.1 — keep SQLite+FTS5 as the load-bearing index) and whether a QuickLook plugin is needed (probably not for v0.1).

---

## 10. Resolved open questions

| Question | Resolution |
|---|---|
| SwiftUI/AppKit boundary for the annotation editor | AppKit `NSView` canvas (deterministic coordinates, focus, hit-testing, `PencilKit` integration). SwiftUI for the inspector / toolbar strip / property sheets. |
| `.shot` format — flat file vs directory | Directory (macOS package convention). UTI-registered. |
| Platform floor | macOS 26+ (deletes click-ring re-implementation, native `SCRecordingOutput` / `captureMicrophone` / `SensitiveContentAnalysis`). |
| Witness integrity level | Local SHA-256 for v0.1 (§13.6). RFC 3161 TSA deferred (§11). |
| At-rest encryption | FileVault-dependent for v0.1 (§13.2). Per-library passphrase deferred (§11). |
| SCA default action | Surface a prompt ("Redact and re-save"). Never auto-modify the original master. |
| Keymap reload | Restart-only for v0.1. Hot-reload deferred (§11). |
| Bundle ID | `dev.friquelme.shotfuse`. |
| License | MIT. |

---

## 11. Deferred open questions (with revisit triggers)

| Question | Revisit when |
|---|---|
| Router prediction confidence thresholds (`0.85` / `0.4`) | After 100 real-world captures post-Weekend-2; tune from `telemetry.jsonl` |
| "What will I hate about this app in 6 months" retrospective | 8 weeks post-v0.1 ship; compare real friction against BRAINSTORM.md paradoxes |
| CI for notarization + hardened runtime | Before tagging `v0.1.0`; GitHub Actions + `notarytool` |
| `Capture Echo` detection algorithm and return to vocabulary | After Weekend 2; re-admit at `spec_version = 2` |
| Verbal vs Reference classification heuristic | After Weekend 2; may be explicit user toggle in v0.1 and auto-detected later |
| Witness TSA signing (RFC 3161) | Before first external-trust use case |
| Annotation renderer version field in `annotations.json` | After a renderer bug causes a post-upgrade regression |
| Library-level encryption (per-library passphrase) | When library-sync (iCloud / git) is promoted from non-goal |
| Hot-reload of `keymap.toml` | When manual restart becomes painful |
| First-run onboarding flow spec | Before Weekend 1 first user run (self included) |
| Menubar icon state-machine spec | Before Weekend 1 first user run |
| Localization / `Localizable.strings` infrastructure | When non-English contributors appear |

---

## 12. Spec change policy

- SPEC.md is the v0.1 contract.
- Changes to **architecture contracts** (§5) or **locked vocabulary** (§4) require a versioned spec delta: `SPEC-DELTA-YYYY-MM-DD.md` reviewed before code lands.
- Changes to **non-goals** (§3) that promote something into scope are non-breaking additions — update in place, note the date.
- Changes to the **`.shot` format** (§6) bump `spec_version` in `manifest.json` and require a forward-compatibility migration in `Core`.
- BRAINSTORM.md is never updated. It is the historical record of how we got here.
- **Solo-review protocol** (this is a one-developer project): a `SPEC-DELTA-YYYY-MM-DD.md` commit lands on a separate branch, soaks for 24h, then merges into `main`. The audit document (e.g., `SPEC-AUDIT-YYYY-MM-DD.md`) serves as the pre-code review artifact for the corresponding delta.

---

## 13. Privacy contract

A `.shot` package is a device-state snapshot, not a screenshot. It contains pixels, OCR-recognized text of anything on screen, the AX tree (including focused file URLs), and possibly clipboard contents. The library lives plaintext on disk.

### 13.1 Sensitivity classification

| Field                       | Sensitivity | Handling |
|-----------------------------|-------------|----------|
| `master.png`                | High        | Stored plaintext; excluded from telemetry |
| `ocr.json.results[].text`   | High        | Stored plaintext; redacted in logs (hash only) |
| `context.clipboard`         | High        | Capture gated by §13.3 |
| `context.frontmost.*`       | Medium      | Stored plaintext |
| `manifest.*`                | Low         | Stored plaintext |

### 13.2 At-rest encryption

v0.1 relies on **FileVault** for at-rest encryption. Users without FileVault are exposed; this is an acknowledged assumption, not a fix. A per-library passphrase is deferred (§11).

### 13.3 `SENSITIVE_BUNDLES` exclusion list

Both image capture and clipboard snapshotting skip these bundles:

- `com.1password.*`
- `com.agilebits.onepassword*`
- `com.apple.keychainaccess`
- `com.apple.Passwords`
- `com.lastpass.*`
- `com.bitwarden.*`

List is user-extensible via `~/.shotfuse/exclusions.toml`. If the frontmost app is in the list at capture time, `CaptureEngine` transitions `arming → failed` with a user-visible "Capture suppressed: sensitive app" toast. The `.shot` is NOT written.

For clipboard specifically, Shotfuse tracks the last-modifier bundle ID via `NSPasteboard.changeCount` and skips `context.clipboard` if that bundle is in `SENSITIVE_BUNDLES` within the last 60s (even if the frontmost app is not).

### 13.4 SensitiveContentAnalysis

v0.1 runs `SCSensitivityAnalyzer` against `master.png` post-capture. Results stored in `manifest.sensitivity` as a list of detected categories: any of `{"nudity", "password_field", "card_number"}`, or the singleton `["none"]` if clean.

If any category ≠ `"none"`, the `Limbo` HUD surfaces a one-tap **"Redact and re-save"** action. Redaction **never modifies the original `master.png`** (Invariant 3): it creates a new `.shot` package with the flagged regions blurred; the user then decides whether to delete the pre-redaction capture.

### 13.5 Telemetry

`~/.shotfuse/telemetry.jsonl` contains only: `{ id, ts, predicted, chosen, top_score, second_score }`. No OCR text, no bundle contents, no clipboard, no filename, no file paths. **Never uploaded anywhere.** Size cap: rotate at 10 MB, keep 2 rotations.

### 13.6 Witness cryptographic hash

For `mode = "witness"` captures, `manifest.witness.hash` contains the SHA-256 hex digest of:

```
SHA-256( SHA-256(master.png)
       || canonical_json(manifest with `witness` field omitted, keys sorted, no whitespace)
       || captured_at_as_utf8 )
```

The hash is locally-verifiable: it proves the capture has not been modified since creation on this machine. It is **NOT** a third-party-verifiable timestamp. RFC 3161 TSA signing is deferred (§11) until there is a concrete external-trust use case.

---

## 14. macOS 26 platform features

| Feature                        | v0.1 use          | Rationale |
|--------------------------------|-------------------|-----------|
| `SCShareableContent`           | Yes               | Replaces deprecated `CGPreflightScreenCaptureAccess` (Invariant 8) |
| `SCSensitivityAnalyzer`        | Yes               | §13.4 — core privacy posture |
| `SCStream.showsCursor = false` | Yes               | Invariant 10 |
| `includeChildWindows`          | Yes (Weekend 2)   | Required for correct window-mode capture |
| `SCRecordingOutput`            | No                | Recording is non-goal for v0.1 |
| `captureMicrophone`            | No                | Non-goal (v0.4+) |
| `showMouseClicks`              | No                | Recording-only; non-goal |

---

## 15. System integration

### 15.1 Fuse cleanup launch agent

| Property | Value |
|---|---|
| Identifier | `dev.friquelme.shotfuse.fuse` |
| Plist | `~/Library/LaunchAgents/dev.friquelme.shotfuse.fuse.plist` |
| StartInterval | `3600` (hourly) |
| ProgramArguments | `[<app_bundle>/Contents/MacOS/shot, system, fuse-gc]` |
| Installed | On first app launch if absent |
| Uninstalled | `shot system uninstall` |

### 15.2 LSUIElement

App `Info.plist` has `LSUIElement = true`. No Dock icon. Surface is menubar only.

---

## 16. CLI surface (v0.1 minimum)

v0.1 ships exactly these commands. All others are out-of-scope.

| Command                                | Weekend | Behavior |
|----------------------------------------|---------|----------|
| `shot last [--ocr] [--path] [--copy]`  | 1       | Most recent capture; `--ocr` prints OCR text, `--path` prints package path, `--copy` re-copies to clipboard |
| `shot list [--since <ISO8601>]`        | 1       | One line per capture; default last 24h |
| `shot show <id>`                       | 1       | Pretty-print `manifest.json` + exports index |
| `shot system status`                   | 1       | TCC gates, library count, fuse-gc last-run, launch-agent status |
| `shot system fuse-gc`                  | 1       | Run fuse cleanup synchronously; used by launch agent |
| `shot system export <tarball>`         | 1       | `tar -czf` of `~/.shotfuse/` minus telemetry |
| `shot system uninstall`                | 1       | Remove launch agent; keeps library |

---

## 17. Observability

### 17.1 Unified logging

Subsystem: `dev.friquelme.shotfuse`. Categories:

- `capture` — engine state transitions, timings
- `router` — predictor scores and routing decisions
- `library` — package writes, scanner, index rebuilds
- `fuse` — cleanup runs, packages removed
- `tcc` — permission gate checks

Default level `info`. Deep debug via `log config --mode level:debug --subsystem dev.friquelme.shotfuse --category <cat>`.

### 17.2 Redaction

Logs NEVER contain `context.clipboard` or OCR `text` values verbatim. When referenced, they are replaced by `sha256[:8]` of the value.

### 17.3 User-visible diagnostics

- `shot system status` surfaces all gates, timings, and queue depths.
- Menubar icon badges: TCC denial, hotkey conflict, disk full, launch-agent failure.
