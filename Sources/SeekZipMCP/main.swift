import Foundation
import SeekZipCore

// seekzip-mcp — MCP server (stdio, newline-delimited JSON-RPC 2.0).
// A thin schema layer over SeekZipCore: AI assistants get typed, safe
// tools instead of parsing terminal output. Tools:
//   list_archive    { path, password? }
//   test_archive    { path, password? }
//   extract_entries { path, destination, entries?, password? }
//   create_archive  { path, sources, format?, password? }
//   queue_enqueue   { kind, archive, destination?, entries?, sources?, format?, password? }
//   queue_list      {}
//   queue_pause / queue_resume / queue_cancel { id }
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
     "description": "List entries of an archive (streaming, safe for very large archives).",
     "inputSchema": ["type": "object",
                     "properties": ["path": ["type": "string"], "password": ["type": "string"]],
                     "required": ["path"]]],
    ["name": "test_archive",
     "description": "Verify archive integrity (CRC test).",
     "inputSchema": ["type": "object",
                     "properties": ["path": ["type": "string"], "password": ["type": "string"]],
                     "required": ["path"]]],
    ["name": "extract_entries",
     "description": "Extract selected entries (or all) with zip-slip protection.",
     "inputSchema": ["type": "object",
                     "properties": ["path": ["type": "string"],
                                    "destination": ["type": "string"],
                                    "entries": ["type": "array", "items": ["type": "string"]],
                                    "password": ["type": "string"]],
                     "required": ["path", "destination"]]],
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
]

let engine = try? SevenZipEngine()

/// The shared persistent queue (M4). Created from the same engine so
/// MCP jobs use the same store file as `seekzip queue` on the CLI.
let sharedQueue: JobQueue? = engine.map { JobQueue(engine: $0) }

/// Starts the background runner (a no-op when one is already active).
func kickQueue() {
    guard let sharedQueue else { return }
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
        guard let engine, let name = request.params?.name else {
            toolResult(id: request.id, "engine unavailable (7zz not found)", isError: true)
            continue
        }
        let a = request.params?.arguments ?? [:]
        do {
            switch name {
            case "list_archive":
                let info = try engine.list(archive: URL(fileURLWithPath: a["path"]?.string ?? ""),
                                           password: a["password"]?.string)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                toolResult(id: request.id, String(decoding: try encoder.encode(info), as: UTF8.self))
            case "test_archive":
                try engine.test(archive: URL(fileURLWithPath: a["path"]?.string ?? ""),
                                password: a["password"]?.string)
                toolResult(id: request.id, "Everything is Ok")
            case "extract_entries":
                try engine.extract(archive: URL(fileURLWithPath: a["path"]?.string ?? ""),
                                   entries: a["entries"]?.array,
                                   to: URL(fileURLWithPath: a["destination"]?.string ?? ""),
                                   password: a["password"]?.string)
                toolResult(id: request.id, "Extracted")
            case "create_archive":
                try engine.create(archive: URL(fileURLWithPath: a["path"]?.string ?? ""),
                                  sources: (a["sources"]?.array ?? []).map { URL(fileURLWithPath: $0) },
                                  format: a["format"]?.string ?? "zip",
                                  password: a["password"]?.string)
                toolResult(id: request.id, "Created")
            case "queue_enqueue":
                guard let queue = sharedQueue else {
                    toolResult(id: request.id, "queue unavailable (7zz not found)", isError: true)
                    continue
                }
                guard let kind = JobKind(rawValue: a["kind"]?.string ?? "") else {
                    toolResult(id: request.id, "kind must be extract, create or test", isError: true)
                    continue
                }
                let record = queue.enqueue(JobDescriptor(
                    kind: kind, archive: a["archive"]?.string ?? "",
                    destination: a["destination"]?.string,
                    entries: a["entries"]?.array,
                    sources: a["sources"]?.array,
                    format: a["format"]?.string),
                    password: a["password"]?.string)
                kickQueue()
                toolResult(id: request.id, encodeJSON(record))
            case "queue_list":
                guard let queue = sharedQueue else {
                    toolResult(id: request.id, "queue unavailable (7zz not found)", isError: true)
                    continue
                }
                toolResult(id: request.id, encodeJSON(queue.jobs()))
            case "queue_pause", "queue_resume", "queue_cancel":
                guard let queue = sharedQueue else {
                    toolResult(id: request.id, "queue unavailable (7zz not found)", isError: true)
                    continue
                }
                guard let record = queue.record(matching: a["id"]?.string ?? "") else {
                    toolResult(id: request.id, "no such job (or ambiguous id)", isError: true)
                    continue
                }
                let ok: Bool
                switch name {
                case "queue_pause": ok = queue.pause(id: record.id)
                case "queue_resume": ok = queue.resume(id: record.id)
                default: ok = queue.cancel(id: record.id)
                }
                guard ok else {
                    toolResult(id: request.id,
                               "cannot \(name) job in state \(record.status.rawValue)", isError: true)
                    continue
                }
                toolResult(id: request.id,
                           encodeJSON(queue.record(for: record.id)!))
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
