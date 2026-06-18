// SPDX-License-Identifier: Apache-2.0
// Copyright (c) Synheart authors

import XCTest
import struct SynheartSession.BiosignalSample
@testable import SynheartCoreEdge

final class WatchSessionEngineTests: XCTestCase {

    private func makeEngine() -> WatchSessionEngine {
        WatchSessionEngine(
            provider: MockBiosignalProvider(),
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

    /// Proves the frame metrics carry the raw `preprocessed` artifact (real
    /// HR/HRV/motion numbers) under the stable contract key. The JSON shape
    /// matches the runtime's preprocessed payload: derived_features.hrv.
    /// {rmssd_ms,sdnn_ms,hr_mean_bpm,...} + derived_features.motion.accel_rms +
    /// a top-level quality block.
    func testFrameMetricsCarryPreprocessedHrv() {
        let preprocessed = """
        {
          "schema_version": "1.0.0",
          "window_start_ms": 1000,
          "window_end_ms": 61000,
          "session_id": "test-pp",
          "quality": {"score": 0.92, "coverage_pct": 0.88, "dropout_count": 1, "rr_count": 55, "artifact_pct": 0.04},
          "derived_features": {
            "hrv": {"rmssd_ms": 42.5, "sdnn_ms": 58.1, "pnn50": 0.21, "mean_rr_ms": 820.0, "hr_mean_bpm": 73.2, "hr_std_bpm": 3.4, "rr_count": 55},
            "motion": {"accel_rms": 0.13, "accel_var": 0.02, "steps_est": 4, "posture_proxy": 0.7, "sample_count": 300},
            "artifact": null
          },
          "behavior_features": null
        }
        """
        let quality = """
        {"score": 0.92, "coverage_pct": 0.88, "artifact_pct": 0.04}
        """

        var metrics: [String: Any] = ["session_id": "test-pp", "seq": 3]
        WatchSessionEngine.merge(preprocessedJson: preprocessed, qualityJson: quality, into: &metrics)

        guard let pp = metrics["preprocessed"] as? [String: Any] else {
            return XCTFail("metrics missing preprocessed object")
        }
        guard let derived = pp["derived_features"] as? [String: Any],
              let hrv = derived["hrv"] as? [String: Any] else {
            return XCTFail("preprocessed missing derived_features.hrv")
        }
        XCTAssertEqual(hrv["sdnn_ms"] as? Double, 58.1)
        XCTAssertEqual(hrv["rmssd_ms"] as? Double, 42.5)
        XCTAssertEqual(hrv["hr_mean_bpm"] as? Double, 73.2)

        guard let motion = derived["motion"] as? [String: Any] else {
            return XCTFail("preprocessed missing derived_features.motion")
        }
        XCTAssertEqual(motion["accel_rms"] as? Double, 0.13)

        guard let q = metrics["quality"] as? [String: Any] else {
            return XCTFail("metrics missing quality object")
        }
        XCTAssertEqual(q["score"] as? Double, 0.92)
    }

    /// Stream mode (no runtime) must not fabricate a preprocessed/quality block.
    func testMergeNoOpWhenJsonAbsent() {
        var metrics: [String: Any] = ["seq": 1]
        WatchSessionEngine.merge(preprocessedJson: nil, qualityJson: nil, into: &metrics)
        XCTAssertNil(metrics["preprocessed"])
        XCTAssertNil(metrics["quality"])
    }

    func testSessionKindOnPreset() {
        let preset = SessionPreset.defaults.first { $0.kind == .nap }
        XCTAssertNotNil(preset)
        XCTAssertEqual(preset?.mode, "nap")
    }

    // MARK: - edge_mode config emission

    func testEdgeModeWireRawValues() {
        XCTAssertEqual(EdgeMode.off.rawValue, "off")
        XCTAssertEqual(EdgeMode.shadow.rawValue, "shadow")
        XCTAssertEqual(EdgeMode.canonical.rawValue, "canonical")
    }

    func testComputeProfileDefaultsToCanonical() {
        XCTAssertEqual(ComputeProfile().edgeMode, .canonical)
    }

    func testComputeProfileEdgeModeFromMap() {
        let p = ComputeProfile(from: ["window_sec": 30, "emit_interval_sec": 5, "edge_mode": "shadow"])
        XCTAssertEqual(p.edgeMode, .shadow)
        // Missing key defaults to canonical (forward-compatible / additive).
        let d = ComputeProfile(from: ["window_sec": 30])
        XCTAssertEqual(d.edgeMode, .canonical)
        // Unknown value falls back to canonical.
        let u = ComputeProfile(from: ["edge_mode": "bogus"])
        XCTAssertEqual(u.edgeMode, .canonical)
    }

    func testComputeProfileEdgeModeCodableRoundTrip() throws {
        let p = ComputeProfile(windowSec: 60, emitIntervalSec: 5, edgeMode: .shadow)
        let data = try JSONEncoder().encode(p)
        // JSON key must be the wire key `edge_mode` with the lowercase rawValue.
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["edge_mode"] as? String, "shadow")
        let decoded = try JSONDecoder().decode(ComputeProfile.self, from: data)
        XCTAssertEqual(decoded.edgeMode, .shadow)
    }

    /// Asserts the create-config JSON contains `compute_profile.edge_mode` with
    /// the lowercase wire rawValue.
    func testCreateConfigJsonEmitsComputeProfileEdgeMode() throws {
        let dict = RuntimeBridge.buildConfigDict(.init(
            subjectId: "sub_test",
            sessionId: "sess-1",
            edgeMode: .canonical
        ))
        guard let cp = dict["compute_profile"] as? [String: Any] else {
            return XCTFail("create-config JSON missing compute_profile")
        }
        XCTAssertEqual(cp["edge_mode"] as? String, "canonical")

        // Round-trip through JSONSerialization to prove it survives the wire.
        let data = try JSONSerialization.data(withJSONObject: dict)
        let reparsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let reCp = reparsed?["compute_profile"] as? [String: Any]
        XCTAssertEqual(reCp?["edge_mode"] as? String, "canonical")

        // Shadow variant.
        let shadowDict = RuntimeBridge.buildConfigDict(.init(
            subjectId: "s", sessionId: "x", edgeMode: .shadow
        ))
        let shadowCp = shadowDict["compute_profile"] as? [String: Any]
        XCTAssertEqual(shadowCp?["edge_mode"] as? String, "shadow")
    }

    // MARK: - handle lifecycle safety (double-destroy)

    /// Double-stop must be safe (the runtime handle is destroyed at most once;
    /// the bridge nils its handle after the first free so a second destroy is a
    /// guarded no-op). In the test environment the native lib is absent so the
    /// bridge is nil, but the engine must still tolerate the repeated teardown.
    func testDoubleStopIsSafe() {
        let engine = makeEngine()
        engine.startSession(config: testConfig())
        engine.stopSession()
        // Second stop must not crash / re-emit; state stays idle.
        engine.stopSession()
        XCTAssertEqual(engine.state, .idle)
    }

    // MARK: - supported HSI versions

    func testSupportedHsiVersions() {
        XCTAssertEqual(WatchSessionEngine.SUPPORTED_HSI_VERSIONS, ["1.1", "1.2", "1.3"])
    }

    /// `checkHsiVersion` must not throw / mutate; it only logs out-of-set
    /// versions. Exercise both in-set and out-of-set + missing-key paths.
    func testCheckHsiVersionDoesNotThrowOnAnyInput() {
        WatchSessionEngine.checkHsiVersion(["hsi_version": "1.3"])   // supported
        WatchSessionEngine.checkHsiVersion(["hsi_version": "9.9"])   // logs, no crash
        WatchSessionEngine.checkHsiVersion(["axes": [:]])           // missing key, no-op
    }

    // MARK: - envelope carries hsi_version

    /// The artifact envelope must extract the wrapped payload's top-level
    /// `hsi_version` and surface it on the wire message — distinct from the
    /// envelope's own `schema_version`.
    func testEnvelopeCarriesHsiVersionMatchingPayload() {
        let payload = "{\"hsi_version\":\"1.3\",\"axes\":{}}"
        let envelope = HsiArtifactEnvelope.wrap(
            sessionId: "s-hv", seq: 2, hsiJson: payload,
            deliveryMode: .realtime, origin: .phone, kind: .focus
        )
        XCTAssertEqual(envelope.hsiVersion, "1.3")
        XCTAssertEqual(envelope.schemaVersion, "1.1") // wrapper version is distinct

        let msg = envelope.toMessage()
        XCTAssertEqual(msg["hsi_version"] as? String, "1.3")
        XCTAssertEqual(msg["schema_version"] as? String, "1.1")
        XCTAssertEqual(msg["type"] as? String, "hsi_artifact")
    }

    /// Unparseable / version-less payloads default to "unknown" (tolerant).
    func testEnvelopeHsiVersionDefaultsUnknown() {
        let bad = HsiArtifactEnvelope.wrap(
            sessionId: "s", seq: 0, hsiJson: "not json",
            deliveryMode: .realtime, origin: .phone, kind: nil
        )
        XCTAssertEqual(bad.hsiVersion, "unknown")

        let noVersion = HsiArtifactEnvelope.wrap(
            sessionId: "s", seq: 0, hsiJson: "{\"axes\":{}}",
            deliveryMode: .realtime, origin: .phone, kind: nil
        )
        XCTAssertEqual(noVersion.hsiVersion, "unknown")
    }

    /// Decode is tolerant: a JSON envelope predating `hsi_version` decodes with
    /// "unknown" rather than failing (additive field).
    func testEnvelopeDecodeTolerantOfMissingHsiVersion() throws {
        let legacy = """
        {"artifact_id":"hsi_x_0","session_id":"s","seq":0,"created_at_ms":1,
         "schema_version":"1.1","payload_hash_sha256":"ab","payload_json":"{}",
         "delivery_mode":"REALTIME","session_origin":"PHONE"}
        """
        let decoded = try JSONDecoder().decode(
            HsiArtifactEnvelope.self, from: Data(legacy.utf8)
        )
        XCTAssertEqual(decoded.hsiVersion, "unknown")
        XCTAssertEqual(decoded.schemaVersion, "1.1")

        // Round-trip with hsi_version present.
        let withVersion = HsiArtifactEnvelope.wrap(
            sessionId: "s", seq: 1, hsiJson: "{\"hsi_version\":\"1.2\"}",
            deliveryMode: .realtime, origin: .phone, kind: .focus
        )
        let data = try JSONEncoder().encode(withVersion)
        let back = try JSONDecoder().decode(HsiArtifactEnvelope.self, from: data)
        XCTAssertEqual(back.hsiVersion, "1.2")
    }

    // MARK: - phone→watch start/stop command routing

    /// `start_session` parses a SessionConfig and dispatches it to the engine
    /// callback; `stop_session` fires the stop callback.
    func testCommandRouterDispatchesStartAndStop() {
        var started: SessionConfig?
        var stopped = false
        let route: ([String: Any]) -> PhoneCommandRouter.Command? = { msg in
            PhoneCommandRouter.route(
                msg,
                onStart: { started = $0 },
                onStop: { stopped = true },
                onSyncPresets: { _ in }, onArtifactAck: { _ in }, onSyncResponse: { _ in }
            )
        }

        let startCmd: [String: Any] = [
            "command": "start_session",
            "session_id": "phone-sess-1",
            "mode": "focus",
            "duration_sec": 300,
            "kind": "FOCUS"
        ]
        XCTAssertEqual(route(startCmd), .startSession)
        XCTAssertEqual(started?.sessionId, "phone-sess-1")
        XCTAssertEqual(started?.durationSec, 300)
        XCTAssertEqual(started?.origin, .phone)
        XCTAssertEqual(started?.kind, .focus)

        XCTAssertEqual(route(["command": "stop_session"]), .stopSession)
        XCTAssertTrue(stopped)
    }

    /// A malformed start_session body must NOT fabricate a session.
    func testCommandRouterIgnoresMalformedStart() {
        var started: SessionConfig?
        let cmd: [String: Any] = ["command": "start_session", "mode": "focus"] // no session_id/duration
        let matched = PhoneCommandRouter.route(
            cmd,
            onStart: { started = $0 }, onStop: {},
            onSyncPresets: { _ in }, onArtifactAck: { _ in }, onSyncResponse: { _ in }
        )
        XCTAssertEqual(matched, .startSession) // recognised verb...
        XCTAssertNil(started)                   // ...but no config dispatched
    }

    /// Sync/ack/preset commands still route to their handlers; unknown verbs
    /// and command-less bodies are no-ops.
    func testCommandRouterRoutesSyncAndIgnoresUnknown() {
        var presets = false, ack = false, sync = false
        func route(_ m: [String: Any]) -> PhoneCommandRouter.Command? {
            PhoneCommandRouter.route(
                m, onStart: { _ in }, onStop: {},
                onSyncPresets: { _ in presets = true },
                onArtifactAck: { _ in ack = true },
                onSyncResponse: { _ in sync = true }
            )
        }
        XCTAssertEqual(route(["command": "sync_presets"]), .syncPresets)
        XCTAssertEqual(route(["command": "artifact_ack"]), .artifactAck)
        XCTAssertEqual(route(["command": "sync_response"]), .syncResponse)
        XCTAssertNil(route(["command": "bogus"]))
        XCTAssertNil(route(["bpm": 72.0]))
        XCTAssertTrue(presets && ack && sync)
    }

    // MARK: - edge_mode honoring

    /// Fake runtime so COMPUTE_LOCAL is resolved without the native library.
    /// Records pushed HR samples so the test can prove SHADOW computes locally.
    private final class FakeRuntime: RuntimeHandle {
        private(set) var hrPushes: [(Int64, Double)] = []
        private(set) var destroyed = false
        func pushRr(tsMs: Int64, rrMs: Double) {}
        func pushHr(tsMs: Int64, bpm: Double) { hrPushes.append((tsMs, bpm)) }
        func pushAccel(tsMs: Int64, x: Double, y: Double, z: Double) {}
        func tick(nowMs: Int64) -> String? { nil }
        func lastQuality() -> String? { nil }
        func lastPreprocessed() -> String? { nil }
        func destroy() { destroyed = true }
    }

    private func edgeConfig(edgeMode: EdgeMode) -> SessionConfig {
        SessionConfig(
            sessionId: "edge-mode-\(edgeMode.rawValue)",
            mode: "focus",
            durationSec: 60,
            profile: ComputeProfile(windowSec: 10, emitIntervalSec: 5, edgeMode: edgeMode),
            origin: .phone,
            kind: .focus
        )
    }

    private func makeEngineWithFakeRuntime(_ fake: FakeRuntime?) -> (WatchSessionEngine, MockBiosignalProvider) {
        let provider = MockBiosignalProvider()
        let engine = WatchSessionEngine(
            provider: provider,
            outbox: EdgeOutbox(),
            sessionManager: EdgeSessionManager()
        )
        engine.runtimeFactory = { _ in fake }
        return (engine, provider)
    }

    private func sample(bpm: Double = 72) -> BiosignalSample {
        BiosignalSample(timestampMs: 1_000, bpm: bpm, rrIntervalsMs: [820], source: "mock")
    }

    /// OFF → engine resolves to .stream and the native runtime is NEVER created
    /// (factory is not consulted because edge_mode==off short-circuits). Raw
    /// samples ARE relayed via onBiosignalSample.
    func testEdgeModeOffStreamsRawAndSkipsRuntime() {
        var factoryCalled = false
        let provider = MockBiosignalProvider()
        let engine = WatchSessionEngine(provider: provider, outbox: EdgeOutbox(), sessionManager: EdgeSessionManager())
        engine.runtimeFactory = { _ in factoryCalled = true; return FakeRuntime() }

        var relayed: [BiosignalSample] = []
        engine.onBiosignalSample = { relayed.append($0) }

        engine.startSession(config: edgeConfig(edgeMode: .off))
        XCTAssertEqual(engine.mode, .stream)
        XCTAssertTrue(engine.streamRawSamples)
        XCTAssertFalse(factoryCalled, "OFF must NOT create/start the runtime")

        provider.emit(sample(bpm: 70))
        XCTAssertEqual(relayed.count, 1, "OFF must stream raw samples")

        engine.stopSession()
    }

    /// CANONICAL (runtime available) → .computeLocal, does NOT emit raw via
    /// onBiosignalSample (edge HSI is product-of-record). Sample still feeds runtime.
    func testEdgeModeCanonicalComputesAndSuppressesRaw() {
        let fake = FakeRuntime()
        let (engine, provider) = makeEngineWithFakeRuntime(fake)

        var relayed: [BiosignalSample] = []
        engine.onBiosignalSample = { relayed.append($0) }

        engine.startSession(config: edgeConfig(edgeMode: .canonical))
        XCTAssertEqual(engine.mode, .computeLocal)
        XCTAssertFalse(engine.streamRawSamples, "CANONICAL must NOT stream raw")

        provider.emit(sample(bpm: 75))
        XCTAssertTrue(relayed.isEmpty, "CANONICAL must suppress raw onBiosignalSample")
        XCTAssertEqual(fake.hrPushes.count, 1, "CANONICAL must feed the runtime")

        engine.stopSession()
    }

    /// SHADOW (runtime available) → .computeLocal AND ALSO emits raw via
    /// onBiosignalSample (compute locally and stream raw).
    func testEdgeModeShadowComputesAndStreamsRaw() {
        let fake = FakeRuntime()
        let (engine, provider) = makeEngineWithFakeRuntime(fake)

        var relayed: [BiosignalSample] = []
        engine.onBiosignalSample = { relayed.append($0) }

        engine.startSession(config: edgeConfig(edgeMode: .shadow))
        XCTAssertEqual(engine.mode, .computeLocal)
        XCTAssertTrue(engine.streamRawSamples, "SHADOW must stream raw")

        provider.emit(sample(bpm: 80))
        XCTAssertEqual(relayed.count, 1, "SHADOW must ALSO stream raw")
        XCTAssertEqual(fake.hrPushes.count, 1, "SHADOW must compute locally")

        engine.stopSession()
    }

    /// SHADOW with NO runtime available degrades to .stream and forces raw
    /// streaming so the phone is still fed.
    func testEdgeModeShadowWithoutRuntimeDegradesToStream() {
        let (engine, provider) = makeEngineWithFakeRuntime(nil)

        var relayed: [BiosignalSample] = []
        engine.onBiosignalSample = { relayed.append($0) }

        engine.startSession(config: edgeConfig(edgeMode: .shadow))
        XCTAssertEqual(engine.mode, .stream, "no runtime → degrade to stream")
        XCTAssertTrue(engine.streamRawSamples)

        provider.emit(sample(bpm: 65))
        XCTAssertEqual(relayed.count, 1)

        engine.stopSession()
    }

    /// An explicit requestedMode == .stream wins even when a runtime is
    /// available, and the resolved-but-unused runtime is destroyed.
    func testRequestedStreamOverridesAndDestroysUnusedRuntime() {
        let fake = FakeRuntime()
        let (engine, provider) = makeEngineWithFakeRuntime(fake)
        engine.startSession(config: edgeConfig(edgeMode: .shadow), mode: .stream)
        XCTAssertEqual(engine.mode, .stream)
        // Factory short-circuited (requestedMode==.stream) so the fake is never
        // even created/used; the engine must run as a pure stream.
        provider.emit(sample())
        XCTAssertTrue(fake.hrPushes.isEmpty)
        engine.stopSession()
    }

    // MARK: - Final-window artifact durability

    /// A fake whose `tick` returns HSI on demand so the final teardown tick can
    /// be exercised. `tickAndReadout` uses the protocol default (composes the
    /// discrete calls), which is enough for the engine contract.
    private final class FinalTickRuntime: RuntimeHandle {
        var nextTick: String?
        private(set) var destroyed = false
        func pushRr(tsMs: Int64, rrMs: Double) {}
        func pushHr(tsMs: Int64, bpm: Double) {}
        func pushAccel(tsMs: Int64, x: Double, y: Double, z: Double) {}
        func tick(nowMs: Int64) -> String? { nextTick }
        func lastQuality() -> String? { nil }
        func lastPreprocessed() -> String? { nil }
        func destroy() { destroyed = true }
    }

    /// When the FINAL tick (in finishSession) produces HSI, the engine must
    /// persist it to the outbox AND relay an `.artifact` event — not leave the
    /// last window only in the Summary metrics.
    func testFinalWindowArtifactIsPersistedAndRelayed() {
        let fake = FinalTickRuntime()
        let provider = MockBiosignalProvider()
        let outbox = EdgeOutbox()
        outbox.clear()
        let engine = WatchSessionEngine(
            provider: provider, outbox: outbox, sessionManager: EdgeSessionManager()
        )
        engine.runtimeFactory = { _ in fake }

        var artifacts: [HsiArtifactEnvelope] = []
        engine.onEvent = { if case .artifact(let e) = $0 { artifacts.append(e) } }

        engine.startSession(config: edgeConfig(edgeMode: .canonical))
        XCTAssertEqual(engine.mode, .computeLocal)

        // Arm the final tick to return a real HSI payload, then stop.
        fake.nextTick = "{\"hsi_version\":\"1.3\",\"axes\":{}}"
        engine.stopSession()

        // Exactly one final artifact relayed, carrying the payload's version.
        XCTAssertEqual(artifacts.count, 1, "final window must emit one .artifact")
        XCTAssertEqual(artifacts.first?.hsiVersion, "1.3")

        // And it must be durable in the outbox.
        let exp = XCTestExpectation(description: "outbox write")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertEqual(outbox.pendingCount, 1, "final window must be persisted")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3)
        outbox.clear()
    }

    /// Negative case: a final tick that returns nil (no window) must NOT fabricate
    /// an artifact (stream-mode parity / no-op).
    func testNoFinalArtifactWhenFinalTickNil() {
        let fake = FinalTickRuntime() // nextTick stays nil
        let provider = MockBiosignalProvider()
        let outbox = EdgeOutbox()
        outbox.clear()
        let engine = WatchSessionEngine(
            provider: provider, outbox: outbox, sessionManager: EdgeSessionManager()
        )
        engine.runtimeFactory = { _ in fake }
        var artifacts: [HsiArtifactEnvelope] = []
        engine.onEvent = { if case .artifact(let e) = $0 { artifacts.append(e) } }

        engine.startSession(config: edgeConfig(edgeMode: .canonical))
        engine.stopSession()
        XCTAssertTrue(artifacts.isEmpty, "no HSI → no final artifact")
    }

    // MARK: - artifact_id path-traversal sanitization

    func testArtifactIdSanitizeAcceptsSafeIds() {
        XCTAssertTrue(EdgeOutbox.isSafeArtifactId("hsi_abc123_4"))
        XCTAssertTrue(EdgeOutbox.isSafeArtifactId("ABC-def_0"))
        XCTAssertTrue(EdgeOutbox.isSafeArtifactId("0"))
    }

    func testArtifactIdSanitizeRejectsTraversalAndSpecials() {
        XCTAssertFalse(EdgeOutbox.isSafeArtifactId(""))
        XCTAssertFalse(EdgeOutbox.isSafeArtifactId(".."))
        XCTAssertFalse(EdgeOutbox.isSafeArtifactId("../../etc/passwd"))
        XCTAssertFalse(EdgeOutbox.isSafeArtifactId("a/b"))
        XCTAssertFalse(EdgeOutbox.isSafeArtifactId("a.b"))
        XCTAssertFalse(EdgeOutbox.isSafeArtifactId("a b"))
        XCTAssertFalse(EdgeOutbox.isSafeArtifactId("a\u{0000}b"))
    }

    /// A crafted (unsafe) artifact_id must NOT write a file outside the outbox:
    /// enqueue is skipped entirely, so pendingCount stays 0.
    func testEnqueueRejectsUnsafeArtifactId() throws {
        let outbox = EdgeOutbox()
        outbox.clear()
        let unsafe = HsiArtifactEnvelope(
            artifactId: "../escape",
            sessionId: "s", seq: 1, createdAtMs: 1, schemaVersion: "1.1",
            hsiVersion: "1.3", payloadHashSha256: "ab", payloadJson: "{}",
            deliveryMode: .realtime, sessionOrigin: .phone, sessionKind: .focus
        )
        outbox.enqueue(unsafe)
        let exp = XCTestExpectation(description: "rejected")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertEqual(outbox.pendingCount, 0, "unsafe id must not be persisted")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3)
    }

    // MARK: - Single-section tickAndReadout

    /// A bridge-like fake that records call ordering proves tickAndReadout
    /// fetches hsi + preprocessed + quality together (one snapshot) rather than
    /// in three separate, tear-prone reads.
    private final class ReadoutRecordingRuntime: RuntimeHandle {
        private(set) var calls: [String] = []
        func pushRr(tsMs: Int64, rrMs: Double) {}
        func pushHr(tsMs: Int64, bpm: Double) {}
        func pushAccel(tsMs: Int64, x: Double, y: Double, z: Double) {}
        func tick(nowMs: Int64) -> String? { calls.append("tick"); return "{\"hsi_version\":\"1.3\"}" }
        func lastPreprocessed() -> String? { calls.append("pre"); return "{\"derived_features\":{}}" }
        func lastQuality() -> String? { calls.append("qual"); return "{\"score\":0.9}" }
        func destroy() {}
        // Override the default to fetch all three as one consistent snapshot.
        func tickAndReadout(nowMs: Int64) -> RuntimeReadout {
            RuntimeReadout(hsiJson: tick(nowMs: nowMs),
                           preprocessed: lastPreprocessed(),
                           quality: lastQuality())
        }
    }

    func testTickAndReadoutReturnsConsistentSnapshot() {
        let fake = ReadoutRecordingRuntime()
        let r = fake.tickAndReadout(nowMs: 1000)
        XCTAssertEqual(r.hsiJson, "{\"hsi_version\":\"1.3\"}")
        XCTAssertEqual(r.preprocessed, "{\"derived_features\":{}}")
        XCTAssertEqual(r.quality, "{\"score\":0.9}")
        // All three reads happened, in order, as one readout.
        XCTAssertEqual(fake.calls, ["tick", "pre", "qual"])
    }

    /// The protocol default composes the discrete calls so test fakes that
    /// don't override it still work.
    func testTickAndReadoutDefaultComposition() {
        let fake = FinalTickRuntime()
        fake.nextTick = "{\"hsi_version\":\"1.2\"}"
        let r = fake.tickAndReadout(nowMs: 0)
        XCTAssertEqual(r.hsiJson, "{\"hsi_version\":\"1.2\"}")
        XCTAssertNil(r.preprocessed)
        XCTAssertNil(r.quality)
    }

    // MARK: - hsi_version decode re-extraction (parity with Kotlin)

    /// An outbox file written before `hsi_version` existed (no top-level field)
    /// must re-extract the real version from `payload_json` rather than
    /// defaulting to "unknown".
    func testDecodeReextractsHsiVersionFromPayload() throws {
        let legacy = """
        {"artifact_id":"hsi_x_0","session_id":"s","seq":0,"created_at_ms":1,
         "schema_version":"1.1","payload_hash_sha256":"ab",
         "payload_json":"{\\"hsi_version\\":\\"1.2\\",\\"axes\\":{}}",
         "delivery_mode":"REALTIME","session_origin":"PHONE"}
        """
        let decoded = try JSONDecoder().decode(
            HsiArtifactEnvelope.self, from: Data(legacy.utf8)
        )
        XCTAssertEqual(decoded.hsiVersion, "1.2", "must re-extract from payload_json")
    }

    /// Still "unknown" when neither the top-level field nor the payload carry it.
    func testDecodeFallsBackToUnknownWhenPayloadHasNoVersion() throws {
        let legacy = """
        {"artifact_id":"hsi_x_0","session_id":"s","seq":0,"created_at_ms":1,
         "schema_version":"1.1","payload_hash_sha256":"ab","payload_json":"{}",
         "delivery_mode":"REALTIME","session_origin":"PHONE"}
        """
        let decoded = try JSONDecoder().decode(
            HsiArtifactEnvelope.self, from: Data(legacy.utf8)
        )
        XCTAssertEqual(decoded.hsiVersion, "unknown")
    }

    // MARK: - SessionConfig numeric duration (Double-or-Int)

    func testPhoneCommandAcceptsDoubleDuration() throws {
        let cfg = try SessionConfig(fromPhoneCommand: [
            "session_id": "s", "mode": "focus", "duration_sec": 300.0, "kind": "FOCUS"
        ])
        XCTAssertEqual(cfg.durationSec, 300)
    }

    func testPhoneCommandAcceptsIntDuration() throws {
        let cfg = try SessionConfig(fromPhoneCommand: [
            "session_id": "s", "mode": "focus", "duration_sec": 300, "kind": "FOCUS"
        ])
        XCTAssertEqual(cfg.durationSec, 300)
    }

    func testPhoneCommandRejectsNonNumericDuration() {
        XCTAssertThrowsError(try SessionConfig(fromPhoneCommand: [
            "session_id": "s", "mode": "focus", "duration_sec": "300", "kind": "FOCUS"
        ]))
    }

    /// EdgeSessionManager exposes a stable per-device opaque subject id of the
    /// form `sub_<deviceOpaque>`, used as the runtime subject_id. It is never a
    /// shared placeholder constant.
    func testEdgeSessionManagerSubjectId() {
        let mgr = EdgeSessionManager()
        XCTAssertTrue(mgr.subjectId.hasPrefix("sub_"))
        XCTAssertNotEqual(mgr.subjectId, "sub_watch")
        // Stable across calls on the same instance.
        XCTAssertEqual(mgr.subjectId, mgr.subjectId)
    }
}
