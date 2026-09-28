// DebugLog.swift
// One line per call to ~/Library/Application Support/notchcode/debug.log, only when the
// app was launched with --debug-log. Used for the mode and frame trace the smoke run reads.

import Foundation

/// Appends a line to ~/Library/Application Support/notchcode/debug.log when launched with --debug-log.
func debugLog(_ text: String) {
    guard CommandLine.arguments.contains("--debug-log") else { return }
    let line = "\(Date()) \(text)\n"
    let url = NotchcodePaths.supportDirectory.appendingPathComponent("debug.log")
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
}
