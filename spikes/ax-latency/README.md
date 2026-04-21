# Spike A — AX tree extraction latency

**Issue:** `hq-91t` · **Spec ref:** SPEC.md §9 Spike A, Invariant 1

## Question
Can the AX tree snapshot for the frontmost app complete in **≤50ms p95** at capture
time? If yes, `CaptureEngine` can enrich `context.json` synchronously during the
`capturing → finalizing` transition. If no, enrichment goes async and the Limbo HUD
must paint without context on first frame.

## What this benchmarks
For each of 5 target apps × 20 iterations (100 samples total), measures wall-clock
(`ContinuousClock`) cost of:

1. `AXUIElementCreateApplication(pid)`
2. `kAXFocusedWindowAttribute` on the app element
3. `kAXTitleAttribute` on the window
4. `kAXURLAttribute` on the window (browsers) → fallback `kAXDocumentAttribute`
5. `kAXFocusedUIElementAttribute` → `kAXURLAttribute` on the focused element

Extracts `{ bundle_id, window_title, file/browser URL }` — the exact fields
`context.json` (§6.2) needs from the AX path.

## Prerequisites

- macOS 26+, on AC power, screen unlocked.
- All 5 target apps installed and **launched at least once and frontmost once**
  before the measurement run (cold AX paths skew p95).
  - Xcode · VS Code · Safari · Slack · Obsidian
- Accessibility permission granted to the running process.
  - `swift run` produces a per-build binary path — easiest is to grant AX to your
    terminal (Terminal.app / iTerm.app / Ghostty) instead.
  - Alternative: `swift build -c release`, then grant AX to the stable binary at
    `$(swift build -c release --show-bin-path)/AXLatency`.

## Run

```bash
cd spikes/ax-latency
swift build -c release
swift run -c release AXLatency
```

Re-run 3× and report the median run's numbers in the issue — cold-start skew.

## Output format

```
Xcode         n= 20  p50=  X.XXms  p95=  X.XXms  p99=  X.XXms  min=...  max=...
              title: <last observed>
              url:   <last observed>
VS Code       n= 20  ...
...
ALL           n=100  p50=...  p95=...  p99=...
DECISION: sync at capture time (p95 X.XXms ≤ 50ms)    # or async if >50ms
```

## Recording the verdict

```bash
# After running, paste the ALL line + decision into the issue:
bd update hq-91t --notes="p50=<X>ms p95=<Y>ms p99=<Z>ms across 5 apps × 20 iters.
Decision: sync|async. Full output: <paste>"
bd close hq-91t --reason="sync path viable (p95 <Y>ms ≤ 50ms)"  # or:
bd close hq-91t --reason="async required (p95 <Y>ms > 50ms); SPEC §5 Invariant 1 gains 'AX enrichment is async' clause"
```

## Notes on measurement hygiene

- `Thread.sleep(0.6s)` between app activations lets the AX tree settle. If p99 has
  a spike on iteration 1 but stabilizes on 2+, that's activation latency — not the
  steady-state capture-time cost we care about.
- This spike measures AX cost **in isolation**. Real capture-time cost may be
  slightly lower (no activation; target app was already frontmost when hotkey
  fired) — so a pass here is conservative.
- Results vary with target window complexity (Xcode with 100 files open vs. empty
  Xcode). Use real-work windows, not fresh launches.
