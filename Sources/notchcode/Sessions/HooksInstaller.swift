// HooksInstaller.swift
// Adds and removes notchcode's hooks in ~/.claude/settings.json, so the Settings window
// can connect and disconnect without Node. Same rules as scripts/lib/settings.mjs:
//
//   - back up to settings.json.notchcode-backup-<timestamp> before any write
//   - add or replace only hook entries whose command contains "notchcode-hook.sh"
//   - never touch any other entry; an event key is removed only when it ends up empty
//   - 2-space pretty print, top-level and nested key order kept exactly
//   - statusLine: ours (notchcode-statusline.sh) replaces whatever was there, which is saved
//     first in ~/Library/Application Support/notchcode/statusline-chain.json as
//     {"previous": <old statusLine>} and keeps running through ours. Disconnect puts it back
//     (or removes the key when there was none) and deletes the chain file.
//
// JSONSerialization loses key order (NSDictionary), so this file carries a small ordered
// JSON parser and printer. Untouched strings and numbers are written back from their
// original text, so a connect followed by a disconnect gives back the same bytes
// (for a file that was already 2-space formatted, as Claude Code and Node write it).
//
// The table of hooks must match wantedHooks() in scripts/lib/settings.mjs and
// plugin/hooks/hooks.json; the statusLine logic matches planStatusLine() there.

import Foundation

enum HooksInstaller {
    enum Status { case connected, notConnected, partial }

    enum InstallError: LocalizedError {
        case invalidJSON(String)
        case notAnObject(String)
        case hookScriptMissing(String)
        case chainUnreadable(String)

        var errorDescription: String? {
            switch self {
            case .invalidJSON(let why): return "settings.json is not valid JSON: \(why)"
            case .notAnObject(let what): return "\(what) in settings.json is not a JSON object; not touching it"
            case .hookScriptMissing(let path): return "hook script missing: \(path)"
            case .chainUnreadable(let path): return "the saved status line in \(path) is not readable; not touching the status line"
            }
        }
    }

    static let marker = "notchcode-hook.sh"
    static let statuslineMarker = "notchcode-statusline.sh"
    /// Keys of the previous statusLine that shape how it looks; ours copies them (same order as settings.mjs).
    private static let carriedStatusLineKeys = ["padding", "refreshInterval"]

    static var settingsPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json").path
    }

    /// Where the statusLine that was there before ours is saved. notchcode-statusline.sh reads it.
    static var chainPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/notchcode/statusline-chain.json").path
    }

    /// The real settings file uses chainPath; any other (a test copy) gets its own chain file
    /// beside it, so a test never touches the real one. Same rule as chainPathFor() in settings.mjs.
    static func chainPath(forSettings path: String) -> String {
        let p = (path as NSString).standardizingPath
        return p == (settingsPath as NSString).standardizingPath ? chainPath : path + ".notchcode-statusline-chain.json"
    }

    /// The status line script inside the app bundle, or the repo's hooks/ folder when running unbundled.
    static var statuslineScriptPath: String {
        if let url = Bundle.main.url(forResource: "notchcode-statusline", withExtension: "sh") { return url.path }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("hooks/notchcode-statusline.sh").path
    }

    /// The hook script inside the app bundle, or the repo's hooks/ folder when running unbundled.
    static var hookScriptPath: String {
        if let url = Bundle.main.url(forResource: "notchcode-hook", withExtension: "sh") { return url.path }
        // Sources/notchcode/Sessions/HooksInstaller.swift -> <repo>/hooks/notchcode-hook.sh
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("hooks/notchcode-hook.sh").path
    }

    // MARK: Public

    static func status() -> Status { status(settingsPath: settingsPath) }
    static func connect() throws { try connect(settingsPath: settingsPath) }
    static func disconnect() throws { try disconnect(settingsPath: settingsPath) }

    /// Connected means every hook and the statusLine are ours; partial means some are.
    static func status(settingsPath path: String) -> Status {
        guard let file = try? readSettings(path), case .object(let top) = file.root else { return .notConnected }
        var hooks: [OJ.Member] = []
        if let h = top.first(where: { $0.key == "hooks" })?.value, case .object(let m) = h { hooks = m }
        let events = wantedEventNames
        let present = events.filter { event in
            guard let groups = hooks.first(where: { $0.key == event })?.value,
                  case .array(let list) = groups else { return false }
            return list.contains(where: groupHasOurs)
        }
        let line = top.first(where: { $0.key == "statusLine" })?.value
        let lineOurs = line.map(isOurStatusLine) ?? false
        let count = present.count + (lineOurs ? 1 : 0)
        if count == events.count + 1 { return .connected }
        return count == 0 ? .notConnected : .partial
    }

    static func connect(settingsPath path: String, hookScript: String? = nil,
                        statuslineScript: String? = nil, chainPath chainOverride: String? = nil) throws {
        let script = hookScript ?? hookScriptPath
        guard FileManager.default.fileExists(atPath: script) else { throw InstallError.hookScriptMissing(script) }
        let lineScript = statuslineScript ?? statuslineScriptPath
        guard FileManager.default.fileExists(atPath: lineScript) else { throw InstallError.hookScriptMissing(lineScript) }
        let chain = chainOverride ?? chainPath(forSettings: path)

        // A script without the executable bit (for example one copied into a bundle that
        // lost it) is run through sh instead. The bundle itself is never modified.
        func runnable(_ script: String) -> String {
            let quoted = shellQuote(script)
            return FileManager.default.isExecutableFile(atPath: script) ? quoted : "/bin/sh \(quoted)"
        }
        let prefix = runnable(script)
        let wanted = wantedHooks { kind in "\(prefix) \(kind)" }
        // A non-default chain file is handed to the script in NOTCHCODE_CHAIN.
        let lineCommand = (chain as NSString).standardizingPath == (chainPath as NSString).standardizingPath
            ? runnable(lineScript)
            : "NOTCHCODE_CHAIN=\(shellQuote(chain)) \(runnable(lineScript))"

        var file = try readSettings(path)
        guard case .object(var top) = file.root else { throw InstallError.notAnObject("the top level") }
        let before = file.root

        var hooks: [OJ.Member] = []
        if let i = top.firstIndex(where: { $0.key == "hooks" }) {
            guard case .object(let h) = top[i].value else { throw InstallError.notAnObject("\"hooks\"") }
            hooks = h
        }

        for (event, group) in wanted {
            let existingIndex = hooks.firstIndex(where: { $0.key == event })
            var existing: [OJ] = []
            if let i = existingIndex, case .array(let a) = hooks[i].value { existing = a }
            let stripped = stripOurs(existing)
            let oldOurs = existing.filter(groupHasOurs)
            if stripped.removed == 1, oldOurs.count == 1, oldOurs[0].canonical == group.canonical { continue }

            var groups = stripped.groups
            groups.insert(group, at: stripped.firstIndex ?? groups.count)
            if let i = existingIndex {
                hooks[i].value = .array(groups)
            } else {
                hooks.append(OJ.Member(key: event, value: .array(groups)))
            }
        }

        // Our entries on events we no longer install (older versions).
        let wantedNames = Set(wanted.map(\.0))
        hooks = hooks.compactMap { member in
            guard !wantedNames.contains(member.key), case .array(let a) = member.value else { return member }
            let stripped = stripOurs(a)
            if stripped.removed == 0 { return member }
            if stripped.groups.isEmpty { return nil }
            var m = member
            m.value = .array(stripped.groups)
            return m
        }

        if let i = top.firstIndex(where: { $0.key == "hooks" }) {
            top[i].value = .object(hooks)
        } else {
            top.append(OJ.Member(key: "hooks", value: .object(hooks)))
        }

        // statusLine: ours, with the previous one chained.
        enum ChainPlan { case keep, write(OJ), remove }
        var chainPlan = ChainPlan.keep
        let lineIndex = top.firstIndex(where: { $0.key == "statusLine" })
        if let i = lineIndex, isOurStatusLine(top[i].value) {
            // Already ours: only bring the command up to date.
            if case .object(var m) = top[i].value, let c = m.firstIndex(where: { $0.key == "command" }),
               m[c].value.canonical != OJ.string(lineCommand).canonical {
                m[c].value = .string(lineCommand)
                top[i].value = .object(m)
            }
        } else {
            var ours: [OJ.Member] = [.init(key: "type", value: .string("command")),
                                     .init(key: "command", value: .string(lineCommand))]
            if let i = lineIndex, case .object(let old) = top[i].value {
                for key in carriedStatusLineKeys {
                    if let m = old.first(where: { $0.key == key }) { ours.append(.init(key: key, value: m.value)) }
                }
            }
            if let i = lineIndex {
                chainPlan = .write(top[i].value)
                top[i].value = .object(ours)
            } else {
                chainPlan = .remove
                top.append(OJ.Member(key: "statusLine", value: .object(ours)))
            }
        }

        file.root = .object(top)
        if file.existed, file.root.canonical == before.canonical { return }
        // Chain file first: the status line must never point at ours before the old one is saved.
        switch chainPlan {
        case .keep: break
        case .write(let previous): try writeChain(chain, previous: previous)
        case .remove: try? FileManager.default.removeItem(atPath: chain)
        }
        try writeSettings(path, file)
    }

    static func disconnect(settingsPath path: String, chainPath chainOverride: String? = nil) throws {
        var file = try readSettings(path)
        guard file.existed else { return }
        guard case .object(var top) = file.root else { throw InstallError.notAnObject("the top level") }
        let chain = chainOverride ?? chainPath(forSettings: path)

        var changed = false
        var restored = false

        // statusLine: put back the saved one, or remove ours when there was none.
        // A statusLine that is not ours (changed by hand since) is left alone.
        if let li = top.firstIndex(where: { $0.key == "statusLine" }), isOurStatusLine(top[li].value) {
            if let previous = try readChain(chain) {
                top[li].value = previous
            } else {
                top.remove(at: li)
            }
            changed = true
            restored = true
        }

        if let hi = top.firstIndex(where: { $0.key == "hooks" }), case .object(let hooks) = top[hi].value {
            var hooksChanged = false
            let kept: [OJ.Member] = hooks.compactMap { member in
                guard case .array(let a) = member.value else { return member }
                let stripped = stripOurs(a)
                if stripped.removed == 0 { return member }
                hooksChanged = true
                if stripped.groups.isEmpty { return nil }
                var m = member
                m.value = .array(stripped.groups)
                return m
            }
            if hooksChanged {
                top[hi].value = .object(kept)   // left as {} when empty, like disconnect.mjs
                changed = true
            }
        }
        guard changed else { return }
        file.root = .object(top)
        try writeSettings(path, file)
        // Chain file last: until settings.json is written, ours may still run and needs it.
        if restored { try? FileManager.default.removeItem(atPath: chain) }
    }

    // MARK: The hooks we install

    private static var wantedEventNames: [String] { wantedHooks { $0 }.map(\.0) }

    /// Mirrors wantedHooks() in scripts/lib/settings.mjs, same order, same key order.
    private static func wantedHooks(_ cmd: (String) -> String) -> [(String, OJ)] {
        func handler(_ kind: String, timeout: Int, async: Bool, ifRule: String? = nil) -> OJ {
            var m: [OJ.Member] = [.init(key: "type", value: .string("command"))]
            if let ifRule { m.append(.init(key: "if", value: .string(ifRule))) }
            m.append(.init(key: "command", value: .string(cmd(kind))))
            m.append(.init(key: "timeout", value: .number(String(timeout))))
            if async { m.append(.init(key: "async", value: .bool(true))) }
            return .object(m)
        }
        func group(_ matcher: String?, _ h: OJ) -> OJ {
            var m: [OJ.Member] = []
            if let matcher { m.append(.init(key: "matcher", value: .string(matcher))) }
            m.append(.init(key: "hooks", value: .array([h])))
            return .object(m)
        }
        func passive(_ kind: String) -> OJ { handler(kind, timeout: 5, async: true) }
        return [
            ("PermissionRequest", group(nil, handler("permission", timeout: 65, async: false))),
            ("PreToolUse", group("Bash", handler("pre_tool", timeout: 65, async: false, ifRule: "Bash(git commit *)"))),
            ("PostToolUse", group("Edit|Write|MultiEdit|Bash", passive("post_tool"))),
            ("Notification", group(nil, passive("notification"))),
            ("Stop", group(nil, passive("stop"))),
            ("SessionStart", group(nil, passive("session_start"))),
            ("SessionEnd", group(nil, passive("session_end"))),
            ("UserPromptSubmit", group(nil, passive("user_prompt"))),
            ("SubagentStart", group(nil, passive("subagent_start"))),
            ("SubagentStop", group(nil, passive("subagent_stop"))),
        ]
    }

    // MARK: Ours vs theirs

    private static func isOurs(_ hook: OJ) -> Bool {
        guard case .object(let m) = hook,
              let c = m.first(where: { $0.key == "command" })?.value,
              case .string(let s, _) = c else { return false }
        return s.contains(marker)
    }

    private static func isOurStatusLine(_ line: OJ) -> Bool {
        guard case .object(let m) = line,
              let c = m.first(where: { $0.key == "command" })?.value,
              case .string(let s, _) = c else { return false }
        return s.contains(statuslineMarker)
    }

    private static func hooksList(_ group: OJ) -> [OJ]? {
        guard case .object(let m) = group,
              let h = m.first(where: { $0.key == "hooks" })?.value,
              case .array(let list) = h else { return nil }
        return list
    }

    private static func groupHasOurs(_ group: OJ) -> Bool {
        hooksList(group)?.contains(where: isOurs) ?? false
    }

    /// Drops our hooks from each group; a group left with no hooks is dropped too.
    private static func stripOurs(_ groups: [OJ]) -> (groups: [OJ], firstIndex: Int?, removed: Int) {
        var out: [OJ] = []
        var first: Int?
        var removed = 0
        for group in groups {
            guard let list = hooksList(group), list.contains(where: isOurs),
                  case .object(var members) = group else { out.append(group); continue }
            if first == nil { first = out.count }
            let kept = list.filter { !isOurs($0) }
            removed += list.count - kept.count
            if kept.isEmpty { continue }
            if let i = members.firstIndex(where: { $0.key == "hooks" }) { members[i].value = .array(kept) }
            out.append(.object(members))
        }
        return (out, first, removed)
    }

    private static func shellQuote(_ s: String) -> String {
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./:@%+=-")
        if !s.isEmpty, s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Chain file

    /// The saved statusLine, verbatim; nil when no chain file exists or it saved none.
    /// A chain file that exists but cannot be parsed throws, so the status line is not guessed at.
    private static func readChain(_ path: String) throws -> OJ? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        guard let root = try? OJParser.parse(Array(data)), case .object(let m) = root else {
            throw InstallError.chainUnreadable(path)
        }
        return m.first(where: { $0.key == "previous" })?.value
    }

    /// Writes {"previous": <statusLine>} atomically, in the same layout as settings.mjs.
    private static func writeChain(_ path: String, previous: OJ) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let text = OJ.object([.init(key: "previous", value: previous)]).pretty(indent: 0) + "\n"
        let tmp = "\(path).tmp-\(getpid())"
        guard fm.createFile(atPath: tmp, contents: Data(text.utf8)) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmp])
        }
        if rename(tmp, path) != 0 {
            let err = errno
            try? fm.removeItem(atPath: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
    }

    // MARK: File

    private struct SettingsFile {
        var root: OJ
        var existed: Bool
        var trailingNewline: Bool
    }

    private static func readSettings(_ path: String) throws -> SettingsFile {
        guard FileManager.default.fileExists(atPath: path) else {
            return SettingsFile(root: .object([]), existed: false, trailingNewline: true)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let text = String(decoding: data, as: UTF8.self)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SettingsFile(root: .object([]), existed: true, trailingNewline: true)
        }
        let root = try OJParser.parse(Array(data))
        guard case .object = root else { throw InstallError.notAnObject("the top level") }
        return SettingsFile(root: root, existed: true, trailingNewline: text.hasSuffix("\n"))
    }

    /// Backs up (when the file exists), then writes atomically, keeping the file mode.
    private static func writeSettings(_ path: String, _ file: SettingsFile) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var mode: Int = 0o600
        if file.existed {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let stamp = f.string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
                .replacingOccurrences(of: ".", with: "-")
            try fm.copyItem(atPath: path, toPath: "\(path).notchcode-backup-\(stamp)")
            if let m = (try? fm.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber {
                mode = m.intValue & 0o777
            }
        }
        var text = file.root.pretty(indent: 0)
        if file.trailingNewline { text += "\n" }
        let tmp = "\(path).notchcode-tmp-\(getpid())"
        guard fm.createFile(atPath: tmp, contents: Data(text.utf8), attributes: [.posixPermissions: mode]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmp])
        }
        if rename(tmp, path) != 0 {
            let err = errno
            try? fm.removeItem(atPath: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
    }
}

// MARK: - Ordered JSON

/// JSON that keeps key order and the original text of strings and numbers.
private indirect enum OJ {
    struct Member { var key: String; var rawKey: String?; var value: OJ
        init(key: String, rawKey: String? = nil, value: OJ) { self.key = key; self.rawKey = rawKey; self.value = value }
    }
    case object([Member])
    case array([OJ])
    case string(String, raw: String?)   // raw: the literal as written, quotes included
    case number(String)                 // the literal as written
    case bool(Bool)
    case null

    static func string(_ s: String) -> OJ { .string(s, raw: nil) }

    /// Compact text for equality checks (decoded strings, keys in order).
    var canonical: String {
        switch self {
        case .object(let m): return "{" + m.map { OJ.quote($0.key) + ":" + $0.value.canonical }.joined(separator: ",") + "}"
        case .array(let a): return "[" + a.map(\.canonical).joined(separator: ",") + "]"
        case .string(let s, _): return OJ.quote(s)
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        }
    }

    /// Same layout as JSON.stringify(value, null, 2).
    func pretty(indent: Int) -> String {
        let pad = String(repeating: "  ", count: indent)
        let inner = String(repeating: "  ", count: indent + 1)
        switch self {
        case .object(let m):
            if m.isEmpty { return "{}" }
            let body = m.map { inner + ($0.rawKey ?? OJ.quote($0.key)) + ": " + $0.value.pretty(indent: indent + 1) }
            return "{\n" + body.joined(separator: ",\n") + "\n" + pad + "}"
        case .array(let a):
            if a.isEmpty { return "[]" }
            return "[\n" + a.map { inner + $0.pretty(indent: indent + 1) }.joined(separator: ",\n") + "\n" + pad + "]"
        case .string(let s, let raw): return raw ?? OJ.quote(s)
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        }
    }

    /// JSON.stringify's string escaping.
    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }
}

private struct OJParser {
    private let b: [UInt8]
    private var i = 0

    static func parse(_ bytes: [UInt8]) throws -> OJ {
        var p = OJParser(b: bytes)
        if p.b.starts(with: [0xEF, 0xBB, 0xBF]) { p.i = 3 }   // UTF-8 BOM
        let v = try p.value()
        p.skip()
        guard p.i == p.b.count else { throw p.fail("unexpected text after the value") }
        return v
    }

    private init(b: [UInt8]) { self.b = b }

    private func fail(_ why: String) -> HooksInstaller.InstallError { .invalidJSON("\(why) at byte \(i)") }

    private mutating func skip() {
        while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
    }

    private mutating func value() throws -> OJ {
        skip()
        guard i < b.count else { throw fail("unexpected end") }
        switch b[i] {
        case UInt8(ascii: "{"):
            i += 1
            var members: [OJ.Member] = []
            skip()
            if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
            while true {
                skip()
                guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw fail("expected a key") }
                let (key, raw) = try string()
                skip()
                guard i < b.count, b[i] == UInt8(ascii: ":") else { throw fail("expected ':'") }
                i += 1
                members.append(OJ.Member(key: key, rawKey: raw, value: try value()))
                skip()
                guard i < b.count else { throw fail("unexpected end") }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                throw fail("expected ',' or '}'")
            }
        case UInt8(ascii: "["):
            i += 1
            var items: [OJ] = []
            skip()
            if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                items.append(try value())
                skip()
                guard i < b.count else { throw fail("unexpected end") }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                throw fail("expected ',' or ']'")
            }
        case UInt8(ascii: "\""):
            let (s, raw) = try string()
            return .string(s, raw: raw)
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        default:
            let start = i
            while i < b.count, "+-0123456789.eE".utf8.contains(b[i]) { i += 1 }
            guard i > start else { throw fail("unexpected character") }
            let text = String(decoding: b[start..<i], as: UTF8.self)
            guard Double(text) != nil else { throw fail("bad number") }
            return .number(text)
        }
    }

    private mutating func literal(_ word: String) throws {
        let w = Array(word.utf8)
        guard i + w.count <= b.count, Array(b[i..<i + w.count]) == w else { throw fail("unexpected character") }
        i += w.count
    }

    /// Returns the decoded string and its raw literal (quotes included).
    private mutating func string() throws -> (String, String) {
        let start = i
        i += 1
        var scalars = String.UnicodeScalarView()
        var chunk = i
        func flush(_ end: Int) { scalars.append(contentsOf: String(decoding: b[chunk..<end], as: UTF8.self).unicodeScalars) }
        while true {
            guard i < b.count else { throw fail("unterminated string") }
            let c = b[i]
            if c == UInt8(ascii: "\"") {
                flush(i)
                i += 1
                return (String(scalars), String(decoding: b[start..<i], as: UTF8.self))
            }
            if c < 0x20 { throw fail("control character in string") }
            guard c == UInt8(ascii: "\\") else { i += 1; continue }
            flush(i)
            i += 1
            guard i < b.count else { throw fail("unterminated string") }
            let e = b[i]
            i += 1
            switch e {
            case UInt8(ascii: "\""): scalars.append("\"")
            case UInt8(ascii: "\\"): scalars.append("\\")
            case UInt8(ascii: "/"): scalars.append("/")
            case UInt8(ascii: "b"): scalars.append("\u{08}")
            case UInt8(ascii: "f"): scalars.append("\u{0C}")
            case UInt8(ascii: "n"): scalars.append("\n")
            case UInt8(ascii: "r"): scalars.append("\r")
            case UInt8(ascii: "t"): scalars.append("\t")
            case UInt8(ascii: "u"):
                var code = try hex4()
                if (0xD800...0xDBFF).contains(code), i + 1 < b.count, b[i] == UInt8(ascii: "\\"), b[i + 1] == UInt8(ascii: "u") {
                    let save = i
                    i += 2
                    let low = try hex4()
                    if (0xDC00...0xDFFF).contains(low) {
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        i = save
                    }
                }
                scalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
            default:
                throw fail("bad escape")
            }
            chunk = i
        }
    }

    private mutating func hex4() throws -> UInt32 {
        guard i + 4 <= b.count, let v = UInt32(String(decoding: b[i..<i + 4], as: UTF8.self), radix: 16) else {
            throw fail("bad \\u escape")
        }
        i += 4
        return v
    }
}
