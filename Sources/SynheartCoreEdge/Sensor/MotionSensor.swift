// SPDX-License-Identifier: Apache-2.0
// Copyright (c) Synheart authors

import Foundation

#if canImport(CoreMotion) && !os(macOS)
import CoreMotion

/// Streams accelerometer data at ~25 Hz via CMMotionManager.
public final class MotionSensor {

    private let motionManager = CMMotionManager()
    private let queue = OperationQueue()
    private var continuation: AsyncThrowingStream<MotionSample, Error>.Continuation?

    /// Epoch (ms) corresponding to device boot, used to convert a
    /// `CMAccelerometerData.timestamp` (seconds since boot, NOT wall-clock) into
    /// epoch-ms so the accel timeline aligns with HR/RR samples. Captured once at
    /// stream start: `bootEpoch = now − systemUptime`. CoreMotion timestamps are
    /// monotonic device-uptime, so adding the sample's `timestamp` reconstructs
    /// the actual capture instant rather than the (later, jittery) delivery time.
    private var bootEpochMs: Double = 0

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

            // Anchor device-uptime timestamps to wall-clock once at stream start.
            self.bootEpochMs = (Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime) * 1000

            self.motionManager.startAccelerometerUpdates(to: self.queue) { [weak self] data, error in
                guard let self = self else { return }
                if let error = error {
                    continuation.finish(throwing: error)
                    return
                }
                guard let data = data else { return }

                // Use the SAMPLE's CoreMotion timestamp (device-uptime seconds),
                // not Date() at delivery, so accel aligns with the HR/RR timeline.
                let tsMs = Int64((self.bootEpochMs + data.timestamp * 1000).rounded())
                let sample = MotionSample(
                    timestampMs: tsMs,
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
