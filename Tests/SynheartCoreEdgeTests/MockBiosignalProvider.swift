// SPDX-License-Identifier: Apache-2.0
// Copyright (c) Synheart authors

import Foundation
import SynheartSession

/// Test `BiosignalProvider`. By default it does nothing on `startStreaming`
/// (sufficient for state-machine tests that don't depend on real HR data). It
/// also captures the `onSample` callback so tests that need to verify
/// per-`edge_mode` raw-sample relay can push a synthetic sample on demand.
final class MockBiosignalProvider: BiosignalProvider {
    var isAvailable: Bool { true }
    var name: String { "mock" }

    /// The most recent `onSample` callback handed to `startStreaming`, so tests
    /// can drive a sample through the engine deterministically.
    private(set) var onSample: ((BiosignalSample) -> Void)?

    func startStreaming(onSample: @escaping (BiosignalSample) -> Void) throws {
        self.onSample = onSample
    }

    func stopStreaming() {
        onSample = nil
    }

    /// Emit a synthetic sample through the captured callback.
    func emit(_ sample: BiosignalSample) {
        onSample?(sample)
    }
}
