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

/// Parses flags out of the arguments. `--format` takes a value; `--json`
/// and `--stream` do not. Everything else is positional, in order.
var formatFlag: String?
var positional: [String] = []
do {
    var i = rawArgs.startIndex
    while i < rawArgs.endIndex {
        let a = rawArgs[i]
        if a == "--format", rawArgs.index(after: i) < rawArgs.endIndex {
            formatFlag = rawArgs[rawArgs.index(after: i)]
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
    print("usage: seekzip <list|test|extract|create|preview|queue> [--json|--stream] <archive> [args…]")
    print("  list <archive> [nested-entry…]   list an archive, or an archive inside it")
    print("  preview <archive> <entry>        preview one entry (text inline, else Quick Look)")
    print("  preview <archive> <a!/b!/entry>  preview an entry inside nested archives")
    print("  queue add extract <archive> <dest> [entries…]")
    print("  queue add create <archive> <sources…> [--format zip|7z]")
    print("  queue add test <archive>         enqueue a job (it does not run yet)")
    print("  queue list [--json]              show persisted jobs")
    print("  queue pause|resume|cancel <id>   id may be a unique prefix")
    print("  queue run [--json]               run queued jobs in order (Ctrl-C cancels the running job)")
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
            let info = try engine.listNested(archive: url, nestedPath: nested)
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
            let info = try engine.listStreaming(archive: url, control: directControl) { entry in
                emitJSON(entry)
                return true
            }
            FileHandle.standardError.write("seekzip: \(info.entries.count) entries, \(info.totalUncompressed) bytes uncompressed\n".data(using: .utf8)!)
            break
        }
        let info = try engine.list(archive: url, control: directControl)
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
            let info = try engine.listNested(archive: archiveURL, nestedPath: nested)
            guard let entry = info.entries.first(where: { $0.path == leaf }) else {
                fail(3, "entry not found: \(entryPath)")
            }
            printPreview(try provider.previewNested(archive: archiveURL,
                                                    nestedPath: nested, entry: entry))
            break
        }
        let info = try engine.list(archive: archiveURL, control: directControl)
        guard let entry = info.entries.first(where: { $0.path == entryPath }) else {
            fail(3, "entry not found: \(entryPath)")
        }
        printPreview(try provider.preview(archive: archiveURL, entry: entry))
    case "test":
        guard positional.count >= 2 else { fail(2, "test needs an archive path") }
        try engine.test(archive: URL(fileURLWithPath: positional[1]),
                        control: directControl)
        print(json ? "{\"ok\":true}" : "Everything is Ok")
    case "extract":
        guard positional.count >= 3 else { fail(2, "extract needs <archive> <destination> [entry…]") }
        let entries = positional.count > 3 ? Array(positional[3...]) : nil
        try engine.extract(archive: URL(fileURLWithPath: positional[1]),
                           entries: entries,
                           to: URL(fileURLWithPath: positional[2]),
                           control: directControl)
        print(json ? "{\"ok\":true}" : "Extracted")
    case "create":
        guard positional.count >= 3 else { fail(2, "create needs <archive> <source…>") }
        try engine.create(archive: URL(fileURLWithPath: positional[1]),
                          sources: positional[2...].map { URL(fileURLWithPath: $0) },
                          format: formatFlag ?? "zip",
                          control: directControl)
        print(json ? "{\"ok\":true}" : "Created")
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
                    entries: positional.count > 5 ? Array(positional[5...]) : nil))
                printJobs([record])
            case "create":
                guard positional.count >= 5 else { fail(2, "queue add create needs <archive> <sources…>") }
                let format = formatFlag ?? "zip"
                guard format == "zip" || format == "7z" else { fail(2, "format must be zip or 7z") }
                let record = queue.enqueue(JobDescriptor(
                    kind: .create, archive: positional[3],
                    sources: Array(positional[4...]), format: format))
                printJobs([record])
            case "test":
                guard positional.count >= 4 else { fail(2, "queue add test needs <archive>") }
                let record = queue.enqueue(JobDescriptor(
                    kind: .test, archive: positional[3]))
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
