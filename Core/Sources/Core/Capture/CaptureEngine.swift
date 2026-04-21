import Foundation

// CaptureEngine is the sole owner of the capture state machine and (eventually) the
// single owner of any SCStream. SwiftUI holds no reference — enforcing SPEC §5 I2
// (SwiftUI never owns SCStream/SCStreamOutput).

/// Capture lifecycle states per SPEC §5 I1 (v0.1.0 / Weekend 1).
///
/// Legal transitions:
/// ```
/// idle      → arming      (arm)
/// arming    → selecting   (beginSelection)
/// selecting → capturing   (beginCapture)
/// capturing → finalizing  (finalize)
/// finalizing → idle       (reset)
/// any non-terminal → failed(error) (fail)
/// failed    → idle        (reset)
/// ```
public enum CaptureState: Sendable {
    case idle
    case arming
    case selecting
    case capturing
    case finalizing
    case failed(Error)
}

/// Typed error raised when an illegal state transition is attempted.
public enum CaptureStateError: Error, Equatable, Sendable {
    case illegalTransition(from: String, to: String)
}

/// Single actor that owns the capture state machine (SPEC §5 I1).
///
/// Because `state` is `private(set)` and the type is an `actor`, external code
/// cannot mutate state directly; all changes go through the transition methods
/// below, each of which validates the current state and throws
/// `CaptureStateError.illegalTransition` on violation.
public actor CaptureEngine {
    public private(set) var state: CaptureState = .idle

    public init() {}

    // MARK: - Transitions

    /// `idle → arming`
    public func arm() throws {
        switch state {
        case .idle:
            state = .arming
        default:
            throw CaptureStateError.illegalTransition(from: Self.label(state), to: "arming")
        }
    }

    /// `arming → selecting`
    public func beginSelection() throws {
        switch state {
        case .arming:
            state = .selecting
        default:
            throw CaptureStateError.illegalTransition(from: Self.label(state), to: "selecting")
        }
    }

    /// `selecting → capturing`
    public func beginCapture() throws {
        switch state {
        case .selecting:
            state = .capturing
        default:
            throw CaptureStateError.illegalTransition(from: Self.label(state), to: "capturing")
        }
    }

    /// `capturing → finalizing`
    public func finalize() throws {
        switch state {
        case .capturing:
            state = .finalizing
        default:
            throw CaptureStateError.illegalTransition(from: Self.label(state), to: "finalizing")
        }
    }

    /// Any non-terminal state → `failed(error)`.
    /// Non-terminal means: `idle`, `arming`, `selecting`, `capturing`, `finalizing`.
    /// Calling `fail` from `.failed` is itself an illegal transition.
    public func fail(_ error: Error) throws {
        switch state {
        case .idle, .arming, .selecting, .capturing, .finalizing:
            state = .failed(error)
        case .failed:
            throw CaptureStateError.illegalTransition(from: Self.label(state), to: "failed")
        }
    }

    /// `finalizing → idle` or `failed → idle`.
    public func reset() throws {
        switch state {
        case .finalizing, .failed:
            state = .idle
        default:
            throw CaptureStateError.illegalTransition(from: Self.label(state), to: "idle")
        }
    }

    // MARK: - Helpers

    private static func label(_ s: CaptureState) -> String {
        switch s {
        case .idle: return "idle"
        case .arming: return "arming"
        case .selecting: return "selecting"
        case .capturing: return "capturing"
        case .finalizing: return "finalizing"
        case .failed: return "failed"
        }
    }
}
