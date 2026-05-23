import Foundation

/// Bridge to the synheart-core-runtime edge pipeline via C ABI.
///
/// dlsym-based dynamic loading. When the native library is not linked,
/// `createIfAvailable()` returns nil and the caller falls back gracefully.
///
/// Build the static library with:
///   cargo +nightly build --release --target aarch64-apple-watchos \
///     -p synheart-core-runtime --features edge
final class RuntimeBridge {
    private var handle: OpaquePointer?

    struct Config {
        let windowMs: Int64
        let stepMs: Int64
        let subjectId: String
        let sessionId: String
        let behaviorEnabled: Bool
        /// Forwarded to the native runtime as `compute_profile.edge_mode`
        /// (edge-tiering RFC §3.2). Drives the `session_role` stamped on
        /// `meta.synheart.compute` of every emitted HSI envelope.
        let edgeMode: EdgeMode

        init(
            windowMs: Int64 = 60_000,
            stepMs: Int64 = 5_000,
            subjectId: String,
            sessionId: String,
            behaviorEnabled: Bool = false,
            edgeMode: EdgeMode = .canonical
        ) {
            self.windowMs = windowMs
            self.stepMs = stepMs
            self.subjectId = subjectId
            self.sessionId = sessionId
            self.behaviorEnabled = behaviorEnabled
            self.edgeMode = edgeMode
        }
    }

    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        if let h = handle {
            RuntimeFFI.destroy(h)
        }
    }

    /// Create a RuntimeBridge if the native library is available, otherwise nil.
    static func createIfAvailable(config: Config) -> RuntimeBridge? {
        guard RuntimeFFI.isAvailable else { return nil }

        // Nested `compute_profile` is read by core-runtime/SynheartConfig
        // (edge-tiering RFC §3.2) and shapes the `session_role` stamped on
        // every emitted HSI envelope. Pre-RFC native runtimes ignore the
        // extra key, so this is forward-compatible.
        let configJson: [String: Any] = [
            "window_ms": config.windowMs,
            "step_ms": config.stepMs,
            "subject_id": config.subjectId,
            "session_id": config.sessionId,
            "behavior_enabled": config.behaviorEnabled,
            "compute_profile": [
                "edge_mode": config.edgeMode.wireValue
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: configJson),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return nil
        }

        guard let ptr = jsonString.withCString({ cStr in
            RuntimeFFI.create(cStr)
        }) else {
            return nil
        }

        return RuntimeBridge(handle: ptr)
    }

    // MARK: - Push API

    func pushRr(tsMs: Int64, rrMs: Double) {
        guard let h = handle else { return }
        RuntimeFFI.pushRr(h, tsMs, rrMs)
    }

    func pushHr(tsMs: Int64, bpm: Double) {
        guard let h = handle else { return }
        RuntimeFFI.pushHr(h, tsMs, bpm)
    }

    func pushAccel(tsMs: Int64, x: Double, y: Double, z: Double) {
        guard let h = handle else { return }
        RuntimeFFI.pushAccel(h, tsMs, x, y, z)
    }

    // MARK: - Query API

    func tick(nowMs: Int64) -> String? {
        guard let h = handle else { return nil }
        guard let ptr = RuntimeFFI.tick(h, nowMs) else { return nil }
        let result = String(cString: ptr)
        RuntimeFFI.freeString(ptr)
        return result
    }

    func lastQuality() -> String? {
        guard let h = handle else { return nil }
        guard let ptr = RuntimeFFI.lastQuality(h) else { return nil }
        let result = String(cString: ptr)
        RuntimeFFI.freeString(ptr)
        return result
    }

    func lastPreprocessed() -> String? {
        guard let h = handle else { return nil }
        guard let ptr = RuntimeFFI.lastPreprocessed(h) else { return nil }
        let result = String(cString: ptr)
        RuntimeFFI.freeString(ptr)
        return result
    }

    func frameCount() -> UInt64 {
        guard let h = handle else { return 0 }
        return RuntimeFFI.frameCount(h)
    }

    func reset() {
        guard let h = handle else { return }
        RuntimeFFI.reset(h)
    }

    static func version() -> String? {
        guard RuntimeFFI.isAvailable else { return nil }
        guard let ptr = RuntimeFFI.version() else { return nil }
        let result = String(cString: ptr)
        RuntimeFFI.freeString(ptr)
        return result
    }
}

// MARK: - Dynamic FFI Loading

/// Dynamically resolves synheart_core_edge_* symbols at runtime via dlsym.
/// If the library isn't linked, all function pointers are nil and `isAvailable` is false.
private enum RuntimeFFI {
    private typealias CreateFn         = @convention(c) (UnsafePointer<CChar>?) -> OpaquePointer?
    private typealias DestroyFn        = @convention(c) (OpaquePointer?) -> Void
    private typealias PushRrFn         = @convention(c) (OpaquePointer?, Int64, Double) -> Void
    private typealias PushHrFn         = @convention(c) (OpaquePointer?, Int64, Double) -> Void
    private typealias PushAccelFn      = @convention(c) (OpaquePointer?, Int64, Double, Double, Double) -> Void
    private typealias TickFn           = @convention(c) (OpaquePointer?, Int64) -> UnsafeMutablePointer<CChar>?
    private typealias JsonQueryFn      = @convention(c) (OpaquePointer?) -> UnsafeMutablePointer<CChar>?
    private typealias FrameCountFn     = @convention(c) (OpaquePointer?) -> UInt64
    private typealias ResetFn          = @convention(c) (OpaquePointer?) -> Void
    private typealias FreeStringFn     = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    private typealias VersionFn        = @convention(c) () -> UnsafeMutablePointer<CChar>?

    private static let handle: UnsafeMutableRawPointer? = UnsafeMutableRawPointer(bitPattern: -2)

    private static let _create: CreateFn? = {
        guard let sym = dlsym(handle, "synheart_core_edge_create") else { return nil }
        return unsafeBitCast(sym, to: CreateFn.self)
    }()

    private static let _destroy: DestroyFn? = {
        guard let sym = dlsym(handle, "synheart_core_edge_destroy") else { return nil }
        return unsafeBitCast(sym, to: DestroyFn.self)
    }()

    private static let _pushRr: PushRrFn? = {
        guard let sym = dlsym(handle, "synheart_core_edge_push_rr") else { return nil }
        return unsafeBitCast(sym, to: PushRrFn.self)
    }()

    private static let _pushHr: PushHrFn? = {
        guard let sym = dlsym(handle, "synheart_core_edge_push_hr") else { return nil }
        return unsafeBitCast(sym, to: PushHrFn.self)
    }()

    private static let _pushAccel: PushAccelFn? = {
        guard let sym = dlsym(handle, "synheart_core_edge_push_accel") else { return nil }
        return unsafeBitCast(sym, to: PushAccelFn.self)
    }()

    private static let _tick: TickFn? = {
        guard let sym = dlsym(handle, "synheart_core_edge_tick") else { return nil }
        return unsafeBitCast(sym, to: TickFn.self)
    }()

    private static let _lastQuality: JsonQueryFn? = {
        guard let sym = dlsym(handle, "synheart_core_edge_last_quality") else { return nil }
        return unsafeBitCast(sym, to: JsonQueryFn.self)
    }()

    private static let _lastPreprocessed: JsonQueryFn? = {
        guard let sym = dlsym(handle, "synheart_core_edge_last_preprocessed") else { return nil }
        return unsafeBitCast(sym, to: JsonQueryFn.self)
    }()

    private static let _frameCount: FrameCountFn? = {
        guard let sym = dlsym(handle, "synheart_core_edge_frame_count") else { return nil }
        return unsafeBitCast(sym, to: FrameCountFn.self)
    }()

    private static let _reset: ResetFn? = {
        guard let sym = dlsym(handle, "synheart_core_edge_reset") else { return nil }
        return unsafeBitCast(sym, to: ResetFn.self)
    }()

    private static let _freeString: FreeStringFn? = {
        guard let sym = dlsym(handle, "synheart_core_edge_free_string") else { return nil }
        return unsafeBitCast(sym, to: FreeStringFn.self)
    }()

    private static let _version: VersionFn? = {
        guard let sym = dlsym(handle, "synheart_core_edge_version") else { return nil }
        return unsafeBitCast(sym, to: VersionFn.self)
    }()

    static var isAvailable: Bool { _create != nil }

    static func create(_ configJson: UnsafePointer<CChar>?) -> OpaquePointer? { _create?(configJson) }
    static func destroy(_ h: OpaquePointer?) { _destroy?(h) }
    static func pushRr(_ h: OpaquePointer?, _ ts: Int64, _ rr: Double) { _pushRr?(h, ts, rr) }
    static func pushHr(_ h: OpaquePointer?, _ ts: Int64, _ bpm: Double) { _pushHr?(h, ts, bpm) }
    static func pushAccel(_ h: OpaquePointer?, _ ts: Int64, _ x: Double, _ y: Double, _ z: Double) { _pushAccel?(h, ts, x, y, z) }
    static func tick(_ h: OpaquePointer?, _ nowMs: Int64) -> UnsafeMutablePointer<CChar>? { _tick?(h, nowMs) }
    static func lastQuality(_ h: OpaquePointer?) -> UnsafeMutablePointer<CChar>? { _lastQuality?(h) }
    static func lastPreprocessed(_ h: OpaquePointer?) -> UnsafeMutablePointer<CChar>? { _lastPreprocessed?(h) }
    static func frameCount(_ h: OpaquePointer?) -> UInt64 { _frameCount?(h) ?? 0 }
    static func reset(_ h: OpaquePointer?) { _reset?(h) }
    static func freeString(_ ptr: UnsafeMutablePointer<CChar>?) { _freeString?(ptr) }
    static func version() -> UnsafeMutablePointer<CChar>? { _version?() }
}
