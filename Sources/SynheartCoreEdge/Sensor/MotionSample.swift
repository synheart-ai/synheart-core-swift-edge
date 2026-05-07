import Foundation

/// A single accelerometer sample from the watch motion sensor.
struct MotionSample {
    let timestampMs: Int64
    let x: Double  // g-force
    let y: Double
    let z: Double
}
