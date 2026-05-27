import Foundation

#if canImport(CoreMotion) && !os(macOS)
import CoreMotion

/// Streams accelerometer data at ~25 Hz via CMMotionManager.
public final class MotionSensor {

    private let motionManager = CMMotionManager()
    private let queue = OperationQueue()
    private var continuation: AsyncThrowingStream<MotionSample, Error>.Continuation?

    public init() {}

    /// Whether the device has an accelerometer.
    public var isAvailable: Bool {
        motionManager.isAccelerometerAvailable
    }

    /// Start streaming accelerometer samples as an AsyncThrowingStream.
    public func startStreaming() -> AsyncThrowingStream<MotionSample, Error> {
        return AsyncThrowingStream { [weak self] continuation in
            guard let self = self else {
                continuation.finish()
                return
            }
            guard self.isAvailable else {
                continuation.finish()
                return
            }

            self.continuation = continuation
            self.queue.name = "ai.synheart.motion"
            self.queue.maxConcurrentOperationCount = 1

            self.motionManager.accelerometerUpdateInterval = 1.0 / 25.0  // 25 Hz

            self.motionManager.startAccelerometerUpdates(to: self.queue) { data, error in
                if let error = error {
                    continuation.finish(throwing: error)
                    return
                }
                guard let data = data else { return }

                let sample = MotionSample(
                    timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
                    x: data.acceleration.x,  // already in g-force
                    y: data.acceleration.y,
                    z: data.acceleration.z
                )
                continuation.yield(sample)
            }

            continuation.onTermination = { @Sendable _ in
                Task { @MainActor [weak self] in
                    self?.stopStreaming()
                }
            }
        }
    }

    /// Stop accelerometer updates.
    public func stopStreaming() {
        motionManager.stopAccelerometerUpdates()
        continuation?.finish()
        continuation = nil
    }
}

#else

/// Stub for platforms without CoreMotion (e.g. macOS host running tests).
/// All operations are no-ops; `isAvailable` is always `false`.
public final class MotionSensor {
    public init() {}
    public var isAvailable: Bool { false }
    public func startStreaming() -> AsyncThrowingStream<MotionSample, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }
    public func stopStreaming() { }
}

#endif
