# SPEC.md — Adversarial Completeness Audit

**Target**: `SPEC.md` (Shotfuse v0.1, dated 2026-04-21)
**Audited**: 2026-04-21
**Method**: Adversarial completeness challenge against a nine-dimension scoring framework. Non-destructive — SPEC.md unchanged. Deltas proposed for review in §5.
**Verdict**: **53/100 — "Strong core, unsafe edges."** The architecture contracts (§5) and locked vocabulary (§4) are unusually disciplined. The privacy, operability, and error-path dimensions are nearly unspecified. This is shippable for Weekend 1 spine work, but four P0 findings need resolution before the first real capture lands on disk.

---

## 1. Executive summary

Shotfuse's spec nails the **happy-path architecture**: a single actor owns state, `.shot` is a package, renders are derived from an immutable master, coordinate space is canonical. Those are the invariants worth locking and they are locked well.

It is silent on three categories that carry outsized risk for a screen-capture tool:

1. **Privacy of the captured artifact.** A `.shot` is not a screenshot — it is a device-state dump (pixels + OCR text + AX tree + clipboard). The library lives in plaintext on disk. The spec has no threat model and no exclusion list for sensitive apps. macOS 26 provides `SensitiveContentAnalysis` (called out in the platform-stack memory as a stated unlock) and the spec neither requires nor rejects it.
2. **Operability after the happy path.** No logging strategy, no recovery contract for corrupt packages or index, no launch-agent specification, no end-user-visible error surface.
3. **Testability of the Weekend 2 DoD.** "8 of 10 land on predicted destination" has no ground-truth mechanism. The test is self-reported against unwritten-down expectations.

The core is strong enough that these are additive concerns, not rewrites. They belong as new sections (§A Privacy, §B Operability, §C Observability) and as tightening of existing DoD criteria — not as changes to §4/§5.

---

## 2. Score

| Dimension                | Pts | Score | Notes |
|--------------------------|-----|-------|-------|
| Unambiguity              | 15  | **9** | "Within 1s", "pixel-identical", set-membership by human names, 1KB truncation rule all underspecified |
| Testability              | 15  | **9** | Weekend 1 DoD is observable; Weekend 2 "8/10" lacks ground truth; no error-path tests |
| Invariance               | 10  | **7** | Nine strong invariants; Invariant 1 weakened by Weekend-2 caveat; missing: atomic writes, OCR determinism, master format pin |
| Coverage                 | 15  | **7** | Happy path covered; error paths, CLI, settings, onboarding, quit all absent |
| Determinism              | 10  | **6** | Coordinate space determined; `annotations.json` re-render requires font/color-profile/renderer pinning not spec'd; OCR version not pinned |
| Boundary clarity         | 10  | **8** | §3 non-goals and §11 deferred Qs with triggers are excellent; missing sensitive-app exclusion boundary |
| Safety / privacy         | 10  | **2** | No threat model, no at-rest encryption, no app-exclusion list, no SensitiveContentAnalysis commitment |
| Operability              | 10  | **2** | No logging, no repair contract, no launch-agent spec, no onboarding, no error-observable surface |
| Vocabulary lock          | 5   | **3** | §4 format excellent; Witness contradiction (mode vs library); `supersedes` field defined but algorithm deferred |
| **Total**                | 100 | **53**| |

Reading: privacy (2/10) and operability (2/10) pull the total down hard. If you close the four P0s and the eight P1s in §4, the spec moves to ~78/100.

---

## 3. Findings by severity

Each finding cites SPEC.md sections in parentheses. Proposed resolution in §5 groups these as patch-level edits.

### 3.1 P0 — Blockers (resolve before Weekend 1 code)

**AUDIT-001 · Privacy threat model is absent** *(whole spec)*
The library in `~/.shotfuse/library/` accumulates: raw pixels, OCR text of everything on screen, AX tree (roles, values, file paths, window titles), clipboard contents (§6.2). A hostile process with disk read access gets a month of your screens in searchable form. There is no threat model, no statement of what is sensitive, no at-rest encryption decision, no exclusion list. **Why it matters**: this is the single largest risk vector of the product. **Resolution**: add §13 Privacy contract with (a) sensitivity taxonomy per field, (b) at-rest decision (FileVault-only? encrypted library?), (c) app bundle-ID exclusion list for capture *and* clipboard snapshotting, (d) SensitiveContentAnalysis commitment.

**AUDIT-002 · Witness mode is specified two incompatible ways** *(§4 vs §6.1)*
§4 says Witness Capture "lives in `~/.shotfuse/witnesses/`" — a separate library. §6.1 says `manifest.mode: "verbal" | "reference" | "witness"` — Witness is a mode of a normal `.shot`. A reader implementing v0.1 cannot tell whether to scan `~/.shotfuse/witnesses/` for mode=witness packages, or whether library packages can have mode=witness. **Why it matters**: ambiguity in on-disk format is unfixable post-ship. **Resolution**: pick one. Recommend: Witness is a *separate on-disk library* under `~/.shotfuse/witnesses/`, witnesses are full `.shot` packages with `manifest.mode = "witness"`, but they are never indexed into `~/.shotfuse/index.db` or routed. This gives Witness strong isolation while reusing the format.

**AUDIT-003 · Witness cryptographic timestamp is unspecified** *(§4)*
§4 says Witness Capture has "cryptographic hash + timestamp". A local timestamp signed by a local key is not legally meaningful — it is a screenshot of a clock. A witness is either (a) locally-hashed-only, in which case it is proof to the owner alone, or (b) RFC 3161 TSA-signed, in which case it is third-party-verifiable. **Why it matters**: the feature's value proposition depends on which. **Resolution**: commit to one. Recommend (a) for v0.1 with SHA-256 over `master.png + manifest.json (excl. signature) + captured_at`, stored in `manifest.witness.hash`. Defer TSA signing to v0.2.

**AUDIT-004 · Weekend 2 DoD "8 of 10" has no ground truth** *(§2)*
"At least 8 of 10 land on the predicted destination without user intervention OR within one Cmd+Z redirect." *Who* decides what "should have been predicted"? If the user Cmd+Z's every capture, both clauses count as success under different readings. Without a ground-truth log ("what I would have picked if the Router were perfect"), the test is not verifiable. **Resolution**: rewrite the DoD to be observable-from-telemetry: "Across 10 consecutive captures, ≤2 results in the user invoking `Cmd+Z` redirect after auto-delivery, AND ≤2 results in the chooser appearing instead of auto-delivery." Both branches are measurable from `telemetry.jsonl` without user judgment.

### 3.2 P1 — High (resolve before Weekend 2 code)

**AUDIT-005 · Clipboard capture has no bundle-ID exclusion list** *(§6.2)*
`context.clipboard` truncated to 1KB — but 1Password, Keychain, macOS Password autofill, and most browsers put plaintext passwords in the clipboard for ~1 minute. A capture taken during that window permanently archives the password in plaintext. **Resolution**: add invariant: "clipboard is NOT captured if `frontmost.bundle_id ∈ SENSITIVE_BUNDLES` OR the clipboard was last modified <60s ago by a bundle in SENSITIVE_BUNDLES." Define `SENSITIVE_BUNDLES` initial list: `com.1password.*, com.apple.keychainaccess, com.apple.Passwords, com.agilebits.onepassword*, com.lastpass.*, com.bitwarden.*`.

**AUDIT-006 · macOS 26 feature inventory not mapped to spec** *(whole spec)*
Platform-stack memory names four macOS 26 unlocks: `SCRecordingOutput`, `captureMicrophone`, `showMouseClicks`, `includeChildWindows`, `SensitiveContentAnalysis`. The spec references none of them. At minimum, `SensitiveContentAnalysis` and `showMouseClicks` are v0.1-relevant (SCA for redaction of passwords/cards in screenshots; `showMouseClicks` for recording — which is non-goal, fine). **Resolution**: add §14 Platform features matrix: {feature → v0.1 use / v0.2 / out-of-scope / rationale}. Make SensitiveContentAnalysis a v0.1 yes.

**AUDIT-007 · Launch-agent for fuse cleanup is named nowhere** *(§2)*
Weekend 1 DoD: "A background launch-agent deletes unpinned packages past `expires_at`." The agent has no identifier, no plist location, no install/uninstall contract, no schedule interval. **Resolution**: add to §5 or a new §15 System integration: identifier `dev.<owner>.shotfuse.fuse`, plist at `~/Library/LaunchAgents/dev.<owner>.shotfuse.fuse.plist`, interval 3600s, installed on first launch, uninstalled on app delete via helper subcommand `shot system uninstall`.

**AUDIT-008 · Hotkey conflict has no user-visible surface** *(Invariant 7, §7.2)*
`RegisterEventHotKey` returns a status. If another app already owns `cmd+shift+2`, Shotfuse's registration fails silently. User presses the hotkey, nothing happens, no diagnostic. **Resolution**: invariant addendum: "On `RegisterEventHotKey` failure, Shotfuse writes a structured log entry AND surfaces a warning in the menu-bar icon AND offers a settings deep-link to pick an alternate binding."

**AUDIT-009 · "Within 1s" lacks percentile and conditions** *(§2)*
Weekend 1 DoD uses "Within 1s" — median? p95? worst case? Cold (first capture post-launch, Vision model not loaded) vs warm? **Resolution**: "p95 ≤ 1.5s warm, ≤ 3.0s cold (first capture post-launch). p50 ≤ 600ms warm." Measured from hotkey-release to clipboard-write complete AND `.shot` package `fsync` returned.

**AUDIT-010 · Annotation re-render "pixel-identical" is unachievable without more pins** *(§2, §6.4)*
Weekend 2 DoD: "re-render pixel-identically from master.png on re-export". Font rendering depends on installed fonts (different Mac, same spec file), Core Image filter version depends on macOS, text layout differs across Apple OS versions. "Pixel-identical" across machines is not a thing. **Resolution**: replace with "byte-identical *on the same machine and same macOS minor version* AND SSIM ≥ 0.995 across any supported macOS 26.x patchlevel." OR: commit to shipping a renderer-version field in `annotations.json` and rejecting re-renders when mismatched.

**AUDIT-011 · Invariant 1 is self-weakened** *(§5)*
"CaptureEngine is a single actor owning the full state machine: idle → arming → selecting → capturing → finalizing → annotating → failed" followed by "Weekend 1 implements idle through finalizing; annotating is a pass-through until Weekend 2." The invariant is not "a single actor owns the state machine" — it is "a single actor owns whatever subset of the state machine exists this week." **Resolution**: change invariant to reference the Weekend-1 subset explicitly: "In v0.1.0 (Weekend 1), `CaptureEngine` is a single actor owning `{idle, arming, selecting, capturing, finalizing, failed}`. In v0.1.1 (Weekend 2), it extends to include `annotating`. No state is ever added without a spec delta." This makes the invariant non-conditional at each version.

**AUDIT-012 · `supersedes` field ships but detection is deferred** *(§6.1, §11)*
`manifest.supersedes: UUID | null` is in the v0.1 format. Capture Echo detection algorithm is deferred to §11. In v0.1 the field is always null. **Resolution**: remove from `spec_version=1` manifest. Add in `spec_version=2` when detection ships. Reduces v0.1 surface; avoids "field present but unused" archaeology cost later.

**AUDIT-013 · `display_id` alone is insufficient for reliable coordinate restoration** *(§5 Invariant 6, §6.1)*
`CGDirectDisplayID` is re-assigned on reboot, on display reconnect, and differs across Macs. A `.shot` moved between Macs has a meaningless `display_id`. **Resolution**: add `display_meta: { id: CGDirectDisplayID, native_width, native_height, native_scale, vendor_id?, product_id?, serial?, localized_name }`. On re-open, match by (vendor_id, product_id) first, then by (native_width, native_height, native_scale), fall back to ID.

**AUDIT-014 · Router side-effects on git repos unspecified** *(§7)*
`~/Projects/<git-root>/screenshots/` — does Shotfuse create the directory? Add it to `.gitignore`? Silently fail if unwritable? If the user has it in `.gitignore` but Router writes anyway, the file is "tracked-but-ignored" until committed. If it is committed automatically, Shotfuse is mutating a git repo without consent. **Resolution**: spec addition in §7: "Router creates `screenshots/` if missing. Router never modifies `.gitignore`. Router never runs `git add`. If the user wants git-tracked screenshots, they add the path manually."

**AUDIT-015 · `CGPreflightScreenCaptureAccess` is a legacy API** *(§5 Invariant 8, §8)*
Deprecated after macOS 15. On macOS 26, `SCShareableContent.excludingDesktopWindows(...)` is the preflight — attempting to fetch shareable content fails cleanly if permission is missing. **Resolution**: swap Invariant 8 to "On launch, Shotfuse attempts `SCShareableContent.current` with timeout; failure ⇒ deep-link to Settings."

**AUDIT-016 · No CLI contract in SPEC.md** *(whole spec)*
BRAINSTORM.md v0.1 scope names `grab last`, `grab list`, `grab last --ocr`. The rename to `shot` is in memory but the CLI surface is absent from SPEC.md. **Resolution**: add §16 CLI surface with Weekend-1 minimum: `shot last [--ocr | --path | --copy]`, `shot list [--since <time>]`, `shot show <id>`, `shot system status`. Mark all others out-of-scope for v0.1.

**AUDIT-017 · No observability / logging strategy** *(whole spec)*
If Weekend-1 Alice presses `cmd+shift+2` and nothing happens, how does she debug? **Resolution**: add §17 Observability: unified-logging subsystem `dev.<owner>.shotfuse`, categories `capture / router / library / fuse / tcc`. Redact `context.clipboard` and `ocr.text` fields in logs by default (hash only). `shot system log --tail` convenience.

**AUDIT-018 · `exports/` directory behavior unspecified** *(§6)*
`.shot` lists `exports/` with one example file — no naming scheme, no retention policy, no whether it rebuilds every export or append-only. **Resolution**: commit to a policy. Recommend: append-only; name `<iso8601>_<destination-slug>.<ext>`; retention unbounded (user-visible via `shot show` → exports list).

### 3.3 P2 — Medium (v0.2 or with note in v0.1)

**AUDIT-019 · `ocr.json` lang detection and Vision version** *(§6.3)*
Vision OCR output changes between macOS versions. `ocr.json` is stored once; re-OCR on macOS upgrade? **Resolution**: add `ocr.json` top-level `{ vision_version, locale_hints, results: [...] }`. Do not re-OCR unless `shot reindex` run explicitly.

**AUDIT-020 · Annotation UI (colors, fonts, defaults) unspecified** *(§6.4)*
Vector model specified; the editor controls are not. Default arrow color? Font family? Blur default sigma? **Resolution**: add §6.4 addendum: default color `#FF3B30`, default font system body (`.body` via `NSFont.preferredFont(forTextStyle: .body)`), default blur sigma `12pt` (converted to master-pixel at render). All user-overridable via inspector.

**AUDIT-021 · Cursor inclusion in capture** *(§5)*
SCK has `showsCursor: Bool`. Spec silent. **Resolution**: invariant: "Image captures never include the cursor. (Video captures, post-v0.1, may opt in.)"

**AUDIT-022 · Audio isolation during capture** *(§5)*
If Shotfuse plays a success chime and SCK is recording audio, the chime is in the recording. For v0.1 (image only), this is moot. Add invariant anyway for forward-compat. **Resolution**: "Shotfuse plays no audio during any active `SCStream` session."

**AUDIT-023 · First-run onboarding absent** *(whole spec)*
On first launch, what does the user see? TCC prompts? A welcome window? A menubar icon alone? **Resolution**: §18 First-run: "Show welcome window with three steps: (1) grant Screen Recording, (2) optional grant Accessibility, (3) choose library path. Default library path = `~/.shotfuse/library/`. Welcome never shown again unless library path is reset."

**AUDIT-024 · Localization policy undeclared** *(whole spec)*
All UI text in SPEC.md is in English. Is this English-only v0.1? **Resolution**: explicit: "v0.1 ships English only. No Localizable.strings infrastructure. Revisit when non-English contributors appear."

**AUDIT-025 · Menubar icon state machine undefined** *(§8 mentions "warning badge")*
States: idle, capturing, error, TCC-denied. Menu items: Last Capture, Library..., Settings..., Quit. **Resolution**: §19 Menubar: state enum and menu contract.

**AUDIT-026 · No library backup / export path** *(§11)*
"iCloud Drive / git sync" is non-goal; but a user who trashes their Mac loses everything. **Resolution**: add `shot system export <tarball>` to the CLI. Trivial (tar of `~/.shotfuse/`). One line of v0.1.

**AUDIT-027 · Background OCR energy policy** *(§6.3)*
Vision on battery, in low-power mode, on a 12" MacBook — is it running? **Resolution**: "OCR is deferred to AC power or energy-ok mode. A capture without OCR is still searchable by context (app, window title, file URL) immediately. OCR is best-effort async."

### 3.4 P3 — Low (tidy)

**AUDIT-028 · Bundle ID and license deferred without deadline** *(§1, §11)*
Both have "pick before" conditions. Make the condition stricter. **Resolution**: "Bundle ID decided before first notarized build. License decided before first `git push` to public. Both tracked as bd issues; do not defer past 2026-05-01."

**AUDIT-029 · Spec change policy references "review" without specifying reviewer** *(§12)*
Solo project. **Resolution**: "SPEC-DELTA commits land on a separate branch, soak for 24h, then merge. 'Review' = re-read 24h later with fresh eyes."

**AUDIT-030 · Spec-level version missing** *(§1)*
`.shot` format has `spec_version`. The spec document itself does not. **Resolution**: add `**Spec version**: 0.1.0` to header. Bump when §4/§5 change.

**AUDIT-031 · `frontmost.bundle_id ∈ {Xcode, VS Code, Cursor, Zed}` uses product names** *(§7)*
Predicates should use bundle IDs. **Resolution**: rewrite §7 table column with bundle IDs (`com.apple.dt.Xcode`, `com.microsoft.VSCode`, `dev.zed.Zed`, Cursor's current ID). Human names in a comment or footnote.

**AUDIT-032 · `context.clipboard` truncation rule unspecified** *(§6.2)*
1KB = 1024 bytes? UTF-8 boundary? Leading or trailing truncation? **Resolution**: "First 1024 UTF-8 bytes, truncated on a grapheme-cluster boundary, no ellipsis marker. A `clipboard_truncated: true` flag if truncation occurred."

**AUDIT-033 · `manifest.id` generation method unspecified** *(§6.1)*
UUIDv4 vs UUIDv7? v7 is sortable by timestamp, which matters for deterministic library scans. **Resolution**: "UUIDv7."

**AUDIT-034 · Atomic write of `.shot` package not guaranteed** *(§6)*
If app crashes between writing `master.png` and `manifest.json`, library scanner encounters a `.shot` without a manifest. Valid state? **Resolution**: invariant: "Packages are written to `<name>.shot.tmp/` and renamed to `<name>.shot/` only after `manifest.json` is fsync'd. Scanner ignores `*.shot.tmp/`."

---

## 4. P0 / P1 resolution batch (13 items)

If you only close these 13, the spec moves from 53 to ~78/100:

| ID | Section affected | Effort |
|----|------------------|--------|
| AUDIT-001 | New §13 Privacy | Medium |
| AUDIT-002 | §4, §6.1 | Small |
| AUDIT-003 | §4, §6.1 | Small |
| AUDIT-004 | §2 | Small |
| AUDIT-005 | §6.2 | Small |
| AUDIT-006 | New §14 | Small |
| AUDIT-007 | New §15 or §5 | Small |
| AUDIT-008 | §5 Invariant 7 | Trivial |
| AUDIT-009 | §2 | Trivial |
| AUDIT-010 | §2, §6.4 | Small |
| AUDIT-011 | §5 Invariant 1 | Trivial |
| AUDIT-012 | §6.1 | Trivial (remove) |
| AUDIT-013 | §6.1 | Small |
| AUDIT-014 | §7 | Trivial |
| AUDIT-015 | §5 Invariant 8 | Trivial |
| AUDIT-016 | New §16 CLI | Small |
| AUDIT-017 | New §17 Observability | Small |
| AUDIT-018 | §6 | Trivial |

---

## 5. Proposed deltas (paste-ready)

These are the concrete text changes. Apply to a working copy, diff against SPEC.md, commit as `SPEC-DELTA-2026-04-21.md` per §12 policy.

### 5.1 Header tweak *(AUDIT-030)*

Replace the three-line header block with:

```markdown
**Status**: canonical v0.1 contract
**Spec version**: 0.1.0
**Dated**: 2026-04-21
**Source**: tightened from `BRAINSTORM.md` after multi-AI brainstorm + naming round. See SPEC-AUDIT-2026-04-21.md for audit trail. BRAINSTORM.md remains the narrative record; SPEC.md is the executable contract.
```

### 5.2 §2 Weekend 1 DoD tightening *(AUDIT-009)*

Replace "Within 1s" with:

> Within a budget of **p95 ≤ 1.5s warm / ≤ 3.0s cold (first capture post-launch); p50 ≤ 600ms warm**, measured from hotkey-release to *both* clipboard-write complete AND `.shot` package `fsync` returned.

### 5.3 §2 Weekend 2 DoD rewrite *(AUDIT-004, AUDIT-010)*

Replace the "8 of 10" paragraph with:

> Across 10 consecutive real-work captures, as measured by `telemetry.jsonl`: (a) ≤ 2 events where `predicted ≠ chosen` (user invoked `Cmd+Z` redirect), AND (b) ≤ 2 events where the chooser appeared instead of auto-delivery (top_score ≤ 0.85 or second_score ≥ 0.4). Predicted destinations are exactly: `clipboard`, `~/Projects/<git-root>/screenshots/`, `obsidian://daily`. Annotations (arrow, text, blur rectangle) round-trip through `annotations.json` and re-render **byte-identically on the same machine at the same macOS minor version; SSIM ≥ 0.995 across supported macOS 26.x patchlevels**.

### 5.4 §4 Witness + Echo fixes *(AUDIT-002, AUDIT-012)*

Replace the `Witness Capture` row with:

> `Witness Capture` — Cryptographic-hash mode (`Cmd+Shift+W`); bypasses `Limbo`; full `.shot` package stored in `~/.shotfuse/witnesses/` (separate on-disk library); never indexed in `~/.shotfuse/index.db`, never routed. — `WitnessService`, manifest.mode = `"witness"`

Remove the `Capture Echo` row entirely from v0.1 vocabulary. Move to a "Deferred vocabulary" subsection that re-introduces it with `spec_version=2`.

### 5.5 §5 Invariants — edits *(AUDIT-008, AUDIT-011, AUDIT-015, AUDIT-021, AUDIT-022, AUDIT-034)*

- **Invariant 1** — rewrite as:
  > In v0.1.0 (Weekend 1), `CaptureEngine` is a single actor owning `{idle, arming, selecting, capturing, finalizing, failed}`. In v0.1.1 (Weekend 2), it extends to include `annotating`. No state is added without a spec delta.

- **Invariant 7 addendum**:
  > On `RegisterEventHotKey` registration failure, Shotfuse writes a structured log entry to `unified-logging`, surfaces a warning badge on the menubar icon, and offers a settings deep-link to pick an alternate binding.

- **Invariant 8** — replace with:
  > On launch, Shotfuse attempts `SCShareableContent.current` with a 1s timeout. Failure ⇒ deep-link to System Settings → Privacy & Security → Screen Recording. No capture surface is shown until the call succeeds.

- **New Invariant 10**: Image captures never include the cursor. *(Video captures, post-v0.1, may opt in.)*

- **New Invariant 11**: Shotfuse plays no audio during any active `SCStream` session.

- **New Invariant 12**: `.shot` packages are written to `<name>.shot.tmp/` and atomically renamed to `<name>.shot/` only after `manifest.json` is fsync'd. Library scanners ignore `*.shot.tmp/`.

### 5.6 §6.1 manifest.json updates *(AUDIT-012, AUDIT-013, AUDIT-033)*

- Change `id` row note to: "UUIDv7 (sortable by time)."
- Remove `supersedes` row entirely (v0.1 does not detect echoes).
- Replace `display_id` row with a `display` object:

  | `display` | `{ id, native_width, native_height, native_scale, vendor_id?, product_id?, serial?, localized_name }` | yes | ID alone is unstable across reboot/reconnect; metadata enables robust rematch |

### 5.7 §6.2 clipboard privacy *(AUDIT-005, AUDIT-032)*

Add above the table:

> `context.clipboard` is captured ONLY if both hold: (a) `frontmost.bundle_id ∉ SENSITIVE_BUNDLES` (see §13), AND (b) the clipboard was last modified ≥ 60s ago or last-modifier's bundle ID is not in `SENSITIVE_BUNDLES`. Truncation: first 1024 UTF-8 bytes at a grapheme-cluster boundary, no ellipsis marker. If truncated, add `clipboard_truncated: true`.

### 5.8 §6.3 OCR metadata *(AUDIT-019)*

Replace `ocr.json` shape paragraph with:

> Top-level object: `{ vision_version: string, locale_hints: string[], results: [{ text, bbox: [x,y,w,h] in master-pixel space, confidence: 0..1, lang: string }] }`. Vision version is not re-OCR'd on macOS upgrade unless `shot reindex` is invoked explicitly.

### 5.9 §6.4 annotation defaults *(AUDIT-020)*

Append:

> Defaults: `arrow.color = #FF3B30`, `arrow.width = 4pt` (master-pixel at render), `text.font = system body`, `text.color = #FF3B30`, `blur_rect.sigma = 12pt`. All user-overridable via inspector; persisted per-capture.

### 5.10 §7 Router side effects + bundle IDs *(AUDIT-014, AUDIT-031)*

- Replace predicate column entries with bundle IDs:
  - `frontmost.bundle_id ∈ {com.apple.dt.Xcode, com.microsoft.VSCode, dev.zed.Zed, com.todesktop.230313mzl4w4u92}` (Cursor — verify current ID before first notarized build)
- Add §7.3:
  > **Side-effect policy.** Router creates `screenshots/` if missing. Router NEVER modifies `.gitignore`, runs `git add`, or writes outside the target directory. Unwritable target ⇒ fall back to `clipboard` AND log via `unified-logging` category `router`.

### 5.11 New sections (additive)

**§13 Privacy contract** *(AUDIT-001, AUDIT-005)*

```markdown
## 13. Privacy contract

A `.shot` package is a device-state snapshot, not a screenshot. It contains pixels,
OCR-recognized text of anything on screen, the AX tree (including focused file URLs),
and possibly clipboard contents. The library is plaintext on disk.

### 13.1 Sensitivity classification

| Field                       | Sensitivity | Handling |
|-----------------------------|-------------|----------|
| `master.png`                | High        | Stored plaintext; excluded from telemetry |
| `ocr.json`                  | High        | Stored plaintext; redacted in logs |
| `context.clipboard`         | High        | Capture gated by §13.3 |
| `context.frontmost.*`       | Medium      | Stored plaintext |
| `manifest.*`                | Low         | Stored plaintext |

### 13.2 At-rest

v0.1 relies on FileVault for at-rest encryption. A per-library passphrase is deferred.

### 13.3 `SENSITIVE_BUNDLES` initial exclusion list

Both image capture and clipboard snapshotting skip these bundles:

- `com.1password.*`
- `com.agilebits.onepassword*`
- `com.apple.keychainaccess`
- `com.apple.Passwords`
- `com.lastpass.*`
- `com.bitwarden.*`

List is user-extensible via `~/.shotfuse/exclusions.toml`. If the frontmost app is
in the list at capture time, `CaptureEngine` transitions `arming → failed` with a
user-visible "Capture suppressed: sensitive app" toast. Shot is NOT written.

### 13.4 SensitiveContentAnalysis

v0.1 runs `SCSensitivityAnalyzer` against `master.png` post-capture. Results stored
in `manifest.sensitivity = { nudity, password_field, card_number, none }`. UI surfaces
a one-tap "redact and re-save" action if any category ≠ none.

### 13.5 Telemetry

`~/.shotfuse/telemetry.jsonl` contains only: `{ id, ts, predicted, chosen, top_score,
second_score }`. No OCR text, no bundle contents, no clipboard, no filename. Never
uploaded anywhere. Size cap: rotate at 10 MB, keep 2 rotations.
```

**§14 Platform features matrix** *(AUDIT-006)*

```markdown
## 14. macOS 26 platform features

| Feature                        | v0.1 use | Rationale |
|--------------------------------|----------|-----------|
| `SCShareableContent`           | Yes      | Replaces deprecated `CGPreflightScreenCaptureAccess` |
| `SensitiveContentAnalysis`     | Yes      | §13.4 — core privacy posture |
| `SCStream.showsCursor`         | Yes (off for image) | Invariant 10 |
| `includeChildWindows`          | Yes      | Required for window-mode capture in Weekend 2 |
| `SCRecordingOutput`            | No       | Recording is non-goal for v0.1 |
| `captureMicrophone`            | No       | Non-goal |
| `showMouseClicks`              | No       | Recording-only; non-goal |
```

**§15 System integration** *(AUDIT-007)*

```markdown
## 15. System integration

### 15.1 Fuse cleanup launch agent

- Identifier: `dev.<owner>.shotfuse.fuse`
- Plist: `~/Library/LaunchAgents/dev.<owner>.shotfuse.fuse.plist`
- StartInterval: 3600 (hourly)
- ProgramArguments: `[<app_bundle>/Contents/MacOS/shot, system fuse-gc]`
- Installed on first launch if absent
- Uninstalled by `shot system uninstall`

### 15.2 LSUIElement

App Info.plist has `LSUIElement = true`. No Dock icon. Surface is menubar only.
```

**§16 CLI surface (v0.1 minimum)** *(AUDIT-016)*

```markdown
## 16. CLI surface

v0.1 ships exactly these commands. All others are out-of-scope.

| Command                                | Weekend | Behavior |
|----------------------------------------|---------|----------|
| `shot last [--ocr] [--path] [--copy]`  | 1       | Most recent capture; `--ocr` prints OCR text, `--path` prints package path, `--copy` re-copies to clipboard |
| `shot list [--since <ISO8601>]`        | 1       | One line per capture; default last 24h |
| `shot show <id>`                       | 1       | Pretty-print `manifest.json` + exports index |
| `shot system status`                   | 1       | TCC gates, library count, fuse-gc last-run, launch-agent status |
| `shot system fuse-gc`                  | 1       | Run fuse cleanup synchronously; used by launch agent |
| `shot system export <tarball>`         | 1       | `tar -czf` of `~/.shotfuse/` minus telemetry |
| `shot system uninstall`                | 1       | Remove launch agent, keep library |
```

**§17 Observability** *(AUDIT-017)*

```markdown
## 17. Observability

### 17.1 Unified logging

Subsystem: `dev.<owner>.shotfuse`. Categories:

- `capture` — engine state transitions, timings
- `router` — predictor scores and routing decisions
- `library` — package writes, scanner, index rebuilds
- `fuse` — cleanup runs, packages removed
- `tcc` — permission gate checks

Default level `info`. Each category supports `log config --mode level:debug --subsystem dev.<owner>.shotfuse --category capture` for deep debug.

### 17.2 Redaction

Logs NEVER contain `context.clipboard` or `ocr.text` values verbatim. When referenced, they are replaced by `sha256[:8]` of the value.

### 17.3 User-visible diagnostics

- `shot system status` (see §16) surfaces all gates and timings.
- Menubar icon badges on: TCC denial, hotkey conflict, disk full, launch-agent failure.
```

### 5.12 §11 deferred Qs — additions

Add rows:

| Witness TSA signing (RFC 3161) | Before first external-trust use case |
| Annotation renderer version field | After a renderer bug causes a post-upgrade regression |
| Library-level encryption (passphrase) | When library-sync (iCloud/git) is promoted from non-goal |
| `Capture Echo` in `spec_version=2` | After Weekend 2 library has real data; see AUDIT-012 |

---

## 6. Questions that need human decision

Audit findings I cannot resolve without you:

1. **Witness integrity level (AUDIT-003)**: local SHA-256 only, or RFC 3161 TSA? *Proposal: local for v0.1, TSA deferred.*
2. **At-rest encryption (AUDIT-001 / §13.2)**: FileVault-only is fine for personal use. For public distribution, users on non-FileVault systems will be exposed. Ship anyway? *Proposal: yes, document the assumption.*
3. **Bundle ID (AUDIT-028)**: `dev.<owner>.shotfuse` (personal attribution) vs `com.shotfuse.app` (project identity). *Proposal: `dev.<owner>.shotfuse` while this is a personal repo; swap to `com.shotfuse.app` if project gets its own org.*
4. **SensitiveContentAnalysis default action (§13.4)**: redact-and-re-save by default, or surface a prompt? *Proposal: surface, never auto-modify the master.*
5. **Keymap hot-reload (AUDIT-008 adjacent)**: reload on file save, or only on app restart? *Proposal: restart-only in v0.1; hot-reload is a polish lap.*
6. **License (AUDIT-028)**: MIT / Apache-2.0 / MPL-2.0. *Your call; memory flagged default MIT.*

---

## 7. Next steps

- Read this. Disagree where you disagree.
- For each P0/P1 you accept: apply the delta from §5 and commit as `SPEC-DELTA-2026-04-21.md`.
- Bd-track anything deferred.
- Spikes A and B (§9 of SPEC.md) remain blockers for Weekend 1 regardless of this audit. They are now in addition to AUDIT-001..004.
