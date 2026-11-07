import Foundation
import SeekZipCore

// seekzip-mcp — MCP server (stdio, newline-delimited JSON-RPC 2.0).
// A thin schema layer over SeekZipCore: AI assistants get typed, safe
// tools instead of parsing terminal output. Tools:
//   list_archive    { path, password?, engine? }  (engine: auto|7zz|xad)
//   test_archive    { path, password?, engine? }
//   extract_entries { path, destination, entries?, password?, engine? }
//   list_engines    {}  — engines and the formats each covers
//   create_archive  { path, sources, format?, password? }
//   queue_enqueue   { kind, archive, destination?, entries?, sources?, format?, password? }
//   queue_list      {}
//   queue_pause / queue_resume / queue_cancel { id }
//   add_entries     { path, sources, prefix?, password? }
//   remove_entries  { path, entries, password? }
//   rename_entries  { path, from, to, password? }  (from/to are parallel arrays)
//   convert_archive { path, destination, format?, password? }
//   verify_archive  { path, entries?, sha256?, password? }
// Responses for list/test/extract name the engine that handled the
// archive (`ArchiveInfo.engine` for lists, "(engine: …)" for the rest).
// Queue jobs are persisted (M4, PERF-06) and run on a background
// thread; enqueue returns immediately with the job id.

struct RPCRequest: Decodable {
    let id: Int?
    let method: String
    struct Params: Decodable {
        let name: String?
        let arguments: [String: ArgValue]?
    }
    let params: Params?
}

enum ArgValue: Decodable {
    case string(String)
    case array([String])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s); return }
        self = .array(try c.decode([String].self))
    }
    var string: String? { if case .string(let s) = self { return s }; return nil }
    var array: [String]? { if case .array(let a) = self { return a }; return nil }
}

func send(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          let text = String(data: data, encoding: .utf8) else { return }
    print(text)
    fflush(stdout)
}

func result(id: Int?, _ value: Any) {
    send(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": value])
}

func toolResult(id: Int?, _ text: String, isError: Bool = false) {
    result(id: id, ["content": [["type": "text", "text": text]], "isError": isError])
}

let toolDefs: [[String: Any]] = [
    ["name": "list_archive",
     "description": "List entries of an archive (streaming, safe for very large archives). engine: auto (7zz first, XAD fallback), 7zz or xad.",
     "inputSchema": ["type": "object",
                     "properties": ["path": ["type": "string"], "password": ["type": "string"], "engine": ["type": "string"]],
                     "required": ["path"]]],
    ["name": "test_archive",
     "description": "Verify archive integrity (CRC test). engine: auto, 7zz or xad.",
     "inputSchema": ["type": "object",
                     "properties": ["path": ["type": "string"], "password": ["type": "string"], "engine": ["type": "string"]],
                     "required": ["path"]]],
    ["name": "extract_entries",
     "description": "Extract selected entries (or all) with zip-slip protection. engine: auto, 7zz or xad.",
     "inputSchema": ["type": "object",
                     "properties": ["path": ["type": "string"],
                                    "destination": ["type": "string"],
                                    "entries": ["type": "array", "items": ["type": "string"]],
                                    "password": ["type": "string"],
                                    "engine": ["type": "string"]],
                     "required": ["path", "destination"]]],
    ["name": "list_engines",
     "description": "List the engines (7zz and XAD) and which formats each covers, and whether each is installed.",
     "inputSchema": ["type": "object", "properties": [:]]],
    ["name": "create_archive",
     "description": "Create a ZIP or 7z archive from files/folders.",
     "inputSchema": ["type": "object",
                     "properties": ["path": ["type": "string"],
                                    "sources": ["type": "array", "items": ["type": "string"]],
                                    "format": ["type": "string"],
                                    "password": ["type": "string"]],
                     "required": ["path", "sources"]]],
    ["name": "queue_enqueue",
     "description": "Enqueue an extract/create/test job; it runs on a background thread and survives restarts. Returns the job record.",
     "inputSchema": ["type": "object",
                     "properties": ["kind": ["type": "string"],
                                    "archive": ["type": "string"],
                                    "destination": ["type": "string"],
                                    "entries": ["type": "array", "items": ["type": "string"]],
                                    "sources": ["type": "array", "items": ["type": "string"]],
                                    "format": ["type": "string"],
                                    "password": ["type": "string"]],
                     "required": ["kind", "archive"]]],
    ["name": "queue_list",
     "description": "List persisted queue jobs with their status and progress.",
     "inputSchema": ["type": "object", "properties": [:]]],
    ["name": "queue_pause",
     "description": "Pause a queued or running job (id or unique prefix).",
     "inputSchema": ["type": "object",
                     "properties": ["id": ["type": "string"]],
                     "required": ["id"]]],
    ["name": "queue_resume",
     "description": "Resume a paused or interrupted job.",
     "inputSchema": ["type": "object",
                     "properties": ["id": ["type": "string"]],
                     "required": ["id"]]],
    ["name": "queue_cancel",
     "description": "Cancel a queued, paused or running job.",
     "inputSchema": ["type": "object",
                     "properties": ["id": ["type": "string"]],
                     "required": ["id"]]],
    ["name": "add_entries",
     "description": "Add files to a ZIP, 7z or TAR archive (temp-copy + atomic replace, so a failed edit never corrupts the original). Sources are stored under prefix when given.",
     "inputSchema": ["type": "object",
                     "properties": ["path": ["type": "string"],
                                    "sources": ["type": "array", "items": ["type": "string"]],
                                    "prefix": ["type": "string"],
                                    "password": ["type": "string"]],
                     "required": ["path", "sources"]]],
    ["name": "remove_entries",
     "description": "Remove entries from a ZIP, 7z or TAR archive (temp-copy + atomic replace).",
     "inputSchema": ["type": "object",
                     "properties": ["path": ["type": "string"],
                                    "entries": ["type": "array", "items": ["type": "string"]],
                                    "password": ["type": "string"]],
                     "required": ["path", "entries"]]],
    ["name": "rename_entries",
     "description": "Rename entries in a ZIP or 7z archive. from and to are parallel arrays of the same length.",
     "inputSchema": ["type": "object",
                     "properties": ["path": ["type": "string"],
                                    "from": ["type": "array", "items": ["type": "string"]],
                                    "to": ["type": "array", "items": ["type": "string"]],
                                    "password": ["type": "string"]],
                     "required": ["path", "from", "to"]]],
    ["name": "convert_archive",
     "description": "Convert an archive to ZIP, 7z or TAR (extract to temp, re-create). RAR cannot be created.",
     "inputSchema": ["type": "object",
                     "properties": ["path": ["type": "string"],
                                    "destination": ["type": "string"],
                                    "format": ["type": "string"],
                                    "password": ["type": "string"]],
                     "required": ["path", "destination"]]],
    ["name": "verify_archive",
     "description": "Verify entries one by one: stream each entry, hash it (CRC-32, plus SHA-256 when sha256 is true) and compare with the listing CRC. Bad entries are reported, not fatal to the rest.",
     "inputSchema": ["type": "object",
                     "properties": ["path": ["type": "string"],
                                    "entries": ["type": "array", "items": ["type": "string"]],
                                    "sha256": ["type": "string"],
                                    "password": ["type": "string"]],
                     "required": ["path"]]],
]

/// M6: the router owns both engines. A missing 7zz becomes an
/// unavailable placeholder (so `list_engines` still reports it);
/// XAD is always present as an object but reports unavailable
/// without its binaries.
let sevenZip: any ArchiveEngine = (try? SevenZipEngine())
    ?? UnavailableEngine(id: .sevenZip,
                         capabilities: SevenZipEngine.engineCapabilities)
let xad = XADMasterEngine()
let engine = EngineRouter(engines: [sevenZip, xad])

/// The shared persistent queue (M4). Created from the router so MCP
/// jobs use the same store file as `seekzip queue` on the CLI — and
/// queued extracts route across engines too.
let sharedQueue = JobQueue(engine: engine)

/// Starts the background runner (a no-op when one is already active).
func kickQueue() {
    DispatchQueue.global(qos: .utility).async { sharedQueue.runAll() }
}

func encodeJSON<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return (try? encoder.encode(value))
        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
}

while let line = readLine() {
    guard let data = line.data(using: .utf8),
          let request = try? JSONDecoder().decode(RPCRequest.self, from: data) else { continue }
    switch request.method {
    case "initialize":
        result(id: request.id, ["protocolVersion": "2024-11-05",
                                "serverInfo": ["name": "seekzip", "version": "0.1.0"],
                                "capabilities": ["tools": [:]]])
    case "tools/list":
        result(id: request.id, ["tools": toolDefs])
    case "tools/call":
        guard let name = request.params?.name else {
            toolResult(id: request.id, "missing tool name", isError: true)
            continue
        }
        let a = request.params?.arguments ?? [:]
        // M6: a per-call engine selection ("auto"|"7zz"|"xad"); the
        // router goes back to auto when the call returns. Requests
        // are handled one at a time, so this is safe.
        let previousSelection = engine.defaultSelection
        if let raw = a["engine"]?.string,
           let selection = EngineSelection(rawValue: raw) {
            engine.defaultSelection = selection
        }
        defer { engine.defaultSelection = previousSelection }
        do {
            switch name {
            case "list_archive":
                let info = try engine.list(archive: URL(fileURLWithPath: a["path"]?.string ?? ""),
                                           password: a["password"]?.string)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                toolResult(id: request.id, String(decoding: try encoder.encode(info), as: UTF8.self))
            case "list_engines":
                toolResult(id: request.id, encodeJSON(engine.summaries()))
            case "test_archive":
                try engine.test(archive: URL(fileURLWithPath: a["path"]?.string ?? ""),
                                password: a["password"]?.string)
                toolResult(id: request.id, "Everything is Ok (engine: \(engine.lastEngine?.rawValue ?? "?"))")
            case "extract_entries":
                try engine.extract(archive: URL(fileURLWithPath: a["path"]?.string ?? ""),
                                   entries: a["entries"]?.array,
                                   to: URL(fileURLWithPath: a["destination"]?.string ?? ""),
                                   password: a["password"]?.string)
                toolResult(id: request.id, "Extracted (engine: \(engine.lastEngine?.rawValue ?? "?"))")
            case "create_archive":
                try engine.create(archive: URL(fileURLWithPath: a["path"]?.string ?? ""),
                                  sources: (a["sources"]?.array ?? []).map { URL(fileURLWithPath: $0) },
                                  format: a["format"]?.string ?? "zip",
                                  password: a["password"]?.string)
                toolResult(id: request.id, "Created")
            case "queue_enqueue":
                guard let kind = JobKind(rawValue: a["kind"]?.string ?? "") else {
                    toolResult(id: request.id, "kind must be extract, create or test", isError: true)
                    continue
                }
                let record = sharedQueue.enqueue(JobDescriptor(
                    kind: kind, archive: a["archive"]?.string ?? "",
                    destination: a["destination"]?.string,
                    entries: a["entries"]?.array,
                    sources: a["sources"]?.array,
                    format: a["format"]?.string),
                    password: a["password"]?.string)
                kickQueue()
                toolResult(id: request.id, encodeJSON(record))
            case "queue_list":
                toolResult(id: request.id, encodeJSON(sharedQueue.jobs()))
            case "queue_pause", "queue_resume", "queue_cancel":
                guard let record = sharedQueue.record(matching: a["id"]?.string ?? "") else {
                    toolResult(id: request.id, "no such job (or ambiguous id)", isError: true)
                    continue
                }
                let ok: Bool
                switch name {
                case "queue_pause": ok = sharedQueue.pause(id: record.id)
                case "queue_resume": ok = sharedQueue.resume(id: record.id)
                default: ok = sharedQueue.cancel(id: record.id)
                }
                guard ok else {
                    toolResult(id: request.id,
                               "cannot \(name) job in state \(record.status.rawValue)", isError: true)
                    continue
                }
                toolResult(id: request.id,
                           encodeJSON(sharedQueue.record(for: record.id)!))
            case "add_entries":
                try engine.addEntries(
                    archive: URL(fileURLWithPath: a["path"]?.string ?? ""),
                    sources: (a["sources"]?.array ?? []).map { URL(fileURLWithPath: $0) },
                    prefix: a["prefix"]?.string,
                    password: a["password"]?.string)
                toolResult(id: request.id, "Added")
            case "remove_entries":
                try engine.removeEntries(
                    archive: URL(fileURLWithPath: a["path"]?.string ?? ""),
                    entries: a["entries"]?.array ?? [],
                    password: a["password"]?.string)
                toolResult(id: request.id, "Removed")
            case "rename_entries":
                let from = a["from"]?.array ?? []
                let to = a["to"]?.array ?? []
                guard from.count == to.count else {
                    toolResult(id: request.id, "from and to must have the same length", isError: true)
                    continue
                }
                try engine.renameEntries(
                    archive: URL(fileURLWithPath: a["path"]?.string ?? ""),
                    renames: zip(from, to).map { (old: $0, new: $1) },
                    password: a["password"]?.string)
                toolResult(id: request.id, "Renamed")
            case "convert_archive":
                try engine.convert(
                    archive: URL(fileURLWithPath: a["path"]?.string ?? ""),
                    to: URL(fileURLWithPath: a["destination"]?.string ?? ""),
                    targetFormat: a["format"]?.string,
                    password: a["password"]?.string)
                toolResult(id: request.id, "Converted")
            case "verify_archive":
                let results = try engine.verify(
                    archive: URL(fileURLWithPath: a["path"]?.string ?? ""),
                    entries: a["entries"]?.array,
                    includeSHA256: a["sha256"]?.string == "true",
                    password: a["password"]?.string)
                toolResult(id: request.id, encodeJSON(results))
            default:
                toolResult(id: request.id, "unknown tool: \(name)", isError: true)
            }
        } catch {
            toolResult(id: request.id, String(describing: error), isError: true)
        }
    default:
        if request.id != nil {
            send(["jsonrpc": "2.0", "id": request.id!, "error": ["code": -32601, "message": "method not found"]])
        }
    }
}
