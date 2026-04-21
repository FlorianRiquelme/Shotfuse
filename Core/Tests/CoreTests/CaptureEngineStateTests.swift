import Foundation
import Testing
@testable import Core

// Helpers for pattern-matching CaptureState (which is not Equatable because
// `.failed` carries an `Error`).
private func isIdle(_ s: CaptureState) -> Bool {
    if case .idle = s { return true } else { return false }
}
private func isArming(_ s: CaptureState) -> Bool {
    if case .arming = s { return true } else { return false }
}
private func isSelecting(_ s: CaptureState) -> Bool {
    if case .selecting = s { return true } else { return false }
}
private func isCapturing(_ s: CaptureState) -> Bool {
    if case .capturing = s { return true } else { return false }
}
private func isFinalizing(_ s: CaptureState) -> Bool {
    if case .finalizing = s { return true } else { return false }
}
private func failedError(_ s: CaptureState) -> Error? {
    if case .failed(let e) = s { return e } else { return nil }
}

private struct SentinelError: Error, Equatable {
    let tag: String
}

@Suite("CaptureEngineStateTests")
struct CaptureEngineStateTests {

    // MARK: - Initial state

    @Test("New engine starts in .idle")
    func startsIdle() async {
        let engine = CaptureEngine()
        await #expect(isIdle(engine.state))
    }

    // MARK: - Legal happy-path traversal

    @Test("Full legal traversal: idle → arming → selecting → capturing → finalizing → idle")
    func fullHappyPath() async throws {
        let engine = CaptureEngine()

        try await engine.arm()
        await #expect(isArming(engine.state))

        try await engine.beginSelection()
        await #expect(isSelecting(engine.state))

        try await engine.beginCapture()
        await #expect(isCapturing(engine.state))

        try await engine.finalize()
        await #expect(isFinalizing(engine.state))

        try await engine.reset()
        await #expect(isIdle(engine.state))
    }

    // MARK: - Illegal transitions throw CaptureStateError.illegalTransition

    @Test("Illegal: idle → capturing (cannot skip arming/selecting)")
    func illegalIdleToCapturing() async {
        let engine = CaptureEngine()
        await #expect(throws: CaptureStateError.self) {
            try await engine.beginCapture()
        }
        // State unchanged.
        await #expect(isIdle(engine.state))
    }

    @Test("Illegal: capturing → selecting (cannot go backwards)")
    func illegalCapturingToSelecting() async throws {
        let engine = CaptureEngine()
        try await engine.arm()
        try await engine.beginSelection()
        try await engine.beginCapture()

        await #expect(throws: CaptureStateError.self) {
            try await engine.beginSelection()
        }
        await #expect(isCapturing(engine.state))
    }

    @Test("Illegal: finalizing → capturing (cannot rewind)")
    func illegalFinalizingToCapturing() async throws {
        let engine = CaptureEngine()
        try await engine.arm()
        try await engine.beginSelection()
        try await engine.beginCapture()
        try await engine.finalize()

        await #expect(throws: CaptureStateError.self) {
            try await engine.beginCapture()
        }
        await #expect(isFinalizing(engine.state))
    }

    @Test("Illegal transitions throw CaptureStateError.illegalTransition specifically")
    func illegalTransitionErrorType() async {
        let engine = CaptureEngine()
        do {
            try await engine.beginCapture()
            Issue.record("Expected illegal transition to throw")
        } catch let error as CaptureStateError {
            switch error {
            case .illegalTransition(let from, let to):
                #expect(from == "idle")
                #expect(to == "capturing")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - fail(_:) from each non-terminal state

    @Test("fail(_:) from .idle lands in .failed carrying the supplied error")
    func failFromIdle() async throws {
        let engine = CaptureEngine()
        let err = SentinelError(tag: "from-idle")
        try await engine.fail(err)
        let carried = await failedError(engine.state) as? SentinelError
        #expect(carried == err)
    }

    @Test("fail(_:) from .arming lands in .failed carrying the supplied error")
    func failFromArming() async throws {
        let engine = CaptureEngine()
        try await engine.arm()
        let err = SentinelError(tag: "from-arming")
        try await engine.fail(err)
        let carried = await failedError(engine.state) as? SentinelError
        #expect(carried == err)
    }

    @Test("fail(_:) from .selecting lands in .failed carrying the supplied error")
    func failFromSelecting() async throws {
        let engine = CaptureEngine()
        try await engine.arm()
        try await engine.beginSelection()
        let err = SentinelError(tag: "from-selecting")
        try await engine.fail(err)
        let carried = await failedError(engine.state) as? SentinelError
        #expect(carried == err)
    }

    @Test("fail(_:) from .capturing lands in .failed carrying the supplied error")
    func failFromCapturing() async throws {
        let engine = CaptureEngine()
        try await engine.arm()
        try await engine.beginSelection()
        try await engine.beginCapture()
        let err = SentinelError(tag: "from-capturing")
        try await engine.fail(err)
        let carried = await failedError(engine.state) as? SentinelError
        #expect(carried == err)
    }

    @Test("fail(_:) from .finalizing lands in .failed carrying the supplied error")
    func failFromFinalizing() async throws {
        let engine = CaptureEngine()
        try await engine.arm()
        try await engine.beginSelection()
        try await engine.beginCapture()
        try await engine.finalize()
        let err = SentinelError(tag: "from-finalizing")
        try await engine.fail(err)
        let carried = await failedError(engine.state) as? SentinelError
        #expect(carried == err)
    }

    // MARK: - reset() from .failed

    @Test("reset() from .failed returns to .idle")
    func resetFromFailed() async throws {
        let engine = CaptureEngine()
        try await engine.fail(SentinelError(tag: "boom"))
        try await engine.reset()
        await #expect(isIdle(engine.state))
    }

    // MARK: - External mutation guarded by actor isolation + private(set)
    //
    // There is no meaningful runtime check for "external code cannot mutate
    // `state` directly": the `actor` declaration + `public private(set) var`
    // together make the write path unavailable to callers at compile time.
    // Outside code cannot assign to `engine.state` at all, and even reads must
    // `await` the actor's executor. Attempting to relax either of those would
    // fail to compile, which is strictly stronger than any runtime assertion.
    // This test documents that fact; no behavioral check is performed.
    @Test("state mutation is compiler-enforced; no runtime check possible")
    func stateIsExternallyImmutable() async {
        let engine = CaptureEngine()
        // The following line, if uncommented, would fail to compile:
        //   engine.state = .capturing
        // because `state` is `private(set)` and the actor isolates the setter.
        // Even reads require `await`. That is the strongest guarantee Swift
        // offers, so this test asserts only that the read path works.
        await #expect(isIdle(engine.state))
    }
}
