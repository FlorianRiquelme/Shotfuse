import Foundation

// SPEC §4 (Limbo vocabulary): the 2–8s post-capture window during which the
// user can retarget, tag, pin, edit, or delete a just-written capture.
//
// `LimboContext` is the pure data payload the HUD renders. It is the minimum
// projection of a finalized `.shot/` package (SPEC §6) needed to draw a
// thumbnail + action row — the HUD does NOT reach back into the filesystem
// itself.

/// Sensitivity-gating token emitted by SPEC §13.4 SCA surfacing when the
/// analyzer reports "clean".
public let LIMBO_SENSITIVITY_NONE: String = "none"

/// Snapshot of a just-finalized capture, supplied to `LimboHUDController`.
///
/// Per SPEC §4 + §13.4, the HUD surfaces the SCA result via `sensitivity`
/// (one of `["none"]` or any non-empty subset of `{"nudity",
/// "password_field", "card_number"}`). When `sensitivity` does not reduce
/// to `["none"]`, the HUD offers a "Redact and re-save" action — SPEC §5
/// Invariant 3 requires that redaction creates a NEW `.shot`, never
/// mutating the original `master.*`.
public struct LimboContext: Codable, Equatable, Sendable {
    /// UUIDv7 of the finalized capture (matches `manifest.id`).
    public let id: String
    /// Absolute file URL to `thumb.jpg` inside the `.shot/` package.
    public let thumbnailURL: URL
    /// Absolute file URL to `master.png` inside the `.shot/` package.
    /// The HUD must never mutate this file (SPEC §5 Invariant 3).
    public let masterURL: URL
    /// Frontmost bundle ID at capture time. `nil` only when the OS reported
    /// no frontmost app (extremely rare — e.g. login window).
    public let bundleID: String?
    /// Frontmost window title, if available. Nil when AX was denied.
    public let windowTitle: String?
    /// SCA result per SPEC §13.4. `["none"]` ⇒ clean; any other non-empty
    /// combination ⇒ redact affordance surfaced.
    public let sensitivity: [String]
    /// How long the HUD should remain visible before auto-hiding, clamped
    /// by `LimboTimeline` to the SPEC §4 2–8s window.
    public let durationSeconds: TimeInterval

    public init(
        id: String,
        thumbnailURL: URL,
        masterURL: URL,
        bundleID: String?,
        windowTitle: String?,
        sensitivity: [String],
        durationSeconds: TimeInterval
    ) {
        self.id = id
        self.thumbnailURL = thumbnailURL
        self.masterURL = masterURL
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.sensitivity = sensitivity
        self.durationSeconds = durationSeconds
    }

    /// `true` iff SCA reported a non-`none` finding — the HUD should show
    /// the "Redact and re-save" action button.
    public var hasSensitiveContent: Bool {
        let meaningful = sensitivity.filter { $0 != LIMBO_SENSITIVITY_NONE && !$0.isEmpty }
        return !meaningful.isEmpty
    }
}
