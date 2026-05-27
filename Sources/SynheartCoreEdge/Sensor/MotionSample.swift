import Foundation

/// A single accelerometer sample from the watch motion sensor.
public struct MotionSample {
    public let timestampMs: Int64
    public let x: Double  // g-force
    public let y: Double
    public let z: Double

    public init(timestampMs: Int64, x: Double, y: Double, z: Double) {
        self.timestampMs = timestampMs
        self.x = x
        self.y = y
        self.z = z
    }
}
