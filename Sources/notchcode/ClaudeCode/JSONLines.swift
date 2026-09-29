// JSONLines.swift
// Small helpers for reading Claude Code's JSONL transcripts: file identity (stat),
// line splitting, prompt detection shared by the reader and the watcher, and a cache
// that re-parses a transcript incrementally when it only grew.

import Foundation
import Darwin

/// What identifies one version of a file on disk.
struct FileStamp: Equatable {
    var inode: UInt64
    var mtime: Double         // seconds since 1970, with nanoseconds
    var size: Int64

    var modified: Date { Date(timeIntervalSince1970: mtime) }

    init(inode: UInt64, mtime: Double, size: Int64) {
        self.inode = inode
        self.mtime = mtime
        self.size = size
    }

    /// Nil when the file cannot be stat'ed.
    init?(path: String) {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        inode = UInt64(st.st_ino)
        mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        size = Int64(st.st_size)
    }
}

enum JSONLines {

    /// Calls `body` with every complete line (ended by "\\n") of `data` that parses as a JSON
    /// object. Returns the number of bytes consumed: everything up to and including the last
    /// newline. The unterminated remainder, if any, is left for the caller.
    @discardableResult
    static func forEachCompleteLine(_ data: Data, _ body: ([String: Any]) -> Void) -> Int {
        var consumed = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let count = raw.count
            var start = 0
            while start < count {
                guard let hit = memchr(base + start, 0x0A, count - start) else { break }
                let end = base.distance(to: UnsafeRawPointer(hit))
                if end > start {
                    parse(Data(bytes: base + start, count: end - start)).map(body)
                }
                start = end + 1
                consumed = start
            }
        }
        return consumed
    }

    /// One JSON object line, or nil.
    static func parse(_ line: Data) -> [String: Any]? {
        guard !line.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: line, options: [])) as? [String: Any]
    }

    /// Reads `path` from byte `offset` to the end.
    static func read(_ path: String, from offset: Int64) throws -> Data {
        if offset == 0 {
            return try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.readToEnd() ?? Data()
    }

    /// Reads at most `length` bytes of `path` starting at `offset`.
    static func read(_ path: String, from offset: Int64, length: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(0, offset)))
        return try handle.read(upToCount: length) ?? Data()
    }

    // MARK: Prompts

    /// The owner's prompt text for a user line, or nil when the line is a tool result, meta,
    /// an interruption or other noise. Slash commands come back as typed ("/review 12").
    static func promptText(_ line: [String: Any]) -> String? {
        guard (line["type"] as? String) == "user" else { return nil }
        if (line["isMeta"] as? Bool) == true { return nil }
        guard let text = userText(line) else { return nil }
        if text.hasPrefix("[Request interrupted") { return nil }

        // Slash commands are recorded as tags; show them as the owner typed them.
        if let name = tagBody(text, "command-name") {
            let args = tagBody(text, "command-args") ?? ""
            return args.isEmpty ? name : "\(name) \(args)"
        }
        if let cmd = tagBody(text, "bash-input") { return "! \(cmd)" }
        let noise = ["<local-command-stdout>", "<local-command-stderr>", "<local-command-caveat>",
                     "<command-message>", "<task-notification>", "<system-reminder>",
                     "<bash-stdout>", "<bash-stderr>"]
        if noise.contains(where: { text.hasPrefix($0) }) { return nil }
        return text
    }

    /// The trimmed text of a user message that is not a tool result. Nil for tool results
    /// and empty text.
    static func userText(_ line: [String: Any]) -> String? {
        guard let message = line["message"] as? [String: Any] else { return nil }
        var text: String
        if let s = message["content"] as? String {
            text = s
        } else if let blocks = message["content"] as? [[String: Any]] {
            if blocks.contains(where: { ($0["type"] as? String) == "tool_result" }) { return nil }
            text = blocks
                .filter { ($0["type"] as? String) == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
        } else {
            return nil
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func tagBody(_ text: String, _ tag: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        let body = text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }
}

/// Caches a value derived from a JSONL file by feeding its lines to a builder.
/// Unchanged file (same inode, mtime, size): the cached value. File grew in place: only the
/// appended lines are fed to a copy of the saved builder. Anything else (shrunk, replaced,
/// rewritten at the same size): a full re-parse. Claude Code only appends to transcripts.
/// A trailing line without its newline yet is parsed for the returned value but not saved
/// into the builder, so it is read again once complete. Thread-safe.
final class IncrementalCache<Builder, Value> {
    private struct Entry {
        var stamp: FileStamp
        var offset: Int64           // bytes fed to `builder`, always just after a newline
        var builder: Builder
        var value: Value
    }

    private let make: () -> Builder
    private let consume: (inout Builder, [String: Any]) -> Void
    private let finish: (Builder) -> Value
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    init(make: @escaping () -> Builder,
         consume: @escaping (inout Builder, [String: Any]) -> Void,
         finish: @escaping (Builder) -> Value) {
        self.make = make
        self.consume = consume
        self.finish = finish
    }

    func value(for path: String) throws -> Value {
        guard let stamp = FileStamp(path: path) else {
            lock.lock(); entries[path] = nil; lock.unlock()
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: path])
        }
        lock.lock(); defer { lock.unlock() }

        var builder: Builder
        var offset: Int64
        if let e = entries[path] {
            if e.stamp == stamp { return e.value }
            if e.stamp.inode == stamp.inode, stamp.size > e.stamp.size, stamp.size >= e.offset {
                builder = e.builder
                offset = e.offset
            } else {
                builder = make()
                offset = 0
            }
        } else {
            builder = make()
            offset = 0
        }

        let data = try JSONLines.read(path, from: offset)
        let consumed = JSONLines.forEachCompleteLine(data) { consume(&builder, $0) }
        offset += Int64(consumed)

        var forValue = builder
        if consumed < data.count, let tail = JSONLines.parse(data.subdata(in: consumed..<data.count)) {
            consume(&forValue, tail)
        }
        let value = finish(forValue)
        entries[path] = Entry(stamp: stamp, offset: offset, builder: builder, value: value)
        return value
    }

    func forget(_ path: String) {
        lock.lock(); entries[path] = nil; lock.unlock()
    }
}
