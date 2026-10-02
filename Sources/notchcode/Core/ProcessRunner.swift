// ProcessRunner.swift
// Runs one executable off the main thread and awaits it without holding a thread. Shared by
// the Git tool (`/usr/bin/git`) and the Usage tool's `claude -p /usage`. Output goes to
// temporary files rather than pipes, so a large output never fills a pipe and a helper that
// outlives the process (an ssh ControlPersist) never holds the read open. Past the timeout:
// SIGTERM, then SIGKILL after `Theme.Timing.processKillGrace`.

import Foundation

enum ProcessRunner {
    struct Result {
        var status: Int32
        var out: String
        var err: String
        var timedOut = false
    }

    static func run(executable: String,
                    arguments: [String],
                    cwd: String? = nil,
                    environment: [String: String]? = nil,
                    timeout: Double) async -> Result {
        let name = (executable as NSString).lastPathComponent
        let failed = Result(status: -1, out: "", err: "could not run " + name)
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("notchcode-\(name)-" + UUID().uuidString)
        let outURL = base.appendingPathExtension("out")
        let errURL = base.appendingPathExtension("err")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? fm.removeItem(at: outURL)
            try? fm.removeItem(at: errURL)
        }
        guard let outHandle = try? FileHandle(forWritingTo: outURL),
              let errHandle = try? FileHandle(forWritingTo: errURL) else {
            return failed
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true) }
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outHandle
        process.standardError = errHandle

        // Awaits the exit instead of blocking a thread: a semaphore wait here would hold one
        // of Swift's few cooperative threads for up to the whole timeout.
        let timedOut = TimeoutFlag()
        let started: Bool = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            process.terminationHandler = { _ in once.resume(true) }
            do {
                try process.run()
            } catch {
                once.resume(false)
                return
            }
            // Past the timeout: SIGTERM, then SIGKILL after a grace, so a helper that ignores
            // SIGTERM cannot keep the process (and this call) alive.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                timedOut.set()
                process.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Theme.Timing.processKillGrace) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    once.resume(true)
                }
            }
        }
        try? outHandle.close()
        try? errHandle.close()
        guard started else { return failed }

        func text(_ url: URL) -> String {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: Theme.Limits.gitOutputBytes)) ?? nil
            return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        let status = process.isRunning ? -1 : process.terminationStatus
        let wasTimedOut = timedOut.isSet
        return Result(status: wasTimedOut ? -1 : status, out: text(outURL), err: text(errURL), timedOut: wasTimedOut)
    }

    /// Resumes a continuation once, whichever of exit or timeout comes first.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func resume(_ value: Bool) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: value)
        }
    }

    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
}
