# ScreenGrabber — Brainstorm Session

**Date**: 2026-04-21
**Mode**: Multi-AI brainstorm (Claude Octopus Team mode)
**Topic**: A personal Mac app (native Swift + SwiftUI) to replace CleanShot X — for one developer's own use, no commercial pressure, no subscription
**Target**: macOS 14+

---

## Framing Decisions

| Question | Answer | Implication |
|---|---|---|
| Motivation | Replace CleanShot for me | Tool can be brutally opinionated; no users to please |
| Stack | Native Swift + SwiftUI | Lean into modern Apple frameworks; AppKit where it pays |

---

## Multi-Perspective Analysis

### Provider Contributions

| Provider | Key Contribution | Unique Insight |
|---|---|---|
| 🔴 Codex | Hard technical reality: framework map, version boundaries, architecture patterns | SDK header verification — `SCRecordingOutput`/`captureMicrophone`/`showMouseClicks` are macOS 15+; on a 14 floor you re-implement click rings yourself. 4-way TCC permission split. |
| 🟡 Gemini | Lateral thinking & ecosystem glue | Personal-tool freedom unlocks "brutalist" choices: command palette over toolbar, FFmpeg as engine, Hammerspoon WebSocket integration, ghost overlay (trace mode), git-backed history, code-to-capture linking via Exif |
| 🔵 Claude | Pattern naming & paradox hunting | The product isn't the capture moment — it's the 30 seconds and 30 days that follow. Reframed entire product as "router not editor"; named *The Limbo*, *Witness Capture*, *Capture Echo*, *The Decay Gradient*, *Verbal vs Reference Screenshots* |

### Cross-Provider Convergence

Three independent angles pushed toward the same insights — these are non-negotiable:

| Theme | Codex | Gemini | Claude |
|---|---|---|---|
| **Captures are *structured*, not pixels** | OCR bounding boxes | Embed Xcode line refs in Exif | Capture the AX tree |
| **Destination/routing is the real product** | `ShareAction` protocol hook | Pipe to shell via stdin | "Router not editor" |
| **Exclude your own UI / private apps** | Exclude bundle from filter | Stream filtering for 1Password | Witness Capture / private surfaces |
| **Master representation, derive everything** | Master `.mov`, derive GIF later | FFmpeg pipeline, multi-export | Source-immutable, re-renderable |

---

## Breakthroughs (the parts worth tattooing)

### Pattern: The Aftermath, Not the Capture
Most tools optimize the capture moment. The actual job-to-be-done sits in the next 30 seconds (paste, route, annotate) and the next 30 days (find that one screenshot you desperately need). 95% of captures should die within 24 hours. The 5% that matter are currently unfindable.

### Paradoxes
- **Annotation paradox**: Better annotation tools encourage *worse* captures.
- **History paradox**: A pinboard mostly helps you avoid feeling guilty about deleting things, not find them.
- **OCR paradox**: OCR'd UI chrome pollutes search ("Cancel" returns 400 dialogs). Useful only when scoped to *what you cared about at capture time*.
- **Scrolling capture paradox**: A 14k-pixel PNG is almost never the actual job. MHTML or PDF would serve better.

### Named Concepts (use as code primitives)
- **The Limbo** — the 2–8s window between capture and decision. Deserves a dedicated UI surface.
- **Verbal vs Reference Screenshots** — speech-act vs archive. Different storage, retention, search.
- **Capture Echo** — same region recaptured because state changed. Tool should diff/supersede automatically.
- **The Decay Gradient** — the curve of a screenshot's value over time. Most peak in 60s and decay; a tiny minority climb in value.
- **Witness Capture** — proof-to-self ("the price was $X"). Needs cryptographic timestamp; never needs annotation.

### Five Reframes
1. **Router, not editor** — destination prediction (90%+ confidence from frontmost app + clipboard + time of day) is the product. Capture is incidental. One-key undo to redirect.
2. **24-hour fuse default** — born expiring. Saving is the explicit signal, not deletion.
3. **Pinboard as 2D thinking surface** — Milanote-style canvas; clusters *are* project context.
4. **Semantic capture via Accessibility tree** — capture grabs the AX hierarchy at the moment, not just pixels.
5. **Annotation is a chat with an LLM** — drop the toolbar; "redact every email," "circle the value that doesn't match" — the prompt becomes searchable caption.

---

## Architecture Decisions (the foundation)

### The `.gcap` Capture Package
A capture is a directory, not a file. Use the macOS package convention.

```
2026-04-21T10-43-12_xcode_AuthService.gcap/
├── manifest.json           # canonical metadata (the index target)
├── master.png              # immutable source pixels at native resolution
├── thumb.jpg               # 256px preview for the pinboard
├── ocr.json                # Vision results: { text, bbox, confidence }[]
├── context.json            # AX tree snapshot + frontmost app metadata
├── annotations.json        # vector model (rendered fresh on export)
└── exports/
    └── shared-2026-04-21.png   # rendered output, regenerable
```

`master.png` is never touched. Every export re-renders from source + annotations. Recordings swap `master.png` for `master.mov` + `keyframes/`; same router, same annotation model.

**Sneaky wins**:
- Drop the directory in iCloud Drive → free sync, no CloudKit
- `git add` → git-backed history (Gemini's idea) for free
- Register UTI → QuickLook plugin can render the manifest

### `context.json` — The Unlock
At capture time, snapshot:
```json
{
  "frontmost": { "bundleId": "com.apple.dt.Xcode", "title": "AuthService.swift" },
  "axTree": { "focused": { "role": "AXTextArea", "fileURL": "..." } },
  "clipboard": "https://github.com/.../auth#L142",
  "wifi": "Home",
  "time": "2026-04-21T10:43:12Z"
}
```

This is the difference between "screenshot tool I built" and "extension of my nervous system."

### Process Architecture (from Codex)
- `LSUIElement` menu bar app
- AppKit owns capture overlays + Limbo HUD + annotation window (focus/timing/coordinate predictability)
- SwiftUI for settings and inspector panels (display only, not config)
- Single `CaptureEngine` actor with explicit state machine: `idle → arming → selecting → capturing → finalizing → annotating → failed`
- Never let SwiftUI views own `SCStream`
- SQLite + FTS5 for the library index
- No sandbox in v1 (Developer ID + notarization is enough)

### Framework Map
| Capability | Primitive | Notes |
|---|---|---|
| Screenshots | `ScreenCaptureKit` (`SCScreenshotManager`) | Avoid deprecated `CGWindowListCreateImage` |
| Region selection | Custom AppKit overlay → SCK for pixels | Don't conflate UI and capture |
| Recording | `SCStream` → `AVAssetWriter` | Skip `VTCompressionSession` until measured pain |
| GIF | `ImageIO` post-export from .mov | GIF is a delivery format, not capture |
| OCR | `Vision` | Store text **and bounding boxes** |
| Annotation freehand | `PencilKit` | Optional; build own object model for arrows/text/blur |
| Blur/redaction | `Core Image` over source | Non-destructive |
| Microphone | `AVFoundation` | Separate from SCK on macOS 14 floor |
| System audio | `SCStream` audio output | `Core Audio` taps only if per-process needed |
| Sharing | `NSSharingService` | Don't reinvent |
| Previews | `QuickLookThumbnailing` | Don't build a preview stack |

### Hard Constraints (from Codex SDK header verification)
- `SCRecordingOutput`, `captureMicrophone`, `showMouseClicks` → **macOS 15+** (re-implement click rings on 14)
- `includeChildWindows` → **macOS 14.2+**
- 4 separate TCC permissions: Screen Recording / Microphone / Accessibility / Input Monitoring — treat as 4 distinct gates
- Use `CGPreflightScreenCaptureAccess` up front; switch UX to settings deep-link if denied
- Mixed-DPI: store crop rects in canonical point space + display ID; convert at last moment
- Exclude your own bundle from capture filters or you'll record your own success chime
- Use `RegisterEventHotKey` instead of global event taps (avoids Input Monitoring permission)

---

## v0.1 Scope (Two-Weekend MVP)

The point is to **stop opening CleanShot**, not to be feature-complete.

### Weekend 1: The Spine
- LSUIElement menu bar skeleton, TCC permission gates with settings deep-link
- `CaptureEngine` actor with full state machine
- Region capture only (window + fullscreen are 90% the same code, defer)
- `SCScreenshotManager` → `master.png` writer
- AX context snapshot at capture time (frontmost app + window title + URL if browser)
- `.gcap` package format + UTI registration
- SQLite index with FTS5 for OCR text
- Background `Vision` OCR with bounding-box storage
- Default route = clipboard. No router yet. Just put it in the clipboard and write the package to disk.
- Limbo HUD floating pill in top-right; 24-hour fuse cron job

**End of weekend 1**: capture a region → on clipboard → package on disk with OCR + context → dies in 24h → searchable from a Spotlight-like overlay.

### Weekend 2: The Personality
- Annotation editor (`E` from Limbo) — minimum viable: arrow, text, blur rectangle. Object model right (per Codex), screw toolbar polish.
- Three destination predictors: `clipboard`, `~/Projects/<git-root>/screenshots/`, `obsidian://`
- Auto-route if confidence > 0.85 AND second < 0.4; toast with `⌘Z` redirect
- Window capture + fullscreen capture (same engine, different content filter)
- Hotkey config from `~/.gcap/keymap.toml`
- CLI: `grab last`, `grab last --ocr`, `grab list`

**End of weekend 2**: ~80% of daily CleanShot use replaced.

### Deliberately Deferred
| Feature | Why later |
|---|---|
| Screen recording | Big surface area; ScreenCaptureKit + AVAssetWriter is a week of polish |
| GIF export | Trivially derivable from .mov later |
| Scrolling capture | Only worth it for known-good surfaces (Safari + PDF first) |
| Ghost overlay / trace mode | Build as separate `grab ghost <file>` once spine is solid |
| LLM-driven annotation | Wait for the editor to feel mechanical, then replace toolbar |
| iCloud / git sync | Free whenever you want it (the package format makes it trivial) |
| System audio + mic recording | macOS 14 floor + clock drift = real engineering work; v0.4+ |

**The one ambitious thing in v0.1**: the AX context snapshot. Don't ship without it.

---

## The Limbo + 24-Hour Fuse UX

Floating pill in top-right (AppKit panel, not notification, not window). Shows last 1–3 captures with countdown rings.

**Promotion gestures** (reset/extend the fuse):
- Drag thumbnail → sends to destination, `expires_at = +30 days` (purpose served)
- `P` → pin permanently (no fuse)
- `T` then type → tag, extends to 30 days
- Annotate at all → extends to 7 days (weak importance signal)
- `Esc` → kill immediately

**Annotation friction is intentional**: `E` opens a separate editor window. Honors Claude's paradox: annotation should be slightly harder than recapturing.

**Search behavior** (`Cmd+Shift+G`):
- OCR text + AX context (frontmost app, file path, URL) + tags + time
- Active fuse status sorts first — recent unpromoted captures bubble up because they're being held in working memory

**Witness Capture** (`Cmd+Shift+W`):
- Bypasses Limbo entirely
- Cryptographic hash + timestamp in `manifest.json`
- Lives in `~/.gcap/witnesses/` (separate library, never in pinboard)
- Receipts, not communications

---

## Router Architecture

Capture as a function: `(pixels, context) → destination`. Almost always one of 5–7 places.

### Destinations (your taxonomy)
| Name | Trigger pattern |
|---|---|
| `clipboard` | default for fast iteration |
| `obsidian://daily` | `frontmost ∈ {Obsidian, Notes}` |
| `slack://channel` | `frontmost = Slack` and a channel is open |
| `~/Projects/<repo>/screenshots/` | `frontmost = Xcode/VS Code` and AX has fileURL → resolve git root |
| `linear://issue/<id>` | clipboard contains a Linear URL |
| `local-share-link` | one-time SwiftNIO link for "show this to one person" |

### Engine
```swift
protocol DestinationPredictor {
    func score(capture: Capture, context: CaptureContext) -> Double
    func deliver(capture: Capture) async throws
}

actor Router {
    let predictors: [DestinationPredictor]
    func route(_ capture: Capture) async -> Destination {
        let ranked = predictors.map { ($0, $0.score(capture, context)) }
                               .sorted { $0.1 > $1.1 }
        // Auto-deliver if top > 0.85 AND second < 0.4
        // Otherwise show 3-option chooser in Limbo HUD
    }
}
```

### The Undo Affordance Is the Whole UX
After auto-route, a 3-second non-blocking toast: "→ Slack #design-review · `⌘Z` to redirect". `⌘Z` opens the chooser. This is the demo moment.

### Config
No GUI. `~/.gcap/keymap.toml`:
```toml
[capture]
region   = "cmd+shift+2"
window   = "cmd+shift+3"
fullscreen = "cmd+shift+4"
witness  = "cmd+shift+w"
record   = "cmd+shift+5"

[limbo]
edit     = "e"
pin      = "p"
tag      = "t"
delete   = "esc"
redirect = "cmd+z"
```

---

## Strongest Ideas Worth Stealing from Each Provider

### From 🟡 Gemini
- **Ghost overlay (trace mode)** — pin a 20% opacity Figma frame over your IDE for pixel-perfect alignment
- **Code-to-capture Exif linking** — when Xcode is frontmost, embed file:line in PNG metadata
- **CLI as first-class** — `grab --last --ocr | pbcopy` makes capture composable with shell scripts and local LLMs
- **Self-destructing local share link** — SwiftNIO server, view-once + autodestruct, no cloud

### From 🔵 Claude
- **Router not editor** — entire product reframe
- **24-hour fuse default** — invert the save/delete asymmetry
- **Witness Capture** as a distinct mode with crypto timestamps

### From 🔴 Codex
- **Package-format capture** with re-editable annotations from immutable source
- **AX tree snapshot at capture time** as the structured-metadata foundation
- **macOS 14 floor compatibility plan** — knowing what to re-implement vs wait for 15

---

## Open Questions for Future Sessions

- Pressure-test the router prediction confidence thresholds — what % of routes will require manual correction in week 1?
- Does the `.gcap` package format play nicely with Spotlight indexing? (Test before committing.)
- What's the right SwiftUI/AppKit boundary for the annotation editor specifically? (Overlay-style canvas in AppKit, controls in SwiftUI?)
- AX tree extraction performance — is it fast enough to do synchronously at capture time, or does it need to be async?
- The "what will I hate about this app in 6 months" brainstorm — failure modes, second-system effect risks, when does this calcify into yet-another-tool

---

*Generated via `/octo:brainstorm` (Team mode) — Codex GPT-5.4 + Gemini + Claude Opus 4.7*
