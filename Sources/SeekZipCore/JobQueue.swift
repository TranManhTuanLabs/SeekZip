import Foundation

/// Free-space queries with an injectable provider so tests can pretend
/// the destination volume is nearly full (M4, SEC-04). The default
/// provider reads the real filesystem; when it returns `nil` (unknown),
/// prechecks do not block the operation.
public enum DiskSpace {
    public static var freeBytesProvider: ((URL) -> UInt64?) = { url in
        (try? FileManager.default.attributesOfFileSystem(
            forPath: url.path))?[.systemFreeSize] as? UInt64
    }

    public static func freeBytes(at url: URL) -> UInt64? {
        freeBytesProvider(url)
    }

    /// Throws `EngineError.insufficientDiskSpace` when the volume
    /// holding `url` cannot hold `needed` bytes. Unknown free space
    /// never blocks.
    public static func require(_ needed: UInt64, at url: URL) throws {
        guard let free = freeBytes(at: url) else { return }
        guard free >= needed else {
            throw EngineError.insufficientDiskSpace(needed: needed,
                                                    available: free)
        }
    }

    /// Total bytes of the files under `urls` (directories walked
    /// recursively). Used to size a create job's output before 7zz
    /// starts; the estimate is conservative (the compressed archive
    /// is usually smaller), so a precheck failure means "definitely
    /// will not fit", not "might not fit".
    public static func totalSize(of urls: [URL]) throws -> UInt64 {
        var total: UInt64 = 0
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
                throw EngineError.failed(exitCode: 2,
                                         message: "source not found: \(url.path)")
            }
            if !isDir.boolValue {
                total += (try fm.attributesOfItem(atPath: url.path))[.size] as? UInt64 ?? 0
                continue
            }
            guard let enumerator = fm.enumerator(at: url,
                                                 includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                 options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in enumerator {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values.isRegularFile == true {
                    total += UInt64(values.fileSize ?? 0)
                }
            }
        }
        return total
    }
}

/// What a queued job does (M4).
public enum JobKind: String, Codable, Sendable {
    case extract
    case create
    case test
}

/// Lifecycle of one job. `interrupted` means the app died (or was
/// killed) while the job was running — it never silently restarts; the
/// user resumes it explicitly. `paused` jobs survive a relaunch as
/// paused and resume (from the start of that job — a `SIGSTOP` cannot
/// survive process death, see `JobQueue.resume`).
public enum JobStatus: String, Codable, Sendable {
    case queued
    case running
    case paused
    case done
    case failed
    case cancelled
    case interrupted
}

/// A job's immutable inputs. Codable so the queue survives an app
/// relaunch (PERF-06). Deliberately has NO password field: passwords
/// are kept in memory only (`JobQueue.enqueue(password:)`) and are
/// never written to the store file — a job that needs one after a
/// relaunch is marked `.interrupted` instead of resumed (M5/Keychain
/// will make this seamless).
public struct JobDescriptor: Codable, Sendable, Identifiable {
    public var id: UUID
    /// Extract/test: the archive. Create: the destination archive.
    public var archive: String
    public var kind: JobKind
    /// Extract destination.
    public var destination: String?
    /// Extract: selected entries (nil = all).
    public var entries: [String]?
    /// Create: source paths.
    public var sources: [String]?
    /// Create: "zip" or "7z".
    public var format: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), kind: JobKind, archive: String,
                destination: String? = nil, entries: [String]? = nil,
                sources: [String]? = nil, format: String? = nil,
                createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.archive = archive
        self.destination = destination
        self.entries = entries
        self.sources = sources
        self.format = format
        self.createdAt = createdAt
    }
}

/// A job plus its mutable state, as persisted in the store file.
public struct JobRecord: Codable, Sendable, Identifiable {
    public var descriptor: JobDescriptor
    public var status: JobStatus
    /// Last reported progress fraction (0...1), if the engine
    /// measured one.
    public var progress: Double?
    /// Last progress message, or the failure/cancel reason.
    public var message: String?
    public var updatedAt: Date

    public var id: UUID { descriptor.id }

    public init(descriptor: JobDescriptor, status: JobStatus = .queued,
                progress: Double? = nil, message: String? = nil,
                updatedAt: Date = Date()) {
        self.descriptor = descriptor
        self.status = status
        self.progress = progress
        self.message = message
        self.updatedAt = updatedAt
    }
}

private struct QueueStore: Codable {
    var version: Int
    var records: [JobRecord]
}

/// A persistent, sequential job queue (M4).
///
/// Jobs run one at a time, in enqueue order — sequential first, because
/// two `7zz` processes hammering the same disk (and the same
/// destination) make each other slower and make free-space estimates
/// unreliable; the queue's value is ordering and unattended batching,
/// not parallelism. Every state change is persisted to `storeURL`
/// (atomic write: temp file + rename), so `queue list` in a new process
/// sees the same jobs. The default store is
/// `~/Library/Application Support/SeekZip/queue.json`.
///
/// Thread safety: the queue itself is lock-guarded; `runAll` runs on
/// the calling thread while `pause`/`resume`/`cancel` may be called
/// from any thread (e.g. a SIGINT handler or the GUI).
public final class JobQueue: @unchecked Sendable {
    public let storeURL: URL
    private let engine: SevenZipEngine
    private let lock = NSLock()
    private var records: [JobRecord] = []
    /// Passwords, in memory only — never persisted (see JobDescriptor).
    private var passwords: [UUID: String] = [:]
    /// Controls of currently running jobs, by id.
    private var controls: [UUID: JobControl] = [:]
    private var runnerActive = false
    /// Last persisted-progress write, per job, so a chatty progress
    /// callback does not rewrite the store file on every percent point.
    private var lastProgressSave: [UUID: Date] = [:]

    public static func defaultStoreURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SeekZip", isDirectory: true)
            .appendingPathComponent("queue.json")
    }

    /// Loads the persisted queue. A corrupt or missing store starts
    /// empty. Jobs that were `.running` when the app died become
    /// `.interrupted` (never silently restarted); `.paused` jobs stay
    /// paused and can be resumed.
    public init(engine: SevenZipEngine, storeURL: URL? = nil) {
        self.engine = engine
        self.storeURL = storeURL ?? Self.defaultStoreURL()
        load()
    }

    // MARK: - Enqueue / inspect

    @discardableResult
    public func enqueue(_ descriptor: JobDescriptor,
                        password: String? = nil) -> JobRecord {
        let record = JobRecord(descriptor: descriptor)
        synchronized {
            records.append(record)
            if let password { passwords[descriptor.id] = password }
            saveLocked()
        }
        return record
    }

    public func jobs() -> [JobRecord] {
        synchronized { records }
    }

    public func record(for id: UUID) -> JobRecord? {
        synchronized { records.first { $0.id == id } }
    }

    /// Finds a job by full UUID or by a unique id prefix (the CLI
    /// accepts the first 8 characters).
    public func record(matching idPrefix: String) -> JobRecord? {
        synchronized {
            let hits = records.filter { $0.id.uuidString.hasPrefix(idPrefix) }
            return hits.count == 1 ? hits[0] : nil
        }
    }

    // MARK: - Pause / resume / cancel

    /// Pauses a job. A running job's `7zz` is suspended with SIGSTOP
    /// (resumable in place); a queued job is marked paused and the
    /// runner skips it until resumed. Returns false when the id is
    /// unknown or the job is already finished.
    @discardableResult
    public func pause(id: UUID) -> Bool {
        synchronized {
            guard let index = records.firstIndex(where: { $0.id == id }),
                  records[index].status == .running
                    || records[index].status == .queued else { return false }
            if records[index].status == .running {
                controls[id]?.pause()
            }
            setStatusLocked(index, .paused, message: "Paused")
            return true
        }
    }

    /// Resumes a paused job. If its process is still alive in this
    /// session (SIGSTOP), it continues in place with SIGCONT; otherwise
    /// (relaunch, or it was paused while queued) it goes back to
    /// `.queued` and restarts from the beginning when the runner
    /// reaches it — 7zz has no mid-archive resume, and restarting an
    /// extract/create is safe (7zz overwrites with `-y`; create goes
    /// through temp staging). Returns false when the id is unknown or
    /// the job is not paused/interrupted.
    @discardableResult
    public func resume(id: UUID) -> Bool {
        synchronized {
            guard let index = records.firstIndex(where: { $0.id == id }) else {
                return false
            }
            switch records[index].status {
            case .paused where controls[id] != nil:
                controls[id]?.resume()
                setStatusLocked(index, .running, message: "Resumed")
                return true
            case .paused, .interrupted:
                setStatusLocked(index, .queued,
                                message: "Resumed — will restart from the beginning")
                return true
            default:
                return false
            }
        }
    }

    /// Cancels a job. A running job's `7zz` is terminated and the job
    /// ends `.cancelled` (any temp output is cleaned up by the
    /// engine); a queued/paused job is marked cancelled immediately.
    /// Returns false when the id is unknown or the job is finished.
    @discardableResult
    public func cancel(id: UUID) -> Bool {
        synchronized {
            guard let index = records.firstIndex(where: { $0.id == id }) else {
                return false
            }
            switch records[index].status {
            case .running:
                controls[id]?.cancel()
                return true // runOne() marks it .cancelled on the throw
            case .queued, .paused, .interrupted:
                setStatusLocked(index, .cancelled, message: "Cancelled")
                passwords[id] = nil
                return true
            default:
                return false
            }
        }
    }

    /// Cancels whatever job is running right now, if any — the SIGINT
    /// (Ctrl-C) path for the CLI.
    public func cancelCurrent() {
        synchronized {
            guard let running = records.first(where: { $0.status == .running }) else {
                return
            }
            controls[running.id]?.cancel()
        }
    }

    // MARK: - Running

    /// Runs queued jobs sequentially until none are left. Safe to call
    /// from several threads: only one runner is active at a time, the
    /// others return immediately. Blocking — run it on a background
    /// thread in the GUI/MCP server.
    public func runAll(onJobProgress: ((JobRecord, JobProgress) -> Void)? = nil) {
        let alreadyRunning = synchronized {
            if runnerActive { return true }
            runnerActive = true
            return false
        }
        guard !alreadyRunning else { return }
        defer { synchronized { runnerActive = false } }

        while let next = synchronized({ records.first { $0.status == .queued } }) {
            runOne(next, onJobProgress: onJobProgress)
        }
    }

    private func runOne(_ record: JobRecord,
                        onJobProgress: ((JobRecord, JobProgress) -> Void)? = nil) {
        let id = record.id
        let control = JobControl()
        synchronized {
            guard let index = records.firstIndex(where: { $0.id == id }),
                  records[index].status == .queued else { return }
            controls[id] = control
            setStatusLocked(index, .running, message: "Running")
        }
        let password = synchronized { passwords[id] }
        let descriptor = record.descriptor
        let archiveURL = URL(fileURLWithPath: descriptor.archive)

        do {
            switch descriptor.kind {
            case .extract:
                guard let dest = descriptor.destination else {
                    throw EngineError.failed(exitCode: 2,
                                             message: "extract job needs a destination")
                }
                try engine.extract(
                    archive: archiveURL,
                    entries: descriptor.entries,
                    to: URL(fileURLWithPath: dest),
                    password: password,
                    control: control,
                    onProgress: { [weak self] progress in
                        self?.reportProgress(id: id, progress: progress,
                                             onJobProgress: onJobProgress)
                    })
            case .create:
                try engine.create(
                    archive: archiveURL,
                    sources: (descriptor.sources ?? []).map { URL(fileURLWithPath: $0) },
                    format: descriptor.format ?? "zip",
                    password: password,
                    control: control,
                    onProgress: { [weak self] progress in
                        self?.reportProgress(id: id, progress: progress,
                                             onJobProgress: onJobProgress)
                    })
            case .test:
                try engine.test(
                    archive: archiveURL,
                    password: password,
                    control: control,
                    onProgress: { [weak self] progress in
                        self?.reportProgress(id: id, progress: progress,
                                             onJobProgress: onJobProgress)
                    })
            }
            synchronized {
                guard let index = records.firstIndex(where: { $0.id == id }) else { return }
                setStatusLocked(index, .done, progress: 1.0, message: "Done")
                passwords[id] = nil
                controls[id] = nil
            }
        } catch let engineError as EngineError {
            // Cancelled (user or SIGINT) is a status of its own, not a
            // failure — and the engine has already cleaned up temp output.
            let cancelled: Bool
            if case .cancelled = engineError { cancelled = true } else { cancelled = false }
            synchronized {
                guard let index = records.firstIndex(where: { $0.id == id }) else { return }
                if cancelled {
                    setStatusLocked(index, .cancelled, message: "Cancelled")
                } else {
                    setStatusLocked(index, .failed,
                                    message: String(describing: engineError))
                }
                passwords[id] = nil
                controls[id] = nil
            }
        } catch {
            synchronized {
                guard let index = records.firstIndex(where: { $0.id == id }) else { return }
                setStatusLocked(index, .failed,
                                message: String(describing: error))
                passwords[id] = nil
                controls[id] = nil
            }
        }
    }

    private func reportProgress(id: UUID, progress: JobProgress,
                                onJobProgress: ((JobRecord, JobProgress) -> Void)?) {
        let (record, shouldSave) = synchronized { () -> (JobRecord?, Bool) in
            guard let index = records.firstIndex(where: { $0.id == id }) else {
                return (nil, false)
            }
            records[index].progress = progress.fraction
            records[index].message = progress.message
            records[index].updatedAt = Date()
            let last = lastProgressSave[id]
            let due = last == nil || Date().timeIntervalSince(last!) >= 1.0
            if due { lastProgressSave[id] = Date() }
            return (records[index], due)
        }
        if shouldSave { synchronized { saveLocked() } }
        if let record { onJobProgress?(record, progress) }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let store = try? JSONDecoder().decode(QueueStore.self, from: data) else {
            records = []
            return
        }
        records = store.records.map { record in
            var record = record
            if record.status == .running {
                record.status = .interrupted
                record.message = "Interrupted by relaunch — resume to retry"
                record.updatedAt = Date()
            }
            return record
        }
        saveLocked()
    }

    /// Atomic write: temp file in the same directory, then rename over
    /// the store — a crash mid-write never leaves a half-written queue.
    private func saveLocked() {
        let store = QueueStore(version: 1, records: records)
        guard let data = try? JSONEncoder().encode(store) else { return }
        let dir = storeURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(
            ".queue-\(UUID().uuidString).tmp")
        do {
            try data.write(to: tmp, options: [.atomic])
            if FileManager.default.fileExists(atPath: storeURL.path) {
                try FileManager.default.removeItem(at: storeURL)
            }
            try FileManager.default.moveItem(at: tmp, to: storeURL)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    private func setStatusLocked(_ index: Int, _ status: JobStatus,
                                 progress: Double? = nil,
                                 message: String? = nil) {
        records[index].status = status
        if let progress { records[index].progress = progress }
        if let message { records[index].message = message }
        records[index].updatedAt = Date()
        saveLocked()
    }

    private func synchronized<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
