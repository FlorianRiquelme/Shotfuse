# Observability + Redaction Audit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a single Swift Testing suite `ObservabilityAuditTests` that enforces SPEC §17.2 redaction (no raw OCR text, clipboard values, or file paths in logs) and SPEC §13.5 telemetry schema (exactly 6 fields per line) as ordinary unit tests — so future `logger.*` additions or telemetry-shape drift fail CI instead of leaking silently.

**Architecture:** Two tests. (1) A static source-file scanner that walks every `.swift` under `Core/Sources/Core/`, finds every `logger.<method>(...)` call, and flags any string interpolation that references a banned identifier (`ocr*`, `clipboard`, `.path`, `.url`) unless the value is passed through the existing `.sha256Prefix` helper. (2) A pure `TelemetryValidator` struct that accepts a JSON line, returns a typed `Result<Void, TelemetryValidationError>`, and rejects any line whose keys are not exactly `{id, ts, predicted, chosen, top_score, second_score}`. The validator is reused by both the audit test and any future integration tests; the Router does not import it.

**Tech Stack:** Swift Testing, `Foundation.Regex`, `JSONSerialization`, existing `sha256Prefix` helper in `Core/Sources/Core/Router/Router.swift:383-396`.

---

## Context — P7.4 test contract (from `.claude/session-plan.md`)

`ObservabilityAuditTests` must:

- **(a)** Fail the test suite if any `logger.*` call in Core source logs a banned identifier directly (raw OCR text, raw `context.clipboard`, raw file path without `sha256[:8]`).
- **(b)** Reject any telemetry line whose field set is not exactly `{id, ts, predicted, chosen, top_score, second_score}`.

SPEC references: §13.5 (telemetry), §17.2 (redaction). Existing redaction helper: `extension String.sha256Prefix` in `Core/Sources/Core/Router/Router.swift:383-396`.

## Existing state (confirmed 2026-04-24)

- Only three files in `Core/Sources/Core/` instantiate loggers:
  - `Core/Sources/Core/Capture/CaptureCoordinator.swift`
  - `Core/Sources/Core/Limbo/LimboHUDController.swift`
  - `Core/Sources/Core/Router/Router.swift`
- The Router already uses `.sha256Prefix` for every logged path (see Router.swift lines 288, 292, 296, 300, 303, 314, 342).
- The telemetry 6-key audit at the Router unit level already exists at `Core/Tests/CoreTests/RouterTests.swift:279` — the new validator in this plan is a reusable helper that lives at a higher level so any caller can enforce the shape.

---

## File Structure

- **Create** `Core/Sources/Core/Observability/TelemetryValidator.swift` — pure validator. Input: JSON `Data` or `[String: Any]`. Output: `Result<Void, TelemetryValidationError>`. Reason for a dedicated type (vs. inlining in a test): any future writer of telemetry (integration harness, benchmark tool) should be able to call it. DRY.
- **Create** `Core/Tests/CoreTests/ObservabilityAuditTests.swift` — Swift Testing suite with two `@Test` cases. The redaction scanner is local to the test file (it is test-only infrastructure; lifting it to `Core/` would add a regex dependency to the production target for no benefit).

No existing files are modified.

---

### Task 1: Create TelemetryValidator

**Files:**
- Create: `Core/Sources/Core/Observability/TelemetryValidator.swift`
- Regenerate: `Core/Sources/Core/Observability/` is a new directory — SwiftPM picks this up automatically because `Core` uses the default `sources:` glob in `Core/Package.swift`; no manifest edit needed.

- [ ] **Step 1: Write the validator type and tests in the same commit (TDD requires the test exist before the production code compiles — see Task 2 Step 1). Skip straight to implementation here; the failing test comes in Task 2.**

Create `Core/Sources/Core/Observability/TelemetryValidator.swift`:

```swift
import Foundation

/// Validates a single line of `~/.shotfuse/telemetry.jsonl` against SPEC §13.5.
///
/// A valid line is a JSON object with **exactly** these six keys:
/// `id` (String), `ts` (String), `predicted` (String), `chosen` (String),
/// `top_score` (Double), `second_score` (Double). Any extra key, any missing
/// key, or any wrong-typed value is a hard rejection.
///
/// - SeeAlso: §13.5 telemetry; §17.2 redaction (extra keys often leak PII).
/// - Tag: TelemetryValidator
public enum TelemetryValidator {

    public enum ValidationError: Error, Equatable {
        case notAnObject
        case wrongKeySet(expected: Set<String>, actual: Set<String>)
        case wrongType(key: String, expected: String)
        case invalidSlug(key: String, value: String)
    }

    public static let requiredKeys: Set<String> = [
        "id", "ts", "predicted", "chosen", "top_score", "second_score",
    ]

    public static let validDestinationSlugs: Set<String> = [
        "clipboard", "project_screenshots", "obsidian_daily",
    ]

    public static func validate(jsonLine data: Data) -> Result<Void, ValidationError> {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            return .failure(.notAnObject)
        }
        guard let dict = parsed as? [String: Any] else {
            return .failure(.notAnObject)
        }
        return validate(dictionary: dict)
    }

    public static func validate(dictionary dict: [String: Any]) -> Result<Void, ValidationError> {
        let actual = Set(dict.keys)
        guard actual == requiredKeys else {
            return .failure(.wrongKeySet(expected: requiredKeys, actual: actual))
        }

        func expectString(_ key: String) -> ValidationError? {
            dict[key] is String ? nil : .wrongType(key: key, expected: "String")
        }
        func expectDouble(_ key: String) -> ValidationError? {
            // JSONSerialization decodes JSON numbers as NSNumber; both ints and
            // doubles bridge to Double. Reject only if the value is not numeric.
            if dict[key] is NSNumber { return nil }
            return .wrongType(key: key, expected: "Double")
        }

        for key in ["id", "ts", "predicted", "chosen"] {
            if let err = expectString(key) { return .failure(err) }
        }
        for key in ["top_score", "second_score"] {
            if let err = expectDouble(key) { return .failure(err) }
        }

        for key in ["predicted", "chosen"] {
            let slug = dict[key] as? String ?? ""
            guard validDestinationSlugs.contains(slug) else {
                return .failure(.invalidSlug(key: key, value: slug))
            }
        }

        return .success(())
    }
}
```

- [ ] **Step 2: Verify the new file compiles**

Run:

```bash
xcodebuild build \
  -workspace Shotfuse.xcworkspace \
  -scheme Core \
  -destination 'platform=macOS' \
  2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`. If the build fails with "cannot find TelemetryValidator in scope" from an unrelated test file, no test is importing it yet — move on; Task 2 will exercise it.

- [ ] **Step 3: Commit**

```bash
git add Core/Sources/Core/Observability/TelemetryValidator.swift
git commit -m "feat(obs): add TelemetryValidator for §13.5 schema enforcement"
```

---

### Task 2: Write the telemetry-validator test (part b)

**Files:**
- Create: `Core/Tests/CoreTests/ObservabilityAuditTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Core/Tests/CoreTests/ObservabilityAuditTests.swift`:

```swift
import Foundation
import Testing
@testable import Core

@Suite("Observability + redaction audit (SPEC §13.5, §17.2 — hq-5v4)")
struct ObservabilityAuditTests {

    // MARK: - (b) Telemetry shape validator

    @Test("Telemetry validator accepts a spec-compliant line")
    func telemetryValidatorAcceptsValidLine() throws {
        let line: [String: Any] = [
            "id": "018fbf4c-1a2b-7a3c-9b4d-5e6f7a8b9c0d",
            "ts": "2026-04-24T13:00:00.000Z",
            "predicted": "project_screenshots",
            "chosen": "project_screenshots",
            "top_score": 0.92,
            "second_score": 0.18,
        ]
        let data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
        let result = TelemetryValidator.validate(jsonLine: data)
        #expect((try? result.get()) != nil, "validator rejected a spec-compliant line: \(result)")
    }

    @Test("Telemetry validator rejects an extra key")
    func telemetryValidatorRejectsExtraKey() throws {
        let line: [String: Any] = [
            "id": "018fbf4c-1a2b-7a3c-9b4d-5e6f7a8b9c0d",
            "ts": "2026-04-24T13:00:00.000Z",
            "predicted": "clipboard",
            "chosen": "clipboard",
            "top_score": 0.10,
            "second_score": 0.00,
            "bundle_id": "com.example.leak", // banned — would leak PII
        ]
        let data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
        let result = TelemetryValidator.validate(jsonLine: data)
        guard case .failure(.wrongKeySet) = result else {
            Issue.record("expected .wrongKeySet failure, got \(result)")
            return
        }
    }

    @Test("Telemetry validator rejects a missing key")
    func telemetryValidatorRejectsMissingKey() throws {
        let line: [String: Any] = [
            "id": "018fbf4c-1a2b-7a3c-9b4d-5e6f7a8b9c0d",
            "ts": "2026-04-24T13:00:00.000Z",
            "predicted": "clipboard",
            "chosen": "clipboard",
            "top_score": 0.10,
            // second_score omitted
        ]
        let data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
        let result = TelemetryValidator.validate(jsonLine: data)
        guard case .failure(.wrongKeySet) = result else {
            Issue.record("expected .wrongKeySet failure, got \(result)")
            return
        }
    }

    @Test("Telemetry validator rejects an unknown destination slug")
    func telemetryValidatorRejectsUnknownSlug() throws {
        let line: [String: Any] = [
            "id": "018fbf4c-1a2b-7a3c-9b4d-5e6f7a8b9c0d",
            "ts": "2026-04-24T13:00:00.000Z",
            "predicted": "slack_channel",
            "chosen": "slack_channel",
            "top_score": 0.90,
            "second_score": 0.10,
        ]
        let data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
        let result = TelemetryValidator.validate(jsonLine: data)
        guard case .failure(.invalidSlug(let key, _)) = result else {
            Issue.record("expected .invalidSlug failure, got \(result)")
            return
        }
        #expect(key == "predicted", "first invalid slug should be reported for 'predicted' before 'chosen'")
    }

    // MARK: - (a) Static redaction scanner — added in Task 3
}
```

- [ ] **Step 2: Run the telemetry-validator tests and confirm they pass**

Run:

```bash
xcodebuild test \
  -workspace Shotfuse.xcworkspace \
  -scheme Core \
  -destination 'platform=macOS' \
  -only-testing:CoreTests/ObservabilityAuditTests \
  2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **` with 4 test cases passing.

- [ ] **Step 3: Commit**

```bash
git add Core/Tests/CoreTests/ObservabilityAuditTests.swift
git commit -m "test(obs): add TelemetryValidator shape enforcement tests"
```

---

### Task 3: Add the static redaction scanner test (part a)

**Files:**
- Modify: `Core/Tests/CoreTests/ObservabilityAuditTests.swift`

The scanner walks every `.swift` file under `Core/Sources/Core/`, extracts every `logger.<method>(...)` call, and flags any call string whose interpolations reference a banned identifier unless the identifier passes through `.sha256Prefix`. The scanner is intentionally regex-based, not AST-based: Swift's `Regex` literal is adequate for the call-site patterns we emit, and a full AST parser (SwiftSyntax) is a dependency we do not want to pull into tests.

- [ ] **Step 1: Add the failing scanner test below the telemetry tests**

Append inside the `ObservabilityAuditTests` struct in `Core/Tests/CoreTests/ObservabilityAuditTests.swift` (immediately before the closing `}` of the suite):

```swift
    // MARK: - (a) Static redaction scanner

    /// Identifiers that are banned from appearing **raw** inside any
    /// `logger.*` interpolation. If the identifier is inside a `\(…)` that
    /// also contains `.sha256Prefix`, the call site is considered redacted
    /// and not flagged.
    private static let bannedSubstrings: [String] = [
        "ocr",        // ocrText, ocr.text, rawOCR, etc.
        "clipboard",  // context.clipboard, clipboardValue
        ".path",      // raw file-system path
        ".url",       // raw URL
        "fileURL",
    ]

    @Test("No logger.* call in Core sources leaks a raw path/ocr/clipboard value")
    func noRawRedactableValuesInLogs() throws {
        let coreSources = coreSourcesRoot()
        let swiftFiles = try swiftFilesRecursive(at: coreSources)
        #expect(!swiftFiles.isEmpty, "sanity: found 0 .swift files under \(coreSources.path)")

        var violations: [String] = []
        for url in swiftFiles {
            let contents = try String(contentsOf: url, encoding: .utf8)
            violations.append(contentsOf: scanLoggerViolations(in: contents, file: url))
        }

        if !violations.isEmpty {
            Issue.record("""
            Redaction audit failed — banned raw identifiers found in logger.* calls.
            Either route the value through `.sha256Prefix` or drop it from the log.

            Violations:
            \(violations.joined(separator: "\n"))
            """)
        }
    }

    // MARK: - Scanner helpers

    private func coreSourcesRoot() -> URL {
        // #filePath in test files resolves to the absolute path of this file
        // at build time. From there we reach Core/Sources/Core/ by walking
        // up two directories (Tests/CoreTests/..) and into Sources/Core.
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile
            .deletingLastPathComponent() // CoreTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Core/  (the package root, not the module)
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("Core", isDirectory: true)
    }

    private func swiftFilesRecursive(at root: URL) throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            out.append(url)
        }
        return out
    }

    /// Extracts every `logger.<method>(...)` call argument-list and checks
    /// whether any banned substring appears outside a `.sha256Prefix` guard.
    /// Returns a list of human-readable violation strings (one per offending
    /// call) — empty means clean.
    private func scanLoggerViolations(in source: String, file: URL) -> [String] {
        // Match: `logger.<word>("...any chars incl. newlines...")` — non-greedy
        // up to the closing quote + paren on the same statement. Swift's
        // `os.Logger` convention is single-line strings, so we match up to
        // the first `")` we see.
        let pattern = #/logger\.\w+\("((?:\\.|[^"\\])*)"\)/#
        var violations: [String] = []

        for match in source.matches(of: pattern) {
            let callString = String(match.output.1)
            let lineNumber = lineNumber(of: match.range.lowerBound, in: source)

            for banned in Self.bannedSubstrings {
                if callString.contains(banned) && !callString.contains(".sha256Prefix") {
                    violations.append("\(file.path):\(lineNumber) — logger.* contains raw `\(banned)` without .sha256Prefix")
                }
            }
        }
        return violations
    }

    private func lineNumber(of index: String.Index, in source: String) -> Int {
        source[..<index].reduce(1) { count, ch in ch == "\n" ? count + 1 : count }
    }
```

- [ ] **Step 2: Run the scanner test and verify it passes against the current tree**

Run:

```bash
xcodebuild test \
  -workspace Shotfuse.xcworkspace \
  -scheme Core \
  -destination 'platform=macOS' \
  -only-testing:CoreTests/ObservabilityAuditTests/noRawRedactableValuesInLogs \
  2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **` — confirms the current tree (Router/CaptureCoordinator/LimboHUDController already use `.sha256Prefix`) is clean.

- [ ] **Step 3: Prove the scanner catches a real violation**

Temporarily introduce a deliberate leak to verify the test actually fails. Edit `Core/Sources/Core/Router/Router.swift` at the clipboard log inside `sideEffect(for:context:)` around line 275:

Change:

```swift
logger.info("Side effect: Chosen destination is Clipboard. No direct file system side effect.")
```

to:

```swift
logger.info("Side effect: Clipboard = \(context.gitRoot?.path ?? "none")")
```

Run the scanner:

```bash
xcodebuild test \
  -workspace Shotfuse.xcworkspace \
  -scheme Core \
  -destination 'platform=macOS' \
  -only-testing:CoreTests/ObservabilityAuditTests/noRawRedactableValuesInLogs \
  2>&1 | tail -20
```

Expected: `** TEST FAILED **` with a message containing `— logger.* contains raw \`.path\` without .sha256Prefix`.

Then revert:

```bash
git checkout -- Core/Sources/Core/Router/Router.swift
```

Verify the test passes again:

```bash
xcodebuild test \
  -workspace Shotfuse.xcworkspace \
  -scheme Core \
  -destination 'platform=macOS' \
  -only-testing:CoreTests/ObservabilityAuditTests/noRawRedactableValuesInLogs \
  2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Core/Tests/CoreTests/ObservabilityAuditTests.swift
git commit -m "test(obs): add static redaction scanner for logger.* call sites"
```

---

### Task 4: Close the bd item

**Files:**
- None

- [ ] **Step 1: Close hq-5v4**

Run:

```bash
bd close hq-5v4 --notes "Closed during beads → superpowers-plans migration on 2026-04-24. Redaction scanner + telemetry validator shipped in Core/Tests/CoreTests/ObservabilityAuditTests.swift. See docs/superpowers/plans/2026-04-24-observability-redaction-audit.md."
```

Expected: `hq-5v4` no longer appears in `bd list --status=open`.

---

## Self-Review

**1. Spec coverage.**
- §13.5 telemetry (exactly 6 keys) → `TelemetryValidator.validate` + tests in Task 2.
- §17.2 redaction (sha256[:8] only) → static scanner in Task 3.
- P7.4 contract (a) "build fails if banned field is logged directly" → Task 3 Step 3 empirically demonstrates the test fails when a leak is introduced.
- P7.4 contract (b) "telemetry validator rejects extra fields" → Task 2's `telemetryValidatorRejectsExtraKey` case.

**2. Placeholder scan.** No TBDs, no "handle edge cases", no unlabeled tests. Every test has concrete input data and a concrete expected result path.

**3. Type consistency.** `TelemetryValidator.ValidationError` has four cases (`.notAnObject`, `.wrongKeySet`, `.wrongType`, `.invalidSlug`); all four are exercised by tests. `requiredKeys` is the single source of truth for both the validator and the assertion. `bannedSubstrings` is used only by the scanner helper and not exposed — the scanner is a private test implementation detail.
