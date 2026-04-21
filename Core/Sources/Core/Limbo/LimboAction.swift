import Foundation

// SPEC §4 keymap for the Limbo HUD. The raw values are the key characters
// consumed by the keyboard dispatcher in `LimboHUDController`:
//
//   e       → edit          (opens annotation canvas, SPEC §6.4)
//   p       → pin           (sets manifest.pinned = true; bypass Fuse GC)
//   t       → tag           (appends a tag; rewrites manifest atomically)
//   esc     → delete        (discards the `.shot/` before Fuse could)
//   cmd+z   → redirect      (reopens the Router chooser, SPEC §7 / §7.1)
//
// The enum is the single source of truth for the keymap and for tests.
// `init(keyToken:)` parses the token form that `LimboHUDController`
// synthesizes from `NSEvent` — we keep the mapping free of AppKit so
// `LimboAction` is usable inside `Core` under Swift 6 strict concurrency.

/// Actions the Limbo HUD dispatches to its host on key press or button
/// click. Raw values match the token strings fired by the keyboard
/// dispatcher so `LimboAction(rawValue:)` is the inverse of the keymap.
public enum LimboAction: String, CaseIterable, Sendable, Codable {
    /// `[e]` — open the annotation editor for this capture (SPEC §6.4).
    case edit = "e"
    /// `[p]` — pin the capture so Fuse never reaps it (SPEC §4 + §15.1).
    case pin = "p"
    /// `[t]` — add a tag to the capture (manifest rewrite).
    case tag = "t"
    /// `[esc]` — delete the capture before it escapes Limbo. Raw value
    /// `"esc"` because NSEvent's `escape` has no printable character.
    case deleteEsc = "esc"
    /// `[cmd+z]` — re-open the Router chooser (SPEC §7.1 decision rule).
    case redirect = "cmd_z"

    /// Parses a token emitted by the HUD's keyboard dispatcher. Returns
    /// `nil` for any unmapped key so the caller can fall through to the
    /// usual responder chain.
    ///
    /// Token shape:
    ///   - printable keys → the character, lowercased (`"e"`, `"p"`, `"t"`).
    ///   - escape         → `"esc"`.
    ///   - cmd+z          → `"cmd_z"` (synthesized by the dispatcher).
    public init?(keyToken: String) {
        self.init(rawValue: keyToken)
    }
}
