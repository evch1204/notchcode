// TextLines.swift
// Line splitting and path helpers shared by every reader of file text.
// In Swift "\r\n" is one Character, so `split(separator: "\n")` and `hasSuffix("\n")` miss
// CRLF line ends and a Windows file reads as one line. These work on unicode scalars and
// treat "\n", "\r\n" and a lone "\r" as one line break each.

import Foundation
import Darwin

extension StringProtocol {
    /// The text between line breaks ("\n", "\r\n" or "\r"), breaks removed. Like
    /// `split(separator: "\n", omittingEmptySubsequences:)`: "a\n" gives ["a", ""].
    /// `breaksOnLoneCR: false` keeps a lone "\r" inside its line, as git does (for diff text).
    func splitLines(omittingEmptySubsequences: Bool = false, breaksOnLoneCR: Bool = true) -> [SubSequence] {
        var lines: [SubSequence] = []
        let scalars = unicodeScalars
        var start = startIndex
        var i = scalars.startIndex
        while i < scalars.endIndex {
            let scalar = scalars[i]
            guard scalar == "\n" || scalar == "\r" else {
                i = scalars.index(after: i)
                continue
            }
            var next = scalars.index(after: i)
            if scalar == "\r" {
                if next < scalars.endIndex, scalars[next] == "\n" {
                    next = scalars.index(after: next)
                } else if !breaksOnLoneCR {
                    i = next
                    continue
                }
            }
            if !(omittingEmptySubsequences && start == i) { lines.append(self[start..<i]) }
            start = next
            i = next
        }
        if !(omittingEmptySubsequences && start == endIndex) { lines.append(self[start..<endIndex]) }
        return lines
    }

    /// Ends with "\n", "\r\n" or "\r".
    var endsWithNewline: Bool {
        guard let last = unicodeScalars.last else { return false }
        return last == "\n" || last == "\r"
    }

    /// The lines of a text file: "" is none, and a final line break does not add an empty line.
    var fileLines: [SubSequence] {
        guard !isEmpty else { return [] }
        var lines = splitLines()
        if endsWithNewline { lines.removeLast() }
        return lines
    }
}

/// Paths as the hooks and transcripts give them: absolute, or relative to a session's cwd.
enum Paths {
    /// `path` relative to `cwd` when it lies inside it; otherwise unchanged.
    static func relative(_ path: String, cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return path }
        let base = cwd.hasSuffix("/") ? cwd : cwd + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    /// `path` made absolute against `cwd` ("." and ".." resolved); absolute paths and an
    /// empty cwd leave it unchanged. Never touches the disk.
    static func absolute(_ path: String, cwd: String) -> String {
        if path.hasPrefix("/") || cwd.isEmpty { return path }
        return URL(fileURLWithPath: cwd, isDirectory: true)
            .appendingPathComponent(path, isDirectory: false).standardizedFileURL.path
    }
}

/// Opens files the app only reads (permission diffs, previews, line counts). Anything but a
/// regular file is refused: reading a FIFO or a device blocks forever. Symlinks are followed,
/// and the checks apply to the file they point at.
enum RegularFile {
    /// A handle on `path` when it is a regular file of at most `maxBytes` (no cap when nil).
    /// Opened non-blocking and checked with fstat on the open descriptor, so a path swapped
    /// for a FIFO between a check and the open cannot block either.
    static func open(_ path: String, maxBytes: Int? = nil) -> FileHandle? {
        let fd = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              maxBytes.map({ Int64(st.st_size) <= Int64($0) }) ?? true
        else {
            close(fd)
            return nil
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// True when `path` (followed through symlinks) is a regular file.
    static func isRegular(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }
}
