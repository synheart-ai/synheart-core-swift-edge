import XCTest
@testable import SynheartCoreEdge

final class WatchSessionEngineTests: XCTestCase {

    private func makeEngine() -> WatchSessionEngine {
        WatchSessionEngine(
            outbox: EdgeOutbox(),
            sessionManager: EdgeSessionManager()
        )
    }

    private func testConfig(
        sessionId: String = "test-1",
        mode: String = "focus",
        origin: SessionOrigin = .phone,
        kind: SessionKind = .focus
    ) -> SessionConfig {
        SessionConfig(
            sessionId: sessionId,
            mode: mode,
            durationSec: 60,
            profile: ComputeProfile(windowSec: 10, emitIntervalSec: 5),
            origin: origin,
            kind: kind
        )
    }

    func testStartTransitionsToRunning() {
        let engine = makeEngine()
        XCTAssertEqual(engine.state, .idle)

        engine.startSession(config: testConfig())
        XCTAssertEqual(engine.state, .running)

        engine.stopSession()
    }

    func testStopTransitionsToIdle() {
        let engine = makeEngine()
        engine.startSession(config: testConfig())
        engine.stopSession()

        XCTAssertEqual(engine.state, .idle)
    }

    func testStartEmitsStartedEvent() {
        let engine = makeEngine()
        var events: [SessionEvent] = []
        engine.onEvent = { events.append($0) }

        engine.startSession(config: testConfig())

        let startedCount = events.filter {
            if case .started = $0 { return true }
            return false
        }.count
        XCTAssertEqual(startedCount, 1)

        engine.stopSession()
    }

    func testDoubleStartIgnored() {
        let engine = makeEngine()
        var events: [SessionEvent] = []
        engine.onEvent = { events.append($0) }

        engine.startSession(config: testConfig())
        engine.startSession(config: testConfig())

        let startedCount = events.filter {
            if case .started = $0 { return true }
            return false
        }.count
        XCTAssertEqual(startedCount, 1)

        engine.stopSession()
    }

    func testStopEmitsSummary() {
        let engine = makeEngine()
        var events: [SessionEvent] = []
        engine.onEvent = { events.append($0) }

        engine.startSession(config: testConfig(sessionId: "test-2", mode: "breathing"))
        engine.stopSession()

        let summaryCount = events.filter {
            if case .summary = $0 { return true }
            return false
        }.count
        XCTAssertEqual(summaryCount, 1)
    }

    func testStateTransitionGuard() {
        let state = WatchSessionState.idle
        XCTAssertTrue(state.canTransition(to: .starting))
        XCTAssertFalse(state.canTransition(to: .running))
        XCTAssertFalse(state.canTransition(to: .stopping))
    }

    func testEdgeSessionIdFormat() {
        let mgr = EdgeSessionManager()
        let id = mgr.generateSessionId()
        XCTAssertTrue(id.hasPrefix("edge_w_"))
        // Format: edge_w_<device>_<ts>_<rand>
        let parts = id.split(separator: "_")
        XCTAssertTrue(parts.count >= 5)
    }

    func testArtifactEnvelopeCreation() {
        let envelope = HsiArtifactEnvelope.wrap(
            sessionId: "test-session",
            seq: 1,
            hsiJson: "{\"test\": true}",
            deliveryMode: .realtime,
            origin: .phone,
            kind: .focus
        )
        XCTAssertTrue(envelope.artifactId.hasPrefix("hsi_"))
        XCTAssertEqual(envelope.sessionId, "test-session")
        XCTAssertEqual(envelope.seq, 1)
        XCTAssertEqual(envelope.schemaVersion, "1.1")
        XCTAssertFalse(envelope.payloadHashSha256.isEmpty)
        XCTAssertEqual(envelope.deliveryMode, .realtime)
    }

    func testOutboxEnqueueAndAck() {
        let outbox = EdgeOutbox()
        outbox.clear()

        let envelope = HsiArtifactEnvelope.wrap(
            sessionId: "test-session",
            seq: 1,
            hsiJson: "{\"v\":1}",
            deliveryMode: .realtime,
            origin: .phone,
            kind: .focus
        )
        outbox.enqueue(envelope)

        // Small delay for async write
        let expectation = XCTestExpectation(description: "outbox write")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertEqual(outbox.pendingCount, 1)

            outbox.ack(artifactId: envelope.artifactId)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                XCTAssertEqual(outbox.pendingCount, 0)
                expectation.fulfill()
            }
        }
        wait(for: [expectation], timeout: 3)
    }

    func testSessionKindOnPreset() {
        let preset = SessionPreset.defaults.first { $0.kind == .nap }
        XCTAssertNotNil(preset)
        XCTAssertEqual(preset?.mode, "nap")
    }
}
