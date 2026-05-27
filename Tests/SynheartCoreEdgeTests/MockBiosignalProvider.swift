import Foundation
import SynheartSession

/// No-op `BiosignalProvider` for tests. Does nothing when `startStreaming`
/// is called; never emits samples. Sufficient for state-machine tests that
/// don't depend on real HR data flowing through the engine.
final class MockBiosignalProvider: BiosignalProvider {
    var isAvailable: Bool { true }
    var name: String { "mock" }
    func startStreaming(onSample: @escaping (BiosignalSample) -> Void) throws {}
    func stopStreaming() {}
}
