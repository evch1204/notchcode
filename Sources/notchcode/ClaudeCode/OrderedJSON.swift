// OrderedJSON.swift
// A small JSON parser and printer that keeps key order and the original text of strings
// and numbers, so HooksInstaller can edit ~/.claude/settings.json and write back the same
// bytes for everything it did not touch. JSONSerialization loses key order (NSDictionary).

import Foundation

/// JSON that keeps key order and the original text of strings and numbers.
indirect enum OJ {
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

struct OJParser {
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
