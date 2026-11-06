import Foundation
import SeekZipCore

// seekzip — command-line frontend for SeekZipCore.
// Exit codes: 0 ok · 2 usage · 3 engine error · 4 safety-blocked · 5 password

let args = Array(CommandLine.arguments.dropFirst())
let json = args.contains("--json")
let stream = args.contains("--stream")
let positional = args.filter { !$0.hasPrefix("--") }

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

guard let command = positional.first else {
    print("usage: seekzip <list|test|extract|create> [--json|--stream] <archive> [args…]")
    exit(2)
}

do {
    let engine = try SevenZipEngine()
    switch command {
    case "list":
        guard positional.count >= 2 else { fail(2, "list needs an archive path") }
        let url = URL(fileURLWithPath: positional[1])
        if stream {
            // M2: one JSON object per entry, printed as it arrives; the
            // summary goes to stderr so stdout stays pure JSON lines.
            // If 7zz fails after some entries were printed, the exit
            // code still reports the failure — treat a non-zero exit
            // as an incomplete listing.
            let info = try engine.listStreaming(archive: url) { entry in
                emitJSON(entry)
                return true
            }
            FileHandle.standardError.write("seekzip: \(info.entries.count) entries, \(info.totalUncompressed) bytes uncompressed\n".data(using: .utf8)!)
            break
        }
        let info = try engine.list(archive: url)
        if json { emitJSON(info) }
        else {
            for e in info.entries {
                print("\(e.isDirectory ? "d" : "-") \(String(format: "%12d", e.size))  \(e.path)")
            }
            print("\(info.entries.count) entries, \(info.totalUncompressed) bytes uncompressed")
        }
    case "test":
        guard positional.count >= 2 else { fail(2, "test needs an archive path") }
        try engine.test(archive: URL(fileURLWithPath: positional[1]))
        print(json ? "{\"ok\":true}" : "Everything is Ok")
    case "extract":
        guard positional.count >= 3 else { fail(2, "extract needs <archive> <destination> [entry…]") }
        let entries = positional.count > 3 ? Array(positional[3...]) : nil
        try engine.extract(archive: URL(fileURLWithPath: positional[1]),
                           entries: entries,
                           to: URL(fileURLWithPath: positional[2]))
        print(json ? "{\"ok\":true}" : "Extracted")
    case "create":
        guard positional.count >= 3 else { fail(2, "create needs <archive> <source…>") }
        try engine.create(archive: URL(fileURLWithPath: positional[1]),
                          sources: positional[2...].map { URL(fileURLWithPath: $0) })
        print(json ? "{\"ok\":true}" : "Created")
    default:
        fail(2, "unknown command: \(command)")
    }
} catch let v as EntryPathSafety.Violation {
    fail(4, v.description)
} catch {
    fail(3, String(describing: error))
}
