// SPDX-License-Identifier: Apache-2.0
// Copyright (c) Synheart authors

import Foundation

/// Snapshot of one serial runtime read: the tick HSI JSON plus the raw
/// preprocessed + quality JSON, all fetched in a SINGLE critical section on the
/// runtime queue so a concurrent `push*` (e.g. the motion `Task`) can't
/// interleave and tear preprocessed/quality away from the HSI of that frame.
/// Mirrors the Kotlin `RuntimeReadout`.
struct RuntimeReadout {
    let hsiJson: String?
    let preprocessed: String?
    let quality: String?
}

/// Abstraction over the native edge runtime handle. Production uses
/// `RuntimeBridge` (dlsym/FFI); tests inject a fake so the engine's per-
/// `edge_mode` resolution + frame/summary metric contract can be exercised
/// without the native library.
protocol RuntimeHandle: AnyObject {
    func pushRr(tsMs: Int64, rrMs: Double)
    func pushHr(tsMs: Int64, bpm: Double)
    func pushAccel(tsMs: Int64, x: Double, y: Double, z: Double)
    func tick(nowMs: Int64) -> String?
    /// Count of native FFI calls the runtime reported as errored/dropped under
    /// contention (diagnostic). Fakes report 0.
    var droppedFrames: Int64 { get }
    /// Tick + read preprocessed + quality in one critical section so the three
    /// values are consistent with the HSI of the same frame. Default-implemented
    /// for fakes in terms of the discrete calls; the real bridge overrides it
    /// with a single `queue.sync` (see `RuntimeBridge.tickAndReadout`).
    func tickAndReadout(nowMs: Int64) -> RuntimeReadout
    func lastQuality() -> String?
    func lastPreprocessed() -> String?
    func destroy()
}

extension RuntimeHandle {
    /// Default (non-atomic) composition for test fakes. The real `RuntimeBridge`
    /// overrides this to perform all three reads inside one `queue.sync`.
    func tickAndReadout(nowMs: Int64) -> RuntimeReadout {
        RuntimeReadout(
            hsiJson: tick(nowMs: nowMs),
            preprocessed: lastPreprocessed(),
            quality: lastQuality()
        )
    }

    /// Fakes report no dropped frames by default.
    var droppedFrames: Int64 { 0 }
}

/// Bridge to the native edge runtime pipeline via C ABI.
///
/// dlsym-based dynamic loading. When the native library is not linked,
/// `createIfAvailable()` returns nil and the caller falls back gracefully.
///
/// Built from the Synheart native runtime (edge feature) as a static library
/// for the watchOS target.
///
/// ## Thread confinement
/// The native runtime serializes handle access with a `try_lock` and silently
/// DROPS the call on contention. The watch drives a single handle from three
/// threads (HR callback thread, the detached accel `Task`, the frame `Timer`
/// run loop), so every call MUST be funneled through one serial queue. All
/// `push*` / `tick` / `last*` / `frameCount` / `reset` calls here run on the
/// owned `queue`; after each `tick` the runtime's `last_error` is checked and
/// any nonzero code increments `droppedFrames` so contention is observable.
final class RuntimeBridge: RuntimeHandle {
    /// Cleared to nil by `destroy()` so a second `destroy`/`deinit` is a guarded
    /// no-op. Rust's `synheart_core_edge_destroy` is NOT idempotent against an
    /// already-freed pointer (double-free risk), so dropping the reference here
    /// is what makes close idempotent. All handle calls bail when nil.
    private var handle: OpaquePointer?

    /// Dedicated serial queue all handle calls are confined to. Owned by
    /// this bridge instance, so calls for one session never race the handle.
    private let queue: DispatchQueue

    /// Number of FFI calls the native runtime reported as errored/dropped via
    /// `synheart_core_edge_last_error` after a tick (e.g. concurrent-call
    /// rejection). Diagnostic-only; read it to observe contention.
    private var _droppedFrames: Int64 = 0

    struct Config {
        let windowMs: Int64
        let stepMs: Int64
        let subjectId: String
        let sessionId: String
        let behaviorEnabled: Bool
        /// Forwarded to the native runtime as `compute_profile.edge_mode`.
        /// Drives the `session_role` stamped on `meta.synheart.compute` of
        /// every emitted HSI envelope. Defaults to `.canonical`.
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

    private init(handle: OpaquePointer, sessionId: String) {
        self.handle = handle
        self.queue = DispatchQueue(label: "ai.synheart.edge.runtime.\(sessionId)")
    }

    deinit {
        // Route the free through the serial `queue` so it cannot race a handle
        // call still draining on that queue (the native destroy is NOT
        // idempotent — freeing under a concurrent `tick`/`push` is a UAF). Once
        // freed the handle is niled so a later `destroy()` is a guarded no-op.
        queue.sync {
            if let h = handle {
                RuntimeFFI.destroy(h)
                handle = nil
            }
        }
    }

    /// Build the create-config JSON object sent to the native runtime.
    ///
    /// Nested `compute_profile` is read by the native runtime and shapes the
    /// `session_role` stamped on every emitted HSI envelope. Older native
    /// runtimes ignore the extra key, so this is forward-compatible. Factored
    /// out (static, pure) so tests can assert `compute_profile.edge_mode` is
    /// present without a live native library.
    static func buildConfigDict(_ config: Config) -> [String: Any] {
        [
            "window_ms": config.windowMs,
            "step_ms": config.stepMs,
            "subject_id": config.subjectId,
            "session_id": config.sessionId,
            "behavior_enabled": config.behaviorEnabled,
            "compute_profile": ["edge_mode": config.edgeMode.rawValue]
        ]
    }

    /// Create a RuntimeBridge if the native library is available, otherwise nil.
    static func createIfAvailable(config: Config) -> RuntimeBridge? {
        guard RuntimeFFI.isAvailable else { return nil }

        let configJson = buildConfigDict(config)

        guard let jsonData = try? JSONSerialization.data(withJSONObject: configJson),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return nil
        }

        guard let ptr = jsonString.withCString({ cStr in
            RuntimeFFI.create(cStr)
        }) else {
            return nil
        }

        return RuntimeBridge(handle: ptr, sessionId: config.sessionId)
    }

    // MARK: - Diagnostics

    /// Count of native FFI calls reported as errored/dropped (contention).
    var droppedFrames: Int64 {
        queue.sync { _droppedFrames }
    }

    // MARK: - Push API

    func pushRr(tsMs: Int64, rrMs: Double) {
        queue.sync {
            guard let h = handle else { return }
            RuntimeFFI.pushRr(h, tsMs, rrMs)
        }
    }

    func pushHr(tsMs: Int64, bpm: Double) {
        queue.sync {
            guard let h = handle else { return }
            RuntimeFFI.pushHr(h, tsMs, bpm)
        }
    }

    func pushAccel(tsMs: Int64, x: Double, y: Double, z: Double) {
        queue.sync {
            guard let h = handle else { return }
            RuntimeFFI.pushAccel(h, tsMs, x, y, z)
        }
    }

    // MARK: - Query API

    func tick(nowMs: Int64) -> String? {
        queue.sync {
            guard let h = handle else { return nil }
            let result: String?
            if let ptr = RuntimeFFI.tick(h, nowMs) {
                result = String(cString: ptr)
                RuntimeFFI.freeString(ptr)
            } else {
                result = nil
            }
            // Surface contention: nonzero last_error means a call lost the
            // native try_lock (or otherwise failed) and was dropped.
            let err = RuntimeFFI.lastError(h)
            if err != 0 {
                _droppedFrames += 1
                NSLog("[RuntimeBridge] tick reported last_error=\(err) (dropped=\(_droppedFrames))")
            }
            return result
        }
    }

    /// Tick + read preprocessed + quality in ONE `queue.sync` so the three
    /// values are a consistent snapshot of the same frame. Doing the reads in
    /// separate critical sections (as `tick` + `lastPreprocessed` +
    /// `lastQuality` would) lets a concurrent push on this serial queue
    /// interleave and tear the readout. `last_error` is checked here too so a
    /// dropped frame is still observed. Mirrors Kotlin's `RuntimeReadout` path.
    func tickAndReadout(nowMs: Int64) -> RuntimeReadout {
        queue.sync {
            guard let h = handle else {
                return RuntimeReadout(hsiJson: nil, preprocessed: nil, quality: nil)
            }
            let hsi: String?
            if let ptr = RuntimeFFI.tick(h, nowMs) {
                hsi = String(cString: ptr)
                RuntimeFFI.freeString(ptr)
            } else {
                hsi = nil
            }
            // Surface contention: nonzero last_error means a call lost the
            // native try_lock (or otherwise failed) and was dropped.
            let err = RuntimeFFI.lastError(h)
            if err != 0 {
                _droppedFrames += 1
                NSLog("[RuntimeBridge] tick reported last_error=\(err) (dropped=\(_droppedFrames))")
            }
            let pre: String?
            if let ptr = RuntimeFFI.lastPreprocessed(h) {
                pre = String(cString: ptr)
                RuntimeFFI.freeString(ptr)
            } else {
                pre = nil
            }
            let qual: String?
            if let ptr = RuntimeFFI.lastQuality(h) {
                qual = String(cString: ptr)
                RuntimeFFI.freeString(ptr)
            } else {
                qual = nil
            }
            return RuntimeReadout(hsiJson: hsi, preprocessed: pre, quality: qual)
        }
    }

    func lastQuality() -> String? {
        queue.sync {
            guard let h = handle else { return nil }
            guard let ptr = RuntimeFFI.lastQuality(h) else { return nil }
            let result = String(cString: ptr)
            RuntimeFFI.freeString(ptr)
            return result
        }
    }

    func lastPreprocessed() -> String? {
        queue.sync {
            guard let h = handle else { return nil }
            guard let ptr = RuntimeFFI.lastPreprocessed(h) else { return nil }
            let result = String(cString: ptr)
            RuntimeFFI.freeString(ptr)
            return result
        }
    }

    func frameCount() -> Int64 {
        queue.sync {
            guard let h = handle else { return 0 }
            return RuntimeFFI.frameCount(h)
        }
    }

    func reset() {
        queue.sync {
            guard let h = handle else { return }
            RuntimeFFI.reset(h)
        }
    }

    /// Destroy the native handle. Idempotent: a second call is a guarded no-op
    /// (the stored handle is niled after the first free), so double-destroy is
    /// safe and cannot double-free.
    func destroy() {
        queue.sync {
            guard let h = handle else { return }
            RuntimeFFI.destroy(h)
            handle = nil
        }
    }

    /// Alias for `destroy()` to match the Kotlin `RuntimeHandle.close()` name.
    func close() {
        destroy()
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
    private typealias FrameCountFn     = @convention(c) (OpaquePointer?) -> Int64
    private typealias LastErrorFn      = @convention(c) (OpaquePointer?) -> Int32
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

    private static let _lastError: LastErrorFn? = {
        guard let sym = dlsym(handle, "synheart_core_edge_last_error") else { return nil }
        return unsafeBitCast(sym, to: LastErrorFn.self)
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
    static func frameCount(_ h: OpaquePointer?) -> Int64 { _frameCount?(h) ?? 0 }
    /// Last error code on the handle (0 = OK, nonzero = error such as a
    /// concurrent-call rejection). 0 when the symbol isn't linked.
    static func lastError(_ h: OpaquePointer?) -> Int32 { _lastError?(h) ?? 0 }
    static func reset(_ h: OpaquePointer?) { _reset?(h) }
    static func freeString(_ ptr: UnsafeMutablePointer<CChar>?) { _freeString?(ptr) }
    static func version() -> UnsafeMutablePointer<CChar>? { _version?() }
}
