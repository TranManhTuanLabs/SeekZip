import Foundation
import SeekZipCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// seekzip — command-line frontend for SeekZipCore.
// Exit codes: 0 ok · 2 usage · 3 engine error · 4 safety-blocked · 5 password

let rawArgs = Array(CommandLine.arguments.dropFirst())
let json = rawArgs.contains("--json")
let stream = rawArgs.contains("--stream")
let sha256Flag = rawArgs.contains("--sha256")

/// Password for this invocation, from the environment (M5). The CLI
/// never accepts a password as an argument — it would show in the
/// process list. `SEEKZIP_PASSWORD` is the non-interactive channel;
/// otherwise the engine falls back to the stored password (Keychain
/// on macOS) via `resolvePassword`.
let envPassword = ProcessInfo.processInfo.environment["SEEKZIP_PASSWORD"]
    .flatMap { $0.isEmpty ? nil : $0 }

/// Parses flags out of the arguments. `--format` and `--into` take a
/// value; `--json`, `--stream` and `--sha256` do not. Everything else
/// is positional, in order.
var formatFlag: String?
var intoFlag: String?
var positional: [String] = []
do {
    var i = rawArgs.startIndex
    while i < rawArgs.endIndex {
        let a = rawArgs[i]
        if a == "--format", rawArgs.index(after: i) < rawArgs.endIndex {
            formatFlag = rawArgs[rawArgs.index(after: i)]
            i = rawArgs.index(after: rawArgs.index(after: i))
        } else if a == "--into", rawArgs.index(after: i) < rawArgs.endIndex {
            intoFlag = rawArgs[rawArgs.index(after: i)]
            i = rawArgs.index(after: rawArgs.index(after: i))
        } else if a.hasPrefix("--") {
            i = rawArgs.index(after: i)
        } else {
            positional.append(a)
            i = rawArgs.index(after: i)
        }
    }
}

/// Ctrl-C handling (M4). SIGINT is ignored by the process and delivered
/// to a DispatchSource on a background queue, which cancels the running
/// job (or the direct command's engine call). The source must be
/// retained, and the handler runs off the main thread so it fires while
/// the main thread blocks reading the `7zz` pipe — that is the gap M2
/// left open (the child 7zz used to outlive a Ctrl-C).
final class InterruptHandler {
    private var source: DispatchSourceSignal?
    var onInterrupt: () -> Void = {}

    init() {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(
            signal: SIGINT, queue: DispatchQueue.global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            FileHandle.standardError.write(
                "seekzip: interrupted — cancelling\n".data(using: .utf8)!)
            self?.onInterrupt()
        }
        source.resume()
        self.source = source
    }
}

let interrupt = InterruptHandler()
/// The control for direct (non-queue) commands; SIGINT cancels it.
let directControl = JobControl()
interrupt.onInterrupt = { directControl.cancel() }

func emitJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    if let data = try? encoder.encode(value),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}

func fail(_ code: Int32, _ message: String) -> Never {
    if json || stream { emitJSON(["error": message]) } else { FileHandle.standardError.write("seekzip: \(message)\n".data(using: .utf8)!) }
    exit(code)
}

func printUsage() {
    print("usage: seekzip <list|test|extract|create|preview|queue|add|remove|rename|convert|verify|checksums|password> [--json|--stream] <archive> [args…]")
    print("  list <archive> [nested-entry…]   list an archive, or an archive inside it")
    print("  preview <archive> <entry>        preview one entry (text inline, else Quick Look)")
    print("  preview <archive> <a!/b!/entry>  preview an entry inside nested archives")
    print("  queue add extract <archive> <dest> [entries…]")
    print("  queue add create <archive> <sources…> [--format zip|7z]")
    print("  queue add test <archive>         enqueue a job (it does not run yet)")
    print("  queue list [--json]              show persisted jobs")
    print("  queue pause|resume|cancel <id>   id may be a unique prefix")
    print("  queue run [--json]               run queued jobs in order (Ctrl-C cancels the running job)")
    print("  add <archive> <sources…> [--into <prefix>]   add files to a ZIP/7z/TAR archive")
    print("  remove <archive> <entries…>      remove entries from a ZIP/7z/TAR archive")
    print("  rename <archive> <old> <new> [<old2> <new2>…]   rename entries (ZIP/7z only)")
    print("  convert <archive> <destination> [--format zip|7z|tar]   convert between formats")
    print("  verify <archive> [entries…] [--sha256]   per-entry CRC check (exit 3 on mismatch)")
    print("  checksums <archive>              CRC-32 of every entry, from the listing")
    print("  password store <archive>         store the archive password (Keychain on macOS)")
    print("  password forget <archive>        forget the stored password")
    print("Passwords: SEEKZIP_PASSWORD env var, else the stored password (Keychain on macOS).")
    print("Never pass a password as an argument — it would show in the process list.")
}

guard let command = positional.first else {
    printUsage()
    exit(2)
}

func printListing(_ info: ArchiveInfo) {
    if json { emitJSON(info) }
    else {
        for e in info.entries {
            print("\(e.isDirectory ? "d" : "-") \(String(format: "%12d", e.size))  \(e.path)")
        }
        print("\(info.entries.count) entries, \(info.totalUncompressed) bytes uncompressed")
    }
}

func printPreview(_ preview: EntryPreview) {
    if json { emitJSON(preview) }
    else if let text = preview.text {
        print(text)
        if preview.truncated {
            FileHandle.standardError.write(
                "seekzip: preview truncated — \(preview.linesShown) lines shown\n".data(using: .utf8)!)
        }
    } else {
        print("\(preview.entryPath) — \(preview.kind.rawValue), \(preview.size) bytes")
        if let note = preview.note { print(note) }
    }
}

/// Short display id for a job (first 8 characters of its UUID).
func shortID(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

func printJobs(_ jobs: [JobRecord]) {
    if json {
        emitJSON(jobs)
        return
    }
    if jobs.isEmpty { print("queue is empty"); return }
    for job in jobs {
        let pct = job.progress.map { String(format: " %3.0f%%", $0 * 100) } ?? ""
        let msg = job.message.map { " — \($0)" } ?? ""
        print("\(shortID(job.id)) \(job.descriptor.kind.rawValue) \(job.status.rawValue)\(pct) \(job.descriptor.archive)\(msg)")
    }
}

do {
    let engine = try SevenZipEngine()
    switch command {
    case "list":
        guard positional.count >= 2 else { fail(2, "list needs an archive path") }
        let url = URL(fileURLWithPath: positional[1])
        // M3: extra positionals are a nested path chain, one entry per
        // level — `list outer.zip inner.zip deep.zip` lists deep.zip.
        if positional.count > 2 {
            let nested = Array(positional[2...])
            let info = try engine.listNested(archive: url, nestedPath: nested,
                                             password: envPassword)
            if stream {
                // The nested archive lives in a temp dir that is gone
                // by the time listNested returns, so streaming here is
                // JSON lines from the collected listing, not incremental.
                for entry in info.entries { emitJSON(entry) }
                FileHandle.standardError.write("seekzip: \(info.entries.count) entries, \(info.totalUncompressed) bytes uncompressed\n".data(using: .utf8)!)
            } else {
                printListing(info)
            }
            break
        }
        if stream {
            // M2: one JSON object per entry, printed as it arrives; the
            // summary goes to stderr so stdout stays pure JSON lines.
            // If 7zz fails after some entries were printed, the exit
            // code still reports the failure — treat a non-zero exit
            // as an incomplete listing.
            let info = try engine.listStreaming(archive: url, password: envPassword,
                                                control: directControl) { entry in
                emitJSON(entry)
                return true
            }
            FileHandle.standardError.write("seekzip: \(info.entries.count) entries, \(info.totalUncompressed) bytes uncompressed\n".data(using: .utf8)!)
            break
        }
        let info = try engine.list(archive: url, password: envPassword,
                                   control: directControl)
        printListing(info)
    case "preview":
        guard positional.count >= 3 else { fail(2, "preview needs <archive> <entry>") }
        let archiveURL = URL(fileURLWithPath: positional[1])
        let entryPath = positional[2]
        let provider = PreviewProvider(engine: engine)
        if entryPath.contains("!/") {
            // M3 nested preview: "inner.zip!/deep.zip!/file.txt".
            let parts = entryPath.split(separator: "!/").map(String.init)
            guard parts.count >= 2 else { fail(2, "preview needs <archive> <entry>") }
            let nested = Array(parts.dropLast())
            let leaf = parts.last!
            let info = try engine.listNested(archive: archiveURL, nestedPath: nested,
                                             password: envPassword)
            guard let entry = info.entries.first(where: { $0.path == leaf }) else {
                fail(3, "entry not found: \(entryPath)")
            }
            printPreview(try provider.previewNested(archive: archiveURL,
                                                    nestedPath: nested, entry: entry,
                                                    password: envPassword))
            break
        }
        let info = try engine.list(archive: archiveURL, password: envPassword,
                                   control: directControl)
        guard let entry = info.entries.first(where: { $0.path == entryPath }) else {
            fail(3, "entry not found: \(entryPath)")
        }
        printPreview(try provider.preview(archive: archiveURL, entry: entry,
                                          password: envPassword))
    case "test":
        guard positional.count >= 2 else { fail(2, "test needs an archive path") }
        try engine.test(archive: URL(fileURLWithPath: positional[1]),
                        password: envPassword, control: directControl)
        print(json ? "{\"ok\":true}" : "Everything is Ok")
    case "extract":
        guard positional.count >= 3 else { fail(2, "extract needs <archive> <destination> [entry…]") }
        let entries = positional.count > 3 ? Array(positional[3...]) : nil
        try engine.extract(archive: URL(fileURLWithPath: positional[1]),
                           entries: entries,
                           to: URL(fileURLWithPath: positional[2]),
                           password: envPassword, control: directControl)
        print(json ? "{\"ok\":true}" : "Extracted")
    case "create":
        guard positional.count >= 3 else { fail(2, "create needs <archive> <source…>") }
        try engine.create(archive: URL(fileURLWithPath: positional[1]),
                          sources: positional[2...].map { URL(fileURLWithPath: $0) },
                          format: formatFlag ?? "zip", password: envPassword,
                          control: directControl)
        print(json ? "{\"ok\":true}" : "Created")
    case "add":
        guard positional.count >= 3 else { fail(2, "add needs <archive> <sources…>") }
        try engine.addEntries(archive: URL(fileURLWithPath: positional[1]),
                              sources: positional[2...].map { URL(fileURLWithPath: $0) },
                              prefix: intoFlag, password: envPassword,
                              control: directControl)
        print(json ? "{\"ok\":true}" : "Added")
    case "remove":
        guard positional.count >= 3 else { fail(2, "remove needs <archive> <entries…>") }
        try engine.removeEntries(archive: URL(fileURLWithPath: positional[1]),
                                 entries: Array(positional[2...]),
                                 password: envPassword, control: directControl)
        print(json ? "{\"ok\":true}" : "Removed")
    case "rename":
        guard positional.count >= 4, (positional.count - 2).isMultiple(of: 2) else {
            fail(2, "rename needs <archive> <old> <new> [<old2> <new2>…]")
        }
        var pairs: [(old: String, new: String)] = []
        var i = 2
        while i + 1 < positional.count {
            pairs.append((old: positional[i], new: positional[i + 1]))
            i += 2
        }
        try engine.renameEntries(archive: URL(fileURLWithPath: positional[1]),
                                 renames: pairs, password: envPassword,
                                 control: directControl)
        print(json ? "{\"ok\":true}" : "Renamed")
    case "convert":
        guard positional.count >= 3 else { fail(2, "convert needs <archive> <destination>") }
        try engine.convert(archive: URL(fileURLWithPath: positional[1]),
                           to: URL(fileURLWithPath: positional[2]),
                           targetFormat: formatFlag, password: envPassword,
                           control: directControl)
        print(json ? "{\"ok\":true}" : "Converted")
    case "verify":
        guard positional.count >= 2 else { fail(2, "verify needs <archive> [entries…]") }
        let results = try engine.verify(
            archive: URL(fileURLWithPath: positional[1]),
            entries: positional.count > 2 ? Array(positional[2...]) : nil,
            includeSHA256: sha256Flag, password: envPassword,
            control: directControl)
        if json {
            emitJSON(results)
        } else {
            for r in results {
                let crc = r.expectedCRC.map { "expected \($0), got \(r.actualCRC ?? "?")" } ?? "no listing CRC"
                print("\(r.status.rawValue)  \(r.entryPath)  (\(crc))\(r.message.map { " — \($0)" } ?? "")")
            }
            let bad = results.filter { $0.status == .mismatch || $0.status == .error }.count
            print("\(results.count - bad)/\(results.count) entries verified")
        }
        if results.contains(where: { $0.status == .mismatch || $0.status == .error }) {
            fail(3, "verification failed for one or more entries")
        }
    case "checksums":
        guard positional.count >= 2 else { fail(2, "checksums needs an archive path") }
        let checksums = try engine.entryChecksums(
            archive: URL(fileURLWithPath: positional[1]),
            password: envPassword, control: directControl)
        if json {
            emitJSON(checksums)
        } else {
            for c in checksums {
                print("\(c.crc ?? "—")  \(c.path)")
            }
        }
    case "password":
        guard positional.count >= 3 else { fail(2, "password needs store|forget <archive>") }
        let archivePath = positional[2]
        switch positional[1] {
        case "store":
            // Secure prompt: getpass() disables echo and reads from
            // /dev/tty, so the password never appears in the shell
            // history or the process list.
            guard let first = getpass("Password: "),
                  let second = getpass("Password (again): ") else {
                fail(2, "could not read a password")
            }
            let firstString = String(cString: first)
            guard firstString == String(cString: second) else {
                fail(2, "passwords do not match")
            }
            guard !firstString.isEmpty else { fail(2, "empty password") }
            try PasswordStore.shared.save(password: firstString, for: archivePath)
            #if canImport(Security)
            print("Password stored in Keychain")
            #else
            print("Password stored for this process only (no Keychain on this platform — use SEEKZIP_PASSWORD for later runs)")
            #endif
        case "forget":
            try PasswordStore.shared.forget(archivePath: archivePath)
            print("Password forgotten")
        default:
            fail(2, "unknown password subcommand: \(positional[1])")
        }
    case "queue":
        // M4: `queue add …` only enqueues — the job is persisted and
        // runs when `queue run` executes it. The queue survives the
        // CLI exiting (PERF-06): `queue list` in a later process sees
        // the same jobs.
        let queue = JobQueue(engine: engine)
        guard positional.count >= 2 else { fail(2, "queue needs a subcommand (add|list|pause|resume|cancel|run)") }
        switch positional[1] {
        case "list":
            printJobs(queue.jobs())
        case "add":
            guard positional.count >= 3 else { fail(2, "queue add needs a kind (extract|create|test)") }
            switch positional[2] {
            case "extract":
                guard positional.count >= 5 else { fail(2, "queue add extract needs <archive> <destination> [entries…]") }
                let record = queue.enqueue(JobDescriptor(
                    kind: .extract, archive: positional[3],
                    destination: positional[4],
                    entries: positional.count > 5 ? Array(positional[5...]) : nil),
                    password: envPassword)
                printJobs([record])
            case "create":
                guard positional.count >= 5 else { fail(2, "queue add create needs <archive> <sources…>") }
                let format = formatFlag ?? "zip"
                guard format == "zip" || format == "7z" else { fail(2, "format must be zip or 7z") }
                let record = queue.enqueue(JobDescriptor(
                    kind: .create, archive: positional[3],
                    sources: Array(positional[4...]), format: format),
                    password: envPassword)
                printJobs([record])
            case "test":
                guard positional.count >= 4 else { fail(2, "queue add test needs <archive>") }
                let record = queue.enqueue(JobDescriptor(
                    kind: .test, archive: positional[3]),
                    password: envPassword)
                printJobs([record])
            default:
                fail(2, "unknown job kind: \(positional[2])")
            }
        case "pause", "resume", "cancel":
            guard positional.count >= 3 else { fail(2, "queue \(positional[1]) needs a job id") }
            guard let record = queue.record(matching: positional[2]) else {
                fail(2, "no such job (or ambiguous id): \(positional[2])")
            }
            let ok: Bool
            switch positional[1] {
            case "pause": ok = queue.pause(id: record.id)
            case "resume": ok = queue.resume(id: record.id)
            default: ok = queue.cancel(id: record.id)
            }
            guard ok else { fail(3, "cannot \(positional[1]) job \(shortID(record.id)) in state \(record.status.rawValue)") }
            printJobs([queue.record(for: record.id)!])
        case "run":
            interrupt.onInterrupt = { queue.cancelCurrent() }
            queue.runAll { record, progress in
                let pct = progress.fraction.map { String(format: " %3.0f%%", $0 * 100) } ?? ""
                FileHandle.standardError.write(
                    "seekzip: \(shortID(record.id)) \(record.descriptor.kind.rawValue)\(pct) \(progress.message)\n"
                        .data(using: .utf8)!)
            }
            printJobs(queue.jobs())
            // A failed job must fail the command, so scripts and CI
            // notice it; cancelled is a user decision, not a failure.
            if queue.jobs().contains(where: { $0.status == .failed }) {
                fail(3, "one or more queued jobs failed")
            }
        default:
            fail(2, "unknown queue subcommand: \(positional[1])")
        }
    default:
        fail(2, "unknown command: \(command)")
    }
} catch let v as EntryPathSafety.Violation {
    fail(4, v.description)
} catch {
    fail(3, String(describing: error))
}
