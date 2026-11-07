import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Progress reported by a running job (M4). `fraction` is 0...1 when the
/// engine can measure it (`7zz -bsp1` percent), `nil` when it cannot —
/// callers must not treat `nil` as 0.
public struct JobProgress: Sendable {
    public var fraction: Double?
    public var message: String

    public init(fraction: Double? = nil, message: String) {
        self.fraction = fraction
        self.message = message
    }
}

/// A handle for pausing, resuming and cancelling a running `7zz`
/// subprocess (M4). One instance is attached to one engine call; the
/// queue owns one per running job.
///
/// Pause is a real process suspension (`SIGSTOP`/`SIGCONT` on the child
/// pid), not a cooperative check — a `7zz` mid-archive stops writing
/// immediately and continues exactly where it left off. Cancel sends
/// `SIGTERM` (`Process.terminate()`); the engine then throws
/// `EngineError.cancelled` and cleans up any temp output.
public final class JobControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var _cancelled = false
    private var _paused = false

    public init() {}

    public var isCancelled: Bool { synchronized { _cancelled } }
    public var isPaused: Bool { synchronized { _paused } }

    /// Terminates the attached process (if any) and marks the job
    /// cancelled. Safe to call before any process is attached: the
    /// process is terminated as soon as it is attached.
    public func cancel() {
        let proc: Process? = synchronized {
            _cancelled = true
            return process
        }
        proc?.terminate()
    }

    /// Suspends the attached process with `SIGSTOP`. Safe to call
    /// before a process is attached: the process is stopped as soon as
    /// it is attached.
    public func pause() {
        let pid: Int32? = synchronized {
            _paused = true
            return process?.processIdentifier
        }
        if let pid { kill(pid, SIGSTOP) }
    }

    /// Resumes a process suspended by `pause()` with `SIGCONT`.
    public func resume() {
        let pid: Int32? = synchronized {
            _paused = false
            return process?.processIdentifier
        }
        if let pid { kill(pid, SIGCONT) }
    }

    /// Called by the engine when a subprocess starts. Applies any
    /// cancel/pause that was requested before the process existed.
    func attach(_ process: Process) {
        let (shouldTerminate, shouldStop) = synchronized {
            self.process = process
            return (_cancelled, _paused)
        }
        if shouldTerminate { process.terminate() }
        if shouldStop { kill(process.processIdentifier, SIGSTOP) }
    }

    func detach() {
        synchronized { process = nil }
    }

    private func synchronized<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
