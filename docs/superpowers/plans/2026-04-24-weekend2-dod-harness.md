# Weekend 2 DoD Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the single observable Weekend 2 acceptance test from SPEC §2 as `Core/Tests/CoreTests/DoD/WeekendTwoDoDTests.swift`, asserting (a) across 10 synthetic telemetry events ≤ 2 have `predicted ≠ chosen` and ≤ 2 are chooser-appearances; (b) Annotations with one each of `Arrow`, `Text`, `BlurRect` re-render byte-identically on the same backend, and stay within SSIM ≥ 0.995 across the two renderer backends that simulate macOS patchlevel drift. When this suite passes, Shotfuse v0.1 ships.

**Architecture:** Two independent test axes. (1) **Router ratios** — write 10 synthetic `RouterTelemetryLine` rows directly into a temp `telemetry.jsonl`, parse them back, and compute the two ratios. We deliberately bypass `RouterScoringModel` because the DoD is a measurement contract, not a scoring-model smoke test; the Router's unit tests already prove the decision rule. (2) **Annotations fidelity** — build an `AnnotationsDocument` containing an Arrow + Text + BlurRect, call `renderAnnotations(..., backend: .coreGraphics)` twice, compare PNG bytes; then render once on each backend and compute SSIM with the existing `simpleSSIM` helper lifted to a shared test-helper file. A mirror of the Weekend 1 harness pattern (`Core/Tests/CoreTests/DoD/WeekendOneDoDTests.swift`).

**Tech Stack:** Swift Testing, `CoreGraphics`, `AppKit.NSBitmapImageRep`, `JSONSerialization`, reusing `TelemetryValidator` from the sibling plan `2026-04-24-observability-redaction-audit.md`.

---

## Context — Weekend 2 DoD (SPEC §2 verbatim)

> Across 10 consecutive real-work captures, as measured by `~/.shotfuse/telemetry.jsonl`: **(a)** ≤ 2 events where `predicted ≠ chosen` (user invoked `Cmd+Z` redirect), AND **(b)** ≤ 2 events where the chooser appeared instead of auto-delivery (i.e. `top_score ≤ 0.85` or `second_score ≥ 0.4`). Predicted destinations are exactly: `clipboard`, `~/Projects/<git-root>/screenshots/`, `obsidian://daily`. Annotations (arrow, text, blur rectangle) round-trip through `annotations.json` and re-render **byte-identically on the same machine at the same macOS minor version; SSIM ≥ 0.995 across supported macOS 26.x patchlevels** from `master.png` on re-export.

## Dependencies between plans

This plan **depends on** `docs/superpowers/plans/2026-04-24-observability-redaction-audit.md` being executed first. It uses `TelemetryValidator` to parse and validate the shape of each synthetic line before asserting the DoD ratios. If you are executing plans out of order, run the observability plan first.

## Existing precedent to mirror

- `Core/Tests/CoreTests/DoD/WeekendOneDoDTests.swift` — 434-line harness, `@Suite("Weekend 1 DoD")` pattern, private `DoDFixtures` + `DoDEnv` helpers at the bottom of the file. Weekend 2 adopts the **same structural pattern** (single `@Suite` per weekend, private helpers at file bottom) so future readers can diff the two.
- `Core/Tests/CoreTests/AnnotationsTests.swift:96-118` — byte-identical + SSIM assertions at the unit level. Uses private `makeFixtureMaster`, `makeFixtureAnnotations`, and `simpleSSIM`. The DoD harness will reuse `simpleSSIM` via a small extract (Task 1) and construct its own three-element fixture.
- `Core/Sources/Core/Annotations/AnnotationRenderer.swift:60` — public `renderAnnotations(master:, annotations:, pointToPixelScale:, backend:)` with two backends (`.coreGraphics`, `.bitmapImageRep`) that exist specifically to enable this SSIM test (see the file header comment in that file).

---

## File Structure

- **Create** `Core/Tests/CoreTests/Support/TestSSIM.swift` — internal helper extracted from `AnnotationsTests.swift`. One public function `testSSIM(pngA: Data, pngB: Data) throws -> Double`. Reason: DRY. Both `AnnotationsTests` and `WeekendTwoDoDTests` need SSIM; keeping two copies of a subtle numerical algorithm invites drift.
- **Modify** `Core/Tests/CoreTests/AnnotationsTests.swift` — delete the private `simpleSSIM` implementation; call `testSSIM(...)` instead. Keep the existing `TestError.decode` local (it's used by the helper call-sites).
- **Create** `Core/Tests/CoreTests/DoD/WeekendTwoDoDTests.swift` — the harness. Self-contained; private fixture helpers live at the bottom of the file (same pattern as Weekend 1).

No production code is created or modified by this plan. All production dependencies (`Router`, `AnnotationsDocument`, `renderAnnotations`, `TelemetryValidator`) already exist.

---

### Task 1: Extract `simpleSSIM` to a shared test helper

**Files:**
- Create: `Core/Tests/CoreTests/Support/TestSSIM.swift`
- Modify: `Core/Tests/CoreTests/AnnotationsTests.swift` — delete `simpleSSIM` body at lines 289-316 (approximate; confirm with `grep -n "simpleSSIM" Core/Tests/CoreTests/AnnotationsTests.swift`), add `import` line (none needed; same module), rename the call site at line 116 from `simpleSSIM(pngA:` to `testSSIM(pngA:`.

- [ ] **Step 1: Find the current `simpleSSIM` line range**

Run:

```bash
grep -n "simpleSSIM\|TestError.decode" Core/Tests/CoreTests/AnnotationsTests.swift
```

Expected output includes the call site near line 116, the `private func simpleSSIM(...)` declaration near line 294, and a range extending to approximately line 316. Note the exact range; you will cut it out in Step 3.

- [ ] **Step 2: Create the shared helper file**

Create `Core/Tests/CoreTests/Support/TestSSIM.swift` with the exact body below. The implementation is a copy of the existing `simpleSSIM` with the signature widened (`internal`, no longer private to a test struct) and a generic error type that does not depend on `AnnotationsTests.TestError`.

```swift
import AppKit
import CoreGraphics
import Foundation

/// Test-only SSIM helper. Mean SSIM across 8×8 non-overlapping blocks on the
/// luma channel. Smaller than the canonical 11×11 Gaussian-windowed SSIM but
/// sufficient for the Weekend 2 DoD contract "SSIM ≥ 0.995 across simulated
/// patchlevels" — the test is about gross pixel drift, not perceptual nuance.
///
/// Returns a value in `[0, 1]`. Throws if either PNG cannot be decoded or if
/// the two images differ in pixel dimensions.
///
/// - Parameters:
///   - pngA: PNG-encoded bytes (first image).
///   - pngB: PNG-encoded bytes (second image).
/// - Returns: Mean block SSIM across the luma channel.
enum TestSSIMError: Error, Equatable {
    case decodeFailed(name: String)
    case dimensionsMismatch(widthA: Int, heightA: Int, widthB: Int, heightB: Int)
}

func testSSIM(pngA: Data, pngB: Data) throws -> Double {
    guard let repA = NSBitmapImageRep(data: pngA),
          let imgA = repA.cgImage
    else { throw TestSSIMError.decodeFailed(name: "pngA") }
    guard let repB = NSBitmapImageRep(data: pngB),
          let imgB = repB.cgImage
    else { throw TestSSIMError.decodeFailed(name: "pngB") }

    let width = imgA.width
    let height = imgA.height
    guard imgB.width == width, imgB.height == height else {
        throw TestSSIMError.dimensionsMismatch(
            widthA: width, heightA: height, widthB: imgB.width, heightB: imgB.height
        )
    }

    let a = try lumaBuffer(from: imgA, width: width, height: height)
    let b = try lumaBuffer(from: imgB, width: width, height: height)

    let blockSize = 8
    let k1 = 0.01
    let k2 = 0.03
    let L = 255.0
    let c1 = (k1 * L) * (k1 * L)
    let c2 = (k2 * L) * (k2 * L)

    var total = 0.0
    var blocks = 0

    var y = 0
    while y + blockSize <= height {
        var x = 0
        while x + blockSize <= width {
            var sumA = 0.0, sumB = 0.0
            for by in 0..<blockSize {
                for bx in 0..<blockSize {
                    let idx = (y + by) * width + (x + bx)
                    sumA += Double(a[idx])
                    sumB += Double(b[idx])
                }
            }
            let n = Double(blockSize * blockSize)
            let muA = sumA / n
            let muB = sumB / n

            var varA = 0.0, varB = 0.0, covAB = 0.0
            for by in 0..<blockSize {
                for bx in 0..<blockSize {
                    let idx = (y + by) * width + (x + bx)
                    let da = Double(a[idx]) - muA
                    let db = Double(b[idx]) - muB
                    varA += da * da
                    varB += db * db
                    covAB += da * db
                }
            }
            varA /= n
            varB /= n
            covAB /= n

            let numerator = (2 * muA * muB + c1) * (2 * covAB + c2)
            let denominator = (muA * muA + muB * muB + c1) * (varA + varB + c2)
            total += numerator / denominator
            blocks += 1
            x += blockSize
        }
        y += blockSize
    }

    return blocks == 0 ? 0.0 : total / Double(blocks)
}

private func lumaBuffer(from image: CGImage, width: Int, height: Int) throws -> [UInt8] {
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: &rgba,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw TestSSIMError.decodeFailed(name: "luma-context") }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var luma = [UInt8](repeating: 0, count: width * height)
    for i in 0..<(width * height) {
        let r = Double(rgba[i * 4 + 0])
        let g = Double(rgba[i * 4 + 1])
        let b = Double(rgba[i * 4 + 2])
        // Rec. 601 luma coefficients.
        let y = 0.299 * r + 0.587 * g + 0.114 * b
        luma[i] = UInt8(max(0.0, min(255.0, y)))
    }
    return luma
}
```

- [ ] **Step 3: Replace the call site in `AnnotationsTests.swift`**

In `Core/Tests/CoreTests/AnnotationsTests.swift`, find the call near line 116:

```swift
let ssim = try simpleSSIM(pngA: pngA, pngB: pngB)
```

Change it to:

```swift
let ssim = try testSSIM(pngA: pngA, pngB: pngB)
```

Then delete the entire `private func simpleSSIM(...)` function and its associated `private func lumaBuffer(...)` if present. Use the line range you noted in Step 1. After deletion, the file should no longer contain any reference to `simpleSSIM`.

- [ ] **Step 4: Verify the affected tests still pass**

Run:

```bash
xcodebuild test \
  -workspace Shotfuse.xcworkspace \
  -scheme Core \
  -destination 'platform=macOS' \
  -only-testing:CoreTests/AnnotationsTests \
  2>&1 | tail -15
```

Expected: `** TEST SUCCEEDED **` with all 5 existing `AnnotationsTests` cases green — the SSIM test must still return ≥ 0.995.

- [ ] **Step 5: Commit**

```bash
git add Core/Tests/CoreTests/Support/TestSSIM.swift Core/Tests/CoreTests/AnnotationsTests.swift
git commit -m "refactor(tests): lift simpleSSIM to shared TestSSIM helper"
```

---

### Task 2: Scaffold `WeekendTwoDoDTests.swift` with empty suite and synthetic-telemetry fixture

**Files:**
- Create: `Core/Tests/CoreTests/DoD/WeekendTwoDoDTests.swift`

- [ ] **Step 1: Create the file with suite header, imports, and the telemetry fixture writer**

Create `Core/Tests/CoreTests/DoD/WeekendTwoDoDTests.swift`:

```swift
import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Core

// SPEC §2 Weekend 2 DoD — observable test for the Personality milestone.
//
// > Across 10 consecutive real-work captures, as measured by
// > ~/.shotfuse/telemetry.jsonl: (a) ≤ 2 events where predicted ≠ chosen,
// > AND (b) ≤ 2 events where the chooser appeared instead of auto-delivery
// > (top_score ≤ 0.85 OR second_score ≥ 0.4). Predicted destinations are
// > exactly: clipboard, project_screenshots, obsidian_daily. Annotations
// > (arrow, text, blur rectangle) round-trip byte-identically on the same
// > machine at the same macOS minor version; SSIM ≥ 0.995 across supported
// > macOS 26.x patchlevels from master.png on re-export.
//
// This harness emits 10 synthetic telemetry lines (bypassing the scoring
// model — unit coverage for the scoring rule lives in RouterTests) and
// parses them back through TelemetryValidator to prove the shape holds.
// The annotations axis constructs a three-element fixture document and
// drives it through renderAnnotations on both backends.

@Suite("Weekend 2 DoD")
struct WeekendTwoDoDTests {

    // MARK: - (a) Router telemetry ratios — filled in Task 3 / Task 4 / Task 5

    // MARK: - (b) Annotations fidelity — filled in Task 6 / Task 7
}

// MARK: - Fixture helpers (Router telemetry)

/// Builds a synthetic 10-line `telemetry.jsonl` modelling the Weekend 2 DoD
/// happy path: 6 clean auto-deliveries, 2 chooser-appearances (both with
/// predicted == chosen — user picked the top option the Router would have
/// picked anyway), and 2 overrides where `predicted != chosen`. The bounds
/// ≤ 2 chooser and ≤ 2 override are hit exactly, not stressed.
private enum DoDTwoTelemetryFixtures {

    struct SyntheticLine {
        let id: String
        let ts: String
        let predicted: String
        let chosen: String
        let topScore: Double
        let secondScore: Double
    }

    /// Returns 10 lines in a known distribution:
    /// - 6 lines: auto-deliver, predicted == chosen, top > 0.85, second < 0.4
    /// - 2 lines: chooser appeared (top ≤ 0.85), predicted == chosen
    /// - 2 lines: auto-deliver predicted, but user Cmd+Z overrode → predicted != chosen
    static func makeTenLines() -> [SyntheticLine] {
        let base = "018fbf4c-1a2b-7a3c-9b4d"
        let ts = "2026-04-24T13:00:00.000Z"

        var lines: [SyntheticLine] = []

        // 6× clean auto-deliver, project_screenshots
        for i in 0..<6 {
            lines.append(SyntheticLine(
                id: "\(base)-0000000000\(i)1",
                ts: ts,
                predicted: "project_screenshots",
                chosen: "project_screenshots",
                topScore: 0.92,
                secondScore: 0.18
            ))
        }

        // 2× chooser appeared (top ≤ 0.85), user still picked top
        for i in 0..<2 {
            lines.append(SyntheticLine(
                id: "\(base)-0000000000a\(i)",
                ts: ts,
                predicted: "obsidian_daily",
                chosen: "obsidian_daily",
                topScore: 0.70,
                secondScore: 0.35
            ))
        }

        // 2× auto-deliver predicted, user overrode via Cmd+Z
        for i in 0..<2 {
            lines.append(SyntheticLine(
                id: "\(base)-0000000000b\(i)",
                ts: ts,
                predicted: "project_screenshots",
                chosen: "clipboard",
                topScore: 0.91,
                secondScore: 0.20
            ))
        }

        return lines
    }

    /// Writes lines to a fresh `telemetry.jsonl` under a temp directory and
    /// returns the file URL. Caller owns cleanup via `tearDown(url:)`.
    static func writeTelemetry(lines: [SyntheticLine]) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dod-w2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = tmp.appendingPathComponent("telemetry.jsonl")

        var contents = ""
        for line in lines {
            let dict: [String: Any] = [
                "id": line.id,
                "ts": line.ts,
                "predicted": line.predicted,
                "chosen": line.chosen,
                "top_score": line.topScore,
                "second_score": line.secondScore,
            ]
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
            contents.append(String(data: data, encoding: .utf8)!)
            contents.append("\n")
        }
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func tearDown(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Parses every line of the file through TelemetryValidator and returns
    /// the decoded dictionaries. Throws if any line fails validation.
    static func readAndValidate(_ url: URL) throws -> [[String: Any]] {
        let raw = try String(contentsOf: url, encoding: .utf8)
        var out: [[String: Any]] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let data = Data(line.utf8)
            switch TelemetryValidator.validate(jsonLine: data) {
            case .success:
                let dict = try JSONSerialization.jsonObject(with: data, options: []) as! [String: Any]
                out.append(dict)
            case .failure(let err):
                throw err
            }
        }
        return out
    }
}
```

- [ ] **Step 2: Verify the scaffold compiles (suite is empty but must build)**

Run:

```bash
xcodebuild build \
  -workspace Shotfuse.xcworkspace \
  -scheme Core \
  -destination 'platform=macOS' \
  2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`. The empty suite is valid per Swift Testing — it compiles and produces no test cases.

- [ ] **Step 3: Commit**

```bash
git add Core/Tests/CoreTests/DoD/WeekendTwoDoDTests.swift
git commit -m "test(dod): scaffold Weekend 2 DoD harness with telemetry fixtures"
```

---

### Task 3: Implement Test A — `predicted ≠ chosen` ≤ 2 across 10 lines

**Files:**
- Modify: `Core/Tests/CoreTests/DoD/WeekendTwoDoDTests.swift`

- [ ] **Step 1: Add the failing test inside the suite**

Inside the `WeekendTwoDoDTests` struct, under the `// MARK: - (a) Router telemetry ratios` marker, add:

```swift
    @Test("10-capture telemetry: at most 2 events have predicted ≠ chosen (§2 DoD subtest a)")
    func telemetryPredictedMismatchIsAtMostTwo() throws {
        let lines = DoDTwoTelemetryFixtures.makeTenLines()
        let url = try DoDTwoTelemetryFixtures.writeTelemetry(lines: lines)
        defer { DoDTwoTelemetryFixtures.tearDown(url) }

        let parsed = try DoDTwoTelemetryFixtures.readAndValidate(url)
        #expect(parsed.count == 10, "fixture did not produce exactly 10 validated lines")

        let mismatches = parsed.filter { dict in
            (dict["predicted"] as? String) != (dict["chosen"] as? String)
        }
        #expect(mismatches.count <= 2,
                "SPEC §2 Weekend 2 DoD violated: \(mismatches.count) events with predicted ≠ chosen (max 2)")
    }
```

- [ ] **Step 2: Run the test**

Run:

```bash
xcodebuild test \
  -workspace Shotfuse.xcworkspace \
  -scheme Core \
  -destination 'platform=macOS' \
  -only-testing:CoreTests/WeekendTwoDoDTests/telemetryPredictedMismatchIsAtMostTwo \
  2>&1 | tail -15
```

Expected: `** TEST SUCCEEDED **`. The fixture has 2 mismatches by construction, which equals the ceiling.

- [ ] **Step 3: Commit**

```bash
git add Core/Tests/CoreTests/DoD/WeekendTwoDoDTests.swift
git commit -m "test(dod): assert W2 DoD predicted≠chosen ≤ 2 across 10 captures"
```

---

### Task 4: Implement Test B — chooser appearances ≤ 2

**Files:**
- Modify: `Core/Tests/CoreTests/DoD/WeekendTwoDoDTests.swift`

- [ ] **Step 1: Add the test inside the suite**

Under the same `// MARK: - (a)` section, immediately after Task 3's test, add:

```swift
    @Test("10-capture telemetry: at most 2 events are chooser-appearances (§2 DoD subtest b)")
    func telemetryChooserAppearancesIsAtMostTwo() throws {
        let lines = DoDTwoTelemetryFixtures.makeTenLines()
        let url = try DoDTwoTelemetryFixtures.writeTelemetry(lines: lines)
        defer { DoDTwoTelemetryFixtures.tearDown(url) }

        let parsed = try DoDTwoTelemetryFixtures.readAndValidate(url)
        #expect(parsed.count == 10, "fixture did not produce exactly 10 validated lines")

        // A chooser-appearance per SPEC §7.1 is: top_score ≤ 0.85 OR second_score ≥ 0.4
        let choosers = parsed.filter { dict in
            let top = dict["top_score"] as? Double ?? 1.0
            let second = dict["second_score"] as? Double ?? 0.0
            return top <= 0.85 || second >= 0.4
        }
        #expect(choosers.count <= 2,
                "SPEC §2 Weekend 2 DoD violated: \(choosers.count) chooser-appearances (max 2)")
    }
```

- [ ] **Step 2: Run both (a) tests together**

Run:

```bash
xcodebuild test \
  -workspace Shotfuse.xcworkspace \
  -scheme Core \
  -destination 'platform=macOS' \
  -only-testing:CoreTests/WeekendTwoDoDTests \
  2>&1 | tail -15
```

Expected: `** TEST SUCCEEDED **` with 2 cases passing.

- [ ] **Step 3: Commit**

```bash
git add Core/Tests/CoreTests/DoD/WeekendTwoDoDTests.swift
git commit -m "test(dod): assert W2 DoD chooser-appearances ≤ 2 across 10 captures"
```

---

### Task 5: Implement Test C — destination taxonomy is exactly the three slugs

**Files:**
- Modify: `Core/Tests/CoreTests/DoD/WeekendTwoDoDTests.swift`

SPEC §2 states: *"Predicted destinations are exactly: `clipboard`, `~/Projects/<git-root>/screenshots/`, `obsidian://daily`."* `TelemetryValidator.validate` already rejects any slug outside `{clipboard, project_screenshots, obsidian_daily}`, so this test is essentially asserting that the fixture + validator loop is airtight. We still assert explicitly so the DoD harness documents the taxonomy requirement in-place.

- [ ] **Step 1: Add the test inside the suite**

Under `// MARK: - (a) Router telemetry ratios`, after Task 4's test:

```swift
    @Test("10-capture telemetry: all predicted/chosen slugs are in the locked v0.1 taxonomy (§2 DoD)")
    func telemetrySlugsMatchTaxonomy() throws {
        let lines = DoDTwoTelemetryFixtures.makeTenLines()
        let url = try DoDTwoTelemetryFixtures.writeTelemetry(lines: lines)
        defer { DoDTwoTelemetryFixtures.tearDown(url) }

        let parsed = try DoDTwoTelemetryFixtures.readAndValidate(url)

        let allowed = TelemetryValidator.validDestinationSlugs
        for dict in parsed {
            let predicted = dict["predicted"] as? String ?? ""
            let chosen = dict["chosen"] as? String ?? ""
            #expect(allowed.contains(predicted), "unknown predicted slug: \(predicted)")
            #expect(allowed.contains(chosen), "unknown chosen slug: \(chosen)")
        }
    }
```

- [ ] **Step 2: Run the test**

Run:

```bash
xcodebuild test \
  -workspace Shotfuse.xcworkspace \
  -scheme Core \
  -destination 'platform=macOS' \
  -only-testing:CoreTests/WeekendTwoDoDTests/telemetrySlugsMatchTaxonomy \
  2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Core/Tests/CoreTests/DoD/WeekendTwoDoDTests.swift
git commit -m "test(dod): assert W2 DoD destination taxonomy is exactly three slugs"
```

---

### Task 6: Implement Test D — annotations byte-identical re-render

**Files:**
- Modify: `Core/Tests/CoreTests/DoD/WeekendTwoDoDTests.swift`

The DoD requires a fixture containing **one each** of arrow, text, and blur rectangle. We construct it in `DoDTwoAnnotationsFixtures` and render twice on `.coreGraphics` — the same-backend path that represents "same machine, same minor version".

- [ ] **Step 1: Add the annotations fixture helper at the bottom of the file**

At the end of `Core/Tests/CoreTests/DoD/WeekendTwoDoDTests.swift`, append:

```swift
// MARK: - Fixture helpers (Annotations)

private enum DoDTwoAnnotationsFixtures {

    /// 400×300 mid-grey master image. Large enough that arrow + text + blur
    /// all land on pixels; small enough that two renders finish in well
    /// under a second each.
    static func makeMaster() throws -> CGImage {
        let width = 400
        let height = 300
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0x80, count: bytesPerRow * height)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = pixels.withUnsafeMutableBufferPointer { buf -> CGContext in
            CGContext(
                data: buf.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
        }
        guard let image = ctx.makeImage() else {
            throw TestSSIMError.decodeFailed(name: "dod-w2-master")
        }
        return image
    }

    /// A document with exactly the three SPEC §6.4-required element types:
    /// one Arrow, one Text, one BlurRect. Values use the published defaults
    /// (red arrow at #FF3B30 4pt, body-style font, blur sigma 12pt).
    static func makeDocument() -> AnnotationsDocument {
        let red = Annotation.Color(red: 0xFF, green: 0x3B, blue: 0x30)
        let arrow = Annotation.arrow(.init(
            from: .init(x: 40, y: 40),
            to: .init(x: 200, y: 120),
            color: red,
            widthPoints: 4.0
        ))
        let text = Annotation.text(.init(
            origin: .init(x: 60, y: 200),
            string: "DoD-W2",
            font: .init(style: .body, size: 17),
            color: red
        ))
        let blur = Annotation.blurRect(.init(
            rect: .init(x: 240, y: 40, width: 120, height: 60),
            sigmaPoints: 12.0
        ))
        return AnnotationsDocument(items: [arrow, text, blur])
    }
}
```

(Note: the constructor calls above use whatever `Annotation.Arrow/Text/BlurRect` init signatures exist in `Core/Sources/Core/Annotations/AnnotationModel.swift`. Confirm the argument names match by running `grep -n "public init" Core/Sources/Core/Annotations/AnnotationModel.swift` — if any label differs, adjust this fixture code to match the production types. Do not alter the production types to fit this fixture.)

- [ ] **Step 2: Add the byte-identical test**

Under `// MARK: - (b) Annotations fidelity` inside the suite, add:

```swift
    @Test("Annotations re-render is byte-identical on the same backend (§2 DoD — same minor)")
    func annotationsByteIdenticalSameBackend() throws {
        let master = try DoDTwoAnnotationsFixtures.makeMaster()
        let doc = DoDTwoAnnotationsFixtures.makeDocument()

        let first = try renderAnnotations(
            master: master,
            annotations: doc,
            pointToPixelScale: 2.0,
            backend: .coreGraphics
        )
        let second = try renderAnnotations(
            master: master,
            annotations: doc,
            pointToPixelScale: 2.0,
            backend: .coreGraphics
        )
        #expect(first == second,
                "Two same-backend renders of the W2 DoD fixture produced different PNG bytes (\(first.count) vs \(second.count))")
    }
```

- [ ] **Step 3: Run the test**

Run:

```bash
xcodebuild test \
  -workspace Shotfuse.xcworkspace \
  -scheme Core \
  -destination 'platform=macOS' \
  -only-testing:CoreTests/WeekendTwoDoDTests/annotationsByteIdenticalSameBackend \
  2>&1 | tail -15
```

Expected: `** TEST SUCCEEDED **`.

If the build fails with a "missing argument label" error in `DoDTwoAnnotationsFixtures.makeDocument()`, open `Core/Sources/Core/Annotations/AnnotationModel.swift`, find the `Arrow`, `Text`, and `BlurRect` public inits, and adjust the fixture to match. The exact labels are not fixed by this plan — they are whatever ship in production.

- [ ] **Step 4: Commit**

```bash
git add Core/Tests/CoreTests/DoD/WeekendTwoDoDTests.swift
git commit -m "test(dod): assert W2 DoD annotations byte-identical same-backend"
```

---

### Task 7: Implement Test E — annotations SSIM ≥ 0.995 across backends

**Files:**
- Modify: `Core/Tests/CoreTests/DoD/WeekendTwoDoDTests.swift`

- [ ] **Step 1: Add the SSIM test**

Under `// MARK: - (b) Annotations fidelity`, directly after Task 6's test:

```swift
    @Test("Annotations SSIM ≥ 0.995 across CoreGraphics vs NSBitmapImageRep backends (§2 DoD — patchlevel drift)")
    func annotationsSSIMAcrossBackendsAboveThreshold() throws {
        let master = try DoDTwoAnnotationsFixtures.makeMaster()
        let doc = DoDTwoAnnotationsFixtures.makeDocument()

        let pngCG = try renderAnnotations(
            master: master,
            annotations: doc,
            pointToPixelScale: 2.0,
            backend: .coreGraphics
        )
        let pngBitmap = try renderAnnotations(
            master: master,
            annotations: doc,
            pointToPixelScale: 2.0,
            backend: .bitmapImageRep
        )

        let ssim = try testSSIM(pngA: pngCG, pngB: pngBitmap)
        #expect(ssim >= 0.995,
                "SPEC §2 Weekend 2 DoD violated: cross-backend SSIM \(ssim) < 0.995 (simulated patchlevel drift too large)")
    }
```

- [ ] **Step 2: Run the full Weekend 2 DoD suite**

Run:

```bash
xcodebuild test \
  -workspace Shotfuse.xcworkspace \
  -scheme Core \
  -destination 'platform=macOS' \
  -only-testing:CoreTests/WeekendTwoDoDTests \
  2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **` with 5 tests passing (3 telemetry + 2 annotations).

- [ ] **Step 3: Run the full test suite to confirm no regressions**

Run:

```bash
xcodebuild test \
  -workspace Shotfuse.xcworkspace \
  -scheme Core \
  -destination 'platform=macOS' \
  2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`. Every suite (Weekend 1, Weekend 2, Router, Annotations, Observability, Capture*, Library, Fuse, etc.) must be green.

- [ ] **Step 4: Commit**

```bash
git add Core/Tests/CoreTests/DoD/WeekendTwoDoDTests.swift
git commit -m "test(dod): assert W2 DoD annotations SSIM ≥ 0.995 across backends"
```

---

### Task 8: Close hq-ap9 and hq-ni3

**Files:**
- None

- [ ] **Step 1: Close hq-ap9 (DoD harness)**

Run:

```bash
bd close hq-ap9 --notes "Closed during beads → superpowers-plans migration on 2026-04-24. Harness shipped at Core/Tests/CoreTests/DoD/WeekendTwoDoDTests.swift. See docs/superpowers/plans/2026-04-24-weekend2-dod-harness.md."
```

- [ ] **Step 2: Close hq-ni3 (Weekend 2 milestone marker)**

Run:

```bash
bd close hq-ni3 --notes "Closed during beads → superpowers-plans migration on 2026-04-24. Weekend 2 DoD harness passes — observable contract from SPEC §2 is met. See docs/superpowers/plans/2026-04-24-weekend2-dod-harness.md."
```

Expected: `bd list --status=open` shows neither item.

---

## Self-Review

**1. Spec coverage.**

| SPEC §2 Weekend 2 DoD clause | Task |
|---|---|
| "Across 10 consecutive… captures" | Task 2 fixture (`makeTenLines`) |
| "as measured by ~/.shotfuse/telemetry.jsonl" | Task 2 (`writeTelemetry`) — synthetic file |
| "≤ 2 events where predicted ≠ chosen" | Task 3 |
| "≤ 2 events where the chooser appeared (top ≤ 0.85 OR second ≥ 0.4)" | Task 4 |
| "Predicted destinations are exactly {clipboard, project_screenshots, obsidian_daily}" | Task 5 (+ `TelemetryValidator.validDestinationSlugs`) |
| "Annotations (arrow, text, blur rectangle)" | Task 6 fixture `makeDocument()` |
| "round-trip byte-identically on the same machine at the same macOS minor" | Task 6 |
| "SSIM ≥ 0.995 across supported 26.x patchlevels" | Task 7 (two backends as patchlevel proxies) |

**2. Placeholder scan.** Every test has concrete inputs, concrete assertions, concrete expected commands. No TBDs. The one conditional is Task 6 Step 3, which anticipates a labeling mismatch between fixture and production types and explicitly tells the engineer to adjust the fixture — a real planning move, not a placeholder.

**3. Type consistency.**
- `DoDTwoTelemetryFixtures.SyntheticLine` fields match the JSON key names the file emits (`id`, `ts`, `predicted`, `chosen`, `top_score`, `second_score`) ↔ consumed by `TelemetryValidator.validate` keys ↔ filtered by the assertion lambdas in Tasks 3/4/5.
- `DoDTwoAnnotationsFixtures.makeMaster()` returns `CGImage`, matching `renderAnnotations(master:)`'s first parameter in `Core/Sources/Core/Annotations/AnnotationRenderer.swift:60`.
- `DoDTwoAnnotationsFixtures.makeDocument()` returns `AnnotationsDocument`, matching the `annotations:` parameter.
- `testSSIM(pngA:pngB:)` signature in Task 1 matches the call site in Task 7 exactly.
- `TestSSIMError` is used by both the shared helper (`Support/TestSSIM.swift`) and the fixture (`makeMaster` fall-through path) — consistent.
